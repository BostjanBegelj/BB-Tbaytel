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
SET PPN = (SELECT $1:ppn_id::NUMBER FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
SELECT $PPN AS PPN_ID;

-- 2) Pre-flight config
CALL ADM.SP_VALIDATE_CONFIG($PPN);

-- 2b) The table list for this run. A run may legitimately process a SUBSET of ETL_TABLES
--     (schedules vary), so the orchestrator decides the list; this is the "all active" case.
SELECT SOURCE_ID, TABLE_NAME, LOAD_TYPE, LOAD_ORDER
  FROM ADM.ETL_TABLES t
 WHERE t.ACTIVE_FLAG
 ORDER BY LOAD_ORDER;

-- 3) Per-table load (wrapped): landing → check-change → HIST → SILVER, one call each.
--    Each call creates/updates its own ADM.PPN_PROCESS row (no pre-seeded plan).
--    (In production ADF's ForEach issues these, ordered by LOAD_ORDER.)
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'BSS_ORA',   'CUSTOMER');
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'BSS_ORA',   'SERVICE_PLAN');
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'BSS_ORA',   'USAGE_DAILY');
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'WHOLESALE', 'PARTNER_ACCOUNT');
CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'WHOLESALE', 'WHOLESALE_USAGE');

-- 4) Finalize: gate → GOLD (stub) → close. Returns SUCCESS, or raises if the run failed.
--    The gate runs antFarm DQ itself (group DQ_SILVER, blocking severity 100 — fixed inside
--    SP_GATE_CHECK), so there is no separate DQ step. Before real antFarm exists this needs the
--    stub from Account Setup/antfarm/ANTFARM_DUMMY_SETUP.sql, whose DQ_SILVER rows are clean.
--    2nd argument = how many tables were dispatched above, so the gate can also prove that none
--    went missing (PPN_PROCESS only holds tables that were actually invoked). ADF supplies
--    @length(activity('LookupTables').output.value); omit it to check failures only.
CALL ADM.SP_FINALIZE_RUN($PPN, 5);

-- =============================================================================
-- INSPECT — what a PASS looks like
-- =============================================================================
-- Run header: STATUS = SUCCESS, END_TS set
SELECT PPN_ID, RUN_ID, STATUS, START_TS, END_TS FROM ADM.PPN WHERE PPN_ID = $PPN;

-- Per-table state: one row per table that actually ran, each SUCCESS or SKIP.
-- WATERMARK_VALUE is populated for tables with a WATERMARK_COLUMN (the MAX that landed).
SELECT SOURCE_ID, TABLE_NAME, STATUS, PHASE, ROWS_EXTRACTED, ROWS_MERGED, ROWS_DELETED, WATERMARK_VALUE
  FROM ADM.PPN_PROCESS WHERE PPN_ID = $PPN ORDER BY SOURCE_ID, TABLE_NAME;

-- WATERMARK demo (WHOLESALE_USAGE, a DATABASE source -> the filter is enforced):
--   Run 1 has no lower bound, so it loads everything and records MAX(MODIFIED_TS).
--   Then add a newer row in the source and run again - only that row should land:
--     INSERT INTO SHARE_SIM_DB.WHOLESALE.WHOLESALE_USAGE
--       (usage_id, account_id, usage_date, units, amount, modified_ts)
--       VALUES (50099, 9001, CURRENT_DATE(), 7777, 999.99, CURRENT_TIMESTAMP());
--     CALL ADM.SP_CREATE_PPN('wm-test');  -- capture the new PPN, then:
--     CALL ADM.SP_RUN_TABLE_LOAD(<new ppn>, 'WHOLESALE', 'WHOLESALE_USAGE');
--     SELECT COUNT(*) FROM DEV_DB.BRONZE.WHOLESALE_USAGE;   -- expect just the 1 new row
--   The bound used and reached is visible in the log:
--     SELECT DETAIL_JSON:results:watermark_from::STRING, DETAIL_JSON:results:watermark_to::STRING
--       FROM ADM.PPN_LOG WHERE PHASE = 'LOAD_DATABASE_TO_BRONZE' ORDER BY LOG_ID DESC LIMIT 1;

-- Empty-snapshot guard (optional): a FULL/INIT table landing 0 rows must ERROR, not wipe SILVER.
--   Simulate by pointing a FULL table's FILE_PATTERN at a file with no rows, or by emptying its
--   BRONZE table between landing and the call. Expect failed_phase = EMPTY_GUARD and
--   PPN_PROCESS.STATUS = ERROR. Set ETL_TABLES.ALLOW_EMPTY = TRUE only if empty is legitimate.
--   SELECT TABLE_NAME, LOAD_TYPE, ALLOW_EMPTY FROM ADM.ETL_TABLES ORDER BY 1;

-- Gate verdict (SP_GATE_CHECK, called by SP_FINALIZE_RUN — blocks GOLD on FAIL).
-- DQ_VERDICT: PASS = clean, WARN = findings below severity 100 (GOLD still built),
--             FAIL = blocking finding or DQ did not complete, SKIPPED = tables already failed.
SELECT DETAIL_JSON:gate:gate::STRING            AS GATE,
       DETAIL_JSON:gate:tables_reported::NUMBER AS REPORTED,
       DETAIL_JSON:gate:tables_expected::NUMBER AS EXPECTED,
       DETAIL_JSON:gate:tables_missing::NUMBER  AS MISSING,
       DETAIL_JSON:gate:entries_not_ok::NUMBER  AS NOT_OK,
       DETAIL_JSON:gate:dq_verdict::STRING      AS DQ_VERDICT,
       DETAIL_JSON:gate:dq_run_id::STRING       AS DQ_RUN_ID,
       DETAIL_JSON:gate:dq_reason::STRING       AS DQ_REASON,
       DETAIL_JSON:gate:reason::STRING          AS REASON
  FROM ADM.PPN_LOG WHERE PPN_ID = $PPN AND PHASE = 'GATE_CHECK';

-- Full DQ payload for the run (failed checks + sampled error rows, capped at 5 per check):
SELECT DETAIL_JSON:gate:dq_result AS DQ_RESULT
  FROM ADM.PPN_LOG WHERE PPN_ID = $PPN AND PHASE = 'GATE_CHECK';

-- Gate FAIL demo (three branches):
--   a) a failed table blocks GOLD — the loaders never raise, so this is the ONLY thing that
--      catches it. Force one table to ERROR (e.g. drop its stage files), then re-run finalize:
--        expect GATE=FAIL, ENTRIES_NOT_OK=1, REASON naming the table, PPN.STATUS=ERROR,
--        and NO GOLD refresh.
--   b) a missing table blocks GOLD — dispatch only 4 of the 5 loads above but call
--        CALL ADM.SP_FINALIZE_RUN($PPN, 5);
--      expect GATE=FAIL, REPORTED=4, EXPECTED=5, MISSING=1.
--   c) a blocking DQ finding blocks GOLD even when every table loaded — see
--      Account Setup/antfarm/ANTFARM_DUMMY_DEMO.sql demo 11a: give DEMO-LOG-SILVER-1 errors,
--      re-run finalize, expect GATE=FAIL, DQ_VERDICT=FAIL, no GOLD refresh. Demo 11b shows the
--      severity-50 case passing with DQ_VERDICT=WARN. Reset with demo 11c.
--      Passing 4 (or omitting the argument) would PASS — that is the point of the parameter:
--      only the orchestrator knows how many tables tonight's schedule actually contains.

-- Step log: the phase trail incl. GATE_CHECK, REFRESH_GOLD (stub), CLOSE_PPN (END)
SELECT LOG_ID, PHASE, STATUS, TABLE_NAME, ROW_COUNT, MESSAGE
  FROM ADM.PPN_LOG WHERE PPN_ID = $PPN ORDER BY LOG_ID;

-- Spot-check the cleansed layer
SELECT PK_HK, ROW_HK, IS_DELETED, CUSTOMER_ID, CITY FROM DEV_DB.SILVER.CUSTOMER ORDER BY CUSTOMER_ID;
