-- =====================================================================
-- 05_analysis_queries.sql : required analysis question
-- "Identify free-flow, transition and congested regimes"  (NO JOINs used)
-- Run after 04_pipeline.sql
-- =====================================================================
USE traffic_fd;

-- Q1. Dataset overview per segment (GROUP BY, aggregates)
SELECT segment_code, COUNT(*) AS n_obs, MIN(obs_time) AS first_obs, MAX(obs_time) AS last_obs,
       ROUND(AVG(density_vpkm),1) AS avg_density, ROUND(AVG(speed_kmh),1) AS avg_speed,
       ROUND(MAX(flow_vph)) AS max_flow
FROM traffic_observation GROUP BY segment_code;

-- Q2. Data quality (conditional aggregation)
SELECT segment_code, SUM(quality_flag='OK') AS ok, SUM(quality_flag='MISSING') AS missing,
       SUM(quality_flag='SUSPECT') AS suspect,
       ROUND(100*SUM(quality_flag<>'OK')/COUNT(*),2) AS pct_rejected
FROM traffic_observation GROUP BY segment_code;

-- Q3. Capacity from data: mean flow per 5 veh/km density bin (CTE + window RANK)
WITH binned AS (
    SELECT segment_code, FLOOR(density_vpkm/5)*5 AS bin_start, COUNT(*) AS n,
           ROUND(AVG(flow_vph)) AS mean_flow, ROUND(AVG(speed_kmh),1) AS mean_speed
    FROM v_clean_observation GROUP BY segment_code, FLOOR(density_vpkm/5)*5
    HAVING COUNT(*) >= 10
)
SELECT * FROM (SELECT b.*, RANK() OVER (PARTITION BY segment_code ORDER BY mean_flow DESC) AS flow_rank
               FROM binned b) x
WHERE flow_rank <= 3 ORDER BY segment_code, flow_rank;

-- Q4. Greenshields fitted IN PURE SQL: least squares from sums
--     slope b = (nSkv - SkSv)/(nSkk - SkSk) ; vf = intercept ; kj = -vf/b ; q_max = vf*kj/4
SELECT segment_code, n, ROUND(vf,2) AS free_flow_speed, ROUND(-vf/slope,1) AS jam_density,
       ROUND(-vf/slope/2,1) AS critical_density, ROUND(vf*(-vf/slope)/4) AS capacity_vph
FROM (
    SELECT segment_code, n, slope, (sv - slope*sk)/n AS vf
    FROM (
        SELECT segment_code, COUNT(*) AS n, SUM(density_vpkm) AS sk, SUM(speed_kmh) AS sv,
               (COUNT(*)*SUM(density_vpkm*speed_kmh) - SUM(density_vpkm)*SUM(speed_kmh))
             / (COUNT(*)*SUM(density_vpkm*density_vpkm) - SUM(density_vpkm)*SUM(density_vpkm)) AS slope
        FROM v_clean_observation GROUP BY segment_code
    ) s1
) s2;

-- Q5. Regime distribution and mean speed (view with window SUM)
SELECT * FROM v_regime_summary ORDER BY segment_code, FIELD(regime,'FREE_FLOW','TRANSITION','CONGESTED');

-- Q6. Hourly profile and peak hour (view + RANK)
SELECT segment_code, hr, avg_density, avg_speed, pct_congested FROM (
    SELECT p.*, RANK() OVER (PARTITION BY segment_code ORDER BY pct_congested DESC) AS rk
    FROM v_hourly_profile p) t
WHERE rk <= 2 ORDER BY segment_code, rk;

-- Q7. Percentile threshold: 95th percentile density per segment (PERCENT_RANK)
SELECT segment_code, MIN(density_vpkm) AS p95_density FROM (
    SELECT segment_code, density_vpkm,
           PERCENT_RANK() OVER (PARTITION BY segment_code ORDER BY density_vpkm) AS pr
    FROM traffic_observation) r
WHERE pr >= 0.95 GROUP BY segment_code;

-- Q8. 1-hour moving average speed on a chosen day (window frame: 4 x 15 min)
SELECT obs_time, density_vpkm, speed_kmh,
       ROUND(AVG(speed_kmh) OVER (ORDER BY obs_time ROWS BETWEEN 3 PRECEDING AND CURRENT ROW),1) AS speed_ma_1h
FROM traffic_observation
WHERE segment_code = 'S2' AND DATE(obs_time) = '2026-09-10' AND obs_time BETWEEN '2026-09-10 15:00:00' AND '2026-09-10 20:00:00';

-- Q9. Longest congested episode per segment (uses v_regime_runs: LAG + running SUM)
SELECT segment_code, start_time, end_time, duration_min FROM (
    SELECT r.*, ROW_NUMBER() OVER (PARTITION BY segment_code ORDER BY duration_min DESC, start_time) AS rn
    FROM v_regime_runs r WHERE regime = 'CONGESTED') t
WHERE rn = 1;

-- Q10. Breakdown events: first congested interval after a non-congested one, with flow change
WITH s AS (
    SELECT segment_code, obs_time, regime, flow_vph, speed_kmh,
           LAG(regime)    OVER (PARTITION BY segment_code ORDER BY obs_time) AS prev_regime,
           LAG(flow_vph)  OVER (PARTITION BY segment_code ORDER BY obs_time) AS prev_flow,
           LAG(speed_kmh) OVER (PARTITION BY segment_code ORDER BY obs_time) AS prev_speed
    FROM traffic_observation WHERE quality_flag = 'OK')
SELECT segment_code, COUNT(*) AS breakdowns,
       ROUND(AVG(prev_speed),1) AS speed_before, ROUND(AVG(speed_kmh),1) AS speed_after,
       ROUND(AVG(100*(flow_vph-prev_flow)/prev_flow),1) AS avg_flow_change_pct
FROM s WHERE regime='CONGESTED' AND prev_regime IN ('FREE_FLOW','TRANSITION')
GROUP BY segment_code;

-- Q11. Weekday vs weekend congestion (GROUP BY expression)
SELECT segment_code, IF(DAYOFWEEK(obs_time) IN (1,7),'weekend','weekday') AS day_type,
       ROUND(100*AVG(regime='CONGESTED'),1) AS pct_congested
FROM traffic_observation GROUP BY segment_code, day_type;

-- Q12. Subquery: days whose peak density exceeded the segment's critical density by 20%+
SELECT segment_code, DATE(obs_time) AS day, MAX(density_vpkm) AS peak_density
FROM traffic_observation o
GROUP BY segment_code, DATE(obs_time)
HAVING MAX(density_vpkm) > 1.2 * (SELECT t.critical_density FROM regime_threshold t
                                   WHERE t.segment_code = o.segment_code)
ORDER BY segment_code, peak_density DESC;
