-- ============================================================
-- Access isolation validation  (negative access tests)
-- RUN AFTER EACH DEPLOYMENT, once more than one environment exists.
--
-- Purpose: produce the evidence that TBAY-372 AC4, AC6, AC7 and AC8 ask
--          for - that an environment's roles CANNOT reach another
--          environment, and that PROD write access is limited to the
--          deployment / operational roles.
--
-- 01_validate_state.sql answers "was everything created?".
-- This file answers "is it actually isolated?" - a different question.
-- An inventory can look perfect while a single stray grant makes DEV
-- able to write PROD.
--
-- Structure:
--   PART 1  declarative scan  - three queries that find cross-environment
--                               grants across the whole account.
--   PART 2  behavioural tests - statements that MUST fail, run as each
--                               role. The error IS the evidence.
--   PART 3  positive controls - statements that MUST succeed, so a PASS
--                               in PART 2 can't be caused by a broken role.
--   PART 4  evidence capture.
--
-- PART 1 reads ACCOUNT_USAGE (up to ~2h latency). Immediately after a
-- deployment, rely on PART 2/3, which are real-time.
-- ============================================================


-- ============================================================
-- PART 1 - DECLARATIVE SCAN
-- ============================================================
USE ROLE ACCOUNTADMIN;

-- ------------------------------------------------------------
-- 1.1  Object privileges held across environment boundaries.
--
-- Every environment object lives in {ENV}_DB and is reached only through
-- database roles inside that database. So a privilege on DEV_DB held by
-- anything whose name does not start with DEV_ is a finding.
--
-- Expected result: ZERO ROWS.
-- ------------------------------------------------------------
WITH env_grants AS (
    SELECT
        grantee_name,
        granted_to,
        privilege,
        granted_on,
        COALESCE(table_catalog,
                 CASE WHEN granted_on = 'DATABASE' THEN name END) AS target_db,
        table_schema,
        name
    FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
    WHERE deleted_on IS NULL
)
SELECT
    grantee_name,
    granted_to,
    privilege,
    granted_on,
    target_db,
    table_schema,
    name,
    'Cross-environment privilege' AS finding
FROM env_grants
WHERE target_db IN ('DEV_DB', 'TEST_DB', 'PROD_DB')
  AND SPLIT_PART(target_db, '_', 1) <> SPLIT_PART(grantee_name, '_', 1)
  -- account-level roles legitimately span environments
  AND grantee_name NOT IN ('ACCOUNTADMIN', 'SYSADMIN', 'SECURITYADMIN',
                           'USERADMIN', 'TERRAFORM_ADMIN')
ORDER BY target_db, grantee_name;


-- ------------------------------------------------------------
-- 1.2  Role hierarchy crossing environments.
--
-- A cross-environment role grant is worse than a stray privilege: it
-- hands over everything the granted role can do, now and in future.
--
-- Expected result: ZERO ROWS.
-- ------------------------------------------------------------
SELECT
    grantee_name AS holder_role,
    name         AS granted_role,
    granted_by,
    created_on,
    'Cross-environment role grant' AS finding
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE deleted_on IS NULL
  AND granted_on = 'ROLE'
  AND SPLIT_PART(name, '_', 1)         IN ('DEV', 'TEST', 'PROD')
  AND SPLIT_PART(grantee_name, '_', 1) IN ('DEV', 'TEST', 'PROD')
  AND SPLIT_PART(name, '_', 1) <> SPLIT_PART(grantee_name, '_', 1)
ORDER BY holder_role;


-- ------------------------------------------------------------
-- 1.3  Users holding roles in more than one environment.
--
-- Not automatically wrong - a platform admin may need DEV and PROD - but
-- every case must be a deliberate, named exception. An engineer who holds
-- DEV_TRANSFORMER and PROD_TRANSFORMER makes AC4 untrue in practice, no
-- matter how the grants look.
--
-- Expected result: only the agreed exceptions.
-- ------------------------------------------------------------
SELECT
    grantee_name AS user_name,
    COUNT(DISTINCT SPLIT_PART(role, '_', 1)) AS environments,
    LISTAGG(DISTINCT role, ', ') AS roles_held
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE deleted_on IS NULL
  AND SPLIT_PART(role, '_', 1) IN ('DEV', 'TEST', 'PROD')
GROUP BY grantee_name
HAVING COUNT(DISTINCT SPLIT_PART(role, '_', 1)) > 1
ORDER BY environments DESC, user_name;


-- ------------------------------------------------------------
-- 1.4  Real-time spot check (no ACCOUNT_USAGE latency).
--     Use straight after a deployment. Repeat per environment.
-- ------------------------------------------------------------
-- SHOW GRANTS ON DATABASE PROD_DB;              -- who holds the database itself
-- SHOW GRANTS OF ROLE PROD_TRANSFORMER;         -- who can assume it
-- SHOW GRANTS OF ROLE PROD_DEPLOYER;
-- SHOW GRANTS TO ROLE DEV_TRANSFORMER;          -- nothing here may name PROD_
-- SHOW DATABASE ROLES IN DATABASE PROD_DB;
-- SHOW GRANTS OF DATABASE ROLE PROD_DB.GOLD_FULL_AR;


-- ============================================================
-- PART 2 - BEHAVIOURAL TESTS  (each statement MUST fail)
--
-- Run each block as the stated role. Record the exact error text and the
-- query ID. A statement that SUCCEEDS is a failed test.
--
-- Note on the expected error: Snowflake reports an unauthorised database
-- as "does not exist or not authorized" - it deliberately does not
-- distinguish the two. That message is the correct, expected outcome.
-- ============================================================

-- ------------------------------------------------------------
-- 2.1  DEV engineering role must not reach PROD  (AC4, AC8)
-- ------------------------------------------------------------
USE ROLE DEV_TRANSFORMER;
USE WAREHOUSE DEV_TRANSFORMER_WH;

-- MUST FAIL - read
SELECT COUNT(*) FROM PROD_DB.GOLD.INFORMATION_SCHEMA.TABLES;
-- MUST FAIL - write
CREATE TABLE PROD_DB.BRONZE.T_ISOLATION_TEST (X INT);
-- MUST FAIL - compute
USE WAREHOUSE PROD_TRANSFORMER_WH;

-- ------------------------------------------------------------
-- 2.2  DEV engineering role must not reach TEST  (AC8)
-- ------------------------------------------------------------
USE ROLE DEV_TRANSFORMER;
USE WAREHOUSE DEV_TRANSFORMER_WH;

-- MUST FAIL
CREATE TABLE TEST_DB.BRONZE.T_ISOLATION_TEST (X INT);

-- ------------------------------------------------------------
-- 2.3  TEST role must not reach PROD  (AC8)
-- ------------------------------------------------------------
USE ROLE TEST_TRANSFORMER;
USE WAREHOUSE TEST_TRANSFORMER_WH;

-- MUST FAIL
CREATE TABLE PROD_DB.BRONZE.T_ISOLATION_TEST (X INT);

-- ------------------------------------------------------------
-- 2.4  PROD write access limited to deployment / operational roles (AC6)
--
-- PROD_ANALYST and PROD_REPORTER are read-only by design. Only
-- PROD_DEPLOYER (CI/CD) and PROD_DATA_LOADER (ingestion) write.
-- ------------------------------------------------------------
USE ROLE PROD_ANALYST;
USE WAREHOUSE PROD_ANALYST_WH;

-- MUST FAIL
CREATE TABLE PROD_DB.SILVER.T_ISOLATION_TEST (X INT);
-- MUST FAIL
DELETE FROM PROD_DB.GOLD.<any_existing_table> WHERE 1 = 0;

USE ROLE PROD_REPORTER;
USE WAREHOUSE PROD_REPORTER_WH;

-- MUST FAIL
CREATE TABLE PROD_DB.GOLD.T_ISOLATION_TEST (X INT);

-- ------------------------------------------------------------
-- 2.5  Domain reporters see only their own domain  (AC8)
-- ------------------------------------------------------------
-- Only meaningful once at least two GOLD_{domain} marts exist.
-- Substitute two real domains for the placeholders below.
USE ROLE PROD_REPORTER_FIN_ACCOUNTING;
USE WAREHOUSE PROD_REPORTER_FIN_ACCOUNTING_WH;

-- MUST FAIL - foreign domain
SELECT COUNT(*) FROM PROD_DB.GOLD_SMC_SALES.INFORMATION_SCHEMA.TABLES;


-- ============================================================
-- PART 3 - POSITIVE CONTROLS  (each statement MUST succeed)
--
-- Without these, PART 2 proves nothing: a role that is broken outright
-- would also "pass" every negative test.
-- ============================================================

-- ------------------------------------------------------------
-- 3.1  DEV engineering role can work in DEV  (AC4)
-- ------------------------------------------------------------
USE ROLE DEV_TRANSFORMER;
USE WAREHOUSE DEV_TRANSFORMER_WH;

-- MUST SUCCEED
CREATE TABLE DEV_DB.BRONZE.T_ISOLATION_TEST (X INT);
INSERT INTO DEV_DB.BRONZE.T_ISOLATION_TEST VALUES (1);
SELECT * FROM DEV_DB.BRONZE.T_ISOLATION_TEST;
DROP TABLE DEV_DB.BRONZE.T_ISOLATION_TEST;

-- ------------------------------------------------------------
-- 3.2  TEST role can work in TEST  (AC5)
-- ------------------------------------------------------------
USE ROLE TEST_TRANSFORMER;
USE WAREHOUSE TEST_TRANSFORMER_WH;

-- MUST SUCCEED
CREATE TABLE TEST_DB.BRONZE.T_ISOLATION_TEST (X INT);
DROP TABLE TEST_DB.BRONZE.T_ISOLATION_TEST;

-- ------------------------------------------------------------
-- 3.3  Approved PROD writer can write  (AC6)
-- ------------------------------------------------------------
USE ROLE PROD_DEPLOYER;
USE WAREHOUSE PROD_DEPLOYER_WH;

-- MUST SUCCEED
CREATE TABLE PROD_DB.SILVER.T_ISOLATION_TEST (X INT);
DROP TABLE PROD_DB.SILVER.T_ISOLATION_TEST;

-- ------------------------------------------------------------
-- 3.4  Read-only PROD roles can still read  (AC6)
-- ------------------------------------------------------------
USE ROLE PROD_ANALYST;
USE WAREHOUSE PROD_ANALYST_WH;

-- MUST SUCCEED
SELECT COUNT(*) FROM PROD_DB.GOLD.INFORMATION_SCHEMA.TABLES;


-- ============================================================
-- PART 4 - EVIDENCE CAPTURE  (AC7, AC10)
--
-- Save with the release, in the deployment folder:
--   * this file, with the environment set actually tested
--   * PART 1 output - each query with its row count (expect 0, 0, and the
--     agreed exception list)
--   * PART 2 output - one line per statement: role, statement, query ID,
--     PASS/FAIL, verbatim error text
--   * PART 3 output - one line per statement: role, statement, query ID,
--     PASS/FAIL
--   * who ran it, when, and against which account
--
-- A negative test with no recorded error text is not evidence. The error
-- text is the artefact an auditor reads.
--
-- Note: PART 2 and 3 name a table T_ISOLATION_TEST. Everything that
-- creates it also drops it. If a run aborts midway, check for leftovers:
--   SHOW TABLES LIKE 'T_ISOLATION_TEST' IN ACCOUNT;
-- ============================================================
