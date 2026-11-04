-- =====================================================================
-- 06_demo_and_optimization.sql : live-demo snippets, transaction, optimisation
-- =====================================================================
USE traffic_fd;

-- ---- LIVE DEMO: change the input value and explain the result ---------
SELECT fn_regime('S2', 60)  AS k60,  fn_regime('S2', 90) AS k90, fn_regime('S2', 130) AS k130;
SELECT ROUND(fn_greenshields_speed(82, 200, 100),1) AS v_at_kc, fn_flow(100, fn_greenshields_speed(82,200,100)) AS q_at_kc;
CALL sp_daily_report('S1', '2026-09-10');

-- ---- TRANSACTION: what-if threshold change that is rolled back --------
START TRANSACTION;
UPDATE regime_threshold SET free_max_density = free_max_density * 0.8 WHERE segment_code = 'S1';
CALL sp_classify_regimes();                 -- NOTE: this procedure COMMITs internally
-- (to demonstrate ROLLBACK use the manual statement below instead)
ROLLBACK;

START TRANSACTION;
UPDATE traffic_observation SET regime = 'CONGESTED' WHERE segment_code = 'S1' AND DATE(obs_time) = '2026-09-10';
SELECT regime, COUNT(*) FROM traffic_observation WHERE segment_code='S1' AND DATE(obs_time)='2026-09-10' GROUP BY regime;
ROLLBACK;                                   -- labels restored; audit_log stays unchanged
SELECT regime, COUNT(*) FROM traffic_observation WHERE segment_code='S1' AND DATE(obs_time)='2026-09-10' GROUP BY regime;

-- ---- TRIGGER TEST: invalid data is rejected ---------------------------
-- INSERT INTO traffic_observation (segment_code, obs_time, flow_vph, speed_kmh, density_vpkm)
-- VALUES ('S1','2026-10-01 08:00:00', 1500, -5, 30);   -- fails: Negative speed or flow ...

-- ---- QUERY OPTIMISATION ------------------------------------------------
-- 1) Without a suitable index the bin query scans the table; with idx_obs_seg_density it can use the index.
EXPLAIN SELECT AVG(flow_vph) FROM traffic_observation
WHERE segment_code = 'S2' AND density_vpkm BETWEEN 80 AND 90;

-- 2) Compare: force a full scan by ignoring the index
EXPLAIN SELECT AVG(flow_vph) FROM traffic_observation IGNORE INDEX (idx_obs_seg_density, idx_obs_regime, uq_seg_time)
WHERE segment_code = 'S2' AND density_vpkm BETWEEN 80 AND 90;

-- 3) Time-range filter uses idx_obs_time
EXPLAIN SELECT COUNT(*) FROM traffic_observation WHERE obs_time >= '2026-09-15' AND obs_time < '2026-09-16';

-- 4) Row-level function in WHERE (DATE(obs_time)) defeats the index; the range form is sargable
EXPLAIN SELECT COUNT(*) FROM traffic_observation WHERE DATE(obs_time) = '2026-09-15';          -- slower pattern
EXPLAIN SELECT COUNT(*) FROM traffic_observation WHERE obs_time >= '2026-09-15' AND obs_time < '2026-09-16'; -- faster pattern
