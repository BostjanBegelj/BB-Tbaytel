-- =============================================================================
-- SHARE_SIM_DB - simulation of an INBOUND Secure Data Share source (dev/test).
--
-- Why a plain database, not a real share:
--   A Snowflake share cannot be consumed by the same account that created it, so
--   an inbound share cannot be simulated within one dev account. This plain,
--   read-only database stands in for the database a consumer would create from a
--   share:  CREATE DATABASE <x> FROM SHARE <provider_account>.<share_name>;
--   (When a real provider account exists, replace this whole script with that one
--    line + the same grants below; the ETL that reads it stays identical.)
--
-- How share-based sources differ from the file sources (EXT_STAGE_AZURE):
--   * No stage / no COPY - the ETL reads straight from SHARE_SIM_DB.<schema>.<table>.
--   * Current-state snapshot with a MODIFIED_TS column:
--       - freshness DQ = MAX(MODIFIED_TS)
--       - incremental  = rows where MODIFIED_TS > last watermark
--
-- Placement: standalone account-level database (a consumed share is its own DB;
-- it is neither {ENV}_DB nor PLATFORM_DB). Owned by SYSADMIN, read-only to the
-- environment pipeline roles (mimics imported privileges on a share).
-- =============================================================================

use role sysadmin;

create database if not exists share_sim_db
    comment = 'SIMULATION of an inbound Secure Data Share source (read-only to pipeline). NOT a real share.';

create schema if not exists share_sim_db.wholesale
    comment = 'Simulated provider schema (partner / wholesale feed).';

use database share_sim_db;
use schema wholesale;

-- ----- Dimension-like: partner accounts (current-state snapshot) -------------
create or replace table wholesale.partner_account (
    account_id     number(38,0) not null,
    partner_name   varchar,
    region         varchar,
    status         varchar,
    effective_date date,
    modified_ts    timestamp_ntz   -- snapshot watermark: freshness DQ + incremental key
);

insert into wholesale.partner_account
    (account_id, partner_name, region, status, effective_date, modified_ts) values
    (9001, 'Rogers Wholesale', 'Canada Central', 'ACTIVE',    '2025-01-01', '2026-07-01 02:00:00'),
    (9002, 'Bell Wholesale',   'Canada East',    'ACTIVE',    '2025-03-15', '2026-07-01 02:00:00'),
    (9003, 'Telus Wholesale',  'Canada West',    'SUSPENDED', '2025-06-01', '2026-07-01 02:00:00');

-- ----- Fact-like: wholesale usage per account per day ------------------------
create or replace table wholesale.wholesale_usage (
    usage_id    number(38,0) not null,
    account_id  number(38,0) not null,
    usage_date  date,
    units       number(18,0),
    amount      number(12,2),
    modified_ts timestamp_ntz
);

insert into wholesale.wholesale_usage
    (usage_id, account_id, usage_date, units, amount, modified_ts) values
    (50001, 9001, '2026-07-01', 12000, 1560.00, '2026-07-01 02:05:00'),
    (50002, 9002, '2026-07-01',  8400, 1092.00, '2026-07-01 02:05:00'),
    (50003, 9001, '2026-07-02', 13100, 1703.00, '2026-07-02 02:05:00'),
    (50004, 9003, '2026-07-02',  5200,  676.00, '2026-07-02 02:05:00');

-- ----- Read-only grants to pipeline roles (mimics imported privileges) -------
-- Repeat per environment role that reads shared sources (tst_/prd_, data_loader, etc.).
grant usage  on database share_sim_db                       to role dev_transformer;
grant usage  on schema   share_sim_db.wholesale             to role dev_transformer;
grant select on all    tables in schema share_sim_db.wholesale to role dev_transformer;
grant select on future tables in schema share_sim_db.wholesale to role dev_transformer;

-- ----- Verify ----------------------------------------------------------------
show tables in schema share_sim_db.wholesale;
select 'partner_account' as tbl, count(*) as row_count, max(modified_ts) as max_modified
  from wholesale.partner_account
union all
select 'wholesale_usage', count(*), max(modified_ts)
  from wholesale.wholesale_usage;

-- ----- Simulate a NEW share snapshot (for incremental / freshness DQ tests) --
--   update wholesale.partner_account
--       set status = 'ACTIVE', modified_ts = current_timestamp()
--       where account_id = 9003;
--   insert into wholesale.wholesale_usage
--       (usage_id, account_id, usage_date, units, amount, modified_ts) values
--       (50005, 9002, current_date(), 6000, 780.00, current_timestamp());
-- Then re-run the pipeline: only rows with MODIFIED_TS > last watermark should load.
