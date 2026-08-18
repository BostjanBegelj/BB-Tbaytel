-- =====================================================================
-- STANDALONE DQ DEMO SCRIPT
-- =====================================================================
--
-- Prerequisites:
--
--   1. Run ANTFARM_DUMMY_SETUP.sql in PLATFORM_DB.
--   2. Deploy in the environment DB:
--
--         ADM.SP_SEND_NOTIFICATION
--         ADM.SP_DQ_RESULT
--         ADM.SP_DQ_EXECUTE
--
-- DEV is shown below. Change USE DATABASE for TEST / PROD.
-- =====================================================================


USE DATABASE DEV_DB;
USE SCHEMA ADM;


-- =====================================================================
-- DEMO 1: TECHNICAL SUCCESS + ZERO DQ ERRORS
--
-- Expected:
--   top-level status        = SUCCESS
--   dq_result.status        = SUCCESS
--   dq_result.has_issues    = FALSE
--   dq_result.total_checks  = 2
--   dq_result.failed_checks = 0
--   dq_result.total_errors  = 0
--   dq_result.results       = []
-- =====================================================================

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DEMO_OK',
    P_OUTPUT_TYPE   => 'JSON'
);


-- =====================================================================
-- DEMO 2: TECHNICAL SUCCESS + DQ ISSUES
--
-- Expected:
--   top-level status                   = SUCCESS
--   dq_result.status                   = SUCCESS
--   dq_result.has_issues               = TRUE
--   dq_result.total_checks             = 3
--   dq_result.failed_checks            = 2
--   dq_result.total_errors             = 3
--   dq_result.max_severity_level       = 100
--
-- This demonstrates that DQ findings are not technical failures.
-- =====================================================================

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DEMO_ISSUES',
    P_OUTPUT_TYPE   => 'JSON'
);


-- =====================================================================
-- DEMO 3: EXECUTION ONLY
-- =====================================================================

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DEMO_ISSUES'
);


-- =====================================================================
-- DEMO 4: RESULT PROCEDURE CALLED SEPARATELY
-- =====================================================================

CALL ADM.SP_DQ_RESULT(
    'DEMO_RUN_ISSUES',
    'JSON'
);


-- =====================================================================
-- DEMO 5: TECHNICAL DQ EXECUTION SUCCESS BUT RESULT IS MISSING
--
-- API_DQ_GET_LOG returns task_status = SUCCESS, but the dummy DQ_LOG
-- contains no rows for this RUN_ID.
--
-- Expected:
--   top-level status = FAILED
--   phase            = GET_RESULT
--   dq_result.status = FAILED
--
-- This proves result-read failures cannot be hidden by a top-level
-- SUCCESS.
-- =====================================================================

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DEMO_RESULT_MISSING',
    P_OUTPUT_TYPE   => 'JSON'
);


-- =====================================================================
-- DEMO 6: SIMULATED TECHNICAL ANTFARM FAILURE
--
-- Expected:
--   top-level status = FAILED
--   task_status      = FAILED
-- =====================================================================

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DEMO_TECH_FAIL',
    P_OUTPUT_TYPE   => 'JSON'
);


-- =====================================================================
-- DEMO 7: METADATA REFRESH FAILURE
--
-- The real LOAD_API_*_META_DATA procedures catch their own exceptions
-- and report failure only in the returned text. The stub reproduces
-- that for P_CALLER_ID = 'demo_meta_fail'.
--
-- Expected:
--   status   = FAILED
--   phase    = REFRESH_METADATA
--   response = 'Error executing SQL: dummy ... failure'
--
-- API_RUN_DQ is never reached.
-- =====================================================================

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DEMO_OK',
    P_CALLER_ID     => 'demo_meta_fail',
    P_OUTPUT_TYPE   => 'JSON'
);


-- =====================================================================
-- DEMO 8: UNKNOWN DQ GROUP
--
-- API_RUN_DQ returns http_code 400 and no run_id.
--
-- Expected:
--   status    = FAILED
--   phase     = RUN_DQ
--   http_code = 400
-- =====================================================================

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DOES_NOT_EXIST',
    P_OUTPUT_TYPE   => 'JSON'
);


-- =====================================================================
-- DEMO 9: EMAIL MODE WITHOUT ACTIVE RECIPIENTS
--
-- Dummy DQ_LOG starts with no active recipients.
--
-- Expected:
--   top-level status         = SUCCESS
--   dq_result.has_issues     = TRUE
--   dq_result.emails_sent    = 0
--   dq_result.emails_skipped = 1
--   dq_result.email_status   = SKIPPED
--   dq_result.message        = '... no active Antfarm email recipient ...'
--
-- No real email is attempted. SKIPPED is a configuration gap, not a
-- transport failure, so the run is not failed - but it is reported.
-- =====================================================================

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DEMO_ISSUES',
    P_OUTPUT_TYPE   => 'EMAIL'
);


-- =====================================================================
-- OPTIONAL DEMO 10: REAL EMAIL DELIVERY
--
-- Only use when:
--   * EMAIL_INTEGRATION exists;
--   * the recipient is a verified Snowflake user in this account;
--   * the recipient is present in EMAIL_INTEGRATION.ALLOWED_RECIPIENTS;
--   * the executing role has USAGE on EMAIL_INTEGRATION.
--
-- Replace the address before running.
-- =====================================================================

/*

UPDATE PLATFORM_DB.ANTFARM.DQ_LOG
SET DQ_LOG_MAIL_TO =
    '{"active":["your.verified.user@company.com"],"inactive":[]}'
WHERE RUN_ID = 'DEMO_RUN_ISSUES';

CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_DEMO_ISSUES',
    P_OUTPUT_TYPE   => 'EMAIL'
);

*/


-- =====================================================================
-- DEMO 11: THE PRE-GOLD GATE
--
-- ADM.SP_GATE_CHECK invokes DQ itself, with the group name and the
-- blocking severity fixed inside the procedure:
--
--     DQ_SILVER, blocking severity 100
--
-- The stub's DQ_SILVER rows are clean, so a run whose tables all
-- loaded should give:
--
--     gate       = PASS
--     dq_verdict = PASS
--     dq_run_id  = DEMO_RUN_SILVER
--
-- Needs a real PPN with PPN_PROCESS rows - use the PPN from
-- etl_build/TESTS/run_clean_end_to_end.sql.
-- =====================================================================

-- CALL ADM.SP_GATE_CHECK(P_PPN_ID => <ppn>, P_EXPECTED_COUNT => <n>);


-- ---------------------------------------------------------------------
-- 11a. BLOCKING DQ -> gate FAIL
--
-- Give the high-severity SILVER check errors. Expected:
--
--     gate       = FAIL
--     dq_verdict = FAIL
--     reason     = 'All n table(s) loaded, but DQ blocked GOLD. ...'
--
-- SP_FINALIZE_RUN then skips GOLD, closes the run ERROR and re-raises.
-- ---------------------------------------------------------------------

/*
UPDATE PLATFORM_DB.ANTFARM.DQ_LOG
SET NUM_OF_ERRORS = 2,
    ERROR_ROWS    = '[{"CUSTOMER_BK":null},{"CUSTOMER_BK":null}]',
    STATUS_ID     = 2,
    ERROR_MESSAGE = 'Demo blocking SILVER finding'
WHERE DQ_LOG_ID = 'DEMO-LOG-SILVER-1';

CALL ADM.SP_GATE_CHECK(P_PPN_ID => <ppn>, P_EXPECTED_COUNT => <n>);
*/


-- ---------------------------------------------------------------------
-- 11b. NON-BLOCKING DQ -> gate PASS with a warning
--
-- Clear the severity-100 check and give errors to the severity-50 one.
-- Expected:
--
--     gate       = PASS
--     dq_verdict = WARN
--     dq_reason  = '... below the blocking severity (max 50 < 100 ...)'
--
-- GOLD is still refreshed. This is the difference between a finding
-- that stops the pipeline and one that only gets reported.
-- ---------------------------------------------------------------------

/*
UPDATE PLATFORM_DB.ANTFARM.DQ_LOG
SET NUM_OF_ERRORS = 0, ERROR_ROWS = '[]', STATUS_ID = 1, ERROR_MESSAGE = NULL
WHERE DQ_LOG_ID = 'DEMO-LOG-SILVER-1';

UPDATE PLATFORM_DB.ANTFARM.DQ_LOG
SET NUM_OF_ERRORS = 1,
    ERROR_ROWS    = '[{"CUSTOMER_BK":"DUP-1"}]',
    STATUS_ID     = 2,
    ERROR_MESSAGE = 'Demo non-blocking SILVER finding'
WHERE DQ_LOG_ID = 'DEMO-LOG-SILVER-2';

CALL ADM.SP_GATE_CHECK(P_PPN_ID => <ppn>, P_EXPECTED_COUNT => <n>);
*/


-- ---------------------------------------------------------------------
-- 11c. RESET DQ_SILVER TO CLEAN
-- ---------------------------------------------------------------------

/*
UPDATE PLATFORM_DB.ANTFARM.DQ_LOG
SET NUM_OF_ERRORS = 0, ERROR_ROWS = '[]', STATUS_ID = 1, ERROR_MESSAGE = NULL
WHERE RUN_ID = 'DEMO_RUN_SILVER';
*/


-- ---------------------------------------------------------------------
-- 11d. DQ SKIPPED BECAUSE THE TABLES ALREADY FAILED
--
-- Use a PPN that has an ERROR row in PPN_PROCESS. Expected:
--
--     gate       = FAIL   (on the table entry, as before)
--     dq_verdict = SKIPPED
--     dq_result  = NULL
--
-- No antFarm execution is spent on a run that is already blocked.
-- ---------------------------------------------------------------------

-- CALL ADM.SP_GATE_CHECK(P_PPN_ID => <ppn with a failed table>);


-- =====================================================================
-- INSPECT DUMMY HISTORICAL RESULTS
-- =====================================================================

SELECT
    RUN_ID,
    DQ_GROUP_NAME,
    DQ_RULE_NAME,
    DQ_SEVERITY_LEVEL,
    DQ_SEVERITY_NAME,
    NUM_OF_ERRORS,
    ERROR_ROWS
FROM PLATFORM_DB.ANTFARM.DQ_LOG
ORDER BY RUN_ID, DQ_RULE_NAME;
