-- ============================================================================
-- GOLD.F_WHOLESALE_USAGE - wholesale usage fact (Dynamic Table).
-- Source: SILVER.WHOLESALE_USAGE (cleansed 1:1 mirror of the wholesale share).
--
-- Grain      : one row per usage record (USAGE_ID) = one partner, one day.
-- Foreign keys (surrogate/conformed):
--     PARTNER_HK -> GOLD.D_PARTNER (resolved via ACCOUNT_ID; COALESCE to the
--                  '-1' unknown member when a partner is missing/soft-deleted)
--     USAGE_DATE -> GOLD.D_DATE.DATE  (D_DATE's key is the DATE value)
--     DATE_KEY   -> YYYYMMDD numeric, handy if a numeric date key is preferred
-- Degenerate : USAGE_ID (transaction id kept on the fact, no separate dim)
-- Measures   : UNITS, AMOUNT (additive) + AMOUNT_PER_UNIT (non-additive ratio)
-- Filter     : IS_DELETED = FALSE.
--
-- Refresh    : Dynamic Table. TARGET_LAG = '1 hour' - Snowflake keeps it within
--              an hour of SILVER automatically, and it drives the DOWNSTREAM
--              refresh of D_PARTNER. A pipeline step (SP_REFRESH_GOLD) can also
--              force it immediately with:
--                 ALTER DYNAMIC TABLE GOLD.F_WHOLESALE_USAGE REFRESH;
--              which cascades to its upstream DOWNSTREAM dimension.
--
-- WAREHOUSE NOTE: see D_PARTNER.sql - DEV_TRANSFORMER_WH is the designed
--   transformation warehouse; the owning role needs USAGE on it (or switch to
--   COMPUTE_WH for the current trial).
-- ============================================================================

use role dev_sysadmin;
use database dev_db;
use schema gold;

CREATE OR REPLACE DYNAMIC TABLE GOLD.F_WHOLESALE_USAGE
    TARGET_LAG   = '1 hour'
    WAREHOUSE    = DEV_TRANSFORMER_WH
    REFRESH_MODE = AUTO
    INITIALIZE   = ON_CREATE
    COMMENT      = 'Wholesale usage fact from SILVER.WHOLESALE_USAGE; FKs to D_PARTNER and D_DATE.'
AS
SELECT
      f.USAGE_ID                                          AS USAGE_ID        -- degenerate dimension
    , COALESCE(dp.PARTNER_HK, '-1')                       AS PARTNER_HK      -- FK -> D_PARTNER
    , f.ACCOUNT_ID                                        AS ACCOUNT_ID      -- natural key (traceability)
    , f.USAGE_DATE                                        AS USAGE_DATE      -- FK -> D_DATE.DATE
    , TO_NUMBER(TO_CHAR(f.USAGE_DATE, 'YYYYMMDD'))        AS DATE_KEY        -- numeric date key
    , f.UNITS                                             AS UNITS           -- measure (additive)
    , f.AMOUNT                                            AS AMOUNT          -- measure (additive)
    , ROUND(f.AMOUNT / NULLIF(f.UNITS, 0), 4)             AS AMOUNT_PER_UNIT -- measure (ratio)
    , f.MODIFIED_TS                                       AS MODIFIED_TS
    , f.DW_UPDATED_AT                                     AS DW_UPDATED_AT   -- lineage from SILVER
FROM DEV_DB.SILVER.WHOLESALE_USAGE f
LEFT JOIN GOLD.D_PARTNER dp
       ON dp.ACCOUNT_ID = f.ACCOUNT_ID
      AND dp.ACCOUNT_ID <> -1          -- never match the unknown member on a real key
WHERE f.IS_DELETED = FALSE
;
