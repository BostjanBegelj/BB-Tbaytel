-- ============================================================================
-- Network rules + ingress network policy
-- Terraform mapping: snowflake_network_rule + snowflake_network_policy
-- Fixes vs. v1: single home DB (PLATFORM_DB), SHARED_WORKSPACE schema removed
--   (belongs in databases/config), policy created in SQL instead of Snowsight,
--   no CREATE OR REPLACE (replacing a rule referenced by a policy fails; to
--   change IPs use ALTER NETWORK RULE ... SET VALUE_LIST).
-- ============================================================================

USE ROLE SYSADMIN;
CREATE SCHEMA IF NOT EXISTS PLATFORM_DB.NETWORK_RULES WITH MANAGED ACCESS;

USE ROLE ACCOUNTADMIN;

-- In516ht network
CREATE NETWORK RULE IF NOT EXISTS PLATFORM_DB.NETWORK_RULES.IN516HT_NETWORK
  TYPE = IPV4
  VALUE_LIST = ('89.212.52.137/32')
  MODE = INGRESS
  COMMENT = 'In516ht IP ranges';

-- Customer network
CREATE NETWORK RULE IF NOT EXISTS PLATFORM_DB.NETWORK_RULES.TBAYTEL_NETWORK
  TYPE = IPV4
  VALUE_LIST = ('0.0.0.0/0') -- TODO replace with actual Tbaytel IP ranges before activating
  MODE = INGRESS
  COMMENT = 'Tbaytel IP ranges';

-- account-level ingress policy
CREATE NETWORK POLICY IF NOT EXISTS INGRESS_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('PLATFORM_DB.NETWORK_RULES.IN516HT_NETWORK',
                               'PLATFORM_DB.NETWORK_RULES.TBAYTEL_NETWORK')
  COMMENT = 'Account ingress policy';

-- to update IP lists later (idempotent-friendly, keeps policy references intact):
-- ALTER NETWORK RULE PLATFORM_DB.NETWORK_RULES.TBAYTEL_NETWORK SET VALUE_LIST = ('x.x.x.x/32');

-- activate only after verifying your own IP is included:
-- ALTER ACCOUNT SET NETWORK_POLICY = INGRESS_POLICY;
