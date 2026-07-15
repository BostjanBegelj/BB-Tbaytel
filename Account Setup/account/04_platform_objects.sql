-- ============================================================
-- PLATFORM_DB - dummy objects & content (SCAFFOLD / PLACEHOLDERS)
-- RUN ONCE PER ACCOUNT.
--
-- Illustrative placeholder objects (with sample rows) showing what
-- each PLATFORM_DB schema is intended to hold, so the three-database
-- picture (SECURITY_DB / PLATFORM_DB / {ENV}_DB) is concrete.
-- Replace or extend these as real content is built.
--
-- Owned by SYSADMIN (owner of PLATFORM_DB). Requires 02 + 03 first.
-- ============================================================
USE ROLE SYSADMIN;
USE WAREHOUSE PLATFORM_WH;
USE DATABASE PLATFORM_DB;


-- ============================================================
-- RBAC - data-driven deployment config
-- ============================================================
USE SCHEMA RBAC;

CREATE TABLE IF NOT EXISTS ENV_CONFIG (
    ENV_ABBR            STRING   COMMENT 'Environment prefix, e.g. DEV_, TEST_, PROD_',
    SCHEMA_NAME         STRING   COMMENT 'Schema to create in {ENV}_DB',
    DATA_RETENTION_DAYS NUMBER   COMMENT 'Time Travel retention tier for the schema',
    IS_ACTIVE           BOOLEAN  DEFAULT TRUE
) COMMENT = 'Dummy: drives data-driven environment provisioning (schema list + retention per env)';

INSERT INTO ENV_CONFIG (ENV_ABBR, SCHEMA_NAME, DATA_RETENTION_DAYS) VALUES
    ('DEV_', 'RAW',            1),
    ('DEV_', 'BRONZE',         1),
    ('DEV_', 'BRONZE_HIST',    7),
    ('DEV_', 'SILVER',         7),
    ('DEV_', 'GOLD',          14),
    ('DEV_', 'GOLD_BILLING',  14),
    ('DEV_', 'GOLD_FINANCE',  14),
    ('DEV_', 'GOLD_MARKETING',14),
    ('DEV_', 'ADM',            7);

-- Entra ID group -> Snowflake role mapping. Drives SCIM grant scripts:
-- SCIM creates the group roles WITHOUT privileges, so this table records
-- which functional/access role each Entra group's role should receive.
CREATE TABLE IF NOT EXISTS ENTRA_GROUP_ROLE_MAP (
    ENTRA_GROUP    STRING  COMMENT 'Entra ID security group display name',
    SNOWFLAKE_ROLE STRING  COMMENT 'Functional/access role to grant to the SCIM-created group role',
    IS_ACTIVE      BOOLEAN DEFAULT TRUE
) COMMENT = 'Dummy: Entra group -> Snowflake role mapping consumed by SCIM grant scripts';

INSERT INTO ENTRA_GROUP_ROLE_MAP (ENTRA_GROUP, SNOWFLAKE_ROLE) VALUES
    ('SG-TBAYTEL-DATA-ENGINEERS', 'DEV_TRANSFORMER'),
    ('SG-TBAYTEL-ANALYSTS',       'DEV_ANALYST'),
    ('SG-TBAYTEL-REPORTING',      'DEV_REPORTER');


-- ============================================================
-- DEPLOYMENT - CI/CD metadata (+ git repositories, see 13/14)
-- ============================================================
USE SCHEMA DEPLOYMENT;

CREATE TABLE IF NOT EXISTS CHANGE_HISTORY (
    SCRIPT     STRING,
    APPLIED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    APPLIED_BY STRING        DEFAULT CURRENT_USER(),
    STATUS     STRING
) COMMENT = 'Dummy: deployment/change history (e.g. schemachange) - one row per applied script';

INSERT INTO CHANGE_HISTORY (SCRIPT, STATUS) VALUES
    ('account/02_platform_database.sql',        'SUCCESS'),
    ('account/03_platform_rbac_procedures.sql', 'SUCCESS');

CREATE TABLE IF NOT EXISTS RELEASE_LOG (
    RELEASE_TAG STRING,
    DEPLOYED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    NOTES       STRING
) COMMENT = 'Dummy: release manifest / deployment log';

INSERT INTO RELEASE_LOG (RELEASE_TAG, NOTES) VALUES
    ('v0.1-bootstrap', 'Initial account + DEV environment bootstrap');

-- Git repositories (CI/CD source) are created in this schema by the
-- integration scripts (account/13-14), e.g.:
--   CREATE GIT REPOSITORY PLATFORM_DB.DEPLOYMENT.BB_TBAYTEL_REPO
--     API_INTEGRATION = GITHUB_API_INTEGRATION ORIGIN = '...';


-- ============================================================
-- MONITORING - observability / FinOps
-- Live views over SNOWFLAKE.ACCOUNT_USAGE need IMPORTED PRIVILEGES
-- ON DATABASE SNOWFLAKE granted to the owning role, so they are
-- shown commented; a dummy table stands in for the scaffold.
-- ============================================================
USE SCHEMA MONITORING;

CREATE TABLE IF NOT EXISTS WAREHOUSE_CREDITS_SNAPSHOT (
    WAREHOUSE_NAME STRING,
    CREDITS_USED   NUMBER(38,3),
    SNAPSHOT_DATE  DATE
) COMMENT = 'Dummy: stand-in for a credits-by-warehouse view over ACCOUNT_USAGE';

INSERT INTO WAREHOUSE_CREDITS_SNAPSHOT VALUES
    ('PLATFORM_WH',        0.42, CURRENT_DATE()),
    ('DEV_TRANSFORMER_WH', 1.87, CURRENT_DATE()),
    ('DEV_REPORTER_WH',    0.63, CURRENT_DATE());

-- Intended real content (enable after granting IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE):
-- CREATE VIEW V_WAREHOUSE_CREDITS AS
--   SELECT WAREHOUSE_NAME, SUM(CREDITS_USED) AS CREDITS_USED
--   FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
--   WHERE START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
--   GROUP BY WAREHOUSE_NAME;
-- CREATE VIEW V_GRANTS_TO_ROLES AS
--   SELECT PRIVILEGE, GRANTED_ON, NAME, GRANTED_TO, GRANTEE_NAME, GRANT_OPTION
--   FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES WHERE DELETED_ON IS NULL;


-- ============================================================
-- UTIL - shared, environment-neutral helper functions
-- ============================================================
USE SCHEMA UTIL;

CREATE FUNCTION IF NOT EXISTS HASH_KEY(INPUT STRING)
  RETURNS BINARY
  COMMENT = 'Dummy: shared hash-key helper (SHA1 of trimmed/upper input) for dimensional keys'
  AS $$ SHA1_BINARY(UPPER(TRIM(INPUT))) $$;

-- sample usage:
-- SELECT UTIL.HASH_KEY('  tbaytel  ');


-- ============================================================
-- REFERENCE - environment-neutral static lookups
-- ============================================================
USE SCHEMA REFERENCE;

CREATE TABLE IF NOT EXISTS COUNTRY_CODE (
    COUNTRY_CODE STRING,
    COUNTRY_NAME STRING
) COMMENT = 'Dummy: environment-neutral static lookup shared by all environments';

INSERT INTO COUNTRY_CODE VALUES
    ('CA', 'Canada'),
    ('US', 'United States');


-- ============================================================
-- SHARED_WORKSPACE - admin/engineer scratch & collaboration
-- ============================================================
USE SCHEMA SHARED_WORKSPACE;

CREATE TABLE IF NOT EXISTS SCRATCH_EXAMPLE (
    NOTE       STRING,
    CREATED_BY STRING        DEFAULT CURRENT_USER(),
    CREATED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Dummy: example scratch object; engineers create ad-hoc cross-env objects here';

INSERT INTO SCRATCH_EXAMPLE (NOTE) VALUES
    ('Shared workspace is for ad-hoc, non-runtime, cross-environment work.');


-- ============================================================
-- VALIDATION
-- ============================================================
SELECT 'RBAC.ENV_CONFIG'                AS OBJECT, COUNT(*) AS ROWS FROM RBAC.ENV_CONFIG
UNION ALL SELECT 'RBAC.ENTRA_GROUP_ROLE_MAP',  COUNT(*) FROM RBAC.ENTRA_GROUP_ROLE_MAP
UNION ALL SELECT 'DEPLOYMENT.CHANGE_HISTORY', COUNT(*) FROM DEPLOYMENT.CHANGE_HISTORY
UNION ALL SELECT 'DEPLOYMENT.RELEASE_LOG',    COUNT(*) FROM DEPLOYMENT.RELEASE_LOG
UNION ALL SELECT 'MONITORING.WAREHOUSE_CREDITS_SNAPSHOT', COUNT(*) FROM MONITORING.WAREHOUSE_CREDITS_SNAPSHOT
UNION ALL SELECT 'REFERENCE.COUNTRY_CODE',    COUNT(*) FROM REFERENCE.COUNTRY_CODE
UNION ALL SELECT 'SHARED_WORKSPACE.SCRATCH_EXAMPLE', COUNT(*) FROM SHARED_WORKSPACE.SCRATCH_EXAMPLE;
