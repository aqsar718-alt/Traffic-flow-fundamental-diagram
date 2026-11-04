-- =====================================================================
-- 04_pipeline.sql : run AFTER 01, 02, 03.  Order matters.
-- =====================================================================
USE traffic_fd;

CALL sp_flag_quality();                 -- 1. mark MISSING / SUSPECT rows
CALL sp_derive_thresholds(0.75, 1.25);  -- 2. first-pass thresholds from binned data
CALL sp_classify_regimes();             -- 3. label every observation

-- >>> Now run:  python python/traffic_fd.py --mysql   (fits 3 models, fills model_fit)
-- >>> Then:
CALL sp_apply_best_model(0.75, 1.25);   -- 4. replace thresholds with best-model values
CALL sp_classify_regimes();             -- 5. re-label (changes are written to audit_log)

SELECT * FROM regime_threshold;
SELECT segment_code, model_name, critical_density, capacity_vph, rmse_speed, r2_speed, is_best
FROM model_fit ORDER BY segment_code, rmse_speed;
SELECT COUNT(*) AS reclassified FROM audit_log;
