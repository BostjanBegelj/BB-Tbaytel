-- Shared Parquet file format for all landed sources, all environments.
-- Placement: PLATFORM_DB (cross-environment objects) per platform convention;
-- {ENV}_DB holds data, PLATFORM_DB holds env-independent objects.
-- Prereq: PLATFORM_DB.FILE_FORMATS schema is created by the account layer
--         (Account Setup/account/02_platform_database.sql).

use role sysadmin;                 -- owner of PLATFORM_DB
use database platform_db;

create or replace file format platform_db.file_formats.file_format_parquet
    type = parquet
    binary_as_text = false
    replace_invalid_characters = false
    use_logical_type = true        -- surface Parquet logical types (timestamps/decimals) correctly
;

-- Grant USAGE to the roles that run COPY (uncomment / template per environment):
-- grant usage on schema platform_db.file_formats to role dev_transformer;
-- grant usage on schema platform_db.file_formats to role dev_data_loader;
-- grant usage on file format platform_db.file_formats.file_format_parquet to role dev_transformer;
-- grant usage on file format platform_db.file_formats.file_format_parquet to role dev_data_loader;

-- Verify
desc file format platform_db.file_formats.file_format_parquet;
