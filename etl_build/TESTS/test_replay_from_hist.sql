-- =============================================================================
-- TEST — SP_REPLAY_FROM_HIST (SILVER recovery from BRONZE_HIST)
--
-- Proves the recovery procedure reconstructs SILVER faithfully by replaying the stored
-- BRONZE_HIST snapshots through the production SILVER logic (SP_LOAD_BRONZE_TO_SILVER):
--   A) FULL REBUILD  (P_RECREATE_SILVER=TRUE)  — drop SILVER, replay all history, and prove the
--                                                rebuilt SILVER equals the pre-drop baseline.
--   B) IN-PLACE REPLAY over the FULL window (P_RECREATE_SILVER=FALSE) — replaying the whole
--                                                history in order onto an already-correct SILVER
--                                                is idempotent (ends at the same state).
--   C) GUARDS — empty window is a no-op (SILVER untouched); a de-configured table is refused.
--
-- The comparison is on the SEMANTIC state only (PK_HK, ROW_HK, IS_DELETED) — NOT the DW_* audit
-- timestamps, which are stamped at replay time and are expected to differ.
--
-- Target table: BSS_ORA.CUSTOMER (FILE, FULL, has a PK, and the DEV fixtures include a delete /
-- change across dates 01→02→03, so delete-detection is exercised). USAGE_DAILY notes at the end.
--
-- Prereqs (once):
--   * All etl_build TABLES + PROCEDURES deployed (incl. SP_REPLAY_FROM_HIST); SEED run.
--   * BRONZE_HIST.CUSTOMER must already hold history (>= 2 PPNs is the interesting case).
--     If it does not, first build it with the multi-date loads in
--     TESTS/test_run_control_and_load.sql (or run three dated PPNs of CUSTOMER), then come back.
-- =============================================================================
use role dev_sysadmin;
use warehouse compute_wh;      -- set your dev warehouse
use database dev_db;
use schema adm;

-- -----------------------------------------------------------------------------
-- 0) PRE-FLIGHT: confirm there is history to replay, and capture the window.
-- -----------------------------------------------------------------------------
SELECT COUNT(DISTINCT PPN_ID) AS PPN_COUNT, MIN(PPN_ID) AS MIN_PPN, MAX(PPN_ID) AS MAX_PPN,
       COUNT(*) AS HIST_ROWS
  FROM DEV_DB.BRONZE_HIST.CUSTOMER;      -- expect PPN_COUNT >= 1 (ideally >= 2)

SET REPLAY_MIN = (SELECT MIN(PPN_ID) FROM DEV_DB.BRONZE_HIST.CUSTOMER);
SET REPLAY_MAX = (SELECT MAX(PPN_ID) FROM DEV_DB.BRONZE_HIST.CUSTOMER);
SELECT $REPLAY_MIN AS FROM_PPN, $REPLAY_MAX AS TO_PPN;

-- Baseline: the current (correct) SILVER semantic state, captured before we touch anything.
CREATE OR REPLACE TEMPORARY TABLE ADM.TMP_SILVER_BASELINE AS
SELECT PK_HK, ROW_HK, IS_DELETED FROM DEV_DB.SILVER.CUSTOMER;

SELECT COUNT(*) AS BASELINE_ROWS,
       COUNT_IF(IS_DELETED)      AS BASELINE_DELETED,
       COUNT_IF(NOT IS_DELETED)  AS BASELINE_ACTIVE
  FROM ADM.TMP_SILVER_BASELINE;

-- =============================================================================
-- A) FULL REBUILD — drop SILVER, replay the entire history, compare to baseline.
-- =============================================================================
-- (This is the path to use after a SILVER hash / transform-logic change: a normal run would only
--  re-apply the latest PPN, so the whole history must be replayed under the new rules.)

CALL ADM.SP_REPLAY_FROM_HIST(
    P_SOURCE_ID       => 'BSS_ORA',
    P_TABLE_NAME      => 'CUSTOMER',
    P_RECREATE_SILVER => TRUE);           -- FROM/TO default NULL => whole history

-- Expect the return payload: status=SUCCESS, action=REBUILT, ppns_replayed = PPN_COUNT above,
-- first_ppn/last_ppn = the window, and rows_merged_total / rows_soft_deleted_total populated.

-- A.1 SEMANTIC EQUALITY: rebuilt SILVER must equal the baseline. BOTH selects must return 0 rows.
SELECT 'in_baseline_missing_after_rebuild' AS DIFF, PK_HK, ROW_HK, IS_DELETED
  FROM ADM.TMP_SILVER_BASELINE
  MINUS
SELECT 'in_baseline_missing_after_rebuild', PK_HK, ROW_HK, IS_DELETED
  FROM DEV_DB.SILVER.CUSTOMER
UNION ALL
SELECT 'extra_after_rebuild_not_in_baseline', PK_HK, ROW_HK, IS_DELETED
  FROM DEV_DB.SILVER.CUSTOMER
  MINUS
SELECT 'extra_after_rebuild_not_in_baseline', PK_HK, ROW_HK, IS_DELETED
  FROM ADM.TMP_SILVER_BASELINE;
-- PASS = zero rows returned (rebuilt state is identical to the pre-drop baseline).

-- A.2 Same counts (sanity next to A.1)
SELECT (SELECT COUNT(*) FROM ADM.TMP_SILVER_BASELINE)   AS BASELINE_ROWS,
       (SELECT COUNT(*) FROM DEV_DB.SILVER.CUSTOMER)     AS REBUILT_ROWS,
       (SELECT COUNT_IF(IS_DELETED) FROM DEV_DB.SILVER.CUSTOMER) AS REBUILT_DELETED;

-- A.3 The replay run is auditable end to end under its own PPN:
SELECT PPN_ID, RUN_ID, STATUS, START_TS, END_TS
  FROM ADM.PPN WHERE RUN_ID = 'REPLAY' ORDER BY PPN_ID DESC LIMIT 1;
SET REPLAY_PPN = (SELECT MAX(PPN_ID) FROM ADM.PPN WHERE RUN_ID = 'REPLAY');
SELECT LOG_ID, PHASE, STATUS, TABLE_NAME, ROW_COUNT, MESSAGE
  FROM ADM.PPN_LOG WHERE PPN_ID = $REPLAY_PPN ORDER BY LOG_ID;   -- REPLAY_PLAN + one REPLAY_STEP per PPN + END

-- =============================================================================
-- B) IN-PLACE REPLAY over the FULL window — must be idempotent to the final state.
-- =============================================================================
-- Replaying every stored snapshot in order onto an already-correct SILVER thrashes intermediate
-- state but ends where it started. (A PARTIAL in-place window is for resume/backfill and is NOT
-- expected to equal the baseline — that is why this assertion uses the full MIN..MAX window.)

CALL ADM.SP_REPLAY_FROM_HIST(
    P_SOURCE_ID       => 'BSS_ORA',
    P_TABLE_NAME      => 'CUSTOMER',
    P_FROM_PPN        => $REPLAY_MIN,
    P_TO_PPN          => $REPLAY_MAX,
    P_RECREATE_SILVER => FALSE);          -- do NOT drop; replay in place

-- Expect: status=SUCCESS, action=REPLAYED_IN_PLACE, ppns_replayed = PPN_COUNT.

-- B.1 SEMANTIC EQUALITY vs baseline again — BOTH selects must return 0 rows.
SELECT 'missing_after_inplace' AS DIFF, PK_HK, ROW_HK, IS_DELETED
  FROM ADM.TMP_SILVER_BASELINE
  MINUS
SELECT 'missing_after_inplace', PK_HK, ROW_HK, IS_DELETED FROM DEV_DB.SILVER.CUSTOMER
UNION ALL
SELECT 'extra_after_inplace', PK_HK, ROW_HK, IS_DELETED FROM DEV_DB.SILVER.CUSTOMER
  MINUS
SELECT 'extra_after_inplace', PK_HK, ROW_HK, IS_DELETED FROM ADM.TMP_SILVER_BASELINE;
-- PASS = zero rows.

-- =============================================================================
-- C) GUARDS
-- =============================================================================
-- C.1 Empty window is a safe no-op: SILVER must be LEFT UNTOUCHED (never drop-then-leave-empty).
--     Use a lower bound above the latest PPN so no snapshot qualifies.
CALL ADM.SP_REPLAY_FROM_HIST(
    P_SOURCE_ID       => 'BSS_ORA',
    P_TABLE_NAME      => 'CUSTOMER',
    P_FROM_PPN        => $REPLAY_MAX + 1,
    P_RECREATE_SILVER => TRUE);           -- recreate=TRUE, but NO history in window
-- Expect: status=SUCCESS, action=NO_HISTORY, ppns_replayed=0, and SILVER still populated:
SELECT COUNT(*) AS SILVER_ROWS_STILL_PRESENT FROM DEV_DB.SILVER.CUSTOMER;   -- expect = baseline count

-- C.2 De-configured / unknown table is refused (same config read as the load path).
CALL ADM.SP_REPLAY_FROM_HIST(
    P_SOURCE_ID  => 'BSS_ORA',
    P_TABLE_NAME => 'NO_SUCH_TABLE');
-- Expect: status=ERROR, phase=READ_CONFIG, message "Expected exactly 1 active ... config row ...".

-- =============================================================================
-- (Optional) USAGE_DAILY — a WATERMARK/INCR-style table. Replay treats WATERMARK exactly like
-- INCR (MERGE only, no delete sweep), so a full rebuild reconstructs the accumulated MERGE result.
-- Repeat block A with P_TABLE_NAME => 'USAGE_DAILY' (adjust the baseline capture table name).
-- Note: for INCR/WATERMARK the per-snapshot rows are partial deltas, so the ONLY correct rebuild
-- is replaying ALL snapshots in order — which is exactly what a full rebuild does.
-- =============================================================================

-- Cleanup the scratch baseline (temp table drops with the session anyway):
DROP TABLE IF EXISTS ADM.TMP_SILVER_BASELINE;
