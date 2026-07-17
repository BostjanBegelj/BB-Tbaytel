-- Seed the DEV config tables for the current test assets:
--   BSS_ORA   (PARQUET)   -> files in EXT_STAGE_AZURE/BSS_ORA/, format FF_PARQUET
--   WHOLESALE (DATASHARE) -> read from SHARE_SIM_DB.WHOLESALE
-- Idempotent: clears then re-inserts. Run AFTER the ADM tables exist.
-- This is dev sample data, NOT production config (build step 9 = the real seed).

use role dev_sysadmin;
use database dev_db;
use schema adm;

-- Clear (child before parent for tidiness; FKs are not enforced in Snowflake).
delete from adm.etl_tables;
delete from adm.etl_sources;

-- Sources
insert into adm.etl_sources (source_id, source_name, source_type, stage_name, share_db, file_format) values
  ('BSS_ORA',   'Billing/CRM (Oracle)',           'PARQUET',   '@DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/', null,           'PLATFORM_DB.FILE_FORMATS.FF_PARQUET'),
  ('WHOLESALE', 'Partner wholesale (Data Share)', 'DATASHARE', null,                                   'SHARE_SIM_DB', null);

-- Tables: BSS_ORA (Parquet)
insert into adm.etl_tables (source_id, table_name, file_pattern, load_type, pk_columns, watermark_column, target_schema, load_order) values
  ('BSS_ORA','CUSTOMER',     '.*CUSTOMER_.*\\.parquet',     'FULL', 'CUSTOMER_ID', null,      'BRONZE', 10),
  ('BSS_ORA','SERVICE_PLAN', '.*SERVICE_PLAN_.*\\.parquet', 'FULL', 'PLAN_ID',     null,      'BRONZE', 20),
  ('BSS_ORA','USAGE_DAILY',  '.*USAGE_DAILY_.*\\.parquet',  'INCR', 'USAGE_ID',    'EVENT_TS', 'BRONZE', 30);

-- Tables: WHOLESALE (Data Share)
insert into adm.etl_tables (source_id, table_name, source_object, load_type, pk_columns, watermark_column, target_schema, load_order) values
  ('WHOLESALE','PARTNER_ACCOUNT','WHOLESALE.PARTNER_ACCOUNT','FULL','ACCOUNT_ID','MODIFIED_TS','BRONZE',10),
  ('WHOLESALE','WHOLESALE_USAGE','WHOLESALE.WHOLESALE_USAGE','INCR','USAGE_ID',  'MODIFIED_TS','BRONZE',20);

-- Verify
select * from adm.etl_sources order by source_id;
select * from adm.etl_tables order by source_id, load_order;
