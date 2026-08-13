-- ADM.SP_GATE_CHECK - the pre-GOLD gate. Pure read of ADM.PPN_PROCESS; runs no data logic and
-- writes nothing (not even a log row - SP_FINALIZE_RUN logs the verdict it received).
--
-- WHY THE GATE EXISTS: SP_RUN_TABLE_LOAD deliberately does NOT raise when one table fails - it
-- records STATUS='ERROR' on its PPN_PROCESS row and returns, so one bad table does not abort the
-- whole run. That means the orchestrator sees a SUCCESSFUL activity even for a failed table.
-- This gate is the only thing that turns those ERROR rows into a blocked GOLD + a failed run.
--
-- VERDICT (fail-closed - anything unclear is FAIL):
--   FAIL if no table reported at all for this PPN.
--   FAIL if any entry has a STATUS outside (SUCCESS, SKIP) - covers ERROR, a left-over RUNNING
--        from a crashed call, and any unknown/NULL value.
--   FAIL if P_EXPECTED_COUNT is supplied and fewer tables reported than were dispatched.
--   PASS otherwise.
--
-- COMPLETENESS (P_EXPECTED_COUNT, optional):
--   PPN_PROCESS only contains tables that were actually invoked - a table the orchestrator never
--   dispatched leaves no row and is therefore invisible here. Snowflake cannot know the intended
--   list: a run may legitimately process a varying SUBSET of ETL_TABLES (schedules differ), so
--   comparing against "all active tables" would be wrong. The orchestrator is the only component
--   that knows the list, so it passes the ONE number it already has - the size of its ForEach
--   collection (ADF: @length(activity('LookupTables').output.value)).
--   A count is sufficient because each dispatched table upserts exactly one row (PK on
--   PPN_ID + SOURCE_ID + TABLE_NAME), so duplicates are impossible: reported < expected can only
--   mean a dispatch never reached Snowflake. Leave it NULL to check failures only.
--
-- RESERVED SOURCE_ID '_RUN_': run-level verdicts rather than tables, e.g. the future DQ result
--   (SOURCE_ID='_RUN_', TABLE_NAME='_DQ_') written by SP_RUN_DQ_CHECKS - SUCCESS/SKIP to pass,
--   ERROR to block GOLD. Such rows count towards the failure test (one uniform rule) but NOT
--   towards the table counts, so the P_EXPECTED_COUNT comparison stays apples-to-apples.

use role dev_sysadmin;
use database dev_db;
use schema adm;

-- Signature changed (P_EXPECTED_COUNT added). Snowflake overloads on argument types, so the old
-- 1-argument version must go or a single-argument CALL becomes ambiguous.
DROP PROCEDURE IF EXISTS ADM.SP_GATE_CHECK(NUMBER);

CREATE OR REPLACE PROCEDURE ADM.SP_GATE_CHECK(
    "P_PPN_ID"         NUMBER(38,0),
    "P_EXPECTED_COUNT" NUMBER(38,0) DEFAULT NULL   -- tables the orchestrator dispatched; NULL = skip
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Pre-GOLD gate (fail-closed): PASS iff >=1 table reported, none outside SUCCESS/SKIP, and no dispatched table missing. Pure read.'
EXECUTE AS CALLER
AS
DECLARE
    v_ppn      NUMBER DEFAULT P_PPN_ID;
    v_expected NUMBER DEFAULT P_EXPECTED_COUNT;
    v_reported NUMBER DEFAULT 0;    -- table entries (excludes reserved '_RUN_' rows)
    v_bad      NUMBER DEFAULT 0;    -- entries not SUCCESS/SKIP (includes '_RUN_' rows)
    v_missing  NUMBER DEFAULT 0;
    v_bad_list STRING;
    v_gate     STRING;
    v_reason   STRING;
BEGIN
    IF (v_ppn IS NULL) THEN
        -- Not a verdict, an input error. SP_FINALIZE_RUN reads a missing 'gate' key as FAIL.
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_GATE_CHECK','message','P_PPN_ID is required.');
    END IF;

    SELECT COUNT_IF(SOURCE_ID <> '_RUN_'),
           COUNT_IF(UPPER(COALESCE(STATUS, '')) NOT IN ('SUCCESS', 'SKIP'))
      INTO :v_reported, :v_bad
      FROM ADM.PPN_PROCESS
     WHERE PPN_ID = :v_ppn;

    v_missing := IFF(v_expected IS NULL, 0, GREATEST(0, v_expected - v_reported));

    /* Name the offenders - "3 of 12 not SUCCESS/SKIP" alone sends the operator digging.
       Second query, but only when something is actually wrong. Capped at 10. */
    IF (v_bad > 0) THEN
        SELECT LISTAGG(SOURCE_ID || '.' || TABLE_NAME || '=' || UPPER(COALESCE(STATUS, '<null>')), ', ')
          INTO :v_bad_list
          FROM (SELECT SOURCE_ID, TABLE_NAME, STATUS
                  FROM ADM.PPN_PROCESS
                 WHERE PPN_ID = :v_ppn
                   AND UPPER(COALESCE(STATUS, '')) NOT IN ('SUCCESS', 'SKIP')
                 ORDER BY SOURCE_ID, TABLE_NAME
                 LIMIT 10);
    END IF;

    IF (v_reported = 0) THEN
        v_gate   := 'FAIL';
        v_reason := 'No table reported for this PPN - the orchestrator loop never ran, or no call '
                 || 'reached Snowflake.';
    ELSEIF (v_bad > 0) THEN
        v_gate   := 'FAIL';
        v_reason := v_bad || ' entry/entries not SUCCESS/SKIP: ' || COALESCE(v_bad_list, '(unavailable)')
                 || IFF(v_bad > 10, ' ... (first 10 shown)', '') || '.';
    ELSEIF (v_missing > 0) THEN
        v_gate   := 'FAIL';
        v_reason := v_missing || ' of ' || v_expected || ' dispatched table(s) never reported - only '
                 || v_reported || ' wrote a PPN_PROCESS row. A dispatch did not reach Snowflake.';
    ELSE
        v_gate   := 'PASS';
        v_reason := 'All ' || v_reported || ' reported table(s) SUCCESS/SKIP'
                 || IFF(v_expected IS NULL, ' (completeness not checked - no expected count supplied)',
                                            ' and all ' || v_expected || ' dispatched table(s) reported') || '.';
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',                 -- the CHECK ran; the verdict is in 'gate'
        'procedure', 'SP_GATE_CHECK',
        'gate', v_gate,
        'ppn_id', v_ppn,
        'tables_reported', v_reported,
        'tables_expected', v_expected,       -- NULL when completeness was not checked
        'tables_missing', v_missing,
        'entries_not_ok', v_bad,
        'entries_not_ok_list', v_bad_list,
        'reason', v_reason
    );
END;
