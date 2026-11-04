-- =====================================================================
-- 03_programs.sql : functions, stored procedures, triggers, views
-- Run in the mysql client (DELIMITER is a client command).
-- =====================================================================
USE traffic_fd;
DELIMITER $$

-- ---------- FUNCTIONS ------------------------------------------------
-- Greenshields speed-density relation  v = vf * (1 - k / kj)
CREATE FUNCTION fn_greenshields_speed(p_vf DOUBLE, p_kj DOUBLE, p_k DOUBLE)
RETURNS DOUBLE DETERMINISTIC
BEGIN
    RETURN GREATEST(p_vf * (1 - p_k / p_kj), 0);
END$$

-- Fundamental relation  q = k * v
CREATE FUNCTION fn_flow(p_k DOUBLE, p_v DOUBLE)
RETURNS DOUBLE DETERMINISTIC
BEGIN
    RETURN p_k * p_v;
END$$

-- Regime of a density value for a given segment (looks up regime_threshold)
CREATE FUNCTION fn_regime(p_segment VARCHAR(10), p_density DOUBLE)
RETURNS VARCHAR(12) READS SQL DATA
BEGIN
    DECLARE v_free DOUBLE;
    DECLARE v_cong DOUBLE;
    SELECT free_max_density, congested_min_density INTO v_free, v_cong
    FROM regime_threshold WHERE segment_code = p_segment;
    RETURN CASE WHEN v_free IS NULL        THEN NULL
                WHEN p_density <  v_free   THEN 'FREE_FLOW'
                WHEN p_density <= v_cong   THEN 'TRANSITION'
                ELSE 'CONGESTED' END;
END$$

-- ---------- TRIGGERS -------------------------------------------------
-- Validate and auto-classify every new observation
CREATE TRIGGER trg_obs_before_insert BEFORE INSERT ON traffic_observation
FOR EACH ROW
BEGIN
    IF NEW.speed_kmh < 0 OR NEW.flow_vph < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Negative speed or flow is not physically valid';
    END IF;
    IF NEW.speed_kmh IS NULL THEN SET NEW.quality_flag = 'MISSING'; END IF;
    SET NEW.regime = fn_regime(NEW.segment_code, NEW.density_vpkm);
END$$

-- Log every regime re-classification (after the first classification)
CREATE TRIGGER trg_obs_after_update AFTER UPDATE ON traffic_observation
FOR EACH ROW
BEGIN
    IF OLD.regime IS NOT NULL AND NOT (OLD.regime <=> NEW.regime) THEN
        INSERT INTO audit_log (obs_id, old_regime, new_regime)
        VALUES (OLD.obs_id, OLD.regime, NEW.regime);
    END IF;
END$$

-- ---------- STORED PROCEDURES ----------------------------------------
-- 1) data-quality flags (rules: missing speed; q != k*v by >25%; speed > 1.5 x limit)
CREATE PROCEDURE sp_flag_quality()
BEGIN
    UPDATE traffic_observation o
    SET o.quality_flag = CASE
        WHEN o.speed_kmh IS NULL OR o.flow_vph IS NULL THEN 'MISSING'
        WHEN ABS(o.flow_vph - o.density_vpkm * o.speed_kmh) > 0.25 * o.density_vpkm * o.speed_kmh THEN 'SUSPECT'
        WHEN o.speed_kmh > 1.5 * (SELECT s.speed_limit_kmh FROM road_segment s
                                  WHERE s.segment_code = o.segment_code) THEN 'SUSPECT'
        ELSE 'OK' END;
END$$

-- 2) derive thresholds directly from data: 5 veh/km density bins, the bin with the
--    highest mean flow gives (k_c, q_max); regimes are k_c*lower / k_c*upper
CREATE PROCEDURE sp_derive_thresholds(IN p_lower DOUBLE, IN p_upper DOUBLE)
BEGIN
    REPLACE INTO regime_threshold
        (segment_code, critical_density, capacity_vph, free_max_density, congested_min_density, source)
    WITH binned AS (
        SELECT segment_code,
               FLOOR(density_vpkm / 5) * 5 + 2.5 AS bin_mid,
               AVG(flow_vph) AS avg_flow
        FROM traffic_observation
        WHERE quality_flag = 'OK'
        GROUP BY segment_code, FLOOR(density_vpkm / 5)
        HAVING COUNT(*) >= 10
    ), ranked AS (
        SELECT segment_code, bin_mid, avg_flow,
               ROW_NUMBER() OVER (PARTITION BY segment_code ORDER BY avg_flow DESC) AS rn
        FROM binned
    )
    SELECT segment_code, bin_mid, avg_flow, bin_mid * p_lower, bin_mid * p_upper, 'SQL_BINNED'
    FROM ranked WHERE rn = 1;
END$$

-- 3) classify all observations inside a transaction
CREATE PROCEDURE sp_classify_regimes()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN ROLLBACK; RESIGNAL; END;
    START TRANSACTION;
    UPDATE traffic_observation SET regime = fn_regime(segment_code, density_vpkm);
    COMMIT;
END$$

-- 4) pick best model per segment (lowest RMSE) and push its thresholds
CREATE PROCEDURE sp_apply_best_model(IN p_lower DOUBLE, IN p_upper DOUBLE)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN ROLLBACK; RESIGNAL; END;
    START TRANSACTION;
    UPDATE model_fit SET is_best = 0;
    UPDATE model_fit SET is_best = 1
    WHERE fit_id IN (SELECT fit_id FROM (
            SELECT fit_id, ROW_NUMBER() OVER (PARTITION BY segment_code ORDER BY rmse_speed) AS rn
            FROM model_fit) ranked
        WHERE rn = 1);
    REPLACE INTO regime_threshold
        (segment_code, critical_density, capacity_vph, free_max_density, congested_min_density, source)
    SELECT segment_code, critical_density, capacity_vph,
           critical_density * p_lower, critical_density * p_upper, 'MODEL_FIT'
    FROM model_fit WHERE is_best = 1;
    COMMIT;
END$$

-- 5) daily report for a segment (used in the live demo)
CREATE PROCEDURE sp_daily_report(IN p_segment VARCHAR(10), IN p_date DATE)
BEGIN
    SELECT regime, COUNT(*) AS intervals, ROUND(AVG(speed_kmh),1) AS avg_speed_kmh,
           ROUND(AVG(flow_vph)) AS avg_flow_vph, ROUND(MAX(density_vpkm),1) AS max_density
    FROM traffic_observation
    WHERE segment_code = p_segment AND DATE(obs_time) = p_date AND quality_flag = 'OK'
    GROUP BY regime
    ORDER BY FIELD(regime,'FREE_FLOW','TRANSITION','CONGESTED');
END$$

DELIMITER ;

-- ---------- VIEWS ----------------------------------------------------
CREATE VIEW v_clean_observation AS
SELECT obs_id, segment_code, obs_time, flow_vph, speed_kmh, density_vpkm, regime
FROM traffic_observation WHERE quality_flag = 'OK';

CREATE VIEW v_regime_summary AS
SELECT segment_code, regime, COUNT(*) AS intervals,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY segment_code), 1) AS pct_of_time,
       ROUND(AVG(speed_kmh), 1) AS avg_speed, ROUND(AVG(flow_vph)) AS avg_flow
FROM traffic_observation GROUP BY segment_code, regime;

CREATE VIEW v_hourly_profile AS
SELECT segment_code, HOUR(obs_time) AS hr,
       ROUND(AVG(density_vpkm),1) AS avg_density, ROUND(AVG(speed_kmh),1) AS avg_speed,
       ROUND(AVG(flow_vph)) AS avg_flow,
       ROUND(100 * AVG(regime = 'CONGESTED'), 1) AS pct_congested
FROM traffic_observation WHERE quality_flag = 'OK'
GROUP BY segment_code, HOUR(obs_time);

-- consecutive runs of the same regime (gaps-and-islands with LAG + running SUM)
CREATE VIEW v_regime_runs AS
WITH ordered AS (
    SELECT segment_code, obs_time, regime,
           LAG(regime) OVER (PARTITION BY segment_code ORDER BY obs_time) AS prev_regime
    FROM traffic_observation
), grouped AS (
    SELECT segment_code, obs_time, regime,
           SUM(CASE WHEN prev_regime IS NULL OR prev_regime <> regime THEN 1 ELSE 0 END)
               OVER (PARTITION BY segment_code ORDER BY obs_time) AS run_no
    FROM ordered
)
SELECT segment_code, run_no, regime, MIN(obs_time) AS start_time, MAX(obs_time) AS end_time,
       COUNT(*) AS intervals, COUNT(*) * 15 AS duration_min
FROM grouped GROUP BY segment_code, run_no, regime;
