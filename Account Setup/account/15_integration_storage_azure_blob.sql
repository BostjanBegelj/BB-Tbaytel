-- ============================================================
-- STORAGE INTEGRATION - Azure Blob
-- RUN ONCE PER ACCOUNT.  The integration is account-level; the
-- external STAGE that uses it is a schema object (belongs in the
-- ETL / environment layer - shown here only as a commented example).
--
-- No public / anonymous test: you need your own Azure tenant and
-- storage account. Creating the integration succeeds immediately,
-- but LIST works only after you consent the Snowflake app in Azure
-- AD and grant it the "Storage Blob Data Reader/Contributor" role
-- on the storage account.
--
-- NOTE: verify syntax against current Snowflake docs before running.
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE STORAGE INTEGRATION AZURE_BLOB_INTEGRATION
  TYPE                      = EXTERNAL_STAGE
  STORAGE_PROVIDER          = 'AZURE'
  ENABLED                   = TRUE
  AZURE_TENANT_ID           = '<AZURE_TENANT_ID>'
  STORAGE_ALLOWED_LOCATIONS = ('azure://<account>.blob.core.windows.net/<container>/');

-- Consent step: run DESC, open AZURE_CONSENT_URL in a browser, then in
-- Azure grant the app named in AZURE_MULTI_TENANT_APP_NAME access to the
-- storage account.
DESC INTEGRATION AZURE_BLOB_INTEGRATION;

GRANT USAGE ON INTEGRATION AZURE_BLOB_INTEGRATION TO ROLE DEV_DATA_LOADER;
GRANT USAGE ON INTEGRATION AZURE_BLOB_INTEGRATION TO ROLE DEV_TRANSFORMER;


-- ------------------------------------------------------------
-- Example external stage (SCHEMA object - move to ETL/environment).
-- ------------------------------------------------------------
-- USE ROLE DEV_DATA_LOADER;
-- CREATE OR REPLACE STAGE DEV_DB.RAW.AZURE_BLOB_STAGE
--   STORAGE_INTEGRATION = AZURE_BLOB_INTEGRATION
--   URL                 = 'azure://<account>.blob.core.windows.net/<container>/';
-- LIST @DEV_DB.RAW.AZURE_BLOB_STAGE;
