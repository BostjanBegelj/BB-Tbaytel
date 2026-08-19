-- ============================================================================
-- GOLD.DIM_PARTNER - partner dimension (Dynamic Table).
-- Source: SILVER.PARTNER_ACCOUNT (cleansed 1:1 mirror of the wholesale share).
--
-- Grain      : one row per partner account (business key ACCOUNT_ID).
-- Surrogate  : PARTNER_HK - reuses SILVER's PK_HK (MD5 of the business key),
--              a deterministic hash key (Kimball hybrid pattern). Facts carry
--              this key so they never depend on the natural key's format.
-- Unknown    : a '-1' member is UNION-ed in so facts with a missing/soft-deleted
--              partner still resolve to a row (no lost fact rows in a join).
-- Filter     : IS_DELETED = FALSE - soft-deleted partners drop out of the dim.
--
-- Refresh    : Dynamic Table. TARGET_LAG = DOWNSTREAM means it refreshes only as
--              needed to satisfy its downstream fact (FCT_WHOLESALE_USAGE), so a
--              manual/scheduled refresh of the fact cascades to this dim in the
--              right order.
--
-- WAREHOUSE NOTE: DEV_DATA_LOADER_WH - the same warehouse the ETL pipeline uses to
--   load data, so GOLD refresh compute is attributed to the load workload. The
--   owning role (DEV_SYSADMIN here) needs USAGE on it - grant once if needed:
--     use role securityadmin;
--     grant usage on warehouse dev_data_loader_wh to role dev_sysadmin;
-- ============================================================================

use role dev_sysadmin;
use database dev_db;
use schema gold;

CREATE OR REPLACE DYNAMIC TABLE GOLD.DIM_PARTNER
    TARGET_LAG   = 'DOWNSTREAM'
    WAREHOUSE    = DEV_DATA_LOADER_WH
    REFRESH_MODE = AUTO
    INITIALIZE   = ON_CREATE
    COMMENT      = 'Partner dimension from SILVER.PARTNER_ACCOUNT; PARTNER_HK surrogate + unknown member.'
AS
SELECT
      s.PK_HK                                   AS PARTNER_HK      -- surrogate (hash) key
    , s.ACCOUNT_ID                              AS ACCOUNT_ID      -- natural / business key
    , s.PARTNER_NAME                            AS PARTNER_NAME
    , s.REGION                                  AS REGION
    , s.STATUS                                  AS STATUS
    , IFF(s.STATUS = 'ACTIVE', TRUE, FALSE)     AS IS_ACTIVE
    , s.EFFECTIVE_DATE                          AS EFFECTIVE_DATE
    , s.DW_UPDATED_AT                           AS DW_UPDATED_AT   -- lineage from SILVER
FROM DEV_DB.SILVER.PARTNER_ACCOUNT s
WHERE s.IS_DELETED = FALSE

UNION ALL

SELECT
      '-1'                                      AS PARTNER_HK
    , -1                                        AS ACCOUNT_ID
    , 'N/A'                                     AS PARTNER_NAME
    , 'N/A'                                     AS REGION
    , 'N/A'                                     AS STATUS
    , FALSE                                     AS IS_ACTIVE
    , TO_DATE('1900-01-01')                     AS EFFECTIVE_DATE
    , TO_TIMESTAMP_NTZ('1900-01-01 00:00:00')   AS DW_UPDATED_AT
;
