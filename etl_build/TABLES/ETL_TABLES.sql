-- ADM.ETL_TABLES - per-table load control (config; ETL_ prefix).
-- One row per table to load. "Config over code": adding a table is a metadata row.
-- Deploy order: create AFTER ETL_SOURCES (FK target).

use role dev_sysadmin;
use database dev_db;
use schema adm;

create or replace table adm.etl_tables (
    source_id        varchar          not null comment 'FK -> ADM.ETL_SOURCES.SOURCE_ID.',
    table_name       varchar          not null comment 'Logical/target table name (e.g. CUSTOMER).',
    source_object    varchar          comment 'DATASHARE: <schema>.<table> in the shared DB.',
    file_pattern     varchar          comment 'PARQUET: regex matching the file(s) for one load, e.g. .*CUSTOMER_.*\\.parquet.',
    load_type        varchar          not null comment 'FULL | INIT | INCR | PARTITION.',
    incr_variant     varchar          comment 'INCR refinement (e.g. MERGE_UPSERT, APPEND_ONLY, SOFT_DELETE).',
    pk_columns       varchar          comment 'Comma-separated business PK columns (required for INCR).',
    watermark_column varchar          comment 'Column driving the incremental high-water mark (e.g. MODIFIED_TS).',
    partition_column varchar          comment 'PARTITION load: column identifying partitions to replace.',
    target_schema    varchar          not null default 'BRONZE' comment 'Landing/target layer schema (see RAW-vs-BRONZE note).',
    load_order       number(38,0)     default 100 comment 'Ascending execution order within a run.',
    dependency       varchar          comment 'Optional: table(s) that must complete first.',
    active_flag      boolean          not null default true comment 'FALSE disables the table.',
    created_ts       timestamp_ntz(9) not null default current_timestamp() comment 'Row creation timestamp.',
    updated_ts       timestamp_ntz(9) comment 'Row last-updated timestamp.',
    constraint pk_adm_etl_tables primary key (source_id, table_name),
    constraint fk_adm_etl_tables_source foreign key (source_id) references adm.etl_sources (source_id)
) comment = 'Config: per-table load control list (ETL_ prefix).';

-- Example seed (uncomment / adjust):
-- insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns, watermark_column, target_schema, load_order) values
--   ('BSS_ORA','CUSTOMER',     '.*CUSTOMER_.*\\.parquet',     'FULL', 'CUSTOMER_ID', null,       'BRONZE', 10),
--   ('BSS_ORA','SERVICE_PLAN', '.*SERVICE_PLAN_.*\\.parquet', 'FULL', 'PLAN_ID',     null,       'BRONZE', 20),
--   ('BSS_ORA','USAGE_DAILY',  '.*USAGE_DAILY_.*\\.parquet',  'INCR', 'USAGE_ID',    'EVENT_TS',  'BRONZE', 30);
-- insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns, watermark_column, target_schema, load_order) values
--   ('WHOLESALE','PARTNER_ACCOUNT','WHOLESALE.PARTNER_ACCOUNT','FULL','ACCOUNT_ID','MODIFIED_TS','BRONZE',10),
--   ('WHOLESALE','WHOLESALE_USAGE','WHOLESALE.WHOLESALE_USAGE','INCR','USAGE_ID',  'MODIFIED_TS','BRONZE',20);
