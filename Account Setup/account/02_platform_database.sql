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
CREATE SCHEMA IF NOT EXISTS SHARED_WORKSPACE WITH MANAGED ACCESS
  COMMENT = 'Admin/engineer cross-environment scratch and collaboration area';


-- ============================================================
-- VALIDATION
-- ============================================================
SHOW SCHEMAS IN DATABASE IDENTIFIER($ENV_DB);
