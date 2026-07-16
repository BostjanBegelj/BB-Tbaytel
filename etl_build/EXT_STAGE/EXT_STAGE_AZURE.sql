-- Stage for landed Parquet extracts. Named EXT_STAGE_AZURE (the final external-stage
-- name) for continuity: during dev/test it is an INTERNAL stand-in (PUT files here);
-- when real Azure Blob is ready, replace it with the external definition below
-- (storage integration + URL). COPY logic and file format stay identical either way.
-- Placement: {ENV}_DB.ADM (env-specific; a stage holds/points at actual data).
-- Note: no FILE_FORMAT on the stage by design — the load proc passes the format at
-- COPY time (P_OTHER), matching the reference loader.

use role dev_sysadmin;
use database dev_db;

-- Internal stand-in (active for dev/test)
create stage if not exists adm.ext_stage_azure
    directory = (enable = true)    -- directory table: LIST / metadata without re-scan
    comment = 'EXT_STAGE_AZURE: internal stand-in for the Azure Blob external stage (dev/test).';

-- Production external stage (enable when Blob is ready; same name, so consumers are unchanged)
/*
create or replace stage adm.ext_stage_azure
    storage_integration = dev_azure_blob_integration
    url = 'azure://<account>.blob.core.windows.net/<container>/<SOURCE>/'
    directory = (enable = true, auto_refresh = false)
    comment = 'EXT_STAGE_AZURE: external stage over Azure Blob landing.';
*/

-- Usage (mirror the Blob path layout under the stage root; source system = BSS_ORA):
--   put file://C:/.../BSS_ORA/CUSTOMER/*.parquet @dev_db.adm.ext_stage_azure/BSS_ORA/CUSTOMER/ auto_compress=false;
--   list @dev_db.adm.ext_stage_azure/BSS_ORA/CUSTOMER/;
--   select * from table(infer_schema(
--       location    => '@dev_db.adm.ext_stage_azure/BSS_ORA/CUSTOMER/',
--       file_format => 'platform_db.file_formats.ff_parquet'));
--   copy into dev_db.raw.<table>
--       from @dev_db.adm.ext_stage_azure/BSS_ORA/CUSTOMER/
--       file_format = (format_name = 'platform_db.file_formats.ff_parquet')
--       match_by_column_name = case_insensitive
--       on_error = abort_statement;

-- Verify
show stages like 'EXT_STAGE_AZURE' in schema adm;
