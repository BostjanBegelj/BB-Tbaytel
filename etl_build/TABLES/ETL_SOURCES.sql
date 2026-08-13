-- ADM.ETL_SOURCES - source-system registry (config; ETL_ prefix).
-- One row per source system. SOURCE_TYPE drives the load pattern:
--   FILE     -> files landed in a stage, loaded via SP_LOAD_FILE_TO_BRONZE
--               (format-agnostic: FILE_FORMAT decides Parquet / CSV / JSON / ...)
--   DATABASE -> read directly from another Snowflake database via SP_LOAD_DATABASE_TO_BRONZE
--               (an inbound data share or any ordinary database - the loader does not care)
-- Deploy order: create this BEFORE ETL_TABLES (which FKs to it).
-- Sample data: see etl_build/SEED/seed_config_dev.sql.

use role dev_sysadmin;
use database dev_db;
use schema adm;

create or replace table adm.etl_sources (
    source_id   varchar not null comment 'Source system identifier (e.g. BSS_ORA).',
    source_name varchar not null comment 'Human-readable source application name.',
    source_type varchar not null comment 'Load pattern: FILE | DATABASE.',
    stage_name  varchar comment 'FILE only: stage root, e.g. @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/.',
    source_db   varchar comment 'DATABASE only: source database name (shared or ordinary), e.g. SHARE_SIM_DB.',
    file_format varchar comment 'FILE only: file format used by COPY, e.g. PLATFORM_DB.FILE_FORMATS.FF_PARQUET.',
    active_flag boolean not null default true comment 'FALSE disables the source (the orchestrator skips it).',
    constraint pk_adm_etl_sources primary key (source_id)
) comment = 'Config: registry of source systems and their load pattern (ETL_ prefix).';
