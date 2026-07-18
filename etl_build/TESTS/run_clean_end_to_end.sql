-- =============================================================================
-- CLEAN END-TO-END RUN — one full pipeline pass on a FRESH PPN (no accumulated state).
-- Proves create → validate → per-table load (wrapped) → finalize (gate → GOLD stub → close)
-- compose into a SUCCESS run.
--
-- Prereqs (once):
--   * All etl_build TABLES + PROCEDURES deployed; SEED/seed_config_dev.sql run.
--   * Parquet files uploaded under @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/...
--   * SHARE_SIM_DB exists and the running role can SELECT it. As DEV_SYSADMIN, once:
--       use role sysadmin;
--       grant usage  on database share_sim_db                       to role dev_sysadmin;
--       grant usage  on schema   share_sim_db.wholesale             to role dev_sysadmin;
--       grant select on all tables in schema share_sim_db.wholesale to role dev_sysadmin;
--       use role dev_sysadmin;
-- =============================================================================
use role dev_sysadmin;
use warehouse compute_wh;      -- set your dev warehouse
use database dev_db;
use schema adm;

-- 1) Start the run
CALL ADM.SP_CREATE_PPN('clean-e2e');
SET PPN = (SELECT "PPN_ID" FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
SELECT $PPN AS PPN_ID;

-- 2) Pre-flight config
CALL ADM.SP_VALIDATE_CONFIG($PPN);

-- 3) Per-table load (wrapped): landing → check-change → HIST → SILVER, one call each.
--    (In production ADF's ForEach issues these, ordered by LOAD_ORDER.)
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'BSS_ORA',   'CUSTOMER');
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'BSS_ORA',   'SERVICE_PLAN');
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'BSS_ORA',   'USAGE_DAILY');
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'WHOLESALE', 'PARTNER_ACCOUNT');
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'WHOLESALE', 'WHOLESALE_USAGE');

-- 4) (DQ would run here once AntFarm's SP_RUN_DQ_CHECKS exists)

-- 5) Finalize: gate → GOLD (stub) → close. Returns SUCCESS, or raises if the run failed.
CALL ADM.SP_FINALIZE_RUN($PPN);

-- =============================================================================
-- INSPECT — what a PASS looks like
-- =============================================================================
-- Run header: STATUS = SUCCESS, END_TS set
SELECT PPN_ID, RUN_ID, STATUS, START_TS, END_TS FROM ADM.PPN WHERE PPN_ID = $PPN;

-- Per-table state: every row STATUS in (SUCCESS, SKIP) -> gate passes
SELECT SOURCE_ID, TABLE_NAME, STATUS, PHASE, ROWS_EXTRACTED, ROWS_INSERTED, ROWS_DELETED
  FROM ADM.PPN_PROCESS WHERE PPN_ID = $PPN ORDER BY SOURCE_ID, TABLE_NAME;

-- Step log: the phase trail incl. GATE_CHECK, REFRESH_GOLD (stub), CLOSE_PPN (END)
SELECT LOG_ID, PHASE, STATUS, TABLE_NAME, ROW_COUNT, MESSAGE
  FROM ADM.PPN_LOG WHERE PPN_ID = $PPN ORDER BY LOG_ID;

-- Spot-check the cleansed layer
SELECT PK_HK, ROW_HK, IS_DELETED, CUSTOMER_ID, CITY FROM DEV_DB.SILVER.CUSTOMER ORDER BY CUSTOMER_ID;
