-- ============================================================
-- ENVIRONMENT ADMIN ROLES + platform provisioning access
-- RUN PER ENVIRONMENT.  Set ENV_ABBR, then run the whole file.
--   DEV_ / TEST_ / QA_ / PROD_
-- ============================================================
SET ENV_ABBR = 'DEV_';

SET ENV_SYSADMIN  = $ENV_ABBR || 'SYSADMIN';
SET ENV_USERADMIN = $ENV_ABBR || 'USERADMIN';


-- ------------------------------------------------------------
-- Create the environment administration roles and slot them into
-- the built-in hierarchy (SYSADMIN inherits ENV_SYSADMIN, etc.).
-- ------------------------------------------------------------
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_SYSADMIN);
GRANT ROLE IDENTIFIER($ENV_SYSADMIN) TO ROLE SYSADMIN;

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_USERADMIN);
GRANT ROLE IDENTIFIER($ENV_USERADMIN) TO ROLE USERADMIN;


-- ------------------------------------------------------------
-- Account-level creation privileges.
-- ENV_SYSADMIN creates databases + warehouses; ENV_USERADMIN
-- creates the functional roles.
-- ------------------------------------------------------------
USE ROLE SYSADMIN;
GRANT CREATE DATABASE  ON ACCOUNT TO ROLE IDENTIFIER($ENV_SYSADMIN);
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE IDENTIFIER($ENV_SYSADMIN);

USE ROLE SECURITYADMIN;
GRANT CREATE ROLE ON ACCOUNT TO ROLE IDENTIFIER($ENV_USERADMIN);


-- ------------------------------------------------------------
-- Platform provisioning access.
-- ENV_SYSADMIN must be able to run the RBAC procedures in
-- PLATFORM_DB.RBAC on PLATFORM_WH. Without these grants the
-- environment DB/schema creation (steps 03/04) fails at
-- USE WAREHOUSE / USE DATABASE / CALL.
-- SYSADMIN owns the platform objects, so it grants the usage.
-- ------------------------------------------------------------
USE ROLE SYSADMIN;
GRANT USAGE ON WAREHOUSE PLATFORM_WH      TO ROLE IDENTIFIER($ENV_SYSADMIN);
GRANT USAGE ON DATABASE  PLATFORM_DB      TO ROLE IDENTIFIER($ENV_SYSADMIN);
GRANT USAGE ON SCHEMA    PLATFORM_DB.RBAC TO ROLE IDENTIFIER($ENV_SYSADMIN);
GRANT USAGE ON ALL PROCEDURES    IN SCHEMA PLATFORM_DB.RBAC TO ROLE IDENTIFIER($ENV_SYSADMIN);
GRANT USAGE ON FUTURE PROCEDURES IN SCHEMA PLATFORM_DB.RBAC TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- ============================================================
-- VALIDATION
-- ============================================================
USE ROLE SECURITYADMIN;
SHOW GRANTS TO ROLE IDENTIFIER($ENV_SYSADMIN);
SHOW GRANTS TO ROLE IDENTIFIER($ENV_USERADMIN);
