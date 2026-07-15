-- ============================================================
-- ACCOUNT PARAMETERS & GUARD-RAIL RESOURCE MONITOR
-- RUN ONCE PER ACCOUNT.
-- Account-level parameter defaults plus a setup-phase guard-rail
-- resource monitor (Azure integration Doc 01).
-- ============================================================
USE ROLE ACCOUNTADMIN;

-- ------------------------------------------------------------
-- Account parameter defaults
-- ------------------------------------------------------------
ALTER ACCOUNT SET TIMEZONE = 'America/Toronto';
ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 3600;
ALTER ACCOUNT SET ABORT_DETACHED_QUERY = TRUE;
ALTER ACCOUNT SET PERIODIC_DATA_REKEYING = TRUE;   -- Business Critical edition only

-- ------------------------------------------------------------
-- Guard-rail resource monitor (account-level).
-- Notifies at 80% and SUSPENDS all warehouses at 100% of the monthly
-- credit quota. Tune CREDIT_QUOTA before relying on it in PROD -
-- SUSPEND halts every warehouse on the account.
-- ------------------------------------------------------------
CREATE RESOURCE MONITOR IF NOT EXISTS RM_ACCOUNT_GUARD WITH
  CREDIT_QUOTA    = 100
  FREQUENCY       = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80  PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND;

ALTER ACCOUNT SET RESOURCE_MONITOR = RM_ACCOUNT_GUARD;
