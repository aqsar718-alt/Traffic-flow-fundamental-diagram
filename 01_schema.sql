-- =====================================================================
-- Traffic Flow Fundamental Diagram Explorer  |  MySQL 8.0+
-- 01_schema.sql : database, tables, constraints, indexes
-- NOTE: the whole project avoids JOINs (assignment rule). Cross-table
-- logic uses subqueries, CTEs, window functions, functions and triggers.
-- =====================================================================
DROP DATABASE IF EXISTS traffic_fd;
CREATE DATABASE traffic_fd CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE traffic_fd;

CREATE TABLE road_segment (
    segment_code     VARCHAR(10)  PRIMARY KEY,
    segment_name     VARCHAR(60)  NOT NULL,
    lanes            TINYINT      NOT NULL,
    length_km        DECIMAL(5,2) NOT NULL,
    speed_limit_kmh  SMALLINT     NOT NULL,
    CONSTRAINT ck_lanes  CHECK (lanes BETWEEN 1 AND 8),
    CONSTRAINT ck_length CHECK (length_km > 0),
    CONSTRAINT ck_limit  CHECK (speed_limit_kmh BETWEEN 20 AND 140)
);

CREATE TABLE traffic_observation (
    obs_id        INT AUTO_INCREMENT PRIMARY KEY,
    segment_code  VARCHAR(10)   NOT NULL,
    obs_time      DATETIME      NOT NULL,          -- 15-minute aggregation interval
    flow_vph      DECIMAL(8,1)  NULL,              -- q  (vehicles / hour)
    speed_kmh     DECIMAL(6,2)  NULL,              -- v  (space-mean speed, km/h)
    density_vpkm  DECIMAL(6,2)  NOT NULL,          -- k  (vehicles / km)
    quality_flag  ENUM('OK','SUSPECT','MISSING') NOT NULL DEFAULT 'OK',
    regime        ENUM('FREE_FLOW','TRANSITION','CONGESTED') NULL,
    CONSTRAINT uq_seg_time UNIQUE (segment_code, obs_time),
    CONSTRAINT fk_obs_seg FOREIGN KEY (segment_code) REFERENCES road_segment(segment_code),
    CONSTRAINT ck_density CHECK (density_vpkm >= 0)
);

-- Thresholds that define the three operating regimes of each segment
CREATE TABLE regime_threshold (
    segment_code          VARCHAR(10) PRIMARY KEY,
    critical_density      DECIMAL(7,2) NOT NULL,   -- k_c  (density at capacity)
    capacity_vph          DECIMAL(8,1) NOT NULL,   -- q_max
    free_max_density      DECIMAL(7,2) NOT NULL,   -- below -> FREE_FLOW
    congested_min_density DECIMAL(7,2) NOT NULL,   -- above -> CONGESTED
    source                VARCHAR(20)  NOT NULL,   -- SQL_BINNED or MODEL_FIT
    updated_at            TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_thr_seg FOREIGN KEY (segment_code) REFERENCES road_segment(segment_code)
);

-- Results of the Python curve fitting (one row per segment x model)
CREATE TABLE model_fit (
    fit_id            INT AUTO_INCREMENT PRIMARY KEY,
    segment_code      VARCHAR(10) NOT NULL,
    model_name        ENUM('GREENSHIELDS','GREENBERG','UNDERWOOD') NOT NULL,
    free_flow_speed   DECIMAL(8,3) NULL,
    jam_density       DECIMAL(8,3) NULL,
    critical_density  DECIMAL(8,3) NOT NULL,
    capacity_vph      DECIMAL(9,2) NOT NULL,
    rmse_speed        DECIMAL(8,4) NOT NULL,
    r2_speed          DECIMAL(8,5) NOT NULL,
    n_obs             INT NOT NULL,
    is_best           TINYINT NOT NULL DEFAULT 0,
    fitted_at         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_fit UNIQUE (segment_code, model_name),
    CONSTRAINT fk_fit_seg FOREIGN KEY (segment_code) REFERENCES road_segment(segment_code)
);

CREATE TABLE audit_log (
    audit_id    INT AUTO_INCREMENT PRIMARY KEY,
    obs_id      INT NOT NULL,
    old_regime  VARCHAR(12) NULL,
    new_regime  VARCHAR(12) NULL,
    changed_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes chosen for the main access paths (see 06_demo_and_optimization.sql)
CREATE INDEX idx_obs_seg_density ON traffic_observation (segment_code, density_vpkm);
CREATE INDEX idx_obs_time        ON traffic_observation (obs_time);
CREATE INDEX idx_obs_regime      ON traffic_observation (segment_code, regime);
