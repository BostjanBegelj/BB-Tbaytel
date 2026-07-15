-- ============================================================
-- TERRAFORM_ADMIN  -  account-level deployment role
-- RUN ONCE PER ACCOUNT (not per environment).
--
-- Account-level: NOT prefixed with DEV_/TEST_/QA_/PROD_.
-- One service user (SVC_TERRAFORM) uses this role to deploy all
-- environments. USERADMIN creates/owns the role; ACCOUNTADMIN
-- delegates the global privileges.
--
-- Terraform connects as TERRAFORM_ADMIN, never as ACCOUNTADMIN.
-- ============================================================

SET TERRAFORM_ADMIN_ROLE = 'TERRAFORM_ADMIN';

USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS IDENTIFIER($TERRAFORM_ADMIN_ROLE)
    COMMENT = 'Account-level administration role used by the Terraform CI/CD service user';


-- ------------------------------------------------------------
-- Core object-creation privileges (account-level databases,
-- warehouses, users, roles). Objects created by TERRAFORM_ADMIN
-- are owned by it unless Terraform transfers ownership.
-- ------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
GRANT CREATE DATABASE  ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
GRANT CREATE USER      ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
GRANT CREATE ROLE      ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- Central privilege management: role hierarchy, role grants to
-- users, object privileges, future grants, managed-access schemas.
-- Highly privileged - protect the service user's key and pipeline.
GRANT MANAGE GRANTS    ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- Integrations (storage, notification, security, API). External
-- access integrations need the separate privilege below.
GRANT CREATE INTEGRATION                 ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
GRANT CREATE EXTERNAL ACCESS INTEGRATION ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- Network policy management + activation.
GRANT CREATE NETWORK POLICY ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
GRANT ATTACH POLICY         ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- Add to hierarchy under ACCOUNTADMIN. ACCOUNTADMIN inherits
-- TERRAFORM_ADMIN; this does NOT grant ACCOUNTADMIN to it.
-- Deliberately NOT granted to SYSADMIN (would leak MANAGE GRANTS,
-- CREATE USER, CREATE ROLE, etc. into SYSADMIN).
GRANT ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE) TO ROLE ACCOUNTADMIN;


-- ============================================================
-- OPTIONAL privileges  -  uncomment only when the object type or
-- operation is included in the Terraform scope.
-- ============================================================

-- Tasks (when Terraform creates/resumes tasks as TERRAFORM_ADMIN):
-- GRANT EXECUTE TASK         ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
-- GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- Account Usage reads from the SNOWFLAKE database:
-- GRANT MONITOR USAGE        ON ACCOUNT          TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
-- GRANT IMPORTED PRIVILEGES  ON DATABASE SNOWFLAKE TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- Applying governance policies/tags to objects it does not own:
-- GRANT APPLY MASKING POLICY    ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
-- GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
-- GRANT APPLY TAG               ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
-- GRANT APPLY PASSWORD POLICY   ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
-- GRANT APPLY SESSION POLICY    ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);

-- Other account-level objects:
-- GRANT CREATE EXTERNAL VOLUME ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
-- GRANT CREATE COMPUTE POOL    ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
-- GRANT CREATE SHARE           ON ACCOUNT TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);


-- ============================================================
-- VALIDATION
-- ============================================================
USE ROLE SECURITYADMIN;
SHOW GRANTS TO ROLE IDENTIFIER($TERRAFORM_ADMIN_ROLE);
