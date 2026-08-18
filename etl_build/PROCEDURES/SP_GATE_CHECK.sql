-- ADM.SP_GATE_CHECK - the pre-GOLD gate. Two verdicts in one place: did every dispatched table
-- load, and does the data pass antFarm DQ. GOLD is refreshed only if both hold.
--
-- WHY THE GATE EXISTS: SP_RUN_TABLE_LOAD deliberately does NOT raise when one table fails - it
-- records STATUS='ERROR' on its PPN_PROCESS row and returns, so one bad table does not abort the
-- whole run. That means the orchestrator sees a SUCCESSFUL activity even for a failed table.
-- This gate is the only thing that turns those ERROR rows into a blocked GOLD + a failed run.
--
-- NOT A PURE READ ANY MORE: the gate now invokes antFarm DQ itself through ADM.SP_DQ_EXECUTE,
-- so it both runs and judges DQ. That is deliberate - the alternative was a separate
-- SP_RUN_DQ_CHECKS whose verdict the gate re-read from a PPN_PROCESS row, which meant two places
-- to keep in step and a run-level row that had to be excluded from the table counts. One caller,
-- one verdict. The procedure still writes nothing itself; SP_FINALIZE_RUN logs the object it gets
-- back, DQ detail included.
--
-- VERDICT (fail-closed - anything unclear is FAIL):
--   FAIL if no table reported at all for this PPN.
--   FAIL if any entry has a STATUS outside (SUCCESS, SKIP) - covers ERROR, a left-over RUNNING
--        from a crashed call, and any unknown/NULL value.
--   FAIL if P_EXPECTED_COUNT is supplied and fewer tables reported than were dispatched.
--   FAIL if antFarm DQ did not complete technically, or reported a finding at or above the
--        blocking severity, or reported findings whose severity cannot be read.
--   PASS otherwise. DQ findings below the blocking severity PASS with dq_verdict = 'WARN'.
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
-- DQ SETTINGS ARE FIXED, NOT PARAMETERS (see the DECLARE block):
--   DQ_GROUP          'DQ_SILVER' - the pre-GOLD DQ group. One gate, one group; there is nothing
--                     for a caller to choose, and keeping it out of the signature means the ADF
--                     contract for SP_FINALIZE_RUN / SP_GATE_CHECK does not change.
--   BLOCKING_SEVERITY 100 - antFarm severity at or above which a finding blocks GOLD. Below it
--                     the run continues and the finding is reported as a warning. Matches
--                     TBAY-267 CRITICAL = blocking.
--   DQ_SAMPLE_ROWS    5 - error rows per failed check carried back in the result. The whole
--                     object lands in PPN_LOG via SP_FINALIZE_RUN, so this is kept small; the
--                     full set stays in PLATFORM_DB.ANTFARM.DQ_LOG.
--   Change any of these in one line here rather than threading them through two signatures.
--
-- DQ IS SKIPPED WHEN THE TABLE CHECKS ALREADY FAILED: GOLD is blocked either way, so there is no
--   reason to spend an antFarm execution and up to an hour of warehouse polling on a run that is
--   already dead. Reported as dq_verdict = 'SKIPPED' with the reason, never as a pass.
--
-- COST: SP_DQ_EXECUTE polls antFarm with SYSTEM$WAIT, which holds the query and stops the
--   warehouse auto-suspending for the whole DQ run. The gate therefore occupies a warehouse for
--   as long as DQ takes (SP_DQ_EXECUTE default P_TIMEOUT_S = 3600). The ADF activity timeout on
--   SP_FINALIZE_RUN must exceed that.
--
-- GRANTS: EXECUTE AS CALLER, so the calling role ({ENV}_DATA_LOADER for ADF) needs USAGE on
--   ADM.SP_DQ_EXECUTE / ADM.SP_DQ_RESULT and on the PLATFORM_DB.ANTFARM objects they reach, plus
--   SELECT on PLATFORM_DB.ANTFARM.DQ_LOG.
--
-- RESERVED SOURCE_ID '_RUN_': run-level rather than table-level rows. Nothing writes one today -
--   DQ is no longer reported that way - but if a row appears it counts towards the failure test
--   (one uniform rule) and NOT towards the table counts, so P_EXPECTED_COUNT stays
--   apples-to-apples.

use role dev_sysadmin;
use database dev_db;
use schema adm;

-- Signature unchanged (P_PPN_ID, P_EXPECTED_COUNT). The pre-P_EXPECTED_COUNT single-argument
-- version must still go, or a one-argument CALL becomes ambiguous against the overload.
DROP PROCEDURE IF EXISTS ADM.SP_GATE_CHECK(NUMBER);

CREATE OR REPLACE PROCEDURE ADM.SP_GATE_CHECK(
    "P_PPN_ID"         NUMBER(38,0),
    "P_EXPECTED_COUNT" NUMBER(38,0) DEFAULT NULL   -- tables the orchestrator dispatched; NULL = skip
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Pre-GOLD gate (fail-closed): PASS iff >=1 table reported, none outside SUCCESS/SKIP, no dispatched table missing, and antFarm DQ group DQ_SILVER shows no finding at severity >= 100.'
EXECUTE AS CALLER
AS
DECLARE
    /* ---- fixed DQ settings (see header) ---------------------------------------------------- */
    c_dq_group    STRING DEFAULT 'DQ_SILVER';
    c_blocking    NUMBER DEFAULT 100;
    c_sample_rows NUMBER DEFAULT 5;

    v_ppn      NUMBER DEFAULT P_PPN_ID;
    v_expected NUMBER DEFAULT P_EXPECTED_COUNT;
    v_reported NUMBER DEFAULT 0;    -- table entries (excludes reserved '_RUN_' rows)
    v_bad      NUMBER DEFAULT 0;    -- entries not SUCCESS/SKIP (includes '_RUN_' rows)
    v_missing  NUMBER DEFAULT 0;
    v_bad_list STRING;
    v_tables_ok BOOLEAN DEFAULT FALSE;

    v_dq         VARIANT;                            -- full ADM.SP_DQ_EXECUTE return
    v_dq_res     VARIANT;                            -- its dq_result member
    v_dq_verdict STRING  DEFAULT 'NOT_RUN';          -- PASS | WARN | FAIL | SKIPPED | NOT_RUN
    v_dq_reason  STRING  DEFAULT '';
    v_dq_status  STRING;
    v_dq_issues  BOOLEAN;
    v_dq_sev     NUMBER;

    v_gate     STRING;
    v_reason   STRING;
BEGIN
    IF (v_ppn IS NULL) THEN
        -- Not a verdict, an input error. SP_FINALIZE_RUN reads a missing 'gate' key as FAIL.
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_GATE_CHECK','message','P_PPN_ID is required.');
    END IF;

    /* 1. TABLE CHECKS ---------------------------------------------------------------------- */

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

    v_tables_ok := (v_reported > 0 AND v_bad = 0 AND v_missing = 0);

    /* 2. DQ -------------------------------------------------------------------------------- */

    IF (NOT v_tables_ok) THEN
        v_dq_verdict := 'SKIPPED';
        v_dq_reason  := 'antFarm DQ not run - the table checks already blocked GOLD, so a DQ '
                     || 'execution would only cost warehouse time.';
    ELSE
        /* SP_DQ_EXECUTE never raises - it returns status=FAILED. The handler is for the case
           where the DQ procedures are not deployed yet, so the CALL itself fails to compile.
           Fail-closed: an unavailable DQ service is not a pass. */
        BEGIN
            CALL ADM.SP_DQ_EXECUTE(
                P_DQ_GROUP_NAME  => :c_dq_group,
                P_OUTPUT_TYPE    => 'JSON',
                P_MAX_ERROR_ROWS => :c_sample_rows
            ) INTO :v_dq;
        EXCEPTION
            WHEN OTHER THEN
                v_dq_verdict := 'FAIL';
                v_dq_reason  := 'Could not invoke ADM.SP_DQ_EXECUTE for group ' || c_dq_group
                             || ': ' || SQLERRM;
        END;

        IF (v_dq_verdict <> 'FAIL') THEN
            v_dq_res    := GET(v_dq, 'dq_result');
            v_dq_status := UPPER(COALESCE(GET(v_dq, 'status')::STRING, 'FAILED'));
            v_dq_issues := COALESCE(GET(v_dq_res, 'has_issues')::BOOLEAN, TRUE);
            v_dq_sev    := TRY_TO_NUMBER(GET(v_dq_res, 'max_severity_level')::STRING);

            IF (v_dq_status <> 'SUCCESS') THEN
                v_dq_verdict := 'FAIL';
                v_dq_reason  := 'antFarm DQ did not complete (status ' || v_dq_status
                             || ', phase ' || COALESCE(GET(v_dq, 'phase')::STRING, '<none>') || '): '
                             || COALESCE(GET(v_dq, 'message')::STRING, '(no message)');
            ELSEIF (NOT v_dq_issues) THEN
                v_dq_verdict := 'PASS';
                v_dq_reason  := 'DQ group ' || c_dq_group || ' clean ('
                             || COALESCE(GET(v_dq_res, 'total_checks')::STRING, '?')
                             || ' check(s), 0 errors).';
            ELSEIF (v_dq_sev IS NULL) THEN
                /* Findings exist but severity is unreadable - unknown never means success. */
                v_dq_verdict := 'FAIL';
                v_dq_reason  := 'DQ group ' || c_dq_group || ' reported findings with no readable '
                             || 'severity - treated as blocking.';
            ELSEIF (v_dq_sev >= c_blocking) THEN
                v_dq_verdict := 'FAIL';
                v_dq_reason  := 'DQ group ' || c_dq_group || ' blocking: severity ' || v_dq_sev
                             || ' (' || COALESCE(GET(v_dq_res, 'max_severity_name')::STRING, '?')
                             || ') >= ' || c_blocking || ', '
                             || COALESCE(GET(v_dq_res, 'failed_checks')::STRING, '?')
                             || ' failed check(s), '
                             || COALESCE(GET(v_dq_res, 'total_errors')::STRING, '?') || ' error(s).';
            ELSE
                v_dq_verdict := 'WARN';
                v_dq_reason  := 'DQ group ' || c_dq_group || ' has findings below the blocking '
                             || 'severity (max ' || v_dq_sev || ' < ' || c_blocking || ', '
                             || COALESCE(GET(v_dq_res, 'failed_checks')::STRING, '?')
                             || ' failed check(s)) - GOLD allowed.';
            END IF;
        END IF;
    END IF;

    /* 3. VERDICT --------------------------------------------------------------------------- */

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
    ELSEIF (v_dq_verdict = 'FAIL') THEN
        v_gate   := 'FAIL';
        v_reason := 'All ' || v_reported || ' table(s) loaded, but DQ blocked GOLD. ' || v_dq_reason;
    ELSE
        v_gate   := 'PASS';
        v_reason := 'All ' || v_reported || ' reported table(s) SUCCESS/SKIP'
                 || IFF(v_expected IS NULL, ' (completeness not checked - no expected count supplied)',
                                            ' and all ' || v_expected || ' dispatched table(s) reported')
                 || '. ' || v_dq_reason;
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
        'dq_group', c_dq_group,
        'dq_blocking_severity', c_blocking,
        'dq_verdict', v_dq_verdict,          -- PASS | WARN | FAIL | SKIPPED
        'dq_reason', v_dq_reason,
        'dq_run_id', GET(v_dq, 'run_id'),
        'dq_result', v_dq,                   -- full SP_DQ_EXECUTE object; NULL when not run
        'reason', v_reason
    );
END;
