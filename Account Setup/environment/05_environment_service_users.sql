-- ============================================================
-- ENVIRONMENT SERVICE USERS
-- RUN PER ENVIRONMENT.  Set ENV_ABBR, then run the whole file.
--
-- Creates the environment's key-pair service users:
--
--   1. Azure Data Factory (ingestion)
--        User:      SVC_<ENV>_ADF
--        Role:      <ENV>_DATA_LOADER
--        Warehouse: <ENV>_DATA_LOADER_WH
--
--   2. Power BI (reporting service account)
--        User:      SVC_<ENV>_POWERBI
--        Role:      <ENV>_REPORTER   (sees GOLD and all GOLD_* schemas)
--        Warehouse: <ENV>_REPORTER_WH
--
--   3. Deployment (CI/CD - schemachange/dbt)
--        User:      SVC_<ENV>_DEPLOY
--        Role:      <ENV>_DEPLOYER   (FULL on env schemas; reads git repos)
--        Warehouse: <ENV>_DEPLOYER_WH
--
-- Note: the general <ENV>_REPORTER role is used by this Power BI
-- SERVICE user (broad read across GOLD + GOLD_*). The per-domain
-- <ENV>_REPORTER_BILLING / _FINANCE / _MARKETING roles are for
-- ACTUAL people connecting via Power BI DirectQuery with SSO, and
-- are provisioned to those users through Entra group mapping - not
-- created as service users here.
--
-- All service users: TYPE = SERVICE, key-pair auth only, no
-- password. Prerequisite: functional roles + warehouses (step 02).
-- NEVER store a private key in this script or in source control.
-- ============================================================
SET ENV_ABBR = 'DEV_';

SET ENV_USERADMIN = $ENV_ABBR || 'USERADMIN';

-- ADF (ingestion)
SET SVC_ADF_USER  = 'SVC_' || $ENV_ABBR || 'ADF';
SET ADF_ROLE      = $ENV_ABBR || 'DATA_LOADER';
SET ADF_WAREHOUSE = $ENV_ABBR || 'DATA_LOADER_WH';

-- Power BI (reporting service account)
SET SVC_PBI_USER  = 'SVC_' || $ENV_ABBR || 'POWERBI';
SET PBI_ROLE      = $ENV_ABBR || 'REPORTER';
SET PBI_WAREHOUSE = $ENV_ABBR || 'REPORTER_WH';

-- Deployment (CI/CD)
SET SVC_DEPLOY_USER  = 'SVC_' || $ENV_ABBR || 'DEPLOY';
SET DEPLOY_ROLE      = $ENV_ABBR || 'DEPLOYER';
SET DEPLOY_WAREHOUSE = $ENV_ABBR || 'DEPLOYER_WH';


-- ============================================================
-- CREATE SERVICE USERS
-- ============================================================
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS IDENTIFIER($SVC_ADF_USER)
    LOGIN_NAME        = $SVC_ADF_USER
    DISPLAY_NAME      = 'Azure Data Factory'
    TYPE              = 'SERVICE'
    COMMENT           = 'Environment ADF ingestion service user - key-pair auth only'
    DEFAULT_ROLE      = $ADF_ROLE
    DEFAULT_WAREHOUSE = $ADF_WAREHOUSE
;

CREATE USER IF NOT EXISTS IDENTIFIER($SVC_PBI_USER)
    LOGIN_NAME        = $SVC_PBI_USER
    DISPLAY_NAME      = 'Power BI'
    TYPE              = 'SERVICE'
    COMMENT           = 'Environment Power BI reporting service user - key-pair auth only'
    DEFAULT_ROLE      = $PBI_ROLE
    DEFAULT_WAREHOUSE = $PBI_WAREHOUSE
;

CREATE USER IF NOT EXISTS IDENTIFIER($SVC_DEPLOY_USER)
    LOGIN_NAME        = $SVC_DEPLOY_USER
    DISPLAY_NAME      = 'CI/CD deployment'
    TYPE              = 'SERVICE'
    COMMENT           = 'Environment deployment service user (schemachange/dbt) - key-pair auth only'
    DEFAULT_ROLE      = $DEPLOY_ROLE
    DEFAULT_WAREHOUSE = $DEPLOY_WAREHOUSE
;


-- ============================================================
-- GRANT ROLES  (DEFAULT_ROLE does not grant the role).
-- ENV_USERADMIN owns the environment functional roles.
-- ============================================================
USE ROLE IDENTIFIER($ENV_USERADMIN);

GRANT ROLE IDENTIFIER($ADF_ROLE)    TO USER IDENTIFIER($SVC_ADF_USER);
GRANT ROLE IDENTIFIER($PBI_ROLE)    TO USER IDENTIFIER($SVC_PBI_USER);
GRANT ROLE IDENTIFIER($DEPLOY_ROLE) TO USER IDENTIFIER($SVC_DEPLOY_USER);


-- ============================================================
-- ASSIGN RSA PUBLIC KEYS
-- Base64 body only: no -----BEGIN/END----- lines, no line breaks.
-- Use a SEPARATE key pair per user. Store private keys only in the
-- secure secret store (ADF -> Azure Key Vault; Power BI -> its
-- gateway/service credential store; deploy -> CI/CD secret store).
-- Uncomment when keys exist.
-- ============================================================
USE ROLE USERADMIN;

-- ADF
-- SET ADF_RSA_PUBLIC_KEY = '<ADF_RSA_PUBLIC_KEY_BODY>';
-- ALTER USER IDENTIFIER($SVC_ADF_USER)
--     SET RSA_PUBLIC_KEY = $ADF_RSA_PUBLIC_KEY;

-- Power BI
-- SET PBI_RSA_PUBLIC_KEY = '<PBI_RSA_PUBLIC_KEY_BODY>';
-- ALTER USER IDENTIFIER($SVC_PBI_USER)
--     SET RSA_PUBLIC_KEY = $PBI_RSA_PUBLIC_KEY;

-- Deployment
-- SET DEPLOY_RSA_PUBLIC_KEY = '<DEPLOY_RSA_PUBLIC_KEY_BODY>';
-- ALTER USER IDENTIFIER($SVC_DEPLOY_USER)
--     SET RSA_PUBLIC_KEY = $DEPLOY_RSA_PUBLIC_KEY;


-- ============================================================
-- VALIDATION
-- ============================================================
USE ROLE USERADMIN;
DESCRIBE USER IDENTIFIER($SVC_ADF_USER);
DESCRIBE USER IDENTIFIER($SVC_PBI_USER);
DESCRIBE USER IDENTIFIER($SVC_DEPLOY_USER);

USE ROLE SECURITYADMIN;
SHOW GRANTS TO USER IDENTIFIER($SVC_ADF_USER);
SHOW GRANTS TO USER IDENTIFIER($SVC_PBI_USER);
SHOW GRANTS TO USER IDENTIFIER($SVC_DEPLOY_USER);
