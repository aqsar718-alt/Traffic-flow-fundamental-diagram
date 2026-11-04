# Traffic Flow Fundamental Diagram Explorer (MySQL 8 + Python)

Project 10, Computational Mathematics. No JOINs anywhere.

## Folder
- sql/01_schema.sql ... 06_demo_and_optimization.sql  (run in this order; 04 is split around the Python step)
- python/generate_data.py (simulator, seed 2026), python/traffic_fd.py (analysis), requirements.txt
- data/traffic_data.csv, data/segments.csv
- figures/fundamental_diagrams.png, figures/model_comparison.png

## Run
1. mysql -u root -p < sql/01_schema.sql ; then 02_seed_data.sql, 03_programs.sql  (use the mysql client: 03 uses DELIMITER)
   If you get error 1418 creating functions: SET GLOBAL log_bin_trust_function_creators = 1;
2. First three CALL lines of sql/04_pipeline.sql
3. pip install -r python/requirements.txt ; edit DB at top of python/traffic_fd.py ; python python/traffic_fd.py --mysql
   (no database? python python/traffic_fd.py --csv)
4. In MySQL: CALL sp_apply_best_model(0.75,1.25); CALL sp_classify_regimes();
5. sql/05_analysis_queries.sql, sql/06_demo_and_optimization.sql
Live what-if: python python/traffic_fd.py --csv --predict S2 --density 90
