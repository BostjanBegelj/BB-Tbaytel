-- ============================================================
-- PLATFORM_DB - global platform-administration database
-- RUN ONCE PER ACCOUNT.
--
-- The account-wide, environment-neutral database for non-security
-- admin content. Unprefixed (exists once). Read-only to runtime
-- pipelines, so a DEV run can never affect PROD state.
--
-- Boundaries:
--   SECURITY_DB   - security / policy objects (separate duty)
--   {ENV}_DB      - per-environment data + run-time control/logging
--   account-level - warehouses, roles, monitors, network, integrations
--                   (not database objects; created elsewhere)
--
-- Creates PLATFORM_WH (provisioning/deployment) + the schemas below.
-- Procedures go in 03_platform_rbac_procedures; dummy objects in
-- 04_platform_objects.
-- ============================================================
SET ENV_ABBR     = '';                          -- PLATFORM_DB is unprefixed (account-wide)
SET ENV_SYSADMIN = $ENV_ABBR || 'SYSADMIN';     -- resolves to built-in SYSADMIN
SET ENV_WH       = $ENV_ABBR || 'PLATFORM_WH';
SET ENV_DB       = $ENV_ABBR || 'PLATFORM_DB';

USE ROLE IDENTIFIER($ENV_SYSADMIN);

-- provisioning + deployment warehouse
CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_WH) WITH
  WAREHOUSE_TYPE      = STANDARD
  WAREHOUSE_SIZE      = XSMALL
  AUTO_SUSPEND        = 60
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE;

-- database
CREATE DATABASE IF NOT EXISTS IDENTIFIER($ENV_DB);
USE DATABASE IDENTIFIER($ENV_DB);
DROP SCHEMA IF EXISTS PUBLIC;

-- schemas (all managed access - grants centralised via access roles)
CREATE SCHEMA IF NOT EXISTS RBAC WITH MANAGED ACCESS
  COMMENT = 'RBAC provisioning: create/drop DB & schema procedures + deployment config';
CREATE SCHEMA IF NOT EXISTS DEPLOYMENT WITH MANAGED ACCESS
  COMMENT = 'CI/CD: git repositories, change history, release log';
CREATE SCHEMA IF NOT EXISTS MONITORING WITH MANAGED ACCESS
  COMMENT = 'Platform observability + FinOps views over SNOWFLAKE.ACCOUNT_USAGE';
CREATE SCHEMA IF NOT EXISTS UTIL WITH MANAGED ACCESS
  COMMENT = 'Shared, environment-neutral helper functions (UDFs/UDTFs)';
CREATE SCHEMA IF NOT EXISTS REFERENCE WITH MANAGED ACCESS
  COMMENT = 'Environment-neutral static reference/lookup data (read-only to runtime)';
CREATE SCHEMA IF NOT EXISTS FILE_FORMATS WITH MANAGED ACCESS
  COMMENT = 'Shared, environment-independent file formats (Parquet, CSV, JSON, ...)';
-- NOTE: SHARED_WORKSPACE is a SQL schema holding cross-environment scratch
-- objects. It is NOT the Snowsight "Workspaces" feature and has no relation
-- to a Snowsight shared workspace (which stores files, not database objects).
CREATE SCHEMA IF NOT EXISTS SHARED_WORKSPACE WITH MANAGED ACCESS
  COMMENT = 'Admin/engineer cross-environment scratch and collaboration area (SQL objects; not a Snowsight workspace)';


-- ------------------------------------------------------------
-- ACCOUNT_USAGE access for the MONITORING schema.
-- The observability and FinOps views read SNOWFLAKE.ACCOUNT_USAGE,
-- which is a shared database: the owning role needs IMPORTED PRIVILEGES
-- or every view fails with "object does not exist". Only ACCOUNTADMIN
-- can grant it. Without this, 04_platform_objects.sql can only create
-- the dummy stand-in tables, not the real views.
--
-- Note the ~45 minute to 2 hour latency on most ACCOUNT_USAGE views;
-- use the INFORMATION_SCHEMA equivalents for real-time checks.
-- ------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE SYSADMIN;
USE ROLE IDENTIFIER($ENV_SYSADMIN);


-- ============================================================
-- VALIDATION
-- ============================================================
-- Expect 7 schemas: RBAC, DEPLOYMENT, MONITORING, UTIL, REFERENCE,
-- FILE_FORMATS, SHARED_WORKSPACE. No PUBLIC.
SHOW SCHEMAS IN DATABASE IDENTIFIER($ENV_DB);

-- Expect PLATFORM_WH, XSMALL, state SUSPENDED.
SHOW WAREHOUSES LIKE 'PLATFORM_WH';

-- Confirm ACCOUNT_USAGE is reachable by SYSADMIN (returns a row count,
-- not an error). Needs a running warehouse, so this is the first
-- statement in the build that consumes a credit.
-- USE WAREHOUSE PLATFORM_WH;
-- SELECT COUNT(*) AS ROLE_COUNT FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES;
