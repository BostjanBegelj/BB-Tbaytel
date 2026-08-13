-- Seed the DEV config tables for the current test assets:
--   BSS_ORA   (FILE)     -> files in EXT_STAGE_AZURE/BSS_ORA/, format FF_PARQUET
--   WHOLESALE (DATABASE) -> read from SHARE_SIM_DB.WHOLESALE
-- Idempotent: clears then re-inserts. Run AFTER the ADM tables exist.
-- This is dev sample data, NOT production config (build step 9 = the real seed).

use role dev_sysadmin;
use database dev_db;
use schema adm;

-- Clear (child before parent for tidiness; FKs are not enforced in Snowflake).
delete from adm.etl_tables;
delete from adm.etl_sources;

-- Sources
insert into adm.etl_sources (source_id, source_name, source_type, stage_name, source_db, file_format) values
  ('BSS_ORA',   'Billing/CRM (Oracle)',           'FILE',     '@DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/', null,           'PLATFORM_DB.FILE_FORMATS.FF_PARQUET'),
  ('WHOLESALE', 'Partner wholesale (Data Share)', 'DATABASE', null,                                   'SHARE_SIM_DB', null);

-- Tables: BSS_ORA (FILE / Parquet)
--   CUSTOMER / SERVICE_PLAN : FULL snapshots -> SILVER soft-deletes keys missing from the snapshot.
--   USAGE_DAILY             : WATERMARK on EVENT_TS (TIMESTAMP), 2-day overlap. For a FILE source
--                             the filter is ADVISORY - ADF decides which rows to extract; Snowflake
--                             records the MAX EVENT_TS landed so ADF can read it back.
--   PATH CONTRACT (confirmed with the ADF team): <stage>/{source}/{table}/{ppn_id}/
--   STAGE_NAME already ends with the source folder, so leaving STAGE_SUBPATH NULL makes the
--   loader read  @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/CUSTOMER/<PPN_ID>/  automatically.
--   That is the production setting - no per-table path config required.
--
--   For MANUAL testing, creating a folder named after each new PPN_ID is impractical, so point
--   the test tables at a fixed per-table folder instead:
--     update adm.etl_tables set stage_subpath = table_name || '/' where source_id = 'BSS_ORA';
--   (drop that override to test the real PPN-scoped path).
insert into adm.etl_tables
    (source_id, table_name, file_pattern, stage_subpath, load_type, pk_columns,
     watermark_column, watermark_type, watermark_overlap, target_schema, load_order) values
  ('BSS_ORA','CUSTOMER',     '.*CUSTOMER_.*\\.parquet',     null, 'FULL',      'CUSTOMER_ID', null,       null,       0, 'BRONZE', 10),
  ('BSS_ORA','SERVICE_PLAN', '.*SERVICE_PLAN_.*\\.parquet', null, 'FULL',      'PLAN_ID',     null,       null,       0, 'BRONZE', 20),
  ('BSS_ORA','USAGE_DAILY',  '.*USAGE_DAILY_.*\\.parquet',  null, 'WATERMARK', 'USAGE_ID',    'EVENT_TS', 'TIMESTAMP', 2, 'BRONZE', 30);

-- Tables: WHOLESALE (DATABASE / data share)
--   PARTNER_ACCOUNT : FULL snapshot of a small dimension.
--   WHOLESALE_USAGE : WATERMARK on MODIFIED_TS (TIMESTAMP), 1-day overlap. For a DATABASE source
--                     this is ENFORCED - the loader appends
--                        WHERE MODIFIED_TS > DATEADD(day, -1, '<last recorded>'::TIMESTAMP_NTZ)
insert into adm.etl_tables
    (source_id, table_name, source_object, load_type, pk_columns,
     watermark_column, watermark_type, watermark_overlap, target_schema, load_order) values
  ('WHOLESALE','PARTNER_ACCOUNT','WHOLESALE.PARTNER_ACCOUNT','FULL',      'ACCOUNT_ID','MODIFIED_TS', null,       0, 'BRONZE', 10),
  ('WHOLESALE','WHOLESALE_USAGE','WHOLESALE.WHOLESALE_USAGE','WATERMARK', 'USAGE_ID',  'MODIFIED_TS','TIMESTAMP', 1, 'BRONZE', 20);

-- =============================================================================================
-- A runnable example of EVERY valid source/load/watermark/subpath combination lives in
--   etl_build/SEED/config_examples.sql
-- (including the invalid combinations SP_VALIDATE_CONFIG rejects, and maintenance statements).
-- The quick summary below is kept for convenience.
-- =============================================================================================
-- LOAD_TYPE variants -------------------------------------------------------------------------
--  FULL      complete snapshot; MERGE + soft-delete missing keys. Deletes ARE detected.
--    ('BSS_ORA','CUSTOMER','.*CUSTOMER_.*\\.parquet','FULL','CUSTOMER_ID',null,null,0,null,'BRONZE',10)
--
--  INIT      one-off seed of a brand-new table; behaves like FULL, then switch the row to INCR/WATERMARK.
--    ('BSS_ORA','CUSTOMER','.*CUSTOMER_INIT_.*\\.parquet','INIT','CUSTOMER_ID',null,null,0,null,'BRONZE',10)
--
--  INCR      a delta produced elsewhere (ADF keeps its own bookmark); MERGE only, no delete detection.
--    ('BSS_ORA','USAGE_DAILY','.*USAGE_DAILY_.*\\.parquet','INCR','USAGE_ID',null,null,0,null,'BRONZE',30)
--
--  PARTITION replace only the partitions present in this load; delete sweep scoped to them.
--    ('BSS_ORA','USAGE_DAILY','.*USAGE_DAILY_.*\\.parquet','PARTITION','USAGE_ID',null,null,0,'USAGE_DATE','BRONZE',30)
--
--  WATERMARK bounded delta; MERGE only (like INCR). Needs WATERMARK_COLUMN + WATERMARK_TYPE.
--    see the three type variants below.
--
-- WATERMARK_TYPE variants --------------------------------------------------------------------
--  TIMESTAMP catches INSERTS and UPDATES (the column changes when a row is modified).
--            OVERLAP is in DAYS. Bound: col > DATEADD(day, -overlap, '<last>'::TIMESTAMP_NTZ)
--    ('WHOLESALE','WHOLESALE_USAGE','WHOLESALE.WHOLESALE_USAGE','WATERMARK','USAGE_ID','MODIFIED_TS','TIMESTAMP',1,null,'BRONZE',20)
--
--  DATE      same as TIMESTAMP but day-grain; OVERLAP in DAYS.
--            Bound: col > DATEADD(day, -overlap, '<last>'::DATE)
--    ('WHOLESALE','WHOLESALE_USAGE','WHOLESALE.WHOLESALE_USAGE','WATERMARK','USAGE_ID','USAGE_DATE','DATE',7,null,'BRONZE',20)
--
--  NUMBER    monotonically increasing id / sequence. OVERLAP in RAW UNITS.
--            Bound: col > (<last> - overlap)
--            WARNING: an id does NOT change when a row is updated, so this detects INSERTS ONLY.
--            Use it for append-only feeds; use TIMESTAMP if rows can be modified.
--    ('WHOLESALE','WHOLESALE_USAGE','WHOLESALE.WHOLESALE_USAGE','WATERMARK','USAGE_ID','USAGE_ID','NUMBER',100,null,'BRONZE',20)
--
-- WATERMARK_OVERLAP ---------------------------------------------------------------------------
--   0   no lookback - fastest, but a row arriving late (below the watermark) is never loaded.
--   1-N re-read that far back each run to catch late arrivals; the SILVER MERGE absorbs the
--       repeats and ROW_HK means unchanged rows do not even update.
--
-- STAGE_SUBPATH (FILE sources) ----------------------------------------------------------------
--   NULL                     PRODUCTION DEFAULT. Follows the agreed ADF contract
--                            <stage>/{source}/{table}/{ppn_id}/ - STAGE_NAME already ends with the
--                            source folder, so the loader appends <TABLE>/<PPN_ID>/ itself.
--   'CUSTOMER/{PPN_ID}/'     the same thing spelled out; only needed if a source deviates from
--                            the convention. {PPN_ID} is substituted at run time.
--   'CUSTOMER/'              TEST override: fixed per-table folder so manually uploaded files can
--                            be reused across runs (no folder per PPN_ID). Not for production.
--
-- Other flags ---------------------------------------------------------------------------------
--   allow_empty: permit a legitimately empty FULL/INIT snapshot (otherwise the empty-guard errors)
--     update adm.etl_tables set allow_empty = true where source_id='BSS_ORA' and table_name='SERVICE_PLAN';
--   active_flag: take a table out of the run without deleting its config
--     update adm.etl_tables set active_flag = false where source_id='BSS_ORA' and table_name='USAGE_DAILY';
--   target_schema: land somewhere other than BRONZE (e.g. RAW for a future semi-structured pattern)

-- Verify
select * from adm.etl_sources order by source_id;
select source_id, table_name, load_type, pk_columns, stage_subpath,
       watermark_column, watermark_type, watermark_overlap,
       partition_column, target_schema, load_order, allow_empty
  from adm.etl_tables order by source_id, load_order;

-- Watermark registry: what the next WATERMARK run will use as its lower bound, and what ADF
-- should read for a FILE source. NULL = no successful run has recorded a value yet.
select source_id, table_name, ppn_id as last_ppn_id, watermark_value as last_watermark
  from adm.ppn_process
 where UPPER(status) in ('SUCCESS','SKIP') and watermark_value is not null
qualify row_number() over (partition by source_id, table_name order by ppn_id desc) = 1
 order by source_id, table_name;
