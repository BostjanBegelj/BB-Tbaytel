-- ============================================================
-- ENVIRONMENT DATABASE  ({ENV}_DB)
-- RUN PER ENVIRONMENT.  Set ENV_ABBR, then run the whole file.
--
-- Uses the CREATE_DATABASE procedure in PLATFORM_DB.RBAC. Runs as
-- ENV_SYSADMIN, which owns the resulting database. Requires the
-- platform provisioning grants from 01_env_admin_roles.sql.
-- ============================================================
SET ENV_ABBR = 'DEV_';
SET DB_NAME  = $ENV_ABBR || 'DB';

SET ENV_SYSADMIN = $ENV_ABBR || 'SYSADMIN';

USE ROLE IDENTIFIER($ENV_SYSADMIN);
USE WAREHOUSE PLATFORM_WH;
USE DATABASE PLATFORM_DB;
USE SCHEMA RBAC;

CALL CREATE_DATABASE($DB_NAME);
