-- ============================================================
-- ENVIRONMENT AND ROLE CONFIGURATION
-- ============================================================

-- Change this value when deploying another environment:
--   DEV_
--   TEST_
--   QA_
--   PROD_
SET ENV_ABBR = 'DEV_';


-- ============================================================
-- ENVIRONMENT ADMINISTRATION ROLES
--
-- These roles are assumed to have already been created as part
-- of the environment administration-role setup.
-- ============================================================

SET ENV_SYSADMIN  = $ENV_ABBR || 'SYSADMIN';
SET ENV_USERADMIN = $ENV_ABBR || 'USERADMIN';


-- ============================================================
-- ACCOUNT-LEVEL TERRAFORM ADMINISTRATION ROLE
--
-- TERRAFORM_ADMIN is account-level and is therefore not
-- prefixed with DEV_, TEST_, QA_, or PROD_.
--
-- One account-level service user, SVC_TERRAFORM, will use this
-- role to deploy all environments in the Snowflake account.
-- ============================================================

SET TERRAFORM_ADMIN_ROLE = 'TERRAFORM_ADMIN';


/*
Environment functional roles:

- TRANSFORMER
  Data engineering and transformation activities.

- ANALYST
  Interactive analysis and development.

- DATA_LOADER
  Data-ingestion role used by Azure Data Factory.

- REPORTER
  General BI/reporting access.

- REPORTER_BILLING
  Billing-specific reporting and Power BI DirectQuery SSO.

- REPORTER_FINANCE
  Finance-specific reporting and Power BI DirectQuery SSO.

- REPORTER_MARKETING
  Marketing-specific reporting and Power BI DirectQuery SSO.

- IT_GOVERNANCE
  Governance, monitoring, and administrative reporting.
*/


-- ============================================================
-- ENVIRONMENT FUNCTIONAL ROLES AND WAREHOUSES
-- ============================================================

SET ENV_TRANSFORMER    = $ENV_ABBR || 'TRANSFORMER';
SET ENV_TRANSFORMER_WH = $ENV_ABBR || 'TRANSFORMER_WH';

SET ENV_ANALYST    = $ENV_ABBR || 'ANALYST';
SET ENV_ANALYST_WH = $ENV_ABBR || 'ANALYST_WH';

SET ENV_DATA_LOADER    = $ENV_ABBR || 'DATA_LOADER';
SET ENV_DATA_LOADER_WH = $ENV_ABBR || 'DATA_LOADER_WH';

SET ENV_REPORTER    = $ENV_ABBR || 'REPORTER';
SET ENV_REPORTER_WH = $ENV_ABBR || 'REPORTER_WH';

SET ENV_REPORTER_BILLING    = $ENV_ABBR || 'REPORTER_BILLING';
SET ENV_REPORTER_BILLING_WH = $ENV_ABBR || 'REPORTER_BILLING_WH';

SET ENV_REPORTER_FINANCE    = $ENV_ABBR || 'REPORTER_FINANCE';
SET ENV_REPORTER_FINANCE_WH = $ENV_ABBR || 'REPORTER_FINANCE_WH';

SET ENV_REPORTER_MARKETING    = $ENV_ABBR || 'REPORTER_MARKETING';
SET ENV_REPORTER_MARKETING_WH = $ENV_ABBR || 'REPORTER_MARKETING_WH';

SET ENV_IT_GOVERNANCE    = $ENV_ABBR || 'IT_GOVERNANCE';
SET ENV_IT_GOVERNANCE_WH = $ENV_ABBR || 'IT_GOVERNANCE_WH';


-- ============================================================
-- CREATE TERRAFORM_ADMIN
--
-- This is a one-time account bootstrap section.
--
-- USERADMIN creates and owns the custom role.
-- ACCOUNTADMIN is used only to delegate the required global
-- privileges to the custom role.
--
-- Terraform must connect using TERRAFORM_ADMIN after bootstrap.
-- It must not connect using ACCOUNTADMIN.
-- ============================================================

USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS IDENTIFIER($TERRAFORM_ADMIN_ROLE)
    COMMENT = 'Account-level administration role used by the Terraform CI/CD service user';


-- ------------------------------------------------------------
-- Core object-creation privileges
--
-- These privileges allow Terraform to create account-level
-- databases, warehouses, users, and account roles.
--
-- Objects created by TERRAFORM_ADMIN are owned by that role
-- unless Terraform explicitly transfers ownership.
-- ------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

GRANT CREATE DATABASE
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

GRANT CREATE WAREHOUSE
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

GRANT CREATE USER
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

GRANT CREATE ROLE
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ------------------------------------------------------------
-- Central privilege-management authority
--
-- Required when Terraform manages:
--   - role hierarchy
--   - role grants to users
--   - object privileges
--   - future grants
--   - grants in managed-access schemas
--
-- MANAGE GRANTS is highly privileged. Access to the Terraform
-- service user's private key and CI/CD pipeline must therefore
-- be strictly controlled.
-- ------------------------------------------------------------

GRANT MANAGE GRANTS
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ------------------------------------------------------------
-- Integration management
--
-- CREATE INTEGRATION covers integrations such as:
--   - storage integrations
--   - notification integrations
--   - security integrations
--   - API integrations
--
-- External access integrations additionally require the
-- separate CREATE EXTERNAL ACCESS INTEGRATION privilege.
-- ------------------------------------------------------------

GRANT CREATE INTEGRATION
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

GRANT CREATE EXTERNAL ACCESS INTEGRATION
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ------------------------------------------------------------
-- Network-policy management
--
-- CREATE NETWORK POLICY allows Terraform to create account-
-- level network policies.
--
-- ATTACH POLICY allows Terraform to activate a network policy
-- by associating it with the Snowflake account.
--
-- Network rules are schema objects. For databases and schemas
-- created by TERRAFORM_ADMIN, the role will normally own the
-- required containers. Existing schemas might require explicit
-- USAGE and CREATE NETWORK RULE grants.
-- ------------------------------------------------------------

GRANT CREATE NETWORK POLICY
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

GRANT ATTACH POLICY
    ON ACCOUNT
    TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ------------------------------------------------------------
-- Add TERRAFORM_ADMIN to the account role hierarchy
--
-- Granting TERRAFORM_ADMIN to ACCOUNTADMIN means ACCOUNTADMIN
-- inherits TERRAFORM_ADMIN.
--
-- This does NOT grant ACCOUNTADMIN to TERRAFORM_ADMIN.
--
-- TERRAFORM_ADMIN is deliberately not granted to SYSADMIN,
-- because SYSADMIN would then inherit MANAGE GRANTS, CREATE USER,
-- CREATE ROLE, and the other Terraform administration rights.
-- ------------------------------------------------------------

GRANT ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE)
    TO ROLE ACCOUNTADMIN;


-- ============================================================
-- OPTIONAL TERRAFORM PRIVILEGES
--
-- Uncomment only when these object types or operations are
-- included in the Terraform scope.
-- ============================================================

-- ------------------------------------------------------------
-- Tasks
--
-- Needed if Terraform creates and resumes tasks while operating
-- directly as TERRAFORM_ADMIN.
-- ------------------------------------------------------------

-- GRANT EXECUTE TASK
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- GRANT EXECUTE MANAGED TASK
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ------------------------------------------------------------
-- Account Usage
--
-- Needed only when Terraform data sources read usage and
-- monitoring information from the SNOWFLAKE database.
-- ------------------------------------------------------------

-- GRANT MONITOR USAGE
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- GRANT IMPORTED PRIVILEGES
--     ON DATABASE SNOWFLAKE
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ------------------------------------------------------------
-- Governance policies and tags
--
-- These global APPLY privileges can be required when Terraform
-- applies policies or tags to existing objects it does not own.
--
-- They might not be necessary when TERRAFORM_ADMIN owns both
-- the policy/tag and the target object.
-- ------------------------------------------------------------

-- GRANT APPLY MASKING POLICY
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- GRANT APPLY ROW ACCESS POLICY
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- GRANT APPLY TAG
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- GRANT APPLY PASSWORD POLICY
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- GRANT APPLY SESSION POLICY
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ------------------------------------------------------------
-- Other account-level objects
--
-- Enable only when explicitly included in Terraform.
-- ------------------------------------------------------------

-- GRANT CREATE EXTERNAL VOLUME
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- GRANT CREATE COMPUTE POOL
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- GRANT CREATE SHARE
--     ON ACCOUNT
--     TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ============================================================
-- CREATE ENVIRONMENT FUNCTIONAL ROLES
--
-- ENV_USERADMIN creates the environment-specific functional
-- roles and adds them below ENV_SYSADMIN in the role hierarchy.
-- ============================================================

USE ROLE IDENTIFIER($ENV_USERADMIN);


-- TRANSFORMER

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_TRANSFORMER);

GRANT ROLE IDENTIFIER($ENV_TRANSFORMER)
    TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- ANALYST

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_ANALYST);

GRANT ROLE IDENTIFIER($ENV_ANALYST)
    TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- DATA_LOADER

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_DATA_LOADER);

GRANT ROLE IDENTIFIER($ENV_DATA_LOADER)
    TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- REPORTER

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_REPORTER);

GRANT ROLE IDENTIFIER($ENV_REPORTER)
    TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- REPORTER_BILLING

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_REPORTER_BILLING);

GRANT ROLE IDENTIFIER($ENV_REPORTER_BILLING)
    TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- REPORTER_FINANCE

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_REPORTER_FINANCE);

GRANT ROLE IDENTIFIER($ENV_REPORTER_FINANCE)
    TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- REPORTER_MARKETING

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_REPORTER_MARKETING);

GRANT ROLE IDENTIFIER($ENV_REPORTER_MARKETING)
    TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- IT_GOVERNANCE

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_IT_GOVERNANCE);

GRANT ROLE IDENTIFIER($ENV_IT_GOVERNANCE)
    TO ROLE IDENTIFIER($ENV_SYSADMIN);


-- ============================================================
-- CREATE ENVIRONMENT VIRTUAL WAREHOUSES
--
-- ENV_SYSADMIN creates and owns the environment warehouses.
--
-- Each functional role receives USAGE only on its corresponding
-- warehouse. USAGE allows the role to use the warehouse but
-- does not allow it to alter, suspend, resume, or drop it.
-- ============================================================

USE ROLE IDENTIFIER($ENV_SYSADMIN);


-- ------------------------------------------------------------
-- TRANSFORMER warehouse
-- ------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_TRANSFORMER_WH)
    WAREHOUSE_TYPE     = STANDARD
    WAREHOUSE_SIZE     = XSMALL
    AUTO_SUSPEND       = 60
    AUTO_RESUME        = TRUE
    INITIALLY_SUSPENDED = TRUE;

GRANT USAGE
    ON WAREHOUSE IDENTIFIER($ENV_TRANSFORMER_WH)
    TO ROLE IDENTIFIER($ENV_TRANSFORMER);


-- ------------------------------------------------------------
-- ANALYST warehouse
-- ------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_ANALYST_WH)
    WAREHOUSE_TYPE      = STANDARD
    WAREHOUSE_SIZE      = XSMALL
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE;

GRANT USAGE
    ON WAREHOUSE IDENTIFIER($ENV_ANALYST_WH)
    TO ROLE IDENTIFIER($ENV_ANALYST);


-- ------------------------------------------------------------
-- DATA_LOADER warehouse
-- ------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_DATA_LOADER_WH)
    WAREHOUSE_TYPE      = STANDARD
    WAREHOUSE_SIZE      = XSMALL
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE;

GRANT USAGE
    ON WAREHOUSE IDENTIFIER($ENV_DATA_LOADER_WH)
    TO ROLE IDENTIFIER($ENV_DATA_LOADER);


-- ------------------------------------------------------------
-- REPORTER warehouse
-- ------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_REPORTER_WH)
    WAREHOUSE_TYPE      = STANDARD
    WAREHOUSE_SIZE      = XSMALL
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE;

GRANT USAGE
    ON WAREHOUSE IDENTIFIER($ENV_REPORTER_WH)
    TO ROLE IDENTIFIER($ENV_REPORTER);


-- ------------------------------------------------------------
-- REPORTER_BILLING warehouse
-- ------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_REPORTER_BILLING_WH)
    WAREHOUSE_TYPE      = STANDARD
    WAREHOUSE_SIZE      = XSMALL
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE;

GRANT USAGE
    ON WAREHOUSE IDENTIFIER($ENV_REPORTER_BILLING_WH)
    TO ROLE IDENTIFIER($ENV_REPORTER_BILLING);


-- ------------------------------------------------------------
-- REPORTER_FINANCE warehouse
-- ------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_REPORTER_FINANCE_WH)
    WAREHOUSE_TYPE      = STANDARD
    WAREHOUSE_SIZE      = XSMALL
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE;

GRANT USAGE
    ON WAREHOUSE IDENTIFIER($ENV_REPORTER_FINANCE_WH)
    TO ROLE IDENTIFIER($ENV_REPORTER_FINANCE);


-- ------------------------------------------------------------
-- REPORTER_MARKETING warehouse
-- ------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_REPORTER_MARKETING_WH)
    WAREHOUSE_TYPE      = STANDARD
    WAREHOUSE_SIZE      = XSMALL
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE;

GRANT USAGE
    ON WAREHOUSE IDENTIFIER($ENV_REPORTER_MARKETING_WH)
    TO ROLE IDENTIFIER($ENV_REPORTER_MARKETING);


-- ------------------------------------------------------------
-- IT_GOVERNANCE warehouse
-- ------------------------------------------------------------

CREATE WAREHOUSE IF NOT EXISTS IDENTIFIER($ENV_IT_GOVERNANCE_WH)
    WAREHOUSE_TYPE      = STANDARD
    WAREHOUSE_SIZE      = XSMALL
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE;

GRANT USAGE
    ON WAREHOUSE IDENTIFIER($ENV_IT_GOVERNANCE_WH)
    TO ROLE IDENTIFIER($ENV_IT_GOVERNANCE);


-- ============================================================
-- VALIDATION
-- ============================================================

USE ROLE SECURITYADMIN;

SHOW GRANTS TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
SHOW GRANTS OF ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);