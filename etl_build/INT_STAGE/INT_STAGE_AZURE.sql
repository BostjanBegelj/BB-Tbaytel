-- Internal stage standing in for the Azure Blob external stage (EXT_STAGE_AZURE)
-- during dev/test. PUT synthetic Parquet here and load exactly as you will from Blob.
-- Placement: {ENV}_DB.ADM (env-specific; a stage holds/points at actual data).
-- When real Blob is ready, use EXT_STAGE_AZURE (storage integration + URL) instead;
-- COPY logic and file format stay identical.

use role dev_sysadmin;
use database dev_db;

create stage if not exists adm.int_stage_azure
    directory = (enable = true)    -- directory table: LIST / metadata without re-scan
    comment = 'Internal stand-in for EXT_STAGE_AZURE (dev/test). Mirror Blob paths as subfolders, e.g. ENDUR_ORA/.';

-- Usage (mirror the external Blob path layout under the stage root):
--   put file://C:/tmp/ENDUR_ORA/*.parquet @dev_db.adm.int_stage_azure/ENDUR_ORA/ auto_compress=false;
--   list @dev_db.adm.int_stage_azure/ENDUR_ORA/;
--   select * from table(infer_schema(
--       location    => '@dev_db.adm.int_stage_azure/ENDUR_ORA/',
--       file_format => 'platform_db.file_formats.file_format_parquet'));
--   copy into dev_db.raw.<table>
--       from @dev_db.adm.int_stage_azure/ENDUR_ORA/
--       file_format = (format_name = 'platform_db.file_formats.file_format_parquet')
--       match_by_column_name = case_insensitive
--       on_error = abort_statement;

-- Verify
show stages like 'INT_STAGE_AZURE' in schema adm;
