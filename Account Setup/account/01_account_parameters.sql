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

-- Limit normal statements to one hour.
-- Consider longer overrides for ETL users or warehouses.
ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 3600;

-- Cancel queries approximately five minutes after an unexpected
-- client disconnection. Test this behavior with ADF and CI/CD clients.
ALTER ACCOUNT SET ABORT_DETACHED_QUERY = TRUE;

-- Enable annual re-encryption of table data.
-- REQUIRES ENTERPRISE EDITION OR HIGHER - this statement fails on
-- Standard. If the account is Standard, comment it out and record the
-- gap; note that on Standard the environment build fails anyway
-- (Time Travel > 1 day, masking and row-access policies all need
-- Enterprise). May generate additional Fail-safe storage costs.
ALTER ACCOUNT SET PERIODIC_DATA_REKEYING = TRUE;


-- ============================================================
-- Guard-rail resource monitor (account-level).
-- ------------------------------------------------------------
-- TRIAL PHASE SETTING. A trial has a fixed LIFETIME credit balance,
-- not a monthly allowance, so FREQUENCY = NEVER is used: the quota
-- never resets and the monitor acts as a hard cap on the whole trial.
--
--   AT HANDOVER, change to a production guard:
--     FREQUENCY = MONTHLY, and a CREDIT_QUOTA agreed with FinOps.
--
-- CAREFUL - DOLLARS ARE NOT CREDITS. The Snowsight balance tile shows
-- the trial allowance in DOLLARS ($400). A resource monitor quota is
-- expressed in CREDITS. On Azure Canada Central a credit costs several
-- dollars and the rate rises with edition, so $400 is on the order of
-- 75-105 credits depending on whether the account is Business Critical
-- or Enterprise - nothing like 400.
--
-- CREDIT_QUOTA is therefore set low and deliberately conservative.
-- Confirm the actual credit rate for this account and edition (Snowsight
-- > Admin > Cost Management, or ask the AE) and adjust once known.
--
-- For scale: an X-Small warehouse burns 1 credit per hour, so 60 credits
-- is 60 hours of X-Small compute. The entire Phase-1 build against
-- synthetic data is minutes of compute, so this cap constrains nothing
-- we intend to do - it only catches a warehouse left running.
--
-- Note also that STORAGE draws down the same $400 balance but is NOT
-- counted by any resource monitor. The cap is a compute guard, not a
-- balance guard.
--
-- Triggers escalate rather than stopping dead at the first threshold:
--   70%  NOTIFY           - early warning, nothing stops
--   90%  SUSPEND          - no new queries; running ones finish
--  100%  SUSPEND_IMMEDIATE- hard stop, running queries killed
--
-- CAUTION: this monitor covers EVERY warehouse on the account. When it
-- suspends, the whole platform stops, including CI/CD and any load in
-- progress.
--
-- LIMITATION: account-level resource monitors track WAREHOUSE credits
-- only. Serverless consumption - automatic clustering, materialized
-- view maintenance, Snowpipe, replication - is NOT capped by this and
-- can still draw down the balance. None of those are in use today;
-- re-check this note before enabling any of them.
-- ============================================================
CREATE RESOURCE MONITOR IF NOT EXISTS RM_ACCOUNT_GUARD WITH
  CREDIT_QUOTA    = 60                       -- credits, NOT dollars. ~60h of X-Small compute.
  FREQUENCY       = NEVER                    -- lifetime cap for the trial; MONTHLY in production
  START_TIMESTAMP = IMMEDIATELY
  -- NOTIFY reaches only account administrators who have enabled
  -- notifications in Snowsight. Name the recipient explicitly so the
  -- warning does not go unread. Uncomment AFTER verifying the user's
  -- email in Snowsight - naming a user without a verified email makes
  -- this statement fail.
  -- NOTIFY_USERS  = ('BOSTJANB')
  TRIGGERS ON  70 PERCENT DO NOTIFY
           ON  90 PERCENT DO SUSPEND
           ON 100 PERCENT DO SUSPEND_IMMEDIATE;

-- Adjusting the quota later does not require recreating the monitor:
--   ALTER RESOURCE MONITOR RM_ACCOUNT_GUARD SET CREDIT_QUOTA = <n>;
-- Note that CREATE ... IF NOT EXISTS above will NOT update an existing
-- monitor, so re-running this file is safe but has no effect on it.

ALTER ACCOUNT SET RESOURCE_MONITOR = RM_ACCOUNT_GUARD;


-- ============================================================
-- VALIDATION
-- ============================================================
SHOW PARAMETERS LIKE 'TIMEZONE' IN ACCOUNT;
SHOW PARAMETERS LIKE 'STATEMENT_TIMEOUT_IN_SECONDS' IN ACCOUNT;
SHOW PARAMETERS LIKE 'ABORT_DETACHED_QUERY' IN ACCOUNT;
SHOW PARAMETERS LIKE 'PERIODIC_DATA_REKEYING' IN ACCOUNT;

-- Expect RM_ACCOUNT_GUARD with credit_quota 60, frequency NEVER,
-- and used_credits near zero.
SHOW RESOURCE MONITORS;

-- Confirm the account landed where intended. Expect an Azure Canada
-- Central region identifier.
SELECT CURRENT_ACCOUNT()           AS ACCOUNT_LOCATOR,
       CURRENT_ORGANIZATION_NAME() AS ORGANIZATION,
       CURRENT_REGION()            AS REGION;

-- Confirm the EDITION before running anything else: the environment
-- build requires Enterprise or higher and fails on Standard.
-- Requires the ORGADMIN role, which the trial's first user holds.
--   USE ROLE ORGADMIN;
--   SHOW ORGANIZATION ACCOUNTS;   -- read the edition column
--   USE ROLE ACCOUNTADMIN;
