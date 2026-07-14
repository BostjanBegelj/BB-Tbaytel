# etl/ — schema-level objects (never Terraform)

Tables, stages, file formats, and stored procedures stay SQL forever and are
deployed with schemachange (or Snowflake git integration + `EXECUTE IMMEDIATE FROM`),
not Terraform. The existing `ETL/` folder at the repo root remains the source
for these; nothing moves here until you adopt schemachange versioned naming
(`V1.0.0__description.sql`).

One relocation from v1: **stages** were created inside the storage-integration
scripts under `Account Setup/3_integrations`. The integration (account-level)
stays in `setup_v2/account/3_integrations`; the stage (schema-level) belongs
here / in `ETL/EXT_STAGE`. Example:

```sql
USE ROLE DEV_TRANSFORMER;
CREATE STAGE IF NOT EXISTS DEV_DB.RAW.AZURE_LANDING_STAGE
  STORAGE_INTEGRATION = DEV_AZURE_BLOB_INTEGRATION
  URL = 'azure://<storage_account>.blob.core.windows.net/<container>/';
```

Rule of thumb: if the object lives *inside a schema*, it does not go to Terraform.
