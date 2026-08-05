-- ============================================================
-- PLATFORM_DB.MONITORING - FinOps and access views
-- RUN ONCE PER ACCOUNT. Requires 02 (schemas + IMPORTED PRIVILEGES).
--
-- Only objects that are actually used are created. UTIL, REFERENCE,
-- DEPLOYMENT and SHARED_WORKSPACE stay empty until there is real
-- content for them; the schema and its access roles are the contract.
--
-- ACCOUNT_USAGE views lag 45 minutes to 3 hours. On a new account these
-- return no rows for a while - that is latency, not a missing grant.
-- ============================================================
USE ROLE SYSADMIN;
USE DATABASE PLATFORM_DB;
USE SCHEMA MONITORING;


-- Credits by warehouse. The resource monitor reports a total; this
-- shows what spent it.
CREATE OR REPLACE VIEW V_WAREHOUSE_CREDITS
  COMMENT = 'Credits by warehouse, last 30 days.'
AS
SELECT WAREHOUSE_NAME,
       ROUND(SUM(CREDITS_USED_COMPUTE), 3)        AS CREDITS_COMPUTE,
       ROUND(SUM(CREDITS_USED_CLOUD_SERVICES), 3) AS CREDITS_CLOUD_SERVICES,
       ROUND(SUM(CREDITS_USED), 3)                AS CREDITS_TOTAL,
       MIN(START_TIME)                            AS FIRST_SEEN,
       MAX(END_TIME)                              AS LAST_SEEN
FROM   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE  START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP  BY WAREHOUSE_NAME;


-- Credits by service type, including serverless. Resource monitors cap
-- warehouse credits only, so this is the only view of serverless spend.
CREATE OR REPLACE VIEW V_CREDITS_BY_SERVICE
  COMMENT = 'Daily credits by service type, last 30 days. Includes serverless, which no resource monitor caps.'
AS
SELECT USAGE_DATE,
       SERVICE_TYPE,
       ROUND(SUM(CREDITS_USED), 3) AS CREDITS_USED
FROM   SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE  USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
GROUP  BY USAGE_DATE, SERVICE_TYPE;


-- Live grant inventory. Used by validation/01 and as the basis for the
-- Terraform import list.
CREATE OR REPLACE VIEW V_GRANTS_TO_ROLES
  COMMENT = 'Current (not deleted) grants to roles.'
AS
SELECT GRANTEE_NAME  AS ROLE_NAME,
       PRIVILEGE,
       GRANTED_ON,
       TABLE_CATALOG AS OBJECT_DATABASE,
       TABLE_SCHEMA  AS OBJECT_SCHEMA,
       NAME          AS OBJECT_NAME,
       GRANTED_BY,
       CREATED_ON
FROM   SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE  DELETED_ON IS NULL;


-- ============================================================
-- VALIDATION
-- ============================================================
-- Expect 3 views. They must compile; empty results are expected on a
-- new account.
SHOW VIEWS IN SCHEMA PLATFORM_DB.MONITORING;
