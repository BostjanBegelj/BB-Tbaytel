-- ADM.ETL_TABLES - per-table load control (config; ETL_ prefix).
-- One row per table to load. "Config over code": adding a table is a metadata row.
-- Deploy order: create AFTER ETL_SOURCES (FK target).
-- Sample data: see etl_build/SEED/seed_config_dev.sql.

use role dev_sysadmin;
use database dev_db;
use schema adm;

create or replace table adm.etl_tables (
    source_id        varchar      not null comment 'FK -> ADM.ETL_SOURCES.SOURCE_ID.',
    table_name       varchar      not null comment 'Logical/target table name (e.g. CUSTOMER).',
    source_object    varchar      comment 'DATASHARE: <schema>.<table> in the shared DB.',
    file_pattern     varchar      comment 'PARQUET: regex matching the file(s) for one load, e.g. .*CUSTOMER_.*\\.parquet.',
    load_type        varchar      not null comment 'FULL | INIT | INCR | PARTITION.',
    pk_columns       varchar      comment 'Comma-separated business PK columns (required for INCR).',
    watermark_column varchar      comment 'Column driving the incremental high-water mark (e.g. MODIFIED_TS).',
    partition_column varchar      comment 'PARTITION load: column identifying partitions to replace.',
    target_schema    varchar      not null default 'BRONZE' comment 'Landing/target layer schema.',
    load_order       number(38,0) default 100 comment 'Ascending execution order within a run.',
    active_flag      boolean      not null default true comment 'FALSE disables the table.',
    constraint pk_adm_etl_tables primary key (source_id, table_name),
    constraint fk_adm_etl_tables_source foreign key (source_id) references adm.etl_sources (source_id)
) comment = 'Config: per-table load control list (ETL_ prefix).';
