-- ============================================================
-- IDENTITY - SCIM provisioning (Microsoft Entra ID)
-- RUN ONCE PER ACCOUNT.  (Azure integration Doc 06)
--
-- Creates the SCIM provisioner role and SCIM security integration.
-- Both are Azure-independent and can be prepared ahead; only the
-- provisioning TOKEN is generated later (runtime, valid ~6 months).
-- SCIM creates group roles WITHOUT privileges - grants are applied
-- separately from PLATFORM_DB.RBAC.ENTRA_GROUP_ROLE_MAP.
-- ============================================================
USE ROLE ACCOUNTADMIN;

-- Provisioner role SCIM runs as (creates users + group roles).
CREATE ROLE IF NOT EXISTS AAD_PROVISIONER
  COMMENT = 'SCIM provisioner - Entra ID creates users/roles as this role';
GRANT CREATE USER ON ACCOUNT TO ROLE AAD_PROVISIONER;
GRANT CREATE ROLE ON ACCOUNT TO ROLE AAD_PROVISIONER;
GRANT ROLE AAD_PROVISIONER TO ROLE ACCOUNTADMIN;

-- SCIM security integration. IF NOT EXISTS so a re-run does not
-- invalidate an already-issued provisioning token.
CREATE SECURITY INTEGRATION IF NOT EXISTS AAD_PROVISIONING
  TYPE        = SCIM
  SCIM_CLIENT = 'AZURE'
  RUN_AS_ROLE = 'AAD_PROVISIONER';


-- ------------------------------------------------------------
-- SCIM network policy - required once INGRESS_POLICY is enforced.
--
-- Entra SCIM has no private path: the integration must point at the
-- PUBLIC account endpoint (not the .privatelink URL) even when Private
-- Link is in use, so provisioning traffic arrives from Microsoft's
-- public ranges. Snowflake currently requires ALL Azure public-cloud
-- ranges to be allowed.
--
-- A policy on the integration OVERRIDES the account policy for this
-- integration only, so those ranges never widen normal user access.
-- That is why they are not in INGRESS_POLICY.
--
-- Azure publishes the ranges as a weekly JSON download; they change, so
-- this needs a refresh process, not a one-off paste.
-- ------------------------------------------------------------
-- CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.ENTRAID_SCIM
--   TYPE = IPV4
--   MODE = INGRESS
--   VALUE_LIST = ('<Azure public cloud ranges>');   -- TODO from Microsoft's published list
--
-- CREATE NETWORK POLICY IF NOT EXISTS SCIM_POLICY
--   ALLOWED_NETWORK_RULE_LIST = ('SECURITY_DB.INBOUND_TRAFFIC.ENTRAID_SCIM')
--   COMMENT = 'Entra SCIM provisioning only. Scoped to the AAD_PROVISIONING integration.';
--
-- ALTER SECURITY INTEGRATION AAD_PROVISIONING SET NETWORK_POLICY = SCIM_POLICY;
-- -- to remove:  ALTER SECURITY INTEGRATION AAD_PROVISIONING UNSET NETWORK_POLICY;


-- ------------------------------------------------------------
-- RUNTIME (not prepared ahead): generate the provisioning token and
-- paste it into the Entra provisioning app. Shown ONCE; valid ~6
-- months; regenerate before expiry or provisioning silently stops.
-- ------------------------------------------------------------
-- SELECT SYSTEM$GENERATE_SCIM_ACCESS_TOKEN('AAD_PROVISIONING');


-- ============================================================
-- VALIDATION
-- ============================================================
DESC SECURITY INTEGRATION AAD_PROVISIONING;
SHOW GRANTS TO ROLE AAD_PROVISIONER;
