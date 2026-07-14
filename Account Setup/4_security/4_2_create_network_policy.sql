-- Account network policy INGRESS_POLICY (Snowflake Standards v0.6, sections 4.3 / 4.4)
-- The policy itself is an ACCOUNT-LEVEL object (lives outside any database);
-- the network rules it references live in SECURITY_DB.INBOUND_TRAFFIC (see 4_1).

USE ROLE SECURITYADMIN;

CREATE NETWORK POLICY IF NOT EXISTS INGRESS_POLICY
  ALLOWED_NETWORK_RULE_LIST = (
    'SECURITY_DB.INBOUND_TRAFFIC.TBAYTEL_NETWORK',
    'SECURITY_DB.INBOUND_TRAFFIC.IN516HT_NETWORK',
    'SECURITY_DB.INBOUND_TRAFFIC.AZURE_PRIVATE_LINK'
  )
  COMMENT = 'Account ingress policy - rules maintained in SECURITY_DB.INBOUND_TRAFFIC';

-- to change the rule list on an existing policy, use ALTER (rules content itself
-- is changed in 4_1 without touching the policy):
-- ALTER NETWORK POLICY INGRESS_POLICY SET ALLOWED_NETWORK_RULE_LIST = ( ... );

-- ---------------------------------------------------------------------------
-- ACTIVATION - !! LOCKOUT RISK !!
-- Before activating, verify your own current IP/endpoint is matched by one of
-- the allowed rules, otherwise you lock yourself (and everyone) out.
-- ---------------------------------------------------------------------------
SELECT CURRENT_IP_ADDRESS(); -- must fall within an allowed rule before proceeding

-- activate at account level (run only after the check above)
-- ALTER ACCOUNT SET NETWORK_POLICY = INGRESS_POLICY;

-- emergency rollback (from an already-connected session):
-- ALTER ACCOUNT UNSET NETWORK_POLICY;
