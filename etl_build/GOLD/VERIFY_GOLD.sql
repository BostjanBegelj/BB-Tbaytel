-- ============================================================================
-- VERIFY_GOLD - sanity checks for the GOLD simulation.
-- Run after the pipeline has landed WHOLESALE into SILVER and the GOLD objects
-- are created. Adjust the warehouse to your session's.
-- ============================================================================
use role dev_sysadmin;
use warehouse dev_data_loader_wh;   -- same warehouse the pipeline loads with
use database dev_db;
use schema gold;

-- 1) Row counts (expect: DIM_PARTNER = 7 [6 + unknown], FCT_WHOLESALE_USAGE = 72)
select 'DIM_PARTNER'         as obj, count(*) as rows from gold.dim_partner
union all select 'FCT_WHOLESALE_USAGE', count(*) from gold.fct_wholesale_usage
union all select 'DIM_DATE',            count(*) from gold.dim_date
union all select 'DIM_TIME',            count(*) from gold.dim_time;

-- 2) The unknown member exists exactly once -----------------------------------
select * from gold.dim_partner where partner_hk = '-1';

-- 3) Every fact row resolves to a real partner (no orphan facts) --------------
--    unknown_facts should be 0 given the demo data.
select count(*)                                             as fact_rows,
       count_if(partner_hk = '-1')                          as unknown_facts,
       count(distinct partner_hk)                           as distinct_partners
  from gold.fct_wholesale_usage;

-- 4) Star join: fact x DIM_PARTNER x DIM_DATE - revenue by partner & month ----
select dp.partner_name,
       dp.region,
       dd.year_month,
       sum(f.units)   as total_units,
       sum(f.amount)  as total_amount,
       count(*)       as usage_days
  from gold.fct_wholesale_usage f
  join gold.dim_partner dp on dp.partner_hk = f.partner_hk
  join gold.dim_date   dd on dd.date        = f.usage_date
 group by 1, 2, 3
 order by total_amount desc;

-- 5) Working-day check on the fact dates (DIM_DATE flags resolve) -------------
select dd.date, dd.day_name, dd.is_weekend, dd.is_holiday, dd.holiday_name,
       sum(f.amount) as amount
  from gold.fct_wholesale_usage f
  join gold.dim_date dd on dd.date = f.usage_date
 group by 1,2,3,4,5
 order by dd.date;

-- 6) Spot-check Canadian holidays in DIM_DATE for 2026 ------------------------
select date, day_name, holiday_name
  from gold.dim_date
 where is_holiday = 1 and year = 2026
 order by date;
--  Expect (Ontario statutory + federal):
--   New Year's Day 01-01, Family Day 02-16, Good Friday 04-03, Victoria Day 05-18,
--   Canada Day 07-01, Labour Day 09-07, Truth & Reconciliation 09-30,
--   Thanksgiving 10-12, Remembrance Day 11-11, Christmas 12-25, Boxing Day 12-26.

-- 7) Dynamic Table health + manual refresh ------------------------------------
show dynamic tables in schema gold;
select "name", "target_lag", "refresh_mode", "scheduling_state", "rows"
  from table(result_scan(last_query_id()));

-- Force an immediate refresh (fact cascades to its DOWNSTREAM dimension);
-- this is exactly what ADM.SP_REFRESH_GOLD runs:
--   alter dynamic table gold.dim_partner         refresh;
--   alter dynamic table gold.fct_wholesale_usage refresh;

-- Or drive it through the pipeline procedure:
--   call adm.sp_refresh_gold(<ppn_id>);

-- Refresh history (last refreshes per DT):
-- select name, state, refresh_start_time, refresh_end_time
--   from table(information_schema.dynamic_table_refresh_history())
--  where schema_name = 'GOLD' order by refresh_start_time desc;
