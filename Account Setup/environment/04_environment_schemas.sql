-- ============================================================
-- ENVIRONMENT SCHEMAS  ({ENV}_DB.*)  + access-role grants
-- RUN PER ENVIRONMENT.  Set ENV_ABBR, then run the whole file.
--
-- For each schema this:
--   1. calls CREATE_SCHEMA (creates schema + RO/RW/FULL database
--      roles + all/future object grants),
--   2. sets a Time Travel retention tier,
--   3. grants the RO / FULL access roles to functional roles.
--
-- Runs as ENV_SYSADMIN (owns {ENV}_DB and the access roles).
-- Requires 01 (platform grants) + 03 ({ENV}_DB) to have run.
--
-- NOTE: IDENTIFIER() accepts a single variable/literal, not an
-- inline expression. Qualified names are built into SET variables
-- first (SCHEMA_FQN, RO_ROLE, FULL_ROLE), then passed to IDENTIFIER.
--
-- Medallion layout (Standards 4.1):
--   ADM, RAW, BRONZE, BRONZE_HIST, SILVER, GOLD
-- GOLD_{domain} marts are added per domain as each is built - see the
-- pattern at the end of this file.
--
-- Retention tiers (DATA_RETENTION_TIME_IN_DAYS).
-- Principle: Time Travel buys ACCIDENT recovery, not history, and is
-- billed on churn x days. Retention is therefore set by how hard the
-- content is to REBUILD, not by how important it is.
--   RAW / BRONZE          1    re-loadable from the source extract
--   SILVER / GOLD*        7    rebuildable from the layer above
--                              (SILVER from BRONZE_HIST, GOLD from
--                              SILVER); high churn on every load
--   BRONZE_HIST / ADM     30   NOT rebuildable - the replay source and
--                              the run-state / audit log. Losing either
--                              breaks rerun and lineage.
-- Business Critical allows up to 90 days if policy later requires more.
-- ============================================================
SET ENV_ABBR = 'DEV_';
SET DB_NAME  = $ENV_ABBR || 'DB';

SET ENV_SYSADMIN = $ENV_ABBR || 'SYSADMIN';

-- functional role names (env-prefixed)
SET R_TRANSFORMER   = $ENV_ABBR || 'TRANSFORMER';
SET R_ANALYST       = $ENV_ABBR || 'ANALYST';
SET R_DATA_LOADER   = $ENV_ABBR || 'DATA_LOADER';
SET R_REPORTER      = $ENV_ABBR || 'REPORTER';      -- human, shared GOLD
SET R_POWERBI       = $ENV_ABBR || 'POWERBI';       -- service, GOLD + all marts
SET R_IT_GOVERNANCE = $ENV_ABBR || 'IT_GOVERNANCE';
SET R_DEPLOYER      = $ENV_ABBR || 'DEPLOYER';
-- Domain reporter roles are created in 02 but are NOT granted here.
-- A GOLD_{domain} schema is created only when that domain's mart is
-- built - see the pattern at the end of this file.

-- context for the CREATE_SCHEMA procedure (set once)
USE ROLE IDENTIFIER($ENV_SYSADMIN);
USE WAREHOUSE PLATFORM_WH;
USE DATABASE PLATFORM_DB;
USE SCHEMA RBAC;


-- ------------------------------------------------------------
-- ADM
-- ------------------------------------------------------------
SET SCHEMA_NAME = 'ADM';
SET SCHEMA_FQN  = $DB_NAME || '.' || $SCHEMA_NAME;
SET RO_ROLE     = $SCHEMA_FQN || '_RO_AR';
SET FULL_ROLE   = $SCHEMA_FQN || '_FULL_AR';
CALL PLATFORM_DB.RBAC.CREATE_SCHEMA($DB_NAME, $SCHEMA_NAME, $ENV_ABBR);
-- 30: run state + audit log. Not rebuildable; loss breaks rerun logic.
ALTER SCHEMA IDENTIFIER($SCHEMA_FQN) SET DATA_RETENTION_TIME_IN_DAYS = 30;
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_ANALYST);
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_IT_GOVERNANCE);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_TRANSFORMER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DATA_LOADER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DEPLOYER);


-- ------------------------------------------------------------
-- RAW
-- ------------------------------------------------------------
SET SCHEMA_NAME = 'RAW';
SET SCHEMA_FQN  = $DB_NAME || '.' || $SCHEMA_NAME;
SET RO_ROLE     = $SCHEMA_FQN || '_RO_AR';
SET FULL_ROLE   = $SCHEMA_FQN || '_FULL_AR';
CALL PLATFORM_DB.RBAC.CREATE_SCHEMA($DB_NAME, $SCHEMA_NAME, $ENV_ABBR);
ALTER SCHEMA IDENTIFIER($SCHEMA_FQN) SET DATA_RETENTION_TIME_IN_DAYS = 1;
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_IT_GOVERNANCE);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_TRANSFORMER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DATA_LOADER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DEPLOYER);


-- ------------------------------------------------------------
-- BRONZE
-- ------------------------------------------------------------
SET SCHEMA_NAME = 'BRONZE';
SET SCHEMA_FQN  = $DB_NAME || '.' || $SCHEMA_NAME;
SET RO_ROLE     = $SCHEMA_FQN || '_RO_AR';
SET FULL_ROLE   = $SCHEMA_FQN || '_FULL_AR';
CALL PLATFORM_DB.RBAC.CREATE_SCHEMA($DB_NAME, $SCHEMA_NAME, $ENV_ABBR);
ALTER SCHEMA IDENTIFIER($SCHEMA_FQN) SET DATA_RETENTION_TIME_IN_DAYS = 1;
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_IT_GOVERNANCE);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_TRANSFORMER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DATA_LOADER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DEPLOYER);


-- ------------------------------------------------------------
-- BRONZE_HIST
-- ------------------------------------------------------------
SET SCHEMA_NAME = 'BRONZE_HIST';
SET SCHEMA_FQN  = $DB_NAME || '.' || $SCHEMA_NAME;
SET RO_ROLE     = $SCHEMA_FQN || '_RO_AR';
SET FULL_ROLE   = $SCHEMA_FQN || '_FULL_AR';
CALL PLATFORM_DB.RBAC.CREATE_SCHEMA($DB_NAME, $SCHEMA_NAME, $ENV_ABBR);
-- 30: the replay / lineage source. No upstream to rebuild it from.
ALTER SCHEMA IDENTIFIER($SCHEMA_FQN) SET DATA_RETENTION_TIME_IN_DAYS = 30;
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_IT_GOVERNANCE);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_TRANSFORMER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DATA_LOADER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DEPLOYER);


-- ------------------------------------------------------------
-- SILVER
-- ------------------------------------------------------------
SET SCHEMA_NAME = 'SILVER';
SET SCHEMA_FQN  = $DB_NAME || '.' || $SCHEMA_NAME;
SET RO_ROLE     = $SCHEMA_FQN || '_RO_AR';
SET FULL_ROLE   = $SCHEMA_FQN || '_FULL_AR';
CALL PLATFORM_DB.RBAC.CREATE_SCHEMA($DB_NAME, $SCHEMA_NAME, $ENV_ABBR);
ALTER SCHEMA IDENTIFIER($SCHEMA_FQN) SET DATA_RETENTION_TIME_IN_DAYS = 7;
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_ANALYST);
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_IT_GOVERNANCE);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_TRANSFORMER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DATA_LOADER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DEPLOYER);


-- ------------------------------------------------------------
-- GOLD  (shared, business-facing)
-- ------------------------------------------------------------
SET SCHEMA_NAME = 'GOLD';
SET SCHEMA_FQN  = $DB_NAME || '.' || $SCHEMA_NAME;
SET RO_ROLE     = $SCHEMA_FQN || '_RO_AR';
SET FULL_ROLE   = $SCHEMA_FQN || '_FULL_AR';
CALL PLATFORM_DB.RBAC.CREATE_SCHEMA($DB_NAME, $SCHEMA_NAME, $ENV_ABBR);
-- 7: rebuildable from SILVER; full-refresh churn makes longer costly.
ALTER SCHEMA IDENTIFIER($SCHEMA_FQN) SET DATA_RETENTION_TIME_IN_DAYS = 7;
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_ANALYST);
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_IT_GOVERNANCE);
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_REPORTER);
GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_POWERBI);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_TRANSFORMER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DATA_LOADER);
GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DEPLOYER);


-- ============================================================
-- GOLD_{domain} MARTS - created per domain, as that domain's mart is
-- built. Not created up front.
--
-- The three schemas previously here (GOLD_BILLING / GOLD_FINANCE /
-- GOLD_MARKETING) were placeholders from before the Data Domain Map
-- existed and did not match it - there is no "Billing" domain, and
-- Finance and Marketing are T1 headings, not T2 domains. They have
-- been removed rather than renamed.
--
-- The 13 domain reporter ROLES exist already (02) so the Entra groups
-- have something to be granted to. A role simply has no schema access
-- until its mart is built.
--
-- To add a domain, set the two names and run this block. The role must
-- already exist in 02.
-- ============================================================
-- SET SCHEMA_NAME  = 'GOLD_FIN_ACCOUNTING';
-- SET DOMAIN_ROLE  = $ENV_ABBR || 'REPORTER_FIN_ACCOUNTING';
-- SET SCHEMA_FQN   = $DB_NAME || '.' || $SCHEMA_NAME;
-- SET RO_ROLE      = $SCHEMA_FQN || '_RO_AR';
-- SET FULL_ROLE    = $SCHEMA_FQN || '_FULL_AR';
-- CALL PLATFORM_DB.RBAC.CREATE_SCHEMA($DB_NAME, $SCHEMA_NAME, $ENV_ABBR);
-- ALTER SCHEMA IDENTIFIER($SCHEMA_FQN) SET DATA_RETENTION_TIME_IN_DAYS = 7;
-- GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_ANALYST);
-- GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_IT_GOVERNANCE);
-- GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($R_POWERBI);
-- GRANT DATABASE ROLE IDENTIFIER($RO_ROLE)   TO ROLE IDENTIFIER($DOMAIN_ROLE);
-- GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_TRANSFORMER);
-- GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DATA_LOADER);
-- GRANT DATABASE ROLE IDENTIFIER($FULL_ROLE) TO ROLE IDENTIFIER($R_DEPLOYER);
--
-- Note: {ENV}_REPORTER is deliberately NOT granted on domain marts.
-- It reads the shared GOLD schema only. Conformed dimensions reach the
-- domain marts as views over GOLD, not as access to GOLD itself.
--
-- Note: HR occupational health is special-category (medical) personal
-- data. Do not create that mart until its handling is agreed with
-- Tbaytel's privacy function.


-- ============================================================
-- VALIDATION
-- ============================================================
USE ROLE IDENTIFIER($ENV_SYSADMIN);
-- Expect 6 schemas: ADM, RAW, BRONZE, BRONZE_HIST, SILVER, GOLD.
-- No PUBLIC. Domain marts appear as they are built.
SHOW SCHEMAS IN DATABASE IDENTIFIER($DB_NAME);
