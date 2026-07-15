-- ============================================================
-- State validation / inventory export
-- RUN AFTER EACH DEPLOYMENT (account + environment layers).
-- Purpose: (1) detect drift between scripts and the account;
--          (2) generate the Terraform import-block list at migration
--              time (names are deterministic).
-- Read-only (SHOW + ACCOUNT_USAGE queries).
-- ============================================================

USE ROLE ACCOUNTADMIN; -- or SECURITYADMIN for the grants sections

-- ---------------------------------------------------------------------------
-- Object inventory
-- ---------------------------------------------------------------------------
SHOW DATABASES;
SHOW WAREHOUSES;
SHOW ROLES;
SHOW DATABASE ROLES IN DATABASE SECURITY_DB;
-- repeat per environment database:
-- SHOW DATABASE ROLES IN DATABASE DEV_DB;
SHOW NETWORK POLICIES;
SHOW NETWORK RULES IN DATABASE SECURITY_DB;
SHOW PASSWORD POLICIES IN SCHEMA SECURITY_DB.POLICIES;
SHOW AUTHENTICATION POLICIES IN SCHEMA SECURITY_DB.POLICIES;
SHOW INTEGRATIONS;
SHOW USERS; -- verify no leftover POC/demo users before TEST/PROD promotion (Standards 9)

-- ---------------------------------------------------------------------------
-- Ownership check - objects should be owned by the designated admin roles
-- (SECURITYADMIN for SECURITY_DB, {ENV}_SYSADMIN for env objects), never by
-- an individual engineer's role. Accidental owners = painful Terraform import.
-- ---------------------------------------------------------------------------
SELECT table_catalog, table_schema, table_owner, COUNT(*) AS objects
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
WHERE deleted IS NULL
GROUP BY 1, 2, 3
ORDER BY 1, 2;

-- ---------------------------------------------------------------------------
-- Grants inventory (ACCOUNT_USAGE has up to ~2h latency)
-- ---------------------------------------------------------------------------
SELECT created_on, privilege, granted_on, name, granted_to, grantee_name, grant_option, granted_by
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE deleted_on IS NULL
ORDER BY grantee_name, granted_on, name;

-- direct grants to users must be role grants ONLY (no object privileges):
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_USERS
WHERE deleted_on IS NULL;

-- future grants per access role (repeat per database/role as needed):
-- SHOW FUTURE GRANTS IN SCHEMA DEV_DB.BRONZE;
-- SHOW FUTURE GRANTS TO DATABASE ROLE DEV_DB.BRONZE_RO_AR;
