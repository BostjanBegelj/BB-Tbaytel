-- ============================================================
-- Account network policy INGRESS_POLICY
-- RUN ONCE PER ACCOUNT.  (Snowflake Standards v0.6, sections 4.3 / 4.4)
-- Account-level object (outside any database) referencing the rules
-- in SECURITY_DB.INBOUND_TRAFFIC (06_security_network_rules).
-- ============================================================

USE ROLE SECURITYADMIN;

CREATE NETWORK POLICY IF NOT EXISTS INGRESS_POLICY
  ALLOWED_NETWORK_RULE_LIST = (
    'SECURITY_DB.INBOUND_TRAFFIC.TBAYTEL_NETWORK',
    'SECURITY_DB.INBOUND_TRAFFIC.BLEND_NETWORK'--,
  --  'SECURITY_DB.INBOUND_TRAFFIC.AZURE_PRIVATE_LINK'
  )
  -- Entra SCIM is NOT listed here by design. It requires all Azure
  -- public-cloud ranges, which do not belong in an account-wide policy.
  -- It gets its own policy on the SCIM integration - see 17.
  COMMENT = 'Account ingress policy - rules maintained in SECURITY_DB.INBOUND_TRAFFIC';

-- to change the rule list on an existing policy, use ALTER (rules content itself
-- is changed in 06_security_network_rules without touching the policy):
-- ALTER NETWORK POLICY INGRESS_POLICY SET ALLOWED_NETWORK_RULE_LIST = ( ... );

-- ---------------------------------------------------------------------------
-- ONCE PRIVATE LINK IS LIVE - force traffic through it.
-- Adding AZURE_PRIVATE_LINK to the ALLOWED list is not enough: private
-- endpoint rules have no effect on public requests, so the public endpoint
-- stays open. Blocking public access needs the BLOCKED list.
-- Note AZURELINKID takes precedence over IPV4, so requests arriving over
-- Private Link ignore the IPv4 rules entirely.
-- ---------------------------------------------------------------------------
-- ALTER NETWORK POLICY INGRESS_POLICY SET
--   BLOCKED_NETWORK_RULE_LIST = ( 'SECURITY_DB.INBOUND_TRAFFIC.BLOCK_PUBLIC_ACCESS' );

-- ---------------------------------------------------------------------------
-- ACTIVATION - !! LOCKOUT RISK !!
-- Before activating, verify your own current IP/endpoint is matched by one of
-- the allowed rules, otherwise you lock yourself (and everyone) out.
-- ---------------------------------------------------------------------------
SELECT CURRENT_IP_ADDRESS(); -- must fall within an allowed rule before proceeding

-- Also check WHAT is allowed, not just that you are in it. If any rule still
-- holds the 0.0.0.0/0 placeholder, activating gives no protection at all.
SHOW NETWORK RULES IN SCHEMA SECURITY_DB.INBOUND_TRAFFIC;

-- activate at account level (run only after the check above)
-- ALTER ACCOUNT SET NETWORK_POLICY = INGRESS_POLICY;

-- emergency rollback (from an already-connected session):
-- ALTER ACCOUNT UNSET NETWORK_POLICY;
