"""
traffic_fd.py - Traffic Flow Fundamental Diagram Explorer (Python component)

  python traffic_fd.py --csv                     # analyse ../data/traffic_data.csv (no database needed)
  python traffic_fd.py --mysql                   # read from MySQL, write fits back to model_fit
  python traffic_fd.py --predict S2 --density 90 # live what-if: speed, flow, regime at a density

Pipeline: load -> clean -> fit 3 speed-density models (least squares) -> capacity & critical
density -> regime thresholds -> KMeans cross-check -> congestion runs -> figures.
"""
import argparse, os, sys, json
import numpy as np, pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
FIG = os.path.join(HERE, "..", "figures")
LOWER, UPPER = 0.75, 1.25            # regime band around critical density k_c
DB = dict(host="localhost", user="root", password="", database="traffic_fd")   # edit for your server
E = np.e

# ------------------------------------------------------------------ data access
def load_csv():
    d = pd.read_csv(os.path.join(HERE, "..", "data", "traffic_data.csv"), parse_dates=["obs_time"])
    seg = pd.read_csv(os.path.join(HERE, "..", "data", "segments.csv")).set_index("segment_code")
    # same rules as sp_flag_quality in SQL
    kv = d.density_vpkm * d.speed_kmh
    lim = d.segment_code.map(seg.speed_limit_kmh)
    d["quality_flag"] = np.select(
        [d.speed_kmh.isna() | d.flow_vph.isna(), (d.flow_vph - kv).abs() > 0.25 * kv, d.speed_kmh > 1.5 * lim],
        ["MISSING", "SUSPECT", "SUSPECT"], default="OK")
    return d, seg

def load_mysql():
    import mysql.connector                       # pip install mysql-connector-python
    cn = mysql.connector.connect(**DB)
    d = pd.read_sql("SELECT segment_code, obs_time, flow_vph, speed_kmh, density_vpkm, quality_flag "
                    "FROM traffic_observation", cn)
    for c in ["flow_vph", "speed_kmh", "density_vpkm"]: d[c] = d[c].astype(float)
    seg = pd.read_sql("SELECT * FROM road_segment", cn).set_index("segment_code")
    return d, seg, cn

# ------------------------------------------------------------------ models
def _ols(x, y):
    """simple least squares y = a + b x via normal equations (closed form)."""
    n = len(x); sx, sy = x.sum(), y.sum()
    b = (n * (x * y).sum() - sx * sy) / (n * (x * x).sum() - sx ** 2)
    return (sy - b * sx) / n, b

def fit_models(k, v):
    out, vmax = {}, v.max()
    a, b = _ols(k, v)                                           # Greenshields  v = vf (1 - k/kj)
    vf, kj = a, -a / b
    out["GREENSHIELDS"] = dict(vf=vf, kj=kj, kc=kj / 2, qmax=vf * kj / 4,
                               f=lambda x, vf=vf, kj=kj: np.clip(vf * (1 - x / kj), 0, None))
    a, b = _ols(np.log(k), v)                                   # Greenberg  v = vm ln(kj/k)
    vm, kj = -b, np.exp(-a / b)
    out["GREENBERG"] = dict(vf=None, kj=kj, kc=kj / E, qmax=vm * kj / E,
                            f=lambda x, vm=vm, kj=kj: np.clip(vm * np.log(kj / x), 0, vmax))
    a, b = _ols(k, np.log(v))                                   # Underwood  v = vf exp(-k/kc)
    vf, kc = np.exp(a), -1 / b
    out["UNDERWOOD"] = dict(vf=vf, kj=None, kc=kc, qmax=vf * kc / E,
                            f=lambda x, vf=vf, kc=kc: vf * np.exp(-x / kc))
    for m in out.values():
        pred = m["f"](k)
        m["rmse"] = float(np.sqrt(np.mean((v - pred) ** 2)))
        m["r2"] = float(1 - ((v - pred) ** 2).sum() / ((v - v.mean()) ** 2).sum())
    return out

def regime_of(k, kc):
    return np.where(k < LOWER * kc, "FREE_FLOW", np.where(k <= UPPER * kc, "TRANSITION", "CONGESTED"))

def longest_run(reg, t, label="CONGESTED"):
    d = pd.DataFrame({"t": t.values, "r": reg}).sort_values("t")
    d["run"] = (d.r != d.r.shift()).cumsum()
    runs = d[d.r == label].groupby("run").t.agg(["min", "max", "count"])
    return runs.loc[runs["count"].idxmax()] if len(runs) else None

def kmeans_check(k, v, q, regimes, seed=1):
    from sklearn.cluster import KMeans
    X = np.column_stack([(k - k.mean()) / k.std(), (v - v.mean()) / v.std(), (q - q.mean()) / q.std()])
    lab = KMeans(3, n_init=10, random_state=seed).fit_predict(X)
    order = pd.Series(k).groupby(lab).mean().sort_values().index
    names = dict(zip(order, ["FREE_FLOW", "TRANSITION", "CONGESTED"]))
    return float((pd.Series(lab).map(names).values == regimes).mean())

# ------------------------------------------------------------------ main analysis
def analyse(d, seg):
    res = {}
    for code in sorted(d.segment_code.unique()):
        s = d[(d.segment_code == code) & (d.quality_flag == "OK")]
        k, v, q = s.density_vpkm.values, s.speed_kmh.values, s.flow_vph.values
        fits = fit_models(k, v)
        best = min(fits, key=lambda m: fits[m]["rmse"])
        kc, qmax = fits[best]["kc"], fits[best]["qmax"]
        reg = regime_of(k, kc)
        allseg = d[d.segment_code == code]
        reg_all = regime_of(allseg.density_vpkm.values, kc)
        run = longest_run(reg_all, allseg.obs_time)
        res[code] = dict(fits=fits, best=best, kc=kc, qmax=qmax, k=k, v=v, q=q, reg=reg, n=len(s),
                         n_total=len(allseg), pct={r: float((reg_all == r).mean() * 100) for r in
                         ["FREE_FLOW", "TRANSITION", "CONGESTED"]},
                         agree=kmeans_check(k, v, q, reg), run=run, obs_max_q=float(q.max()),
                         speed_by_reg={r: float(v[reg == r].mean()) for r in ["FREE_FLOW", "TRANSITION", "CONGESTED"]})
    return res

def print_report(res, seg):
    for code, r in res.items():
        print(f"\n=== {code}  {seg.loc[code, 'segment_name']}  (clean n={r['n']} of {r['n_total']}) ===")
        for m, f in r["fits"].items():
            star = "  <-- best" if m == r["best"] else ""
            print(f"  {m:13s} kc={f['kc']:6.1f} veh/km  qmax={f['qmax']:7.0f} vph  RMSE={f['rmse']:6.2f}  R2={f['r2']:.4f}{star}")
        print(f"  regimes (% of all intervals): " + ", ".join(f"{a}={b:.1f}" for a, b in r["pct"].items()))
        print(f"  mean speed by regime: " + ", ".join(f"{a}={b:.1f}" for a, b in r["speed_by_reg"].items()))
        print(f"  KMeans(k=3) agreement with threshold regimes: {r['agree']*100:.1f}%")
        if r["run"] is not None:
            print(f"  longest congested run: {int(r['run']['count'])*15} min  ({r['run']['min']} -> {r['run']['max']})")

def make_figures(res, seg):
    os.makedirs(FIG, exist_ok=True)
    col = {"FREE_FLOW": "#2a9d8f", "TRANSITION": "#e9c46a", "CONGESTED": "#e63946"}
    fig, axs = plt.subplots(3, 3, figsize=(15, 11))
    for i, (code, r) in enumerate(res.items()):
        kk = np.linspace(1, r["k"].max() * 1.05, 300); f = r["fits"][r["best"]]["f"]
        for rg, c in col.items():
            m = r["reg"] == rg
            axs[i, 0].scatter(r["k"][m], r["q"][m], s=4, c=c, label=rg)
            axs[i, 1].scatter(r["k"][m], r["v"][m], s=4, c=c)
            axs[i, 2].scatter(r["q"][m], r["v"][m], s=4, c=c)
        axs[i, 0].plot(kk, kk * f(kk), "k-", lw=2); axs[i, 1].plot(kk, f(kk), "k-", lw=2)
        axs[i, 2].plot(kk * f(kk), f(kk), "k-", lw=2)
        for j in (0, 1): axs[i, j].axvline(r["kc"], ls="--", c="gray")
        axs[i, 0].axhline(r["qmax"], ls=":", c="gray")
        axs[i, 0].set_title(f"{code} {seg.loc[code,'segment_name']}: flow-density ({r['best'].title()})")
        axs[i, 1].set_title("speed-density"); axs[i, 2].set_title("speed-flow")
        axs[i, 0].set_xlabel("density k (veh/km)"); axs[i, 0].set_ylabel("flow q (veh/h)")
        axs[i, 1].set_xlabel("density k (veh/km)"); axs[i, 1].set_ylabel("speed v (km/h)")
        axs[i, 2].set_xlabel("flow q (veh/h)");      axs[i, 2].set_ylabel("speed v (km/h)")
    axs[0, 0].legend(markerscale=4, fontsize=8)
    plt.tight_layout(); plt.savefig(os.path.join(FIG, "fundamental_diagrams.png"), dpi=130); plt.close()

    fig, axs = plt.subplots(1, 3, figsize=(15, 4.2))
    for ax, (code, r) in zip(axs, res.items()):
        kk = np.linspace(1, r["k"].max() * 1.05, 300)
        ax.scatter(r["k"], r["v"], s=3, c="#bbbbbb")
        for m, f in r["fits"].items(): ax.plot(kk, f["f"](kk), lw=2, label=f"{m.title()} (RMSE {f['rmse']:.1f})")
        ax.set_title(f"{code}: model comparison"); ax.set_xlabel("density (veh/km)"); ax.set_ylabel("speed (km/h)")
        ax.legend(fontsize=8)
    plt.tight_layout(); plt.savefig(os.path.join(FIG, "model_comparison.png"), dpi=130); plt.close()

def write_back(cn, res):
    cur = cn.cursor()
    cur.execute("DELETE FROM model_fit")
    for code, r in res.items():
        for m, f in r["fits"].items():
            cur.execute("INSERT INTO model_fit (segment_code, model_name, free_flow_speed, jam_density, critical_density,"
                        " capacity_vph, rmse_speed, r2_speed, n_obs) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                        (code, m, f["vf"], f["kj"], f["kc"], f["qmax"], f["rmse"], f["r2"], r["n"]))
    cn.commit(); cur.close()
    print("model_fit written. Now run in MySQL:  CALL sp_apply_best_model(0.75,1.25); CALL sp_classify_regimes();")

def predict(res, seg, code, density):
    r = res[code]; f = r["fits"][r["best"]]
    v = float(f["f"](np.array([density]))[0]); q = density * v
    rg = str(regime_of(np.array([density]), r["kc"])[0])
    print(f"{code} ({r['best']}): k={density} veh/km -> v={v:.1f} km/h, q={q:.0f} veh/h, regime={rg}"
          f"  [k_c={r['kc']:.1f}, q_max={r['qmax']:.0f}]")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", action="store_true"); ap.add_argument("--mysql", action="store_true")
    ap.add_argument("--predict"); ap.add_argument("--density", type=float)
    a = ap.parse_args()
    if a.mysql: d, seg, cn = load_mysql()
    else:       d, seg = load_csv(); cn = None
    res = analyse(d, seg)
    if a.predict: predict(res, seg, a.predict, a.density); sys.exit()
    print(d.quality_flag.value_counts().to_string())
    print_report(res, seg); make_figures(res, seg)
    if cn is not None: write_back(cn, res)
