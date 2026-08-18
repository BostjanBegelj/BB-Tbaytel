-- ============================================================
-- NOTIFICATION INTEGRATION - Email
-- RUN ONCE PER ACCOUNT. The integration is account-level; the
-- procedure that uses it (ADM.SP_SEND_NOTIFICATION) is a schema
-- object and is deployed per environment database.
--
-- HARD SNOWFLAKE CONSTRAINT
--   Email notifications can only be delivered to email addresses
--   that belong to a user in THIS account and that the user has
--   verified. An arbitrary business distribution list will not
--   work until it is the verified email of a Snowflake user.
--   ALLOWED_RECIPIENTS accepts at most 50 addresses.
--
--   Consequence for antFarm DQ: whatever a rule author puts in
--   ANTFARM.DQ_LOG.DQ_LOG_MAIL_TO must also exist here, or the
--   send fails. Keep the list short and route fan-out in
--   Exchange, not in Snowflake.
--
-- Omitting ALLOWED_RECIPIENTS is NOT the same as "no restriction"
-- for our purposes: it allows any verified address in the account,
-- which is wider than we want for automated mail. The list is
-- deliberate.
-- ============================================================
USE ROLE ACCOUNTADMIN;


-- ------------------------------------------------------------
-- Prerequisite check: only verified addresses can receive mail.
-- Run this first and put the confirmed addresses in the list below.
-- ------------------------------------------------------------
SELECT NAME,
       EMAIL,
       HAS_RSA_PUBLIC_KEY,
       DISABLED
FROM   SNOWFLAKE.ACCOUNT_USAGE.USERS
WHERE  DELETED_ON IS NULL
  AND  EMAIL IS NOT NULL
ORDER  BY NAME;
-- ACCOUNT_USAGE does not expose the verified flag. Confirm in
-- Snowsight (Profile > Email) or with the user before adding an
-- address. An unverified address is silently not delivered to.


CREATE NOTIFICATION INTEGRATION IF NOT EXISTS EMAIL_INTEGRATION
  TYPE               = EMAIL
  ENABLED            = TRUE
--  ALLOWED_RECIPIENTS = ('<platform.owner@tbaytel.com>',
--                        '<data.ops@tbaytel.com>')
--  DEFAULT_SUBJECT    = 'Snowflake notification'
--  COMMENT            = 'Outbound email for platform notifications (antFarm DQ results, ETL alerts). Used by {ENV}_DB.ADM.SP_SEND_NOTIFICATION.'
;
DESC INTEGRATION EMAIL_INTEGRATION;


-- ------------------------------------------------------------
-- GRANTS
-- USAGE on the integration is required by the role that EXECUTES
-- the notification, not by the procedure owner - the procedures
-- are EXECUTE AS CALLER.
--
--   {ENV}_DATA_LOADER  - the ADF service role (SVC_{ENV}_ADF),
--                        the normal DQ EMAIL caller
--   {ENV}_SYSADMIN     - owns the ADM procedures; needed to test
--                        and to run notifications manually
--
-- DEV shown; repeat for TEST_ and PROD_ at rollout.
-- ------------------------------------------------------------
GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE DEV_DATA_LOADER;
GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE DEV_SYSADMIN;

-- GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE TEST_DATA_LOADER;
-- GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE TEST_SYSADMIN;
-- GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE PROD_DATA_LOADER;
-- GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE PROD_SYSADMIN;


-- ------------------------------------------------------------
-- ADDING A RECIPIENT LATER
-- ALTER replaces the whole list - always restate every address.
-- ------------------------------------------------------------
-- ALTER NOTIFICATION INTEGRATION EMAIL_INTEGRATION
--   SET ALLOWED_RECIPIENTS = ('a@tbaytel.com', 'b@tbaytel.com', 'c@tbaytel.com');


-- ============================================================
-- VALIDATION
-- ============================================================
SHOW INTEGRATIONS LIKE 'EMAIL_INTEGRATION';
-- Expect one row, type NOTIFICATION - EMAIL, enabled = true.

-- End-to-end send test. Run as the role that will actually send
-- (not ACCOUNTADMIN) and use an address from ALLOWED_RECIPIENTS.
-- USE ROLE DEV_DATA_LOADER;
-- CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
--        TEXT_HTML('<html><body><b>EMAIL_INTEGRATION test</b></body></html>'),
--        EMAIL_INTEGRATION_CONFIG('EMAIL_INTEGRATION',
--                                 'Snowflake EMAIL_INTEGRATION test',
--                                 ARRAY_CONSTRUCT('<platform.owner@tbaytel.com>'),
--                                 NULL, NULL));
-- Expect 'Enqueued notifications'. Enqueued is not delivered -
-- confirm the mail actually arrived before declaring this done.

-- Same path through the procedure:
-- USE DATABASE DEV_DB;
-- CALL ADM.SP_SEND_NOTIFICATION(
--        'SP_SEND_NOTIFICATION test',
--        '<html><body>Test message</body></html>',
--        '<platform.owner@tbaytel.com>');
