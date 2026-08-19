-- ============================================================================
-- GOLD.FCT_WHOLESALE_USAGE - wholesale usage fact (Dynamic Table).
-- Source: SILVER.WHOLESALE_USAGE (cleansed 1:1 mirror of the wholesale share).
--
-- Grain      : one row per usage record (USAGE_ID) = one partner, one day.
-- Foreign keys (surrogate/conformed):
--     PARTNER_HK -> GOLD.DIM_PARTNER (resolved via ACCOUNT_ID; COALESCE to the
--                  '-1' unknown member when a partner is missing/soft-deleted)
--     USAGE_DATE -> GOLD.DIM_DATE.DATE  (DIM_DATE's key is the DATE value)
--     DATE_KEY   -> YYYYMMDD numeric, handy if a numeric date key is preferred
-- Degenerate : USAGE_ID (transaction id kept on the fact, no separate dim)
-- Measures   : UNITS, AMOUNT (additive) + AMOUNT_PER_UNIT (non-additive ratio)
-- Filter     : IS_DELETED = FALSE.
--
-- Refresh    : Dynamic Table, PIPELINE-ONLY. SCHEDULER = DISABLE removes it from
--              automatic background refresh; ADM.SP_REFRESH_GOLD refreshes it (and
--              DIM_PARTNER) after the DQ gate PASSes, so GOLD never publishes
--              ungated data. TARGET_LAG is absent (not allowed with
--              SCHEDULER = DISABLE). INITIALIZE = ON_CREATE populates it at deploy.
--              SP_REFRESH_GOLD issues one combined statement over all GOLD dynamic
--              tables, which Snowflake refreshes at a common data timestamp in
--              dependency order (dim before fact) - so this fact always sees a
--              consistent DIM_PARTNER.
--
-- WAREHOUSE NOTE: see DIM_PARTNER.sql - DEV_DATA_LOADER_WH (the ETL load
--   warehouse); the owning role needs USAGE on it.
-- ============================================================================

use role dev_sysadmin;
use database dev_db;
use schema gold;

CREATE OR REPLACE DYNAMIC TABLE GOLD.FCT_WHOLESALE_USAGE
    SCHEDULER    = DISABLE            -- pipeline-only refresh; no automatic background refresh
    WAREHOUSE    = DEV_DATA_LOADER_WH
    REFRESH_MODE = AUTO
    INITIALIZE   = ON_CREATE
    COMMENT      = 'Wholesale usage fact from SILVER.WHOLESALE_USAGE; FKs to DIM_PARTNER and DIM_DATE. Pipeline-refreshed (SCHEDULER=DISABLE).'
AS
SELECT
      f.USAGE_ID                                          AS USAGE_ID        -- degenerate dimension
    , COALESCE(dp.PARTNER_HK, '-1')                       AS PARTNER_HK      -- FK -> DIM_PARTNER
    , f.ACCOUNT_ID                                        AS ACCOUNT_ID      -- natural key (traceability)
    , f.USAGE_DATE                                        AS USAGE_DATE      -- FK -> DIM_DATE.DATE
    , TO_NUMBER(TO_CHAR(f.USAGE_DATE, 'YYYYMMDD'))        AS DATE_KEY        -- numeric date key
    , f.UNITS                                             AS UNITS           -- measure (additive)
    , f.AMOUNT                                            AS AMOUNT          -- measure (additive)
    , ROUND(f.AMOUNT / NULLIF(f.UNITS, 0), 4)             AS AMOUNT_PER_UNIT -- measure (ratio)
    , f.MODIFIED_TS                                       AS MODIFIED_TS
    , f.DW_UPDATED_AT                                     AS DW_UPDATED_AT   -- lineage from SILVER
FROM DEV_DB.SILVER.WHOLESALE_USAGE f
LEFT JOIN GOLD.DIM_PARTNER dp
       ON dp.ACCOUNT_ID = f.ACCOUNT_ID
      AND dp.ACCOUNT_ID <> -1          -- never match the unknown member on a real key
WHERE f.IS_DELETED = FALSE
;
