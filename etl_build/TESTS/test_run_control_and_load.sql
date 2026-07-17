-- =============================================================================
-- Manual smoke test for the run-control + Parquet-load procedures.
-- Prereqs (run once, in order):
--   1. TABLES:      ETL_SOURCES, ETL_TABLES, PPN, PPN_PROCESS, PPN_LOG
--   2. PROCEDURES:  SP_LOG_STEP, SP_SET_PROCESS_STATE, SP_CREATE_PPN,
--                   SP_CLOSE_PPN, SP_VALIDATE_CONFIG, SP_LOAD_FILE_TO_BRONZE
--   3. SEED:        SEED/seed_config_dev.sql
--   4. Parquet test files uploaded under @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/...
-- Run as an owner/privileged role (procs are EXECUTE AS CALLER).
-- Note: RUN_ID is set once by SP_CREATE_PPN into ADM.PPN; all other procs take PPN_ID only.
-- =============================================================================
use role dev_sysadmin;
use warehouse compute_wh;
use database dev_db;
use schema adm;

-- Optional: confirm the stage sees your files first.
LIST @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/;

-- =============================================================================
-- TEST 1 — SP_CREATE_PPN  (allocate a run; RUN_ID captured here; grab PPN_ID)
-- =============================================================================
CALL ADM.SP_CREATE_PPN('test-run-001');
SET PPN_ID = (SELECT "PPN_ID" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
SELECT $PPN_ID AS PPN_ID;
SELECT * FROM ADM.PPN WHERE PPN_ID = $PPN_ID;           -- STATUS=RUNNING, RUN_ID set, START_TS set

-- =============================================================================
-- TEST 2 — SP_VALIDATE_CONFIG  (positive: seeded config should be valid)
-- =============================================================================
CALL ADM.SP_VALIDATE_CONFIG(P_PPN_ID => $PPN_ID);
SELECT PHASE, STATUS, RUN_ID, MESSAGE FROM ADM.PPN_LOG
 WHERE PPN_ID = $PPN_ID AND PHASE = 'VALIDATE_CONFIG';   -- expect SUCCESS, RUN_ID populated via lookup

-- =============================================================================
-- TEST 3 — SP_LOAD_FILE_TO_BRONZE  (the three BSS_ORA Parquet tables)
-- =============================================================================
CALL ADM.SP_LOAD_FILE_TO_BRONZE(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA', P_TABLE_NAME => 'CUSTOMER');
CALL ADM.SP_LOAD_FILE_TO_BRONZE(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA', P_TABLE_NAME => 'SERVICE_PLAN');
CALL ADM.SP_LOAD_FILE_TO_BRONZE(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA', P_TABLE_NAME => 'USAGE_DAILY');

-- Inspect the landed data + lineage columns
SELECT * FROM DEV_DB.BRONZE.CUSTOMER;
SELECT COUNT(*) AS rows_loaded, COUNT(DISTINCT METADATA$FILENAME) AS files, MAX(PPN_ID) AS ppn
  FROM DEV_DB.BRONZE.CUSTOMER;

-- Inspect state + log for this run
SELECT SOURCE_ID, TABLE_NAME, STATUS, PHASE, ROWS_EXTRACTED, START_TS, END_TS
  FROM ADM.PPN_PROCESS WHERE PPN_ID = $PPN_ID ORDER BY TABLE_NAME;
SELECT PHASE, STATUS, TABLE_NAME, ROW_COUNT, DURATION_MSEC, MESSAGE
  FROM ADM.PPN_LOG WHERE PPN_ID = $PPN_ID ORDER BY LOG_ID;

-- =============================================================================
-- TEST 3b — SP_LOAD_SHARE_TO_BRONZE  (WHOLESALE data-share tables)
--   Caller needs SELECT on SHARE_SIM_DB.WHOLESALE. The SHARE_SIM_DB script grants
--   it to DEV_TRANSFORMER; if testing as DEV_SYSADMIN, grant it once:
--     use role sysadmin;
--     grant usage  on database share_sim_db                       to role dev_sysadmin;
--     grant usage  on schema   share_sim_db.wholesale             to role dev_sysadmin;
--     grant select on all tables in schema share_sim_db.wholesale to role dev_sysadmin;
--     use role dev_sysadmin;
-- =============================================================================
CALL ADM.SP_LOAD_SHARE_TO_BRONZE(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'WHOLESALE', P_TABLE_NAME => 'PARTNER_ACCOUNT');
CALL ADM.SP_LOAD_SHARE_TO_BRONZE(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'WHOLESALE', P_TABLE_NAME => 'WHOLESALE_USAGE');
SELECT * FROM DEV_DB.BRONZE.PARTNER_ACCOUNT;
SELECT SOURCE_ID, TABLE_NAME, STATUS, ROWS_EXTRACTED
  FROM ADM.PPN_PROCESS WHERE PPN_ID = $PPN_ID AND SOURCE_ID = 'WHOLESALE';

-- =============================================================================
-- TEST 3c — SP_LOAD_BRONZE_TO_HIST  (append BRONZE -> BRONZE_HIST, idempotent per PPN)
-- =============================================================================
CALL ADM.SP_LOAD_BRONZE_TO_HIST(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA',   P_TABLE_NAME => 'CUSTOMER');
CALL ADM.SP_LOAD_BRONZE_TO_HIST(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'WHOLESALE', P_TABLE_NAME => 'PARTNER_ACCOUNT');
SELECT * FROM DEV_DB.BRONZE_HIST.CUSTOMER WHERE PPN_ID = $PPN_ID;

-- Idempotency: run the same table again -> row count for this PPN must NOT change.
CALL ADM.SP_LOAD_BRONZE_TO_HIST(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA', P_TABLE_NAME => 'CUSTOMER');
SELECT COUNT(*) AS hist_rows_this_ppn FROM DEV_DB.BRONZE_HIST.CUSTOMER WHERE PPN_ID = $PPN_ID;  -- still 5

-- =============================================================================
-- TEST 3d — SP_LOAD_BRONZE_TO_SILVER  (PK_HK/ROW_HK, MERGE, IS_DELETED)
-- =============================================================================
CALL ADM.SP_LOAD_BRONZE_TO_SILVER(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA',   P_TABLE_NAME => 'CUSTOMER');
CALL ADM.SP_LOAD_BRONZE_TO_SILVER(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA',   P_TABLE_NAME => 'SERVICE_PLAN');
CALL ADM.SP_LOAD_BRONZE_TO_SILVER(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA',   P_TABLE_NAME => 'USAGE_DAILY');
CALL ADM.SP_LOAD_BRONZE_TO_SILVER(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'WHOLESALE', P_TABLE_NAME => 'PARTNER_ACCOUNT');
CALL ADM.SP_LOAD_BRONZE_TO_SILVER(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'WHOLESALE', P_TABLE_NAME => 'WHOLESALE_USAGE');

SELECT PK_HK, ROW_HK, IS_DELETED, CUSTOMER_ID, CITY, DW_INSERTED_AT, DW_UPDATED_AT
  FROM DEV_DB.SILVER.CUSTOMER ORDER BY CUSTOMER_ID;

-- To see change-capture + soft-delete end to end, run the whole flow again with the
-- date-02 file, then the date-03 file (each needs a NEW PPN + re-uploaded file):
--   * date-02: customer 1002 changes city/email  -> that row's ROW_HK changes, DW_UPDATED_AT bumps; 1006 inserted.
--   * date-03: customer 1002 is absent            -> SILVER row 1002 gets IS_DELETED = TRUE (others stay FALSE).

-- =============================================================================
-- TEST 4 — negative: PARQUET loader against a DATASHARE source (expect ERROR obj)
--   Returns status=ERROR with a clear message; no SP_LOAD_SHARE_TO_BRONZE yet.
-- =============================================================================
CALL ADM.SP_LOAD_FILE_TO_BRONZE(P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'WHOLESALE', P_TABLE_NAME => 'PARTNER_ACCOUNT');

-- =============================================================================
-- TEST 5 — SP_SET_PROCESS_STATE  (helper, direct: upsert then verify)
-- =============================================================================
CALL ADM.SP_SET_PROCESS_STATE(
    P_PPN_ID => $PPN_ID, P_SOURCE_ID => 'BSS_ORA', P_TABLE_NAME => 'MANUAL_TEST',
    P_STATUS => 'SUCCESS', P_PHASE => 'MANUAL', P_ROWS_EXTRACTED => 42, P_SET_END => TRUE);
SELECT * FROM ADM.PPN_PROCESS WHERE PPN_ID = $PPN_ID AND TABLE_NAME = 'MANUAL_TEST';

-- =============================================================================
-- TEST 6 — SP_LOG_STEP  (helper, direct: write one log row then verify RUN_ID lookup)
-- =============================================================================
CALL ADM.SP_LOG_STEP(
    P_PPN_ID => $PPN_ID, P_PHASE => 'MANUAL', P_STATUS => 'SUCCESS',
    P_SOURCE_ID => 'BSS_ORA', P_TABLE_NAME => 'MANUAL_TEST',
    P_ROW_COUNT => 42, P_MESSAGE => 'manual log-step test');
SELECT PPN_ID, RUN_ID, PHASE, STATUS, MESSAGE FROM ADM.PPN_LOG
 WHERE PPN_ID = $PPN_ID AND PHASE = 'MANUAL' ORDER BY LOG_ID DESC LIMIT 1;   -- RUN_ID auto-filled

-- =============================================================================
-- TEST 7 — SP_CLOSE_PPN  (finalise the run)
-- =============================================================================
CALL ADM.SP_CLOSE_PPN(P_PPN_ID => $PPN_ID, P_STATUS => 'SUCCESS');
SELECT PPN_ID, STATUS, START_TS, END_TS FROM ADM.PPN WHERE PPN_ID = $PPN_ID;   -- STATUS=SUCCESS, END_TS set
SELECT PHASE, STATUS, MESSAGE FROM ADM.PPN_LOG WHERE PPN_ID = $PPN_ID AND PHASE = 'CLOSE_PPN';

-- =============================================================================
-- OPTIONAL — negative validation test (breaks config, expects raise, then fixes)
-- =============================================================================
-- UPDATE ADM.ETL_TABLES SET pk_columns = NULL WHERE source_id='BSS_ORA' AND table_name='USAGE_DAILY';  -- INCR w/o PK
-- CALL ADM.SP_VALIDATE_CONFIG(P_PPN_ID => $PPN_ID);   -- expect an error is raised
-- SELECT DETAIL_JSON FROM ADM.PPN_LOG WHERE PPN_ID = $PPN_ID AND PHASE='VALIDATE_CONFIG' ORDER BY LOG_ID DESC LIMIT 1;
-- UPDATE ADM.ETL_TABLES SET pk_columns = 'USAGE_ID' WHERE source_id='BSS_ORA' AND table_name='USAGE_DAILY';  -- restore
