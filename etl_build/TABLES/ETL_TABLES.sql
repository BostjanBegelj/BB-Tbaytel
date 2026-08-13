-- ADM.ETL_TABLES - per-table load control (config; ETL_ prefix).
-- One row per table to load. "Config over code": adding a table is a metadata row.
--
-- LOAD_TYPE combines the extraction scope with how BRONZE is applied to SILVER:
--   FULL / INIT : complete snapshot  -> MERGE + soft-delete keys missing from the snapshot
--   INCR        : a delta produced elsewhere (ADF) -> MERGE only, deletes cannot be inferred
--   PARTITION   : selected partitions -> MERGE + soft-delete scoped to those partitions
--   WATERMARK   : a delta bounded by WATERMARK_COLUMN -> MERGE only (behaves like INCR in SILVER).
--                 DATABASE sources: the loader adds WHERE <col> > <bound> itself.
--                 FILE sources: advisory only - ADF does the extraction; Snowflake still records
--                 the MAX reached so ADF can read it back as the next lower bound.
--                 Needs WATERMARK_COLUMN + WATERMARK_TYPE; WATERMARK_OVERLAP adds a lookback.
--
-- Snowflake is the single watermark REGISTRY for both source patterns: the value reached by each
-- load is stored in ADM.PPN_PROCESS.WATERMARK_VALUE (see the query at the end of the seed script).
-- Deploy order: create AFTER ETL_SOURCES (FK target).
-- Sample data: see etl_build/SEED/seed_config_dev.sql.

use role dev_sysadmin;
use database dev_db;
use schema adm;

create or replace table adm.etl_tables (
    source_id        varchar      not null comment 'FK -> ADM.ETL_SOURCES.SOURCE_ID.',
    table_name       varchar      not null comment 'Logical/target table name (e.g. CUSTOMER).',
    source_object    varchar      comment 'DATABASE: <schema>.<table> inside SOURCE_DB.',
    file_pattern     varchar      comment 'FILE: regex matching the file(s) for one load, e.g. .*CUSTOMER_.*\\.parquet.',
    load_type        varchar      not null comment 'FULL | INIT | INCR | PARTITION | WATERMARK.',
    pk_columns       varchar      comment 'Comma-separated business PK columns (required for INCR and WATERMARK).',
    watermark_column varchar      comment 'Source column holding the high-water mark (e.g. MODIFIED_TS). Required for LOAD_TYPE WATERMARK. DATABASE sources filter on it; for FILE sources it is advisory (ADF owns extraction) but the reached MAX is still recorded in PPN_PROCESS.WATERMARK_VALUE.',
    watermark_type   varchar      comment 'TIMESTAMP | DATE | NUMBER - how to render/compare WATERMARK_VALUE and how to interpret WATERMARK_OVERLAP. Declared here (not derived) because the DATABASE loader needs it before reading the source. NOTE: a NUMBER (id) watermark detects INSERTS ONLY - an id does not change when a row is updated; use a modified-timestamp to catch updates.',
    watermark_overlap number(38,0) default 0 comment 'Lookback window re-read on each WATERMARK load, to catch late-arriving rows. DAYS for TIMESTAMP/DATE, raw units for NUMBER. 0 = no overlap. Re-read rows are absorbed by the SILVER MERGE (unchanged rows do not even update, thanks to ROW_HK).',
    partition_column varchar      comment 'PARTITION load: column identifying partitions to replace.',
    target_schema    varchar      not null default 'BRONZE' comment 'Landing/target layer schema.',
    load_order       number(38,0) default 100 comment 'Ascending execution order within a run.',
    allow_empty      boolean      not null default false comment 'FULL/INIT only: TRUE permits a zero-row snapshot (which soft-deletes all SILVER rows). FALSE fails the table instead.',
    active_flag      boolean      not null default true comment 'FALSE disables the table.',
    constraint pk_adm_etl_tables primary key (source_id, table_name),
    constraint fk_adm_etl_tables_source foreign key (source_id) references adm.etl_sources (source_id)
) comment = 'Config: per-table load control list (ETL_ prefix).';
