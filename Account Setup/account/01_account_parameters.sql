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


-- ============================================================
-- Guard-rail resource monitor (account-level).
-- ------------------------------------------------------------
-- A resource monitor tracks credits consumed by warehouses and fires
-- triggers at set percentages of a quota - notify, suspend, or suspend
-- immediately. Assigned to the account, it covers every warehouse.
--
-- SETTINGS BELOW ARE FOR THE TRIAL and must be changed at handover:
--   FREQUENCY = NEVER makes the quota a lifetime cap, matching a trial
--   balance. Production needs FREQUENCY = MONTHLY and a quota agreed
--   with FinOps - see the ALTER statements below.
--
-- Quotas are in CREDITS, not dollars. The $400 trial balance is roughly
-- 75-80 credits on Business Critical / Azure Canada Central.
-- ============================================================
CREATE RESOURCE MONITOR IF NOT EXISTS RM_ACCOUNT_GUARD WITH
  CREDIT_QUOTA    = 50                       -- credits, NOT dollars. ~50h of X-Small compute.
  FREQUENCY       = NEVER                    -- lifetime cap for the trial; MONTHLY in production
  START_TIMESTAMP = IMMEDIATELY
  -- Requires a verified email on the user, or this statement fails.
  NOTIFY_USERS    = ('BOSTJANB')
  TRIGGERS ON  70 PERCENT DO NOTIFY
           ON  90 PERCENT DO SUSPEND
           ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER ACCOUNT SET RESOURCE_MONITOR = RM_ACCOUNT_GUARD;

-- ------------------------------------------------------------
-- AT HANDOVER - switch to a production guard. Two changes: a monthly
-- quota instead of a lifetime cap, and NOTIFY only. An account-level
-- SUSPEND in production stops every warehouse at once - reporting,
-- loads and CI/CD - which is an outage caused by a budget threshold.
-- Where a hard stop is wanted, put a separate monitor on the
-- non-production warehouses.
-- ------------------------------------------------------------
-- ALTER RESOURCE MONITOR RM_ACCOUNT_GUARD SET
--   CREDIT_QUOTA    = 1000                   -- placeholder: agree with FinOps
--   FREQUENCY       = MONTHLY
--   START_TIMESTAMP = IMMEDIATELY;
-- ALTER RESOURCE MONITOR RM_ACCOUNT_GUARD SET
--   TRIGGERS ON  75 PERCENT DO NOTIFY
--            ON  90 PERCENT DO NOTIFY
--            ON 100 PERCENT DO NOTIFY;


-- ============================================================
-- VALIDATION
-- ============================================================
SHOW PARAMETERS LIKE 'TIMEZONE' IN ACCOUNT;

-- Expect RM_ACCOUNT_GUARD with credit_quota 50, frequency NEVER,
-- level ACCOUNT, and used_credits near zero.
SHOW RESOURCE MONITORS;
