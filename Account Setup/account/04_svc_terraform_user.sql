-- ============================================================
-- SVC_TERRAFORM  -  account-level Terraform deployment service user
-- RUN ONCE PER ACCOUNT.
--
-- Prerequisites:
--   - TERRAFORM_ADMIN exists (account/03_terraform_admin_role.sql)
--   - PLATFORM_WH exists (account/02_platform_db_and_procs.sql)
--
-- TYPE = SERVICE, key-pair authentication only, no password.
-- CI/CD use only - not an interactive human account.
--
-- NEVER store a private key in this script or in source control.
-- ============================================================

SET SVC_TERRAFORM_USER  = 'SVC_TERRAFORM';
SET TERRAFORM_ROLE      = 'TERRAFORM_ADMIN';
SET TERRAFORM_WAREHOUSE = 'PLATFORM_WH';


-- ------------------------------------------------------------
-- Create the service user. IF NOT EXISTS makes re-runs safe, but
-- note it does not update an existing user's properties.
-- ------------------------------------------------------------
USE ROLE USERADMIN;
CREATE USER IF NOT EXISTS IDENTIFIER($SVC_TERRAFORM_USER)
    LOGIN_NAME        = $SVC_TERRAFORM_USER
    DISPLAY_NAME      = 'Terraform deployment'
    TYPE              = 'SERVICE'
    COMMENT           = 'Terraform service user - key-pair auth, CI/CD only'
    DEFAULT_ROLE      = $TERRAFORM_ROLE
    DEFAULT_WAREHOUSE = $TERRAFORM_WAREHOUSE
;


-- ------------------------------------------------------------
-- Grant the role. Setting DEFAULT_ROLE does not grant it.
-- SECURITYADMIN grants (it has MANAGE GRANTS by default).
-- SVC_TERRAFORM does NOT receive ACCOUNTADMIN.
-- ------------------------------------------------------------
USE ROLE SECURITYADMIN;
GRANT ROLE IDENTIFIER($TERRAFORM_ROLE) TO USER IDENTIFIER($SVC_TERRAFORM_USER);


-- ------------------------------------------------------------
-- Assign the RSA public key.
-- Paste ONLY the Base64 body: no -----BEGIN/END----- lines, no
-- line breaks. Store the matching PRIVATE key only in the CI/CD
-- secret store. Uncomment once a real key is available
-- ('MII...' style placeholders are not valid keys).
-- ------------------------------------------------------------
USE ROLE USERADMIN;
-- SET TERRAFORM_RSA_PUBLIC_KEY = '<TERRAFORM_RSA_PUBLIC_KEY_BODY>';
-- ALTER USER IDENTIFIER($SVC_TERRAFORM_USER)
--     SET RSA_PUBLIC_KEY = $TERRAFORM_RSA_PUBLIC_KEY;

-- Optional rotation slot (introduce a new key before removing the old):
-- ALTER USER IDENTIFIER($SVC_TERRAFORM_USER)
--     SET RSA_PUBLIC_KEY_2 = '<NEW_TERRAFORM_RSA_PUBLIC_KEY_BODY>';


-- ============================================================
-- VALIDATION  -  after a valid key is set, RSA_PUBLIC_KEY_FP is
-- populated in DESCRIBE USER output.
-- ============================================================
USE ROLE USERADMIN;
DESCRIBE USER IDENTIFIER($SVC_TERRAFORM_USER);

USE ROLE SECURITYADMIN;
SHOW GRANTS TO USER IDENTIFIER($SVC_TERRAFORM_USER);
