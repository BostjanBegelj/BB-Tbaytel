-- ============================================================================
-- Terraform deployment identity — create NOW, even while still deploying SQL.
-- Run all account-object scripts through this role from today on; then every
-- account object is owned/manageable by one role and terraform import is
-- trivial at cutover.
--
-- TERRAFORM_ADMIN sits between ACCOUNTADMIN and the env admin roles:
--   it can create databases/warehouses/roles/users/integrations,
--   but is NOT ACCOUNTADMIN (no billing, no account destruction).
-- ============================================================================

-- role
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS TERRAFORM_ADMIN;

USE ROLE SECURITYADMIN;
GRANT ROLE TERRAFORM_ADMIN TO ROLE SYSADMIN; -- keep hierarchy rooted

-- privileges Terraform needs to manage account objects
USE ROLE ACCOUNTADMIN;
GRANT CREATE DATABASE          ON ACCOUNT TO ROLE TERRAFORM_ADMIN;
GRANT CREATE WAREHOUSE         ON ACCOUNT TO ROLE TERRAFORM_ADMIN;
GRANT CREATE INTEGRATION       ON ACCOUNT TO ROLE TERRAFORM_ADMIN;
GRANT CREATE NETWORK POLICY    ON ACCOUNT TO ROLE TERRAFORM_ADMIN;
GRANT CREATE RESOURCE MONITOR  ON ACCOUNT TO ROLE TERRAFORM_ADMIN;

USE ROLE SECURITYADMIN;
GRANT CREATE ROLE ON ACCOUNT TO ROLE TERRAFORM_ADMIN;
GRANT CREATE USER ON ACCOUNT TO ROLE TERRAFORM_ADMIN;
GRANT MANAGE GRANTS ON ACCOUNT TO ROLE TERRAFORM_ADMIN;

-- service user (key-pair auth; store the private key in the CI/CD secret store)
USE ROLE USERADMIN;
CREATE USER IF NOT EXISTS SVC_TERRAFORM
  LOGIN_NAME   = 'SVC_TERRAFORM'
  DISPLAY_NAME = 'Terraform / IaC deployments'
  TYPE         = SERVICE
  COMMENT      = 'Used by CI/CD to deploy account-level objects'
  DEFAULT_ROLE = TERRAFORM_ADMIN
  DEFAULT_WAREHOUSE = PLATFORM_WH;

ALTER USER SVC_TERRAFORM SET RSA_PUBLIC_KEY = 'MII...'; -- replace with actual RSA public key

USE ROLE SECURITYADMIN;
GRANT ROLE TERRAFORM_ADMIN TO USER SVC_TERRAFORM;
