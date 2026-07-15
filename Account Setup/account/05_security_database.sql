-- ============================================================
-- SECURITY_DB - account-wide security database
-- RUN ONCE PER ACCOUNT.  (Snowflake Standards v0.6, section 4.3)
-- Unprefixed, exists once. Owned by SECURITYADMIN so security
-- administration stays a distinct duty from platform admin
-- (PLATFORM_DB / SYSADMIN).
-- ============================================================
--
-- Schemas (network rules organised by direction, policies together):
--   INBOUND_TRAFFIC  - ingress network rules (customer, In516ht, Private Link / VNet)
--   OUTBOUND_TRAFFIC - egress network rules (external access integrations)
--   INTERNAL_STAGE   - network rules restricting internal stage access
--   POLICIES         - authentication, password, masking and row-access policies

-- SECURITYADMIN cannot create databases; ACCOUNTADMIN creates and transfers ownership
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS SECURITY_DB
  COMMENT = 'Account-wide security objects: network rules and policies (Standards 4.3)';

DROP SCHEMA IF EXISTS SECURITY_DB.PUBLIC;

CREATE SCHEMA IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC WITH MANAGED ACCESS
  COMMENT = 'Ingress network rules';
CREATE SCHEMA IF NOT EXISTS SECURITY_DB.OUTBOUND_TRAFFIC WITH MANAGED ACCESS
  COMMENT = 'Egress network rules (external access integrations)';
CREATE SCHEMA IF NOT EXISTS SECURITY_DB.INTERNAL_STAGE WITH MANAGED ACCESS
  COMMENT = 'Network rules restricting internal stage access';
CREATE SCHEMA IF NOT EXISTS SECURITY_DB.POLICIES WITH MANAGED ACCESS
  COMMENT = 'Authentication, password, masking and row-access policies';

-- transfer ownership to SECURITYADMIN (schemas first, then the database)
GRANT OWNERSHIP ON SCHEMA SECURITY_DB.INBOUND_TRAFFIC  TO ROLE SECURITYADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA SECURITY_DB.OUTBOUND_TRAFFIC TO ROLE SECURITYADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA SECURITY_DB.INTERNAL_STAGE   TO ROLE SECURITYADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA SECURITY_DB.POLICIES         TO ROLE SECURITYADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DATABASE SECURITY_DB                TO ROLE SECURITYADMIN COPY CURRENT GRANTS;

-- ---------------------------------------------------------------------------
-- OPTIONAL: dedicated POLICY_ADMIN role beneath SECURITYADMIN (Standards 4.3)
-- Uncomment if policy management should be delegated below SECURITYADMIN.
-- ---------------------------------------------------------------------------
-- USE ROLE USERADMIN;
-- CREATE ROLE IF NOT EXISTS POLICY_ADMIN COMMENT = 'Manages policies in SECURITY_DB';
-- GRANT ROLE POLICY_ADMIN TO ROLE SECURITYADMIN;
-- USE ROLE SECURITYADMIN;
-- GRANT USAGE ON DATABASE SECURITY_DB TO ROLE POLICY_ADMIN;
-- GRANT USAGE, CREATE MASKING POLICY, CREATE ROW ACCESS POLICY,
--       CREATE PASSWORD POLICY, CREATE AUTHENTICATION POLICY
--   ON SCHEMA SECURITY_DB.POLICIES TO ROLE POLICY_ADMIN;
