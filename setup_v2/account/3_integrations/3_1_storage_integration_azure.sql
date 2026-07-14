-- ============================================================================
-- Azure storage integration — account-level object ONLY.
-- Terraform mapping: snowflake_storage_integration
-- Fixes vs. v1: stage creation moved to etl/ (schema-level, stays SQL),
--   no CREATE OR REPLACE (would break existing stages + drop grants).
-- ============================================================================
USE ROLE ACCOUNTADMIN;
CREATE STORAGE INTEGRATION IF NOT EXISTS DEV_AZURE_BLOB_INTEGRATION
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'AZURE'
  ENABLED = TRUE
  AZURE_TENANT_ID = '<tenant_id>' -- replace with Tbaytel Azure tenant ID
  STORAGE_ALLOWED_LOCATIONS = ('azure://<storage_account>.blob.core.windows.net/<container>/');

-- one-time: open the consent URL from the output
DESCRIBE INTEGRATION DEV_AZURE_BLOB_INTEGRATION;

GRANT USAGE ON INTEGRATION DEV_AZURE_BLOB_INTEGRATION TO ROLE DEV_TRANSFORMER;
GRANT USAGE ON INTEGRATION DEV_AZURE_BLOB_INTEGRATION TO ROLE DEV_DATA_LOADER;
