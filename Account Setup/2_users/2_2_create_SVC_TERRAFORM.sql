-- Terraform deployment service user (bridge to the IaC setup in /terraform)
-- Key-pair auth only; no password. Create this BEFORE the Terraform migration -
-- it is the identity Terraform will connect as.
--
-- Roles: Terraform manages account-level objects, so it needs SYSADMIN (databases,
-- warehouses), SECURITYADMIN (roles, grants, policies, network rules) and, for
-- account parameters / integrations, ACCOUNTADMIN. Start with ACCOUNTADMIN for
-- simplicity; split into a least-privilege TERRAFORM_ADMIN role once stable.

USE ROLE USERADMIN;
CREATE USER IF NOT EXISTS SVC_TERRAFORM
  LOGIN_NAME = 'SVC_TERRAFORM'
  DISPLAY_NAME = 'Terraform deployment'
  TYPE = 'SERVICE'
  COMMENT = 'Terraform service user - key-pair auth, used by CI/CD only'
  DEFAULT_ROLE = ACCOUNTADMIN
  DEFAULT_WAREHOUSE = PLATFORM_WH;

ALTER USER SVC_TERRAFORM SET RSA_PUBLIC_KEY = 'MII...'; -- TODO replace with actual RSA public key

USE ROLE SECURITYADMIN;
GRANT ROLE ACCOUNTADMIN TO USER SVC_TERRAFORM; -- TODO replace with least-privilege TERRAFORM_ADMIN role later
