-- ============================================================
-- IDENTITY - SCIM provisioning (Microsoft Entra ID)
-- RUN ONCE PER ACCOUNT.  (Azure integration Doc 06)
--
-- Creates the SCIM provisioner role and SCIM security integration.
-- Both are Azure-independent and can be prepared ahead; only the
-- provisioning TOKEN is generated later (runtime, valid ~6 months).
--
-- ROLE MODEL - two tiers. SCIM creates one Snowflake role per Entra
-- group, holding NO privileges. Each is then GRANTED the matching
-- functional role from environment/02, once, per section 3 below.
-- Entra owns membership; Snowflake owns roles and privileges. The
-- functional roles are never created or owned by SCIM - {ENV}_SYSADMIN
-- in particular must exist before Entra is wired up, since it owns the
-- environment database and runs the RBAC provisioning procedures.
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
-- 3. CONNECT THE SYNCED ROLES TO THE FUNCTIONAL ROLES
--    Run AFTER SCIM has provisioned the groups. One grant per group,
--    once. The explicit grant list (all 59) and the generator query
--    are in 19_entra_group_role_grants.sql.
-- ============================================================


-- ============================================================
-- 4. DEFAULT_SECONDARY_ROLES  -  set on the ENTRA side
--    Users must have DEFAULT_SECONDARY_ROLES = ('ALL') or only one
--    role is active per session. That breaks additive reporting - a
--    person in both {ENV}_REPORTER and a domain reporter needs both at
--    once, and Power BI cannot switch roles mid-session.
--
--    This is the SCIM attribute `defaultSecondaryRoles`, value 'ALL',
--    in namespace urn:ietf:params:scim:schemas:extension:2.0:User
--    (Azure). It belongs in the Entra provisioning attribute mapping.
--    Setting it with ALTER USER is unreliable for SCIM-managed users:
--    a full PUT sync that omits the attribute can reset it.
--
--    Verify on the first provisioned user:
-- DESC USER <login>;   -- check DEFAULT_SECONDARY_ROLES
-- ============================================================


-- ============================================================
-- VALIDATION
-- ============================================================
DESC SECURITY INTEGRATION AAD_PROVISIONING;
SHOW GRANTS TO ROLE AAD_PROVISIONER;
