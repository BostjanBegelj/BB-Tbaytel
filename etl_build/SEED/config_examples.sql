-- =============================================================================================
-- ADM.ETL_SOURCES / ADM.ETL_TABLES - complete configuration catalogue
--
-- Reference only: every example is a runnable INSERT, but they are NOT meant to be run as a
-- batch (they reuse table names). Copy the one you need and adjust.
-- The live DEV config is in seed_config_dev.sql.
--
-- Each INSERT names only the columns it sets; everything else takes its default:
--   TARGET_SCHEMA = 'BRONZE', LOAD_ORDER = 100, ACTIVE_FLAG = TRUE,
--   ALLOW_EMPTY = FALSE, WATERMARK_OVERLAP = 0, all other columns NULL.
-- =============================================================================================
use role dev_sysadmin;
use database dev_db;
use schema adm;

-- =============================================================================================
-- WHAT COMBINATION DOES WHAT
--
--  LOAD_TYPE   BRONZE gets            SILVER does                     deletes detected?
--  ---------   --------------------   -----------------------------   -----------------
--  FULL        complete snapshot      MERGE + soft-delete missing     YES
--  INIT        complete snapshot      same as FULL (one-off seed)     YES
--  INCR        a delta (from ADF)     MERGE only                      no
--  WATERMARK   a bounded delta        MERGE only                      no
--  PARTITION   whole partitions       MERGE + soft-delete in those    within loaded partitions
--
--  SOURCE_TYPE   extraction owner   watermark filter   needs
--  -----------   ----------------   ----------------   ---------------------------------
--  FILE          ADF                ADVISORY only      STAGE_NAME + FILE_FORMAT + FILE_PATTERN
--  DATABASE      this framework     ENFORCED           SOURCE_DB + SOURCE_OBJECT
-- =============================================================================================


-- =============================================================================================
-- 1. SOURCES
-- =============================================================================================

-- 1a. FILE source: ADF lands files in a stage. FILE_FORMAT decides the format, so the same
--     pattern works for CSV/JSON/Avro as well as Parquet.
insert into adm.etl_sources (source_id, source_name, source_type, stage_name, file_format) values
  ('BSS_ORA', 'Billing/CRM (Oracle via ADF)', 'FILE',
   '@DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/', 'PLATFORM_DB.FILE_FORMATS.FF_PARQUET');

-- 1b. FILE source landing CSV instead - only FILE_FORMAT changes.
insert into adm.etl_sources (source_id, source_name, source_type, stage_name, file_format) values
  ('SAP_FI', 'SAP FI/CO (ADF, CSV)', 'FILE',
   '@DEV_DB.ADM.EXT_STAGE_AZURE/SAP_FI/', 'PLATFORM_DB.FILE_FORMATS.FF_CSV');

-- 1c. DATABASE source that happens to be an inbound data share.
insert into adm.etl_sources (source_id, source_name, source_type, source_db) values
  ('WHOLESALE', 'Partner wholesale (inbound share)', 'DATABASE', 'SHARE_SIM_DB');

-- 1d. DATABASE source that is an ordinary database in the same account - identical to the
--     loader; only SELECT access matters.
insert into adm.etl_sources (source_id, source_name, source_type, source_db) values
  ('LEGACY_DWH', 'Legacy warehouse (direct read)', 'DATABASE', 'LEGACY_DB');


-- =============================================================================================
-- 2. FILE-SOURCE TABLES
-- =============================================================================================

-- 2a. FULL snapshot, DEFAULT path  <-- STANDARD PRODUCTION ROW
--     STAGE_SUBPATH NULL => the loader follows the agreed ADF contract automatically:
--       @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/CUSTOMER/<PPN_ID>/
--     Each run reads only its own folder, so stale files from earlier extractions are impossible.
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns, load_order) values
  ('BSS_ORA', 'CUSTOMER', '.*\\.parquet', 'FULL', 'CUSTOMER_ID', 10);

-- 2b. Same, with the path spelled out explicitly. Identical behaviour to 2a - only needed if a
--     source deviates from the convention (e.g. an extra sub-folder level).
insert into adm.etl_tables (source_id, table_name, file_pattern, stage_subpath, load_type, pk_columns, load_order) values
  ('BSS_ORA', 'CUSTOMER', '.*\\.parquet', 'CUSTOMER/{PPN_ID}/', 'FULL', 'CUSTOMER_ID', 10);

-- 2c. OVERRIDE for manual testing: a fixed per-table folder, no PPN level, so uploaded files can
--     be reused across runs. NOT for production - the pattern can then match older files.
insert into adm.etl_tables (source_id, table_name, file_pattern, stage_subpath, load_type, pk_columns, load_order) values
  ('BSS_ORA', 'CUSTOMER', '.*CUSTOMER_.*\\.parquet', 'CUSTOMER/', 'FULL', 'CUSTOMER_ID', 10);

-- 2d. INIT - one-off seed of a brand-new table. Behaves like FULL; switch the row to
--     INCR/WATERMARK afterwards.
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns, load_order) values
  ('BSS_ORA', 'CUSTOMER_HISTORY', '.*\\.parquet', 'INIT', 'CUSTOMER_ID', 15);

-- 2e. INCR - ADF sends a delta and keeps its own bookmark. Nothing is recorded on our side.
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns, load_order) values
  ('BSS_ORA', 'USAGE_DAILY', '.*\\.parquet', 'INCR', 'USAGE_ID', 30);

-- 2f. WATERMARK + TIMESTAMP, 2-day overlap. The filter is ADVISORY for FILE sources (ADF does the
--     extraction) but the MAX EVENT_TS landed is recorded in PPN_PROCESS.WATERMARK_VALUE, so ADF
--     can read it back as its next lower bound. Catches inserts AND updates.
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns,
                            watermark_column, watermark_type, watermark_overlap, load_order) values
  ('BSS_ORA', 'USAGE_DAILY', '.*\\.parquet', 'WATERMARK', 'USAGE_ID',
   'EVENT_TS', 'TIMESTAMP', 2, 30);

-- 2g. WATERMARK + DATE, 7-day overlap (day-grain source column).
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns,
                            watermark_column, watermark_type, watermark_overlap, load_order) values
  ('BSS_ORA', 'INVOICE', '.*\\.parquet', 'WATERMARK', 'INVOICE_ID',
   'INVOICE_DATE', 'DATE', 7, 40);

-- 2h. WATERMARK + NUMBER, 100-unit overlap.
--     WARNING: an id does not change when a row is UPDATED, so this detects INSERTS ONLY.
--     Use it for append-only feeds; use TIMESTAMP if rows can be modified.
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns,
                            watermark_column, watermark_type, watermark_overlap, load_order) values
  ('BSS_ORA', 'CALL_EVENT', '.*\\.parquet', 'WATERMARK', 'EVENT_ID',
   'EVENT_ID', 'NUMBER', 100, 50);

-- 2i. PARTITION - replace only the partitions present in this load; the SILVER delete sweep is
--     scoped to those partitions, so other dates are untouched. Requires PARTITION_COLUMN.
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns,
                            partition_column, load_order) values
  ('BSS_ORA', 'USAGE_DAILY', '.*\\.parquet', 'PARTITION', 'USAGE_ID',
   'USAGE_DATE', 30);

-- 2j. FULL snapshot for a table that may LEGITIMATELY be empty. Without ALLOW_EMPTY the
--     empty-snapshot guard errors the table (a 0-row FULL load would soft-delete all of SILVER).
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns,
                            allow_empty, load_order) values
  ('BSS_ORA', 'PROMO_CAMPAIGN', '.*\\.parquet', 'FULL', 'CAMPAIGN_ID',
   TRUE, 60);

-- 2k. Table with NO business key. PK_HK falls back to the whole row, so identical rows dedupe and
--     a changed row looks like delete+insert. Allowed for FULL/INIT only (INCR/WATERMARK require
--     PK_COLUMNS). Land it in RAW rather than BRONZE, as an example of TARGET_SCHEMA.
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type,
                            target_schema, load_order) values
  ('BSS_ORA', 'RATE_PLAN_DUMP', '.*\\.parquet', 'FULL',
   'RAW', 70);


-- =============================================================================================
-- 3. DATABASE-SOURCE TABLES
--    STAGE_SUBPATH / FILE_PATTERN / FILE_FORMAT are not used at all here.
-- =============================================================================================

-- 3a. FULL snapshot of a small dimension.
insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns, load_order) values
  ('WHOLESALE', 'PARTNER_ACCOUNT', 'WHOLESALE.PARTNER_ACCOUNT', 'FULL', 'ACCOUNT_ID', 10);

-- 3b. INIT seed of a large table, then switch to WATERMARK.
insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns, load_order) values
  ('WHOLESALE', 'WHOLESALE_USAGE', 'WHOLESALE.WHOLESALE_USAGE', 'INIT', 'USAGE_ID', 20);

-- 3c. WATERMARK + TIMESTAMP, 1-day overlap  <-- the enforced case.
--     The loader appends:  WHERE s."MODIFIED_TS" > DATEADD(day, -1, '<last>'::TIMESTAMP_NTZ)
insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns,
                            watermark_column, watermark_type, watermark_overlap, load_order) values
  ('WHOLESALE', 'WHOLESALE_USAGE', 'WHOLESALE.WHOLESALE_USAGE', 'WATERMARK', 'USAGE_ID',
   'MODIFIED_TS', 'TIMESTAMP', 1, 20);

-- 3d. WATERMARK + DATE, minimum 1-day overlap.
--     Loader appends:  WHERE s."USAGE_DATE" > DATEADD(day, -1, '<last>'::DATE)
--     DATE compares at DAY grain with ">", so OVERLAP 0 would permanently skip every row dated
--     exactly on the bound (rows added later the same day are lost). SP_VALIDATE_CONFIG therefore
--     REJECTS WATERMARK_TYPE='DATE' with WATERMARK_OVERLAP < 1.
insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns,
                            watermark_column, watermark_type, watermark_overlap, load_order) values
  ('WHOLESALE', 'WHOLESALE_USAGE', 'WHOLESALE.WHOLESALE_USAGE', 'WATERMARK', 'USAGE_ID',
   'USAGE_DATE', 'DATE', 1, 20);

-- 3e. WATERMARK + NUMBER, 50-unit overlap (append-only ledger).
--     Loader appends:  WHERE s."USAGE_ID" > (<last> - 50)
insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns,
                            watermark_column, watermark_type, watermark_overlap, load_order) values
  ('WHOLESALE', 'WHOLESALE_USAGE', 'WHOLESALE.WHOLESALE_USAGE', 'WATERMARK', 'USAGE_ID',
   'USAGE_ID', 'NUMBER', 50, 20);

-- 3f. PARTITION over a source database table.
insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns,
                            partition_column, load_order) values
  ('WHOLESALE', 'WHOLESALE_USAGE', 'WHOLESALE.WHOLESALE_USAGE', 'PARTITION', 'USAGE_ID',
   'USAGE_DATE', 20);

-- 3g. INCR on a DATABASE source - allowed, but rarely what you want: the loader always reads the
--     FULL source table (no watermark to bound it), yet SILVER treats it as a partial feed and so
--     never detects deletes. Prefer FULL (deletes detected) or WATERMARK (bounded read).
insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns, load_order) values
  ('LEGACY_DWH', 'ACCOUNT_SNAPSHOT', 'DBO.ACCOUNT_SNAPSHOT', 'INCR', 'ACCOUNT_ID', 10);


-- =============================================================================================
-- 4. INVALID COMBINATIONS - SP_VALIDATE_CONFIG rejects these before any table is loaded
-- =============================================================================================
--  SOURCE_TYPE not in (FILE, DATABASE)
--  FILE source without STAGE_NAME or without FILE_FORMAT
--  FILE table without FILE_PATTERN
--  DATABASE source without SOURCE_DB
--  DATABASE table without SOURCE_OBJECT
--  LOAD_TYPE not in (FULL, INIT, INCR, PARTITION, WATERMARK)
--  LOAD_TYPE INCR or WATERMARK without PK_COLUMNS
--  LOAD_TYPE WATERMARK without WATERMARK_COLUMN
--  LOAD_TYPE WATERMARK without WATERMARK_TYPE, or WATERMARK_TYPE not in (TIMESTAMP, DATE, NUMBER)
--  LOAD_TYPE PARTITION without PARTITION_COLUMN
--  WATERMARK_OVERLAP < 0
--  WATERMARK_TYPE 'DATE' with WATERMARK_OVERLAP < 1 (day-grain ">" would skip same-day rows)
--
-- NOT checked (accepted risk): a source column named PPN_ID / PPN_TIMESTAMP / SRC_FILE_NAME would
-- collide with the lineage columns the loaders add. Considered negligible; if it ever happens,
-- rename the column in the extract.
--  a table whose SOURCE_ID has no active ETL_SOURCES row


-- =============================================================================================
-- 5. USEFUL MAINTENANCE STATEMENTS
-- =============================================================================================
-- take a table out of the next run without deleting its config
--   update adm.etl_tables set active_flag = false where source_id='BSS_ORA' and table_name='USAGE_DAILY';
-- switch a seeded table from INIT to ongoing incremental
--   update adm.etl_tables set load_type='WATERMARK', watermark_column='MODIFIED_TS',
--          watermark_type='TIMESTAMP', watermark_overlap=1
--    where source_id='WHOLESALE' and table_name='WHOLESALE_USAGE';
-- switch a table from a TEST override back to the production default path
--   update adm.etl_tables set stage_subpath = null, file_pattern = '.*\\.parquet'
--    where source_id='BSS_ORA' and table_name='CUSTOMER';
-- point ALL of a source's tables at fixed per-table folders for manual testing
--   update adm.etl_tables set stage_subpath = table_name || '/' where source_id='BSS_ORA';
-- force a full reload of a WATERMARK table (clears the recorded bound, so the next run reads all)
--   update adm.ppn_process set watermark_value = null
--    where source_id='WHOLESALE' and table_name='WHOLESALE_USAGE';
-- current watermark bound per table (what the next run will use / what ADF should read)
--   select source_id, table_name, ppn_id, watermark_value
--     from adm.ppn_process
--    where upper(status) in ('SUCCESS','SKIP') and watermark_value is not null
--   qualify row_number() over (partition by source_id, table_name order by ppn_id desc) = 1;
