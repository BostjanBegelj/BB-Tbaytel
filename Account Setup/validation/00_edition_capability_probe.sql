-- ============================================================
-- EDITION / CAPABILITY PROBE
-- RUN FIRST, on any new account, before anything else.
--
-- SHOW ORGANIZATION ACCOUNTS returns no rows on a trial account - the
-- ORGADMIN role exists but the organisation has no registered accounts
-- yet - so it cannot be used to read the edition. The Snowsight UI shows
-- it (Admin > Cost Management), but the label matters less than whether
-- the features this build depends on actually work.
--
-- This file proves them empirically. Every statement below FAILS on
-- Standard Edition and SUCCEEDS on Enterprise or higher. Run it top to
-- bottom: the first error tells you the account cannot run the build.
--
-- Everything is created in a throwaway database and dropped at the end.
-- Compute cost is negligible - no warehouse is resumed.
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS PROBE_DB
  COMMENT = 'Throwaway. Dropped at the end of this script.';
CREATE SCHEMA IF NOT EXISTS PROBE_DB.P;
USE SCHEMA PROBE_DB.P;


-- ------------------------------------------------------------
-- 1. Extended Time Travel  (Enterprise+)
--    Standard caps DATA_RETENTION_TIME_IN_DAYS at 1.
--    Needed by: environment/04_environment_schemas.sql (7 and 30 days)
-- ------------------------------------------------------------
ALTER DATABASE PROBE_DB SET DATA_RETENTION_TIME_IN_DAYS = 7;


-- ------------------------------------------------------------
-- 2. Object tagging  (Enterprise+)
--    Needed by: account/09 - DATA_CLASSIFICATION and PII_TYPE
-- ------------------------------------------------------------
CREATE TAG IF NOT EXISTS T_PROBE COMMENT = 'probe';


-- ------------------------------------------------------------
-- 3. Column-level Security / masking policies  (Enterprise+)
--    Needed by: account/09 - the whole tag-driven masking framework
-- ------------------------------------------------------------
CREATE MASKING POLICY IF NOT EXISTS MP_PROBE
  AS (V STRING) RETURNS STRING -> '***MASKED***';


-- ------------------------------------------------------------
-- 4. Row-level Security / row access policies  (Enterprise+)
--    Needed by: account/09 - RAP_DOMAIN
-- ------------------------------------------------------------
CREATE ROW ACCESS POLICY IF NOT EXISTS RAP_PROBE
  AS (V STRING) RETURNS BOOLEAN -> TRUE;


-- ------------------------------------------------------------
-- 5. Tag-based policy attachment  (Enterprise+)
--    The mechanism the classification design depends on: without this,
--    tagging a column does not mask it and the whole approach changes.
-- ------------------------------------------------------------
ALTER TAG T_PROBE SET MASKING POLICY MP_PROBE FORCE;


-- ------------------------------------------------------------
-- 6. Multi-cluster warehouses  (Enterprise+)
--    Not used in Phase 1, but a clean Enterprise indicator and it costs
--    nothing while suspended.
-- ------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS WH_PROBE
  WAREHOUSE_SIZE = XSMALL
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 2
  INITIALLY_SUSPENDED = TRUE
  AUTO_SUSPEND = 60;


-- ------------------------------------------------------------
-- 7. Report
--    If every statement above succeeded, the account is Enterprise or
--    higher and the build can proceed.
--
--    Business Critical cannot be proven this way - its distinguishing
--    features (Private Link, failover groups, Tri-Secret Secure) either
--    need a second account or are unavailable on a trial. Confirm the
--    edition label in Snowsight (Admin > Cost Management) or with the
--    account executive.
-- ------------------------------------------------------------
SELECT 'Enterprise or higher - all required capabilities available' AS RESULT,
       CURRENT_ACCOUNT()           AS ACCOUNT_LOCATOR,
       CURRENT_ORGANIZATION_NAME() AS ORGANIZATION,
       CURRENT_REGION()            AS REGION,
       CURRENT_TIMESTAMP()         AS CHECKED_AT;


-- ------------------------------------------------------------
-- 8. Clean up. Leave nothing behind.
-- ------------------------------------------------------------
DROP WAREHOUSE IF EXISTS WH_PROBE;
DROP DATABASE  IF EXISTS PROBE_DB;

SHOW DATABASES  LIKE 'PROBE_DB';    -- expect no rows
SHOW WAREHOUSES LIKE 'WH_PROBE';    -- expect no rows
