-- ADM.ETL_SOURCES - source-system registry (config; ETL_ prefix).
-- One row per source system. SOURCE_TYPE drives the load pattern:
--   PARQUET   -> file landed in EXT_STAGE_AZURE, loaded via SP_LOAD_FILE_TO_BRONZE
--   DATASHARE -> read directly from a shared DB via SP_LOAD_SHARE_TO_BRONZE
-- Deploy order: create this BEFORE ETL_TABLES (which FKs to it).
-- Sample data: see etl_build/SEED/seed_config_dev.sql.

use role dev_sysadmin;
use database dev_db;
use schema adm;

create or replace table adm.etl_sources (
    source_id   varchar not null comment 'Source system identifier (e.g. BSS_ORA).',
    source_name varchar not null comment 'Human-readable source application name.',
    source_type varchar not null comment 'Load pattern: PARQUET | DATASHARE.',
    stage_name  varchar comment 'PARQUET only: external stage root, e.g. @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/.',
    share_db    varchar comment 'DATASHARE only: inbound shared database name, e.g. SHARE_SIM_DB.',
    file_format varchar comment 'PARQUET only: file format for COPY, e.g. PLATFORM_DB.FILE_FORMATS.FF_PARQUET.',
    active_flag boolean not null default true comment 'FALSE disables the source (ADF skips it).',
    constraint pk_adm_etl_sources primary key (source_id)
) comment = 'Config: registry of source systems and their load pattern (ETL_ prefix).';
