-- ============================================================================
-- Service users (key-pair auth, TYPE = SERVICE)
-- Terraform mapping: snowflake_service_user + snowflake_grant_account_role
-- Fixes vs. v1: ALTER targeted SVC_DEV_MATILLION while CREATE made SVC_DEV_ADF.
-- ============================================================================

-- ADF service user (DEV)
USE ROLE USERADMIN;
CREATE USER IF NOT EXISTS SVC_DEV_ADF
  LOGIN_NAME        = 'SVC_DEV_ADF'
  DISPLAY_NAME      = 'Azure Data Factory'
  TYPE              = SERVICE
  COMMENT           = 'ADF DEV service user'
  DEFAULT_ROLE      = DEV_DATA_LOADER
  DEFAULT_WAREHOUSE = DEV_DATA_LOADER_WH;

ALTER USER SVC_DEV_ADF SET RSA_PUBLIC_KEY = 'MII...'; -- replace with actual RSA public key

USE ROLE DEV_USERADMIN;
GRANT ROLE DEV_DATA_LOADER TO USER SVC_DEV_ADF;
