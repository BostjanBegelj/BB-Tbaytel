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
