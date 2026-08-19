-- =============================================================================
-- SHARE_SIM_DB_DEMO_DATA - richer sample data for the GOLD simulation.
--
-- Purpose: give the GOLD dynamic tables (DIM_PARTNER, FCT_WHOLESALE_USAGE) enough
--          volume to demo surrogate keys, dimension joins and aggregations.
--          It enriches the SAME two tables the base SHARE_SIM_DB.sql creates:
--            WHOLESALE.PARTNER_ACCOUNT  (dimension-like)
--            WHOLESALE.WHOLESALE_USAGE  (fact-like)
--
-- Prerequisite: run  etl_build/SHARED_SIM/SHARE_SIM_DB.sql  first (it CREATEs the
--               database, schema and tables + the read-only pipeline grants).
--               This script only (re)loads DATA - structure is untouched.
--
-- Idempotent: DELETE then INSERT, so it can be re-run any time.
--
-- No config change is needed: PARTNER_ACCOUNT (FULL) and WHOLESALE_USAGE
-- (WATERMARK on MODIFIED_TS) are already registered in SEED/seed_config_dev.sql,
-- so the existing BRONZE -> SILVER pipeline lands this data automatically.
-- usage_id values stay < 50099 so the watermark demo row in
-- TESTS/run_clean_end_to_end.sql (50099) remains free.
-- =============================================================================

use role sysadmin;
use database share_sim_db;
use schema wholesale;

-- ----- Reset data (structure stays as defined in SHARE_SIM_DB.sql) -----------
delete from wholesale.wholesale_usage;
delete from wholesale.partner_account;

-- ----- Dimension: partner accounts (current-state snapshot) ------------------
--   9003 is SUSPENDED on purpose (a soft-delete / inactive path to demo).
insert into wholesale.partner_account
    (account_id, partner_name, region, status, effective_date, modified_ts) values
    (9001, 'Rogers Wholesale',    'Canada Central',  'ACTIVE',    '2025-01-01', '2026-07-14 02:00:00'),
    (9002, 'Bell Wholesale',      'Canada East',     'ACTIVE',    '2025-03-15', '2026-07-14 02:00:00'),
    (9003, 'Telus Wholesale',     'Canada West',     'SUSPENDED', '2025-06-01', '2026-07-14 02:00:00'),
    (9004, 'Videotron Wholesale', 'Canada East',     'ACTIVE',    '2025-02-10', '2026-07-14 02:00:00'),
    (9005, 'SaskTel Wholesale',   'Canada West',     'ACTIVE',    '2025-04-20', '2026-07-14 02:00:00'),
    (9006, 'Eastlink Wholesale',  'Canada Atlantic', 'ACTIVE',    '2025-07-05', '2026-07-14 02:00:00');

-- ----- Fact: wholesale usage per account per day -----------------------------
--   14 days x 5 active partners, generated with a deterministic HASH so the
--   numbers vary but re-running yields the same data (no RANDOM()).
insert into wholesale.wholesale_usage
    (usage_id, account_id, usage_date, units, amount, modified_ts)
with d as (
    select dateadd(day, seq4(), to_date('2026-07-01')) as usage_date
      from table(generator(rowcount => 14))
),
a as (
    select column1 as account_id
      from values (9001), (9002), (9004), (9005), (9006)
),
g as (
    select a.account_id,
           d.usage_date,
           4000 + mod(abs(hash(a.account_id, d.usage_date)), 12000) as units
      from a cross join d
)
select
    50000 + row_number() over (order by usage_date, account_id) as usage_id,
    account_id,
    usage_date,
    units,
    round(units * 0.13, 2)                                        as amount,
    dateadd(minute, 125, usage_date::timestamp_ntz)              as modified_ts   -- 02:05:00
  from g;

-- A couple of early rows for the SUSPENDED partner (9003), then it goes quiet -
-- shows a dimension member with only historical facts.
insert into wholesale.wholesale_usage
    (usage_id, account_id, usage_date, units, amount, modified_ts) values
    (50090, 9003, '2026-07-01', 5200, 676.00, '2026-07-01 02:05:00'),
    (50091, 9003, '2026-07-02', 4800, 624.00, '2026-07-02 02:05:00');

-- ----- Verify ----------------------------------------------------------------
select 'partner_account' as tbl, count(*) as row_count, max(modified_ts) as max_modified
  from wholesale.partner_account
union all
select 'wholesale_usage', count(*), max(modified_ts)
  from wholesale.wholesale_usage;
--  Expect: partner_account = 6 rows, wholesale_usage = 72 rows.
