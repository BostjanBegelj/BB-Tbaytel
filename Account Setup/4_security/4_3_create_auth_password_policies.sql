-- Authentication and password policies (Snowflake Standards v0.6, sections 4.3 / 6.1)
-- Both are SCHEMA objects and live in SECURITY_DB.POLICIES; they are then set
-- as account defaults. Humans authenticate via Entra ID SSO (SAML2), service
-- users via key pair; passwords remain only for break-glass (user-level policy).

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- Account password policy (applies wherever password auth is still allowed)
-- ---------------------------------------------------------------------------
CREATE PASSWORD POLICY IF NOT EXISTS SECURITY_DB.POLICIES.ACCOUNT_PASSWORD_POLICY
  PASSWORD_MIN_LENGTH = 14
  PASSWORD_MIN_UPPER_CASE_CHARS = 1
  PASSWORD_MIN_LOWER_CASE_CHARS = 1
  PASSWORD_MIN_NUMERIC_CHARS = 1
  PASSWORD_MIN_SPECIAL_CHARS = 1
  PASSWORD_MAX_AGE_DAYS = 90
  PASSWORD_MAX_RETRIES = 5
  PASSWORD_LOCKOUT_TIME_MINS = 30
  PASSWORD_HISTORY = 5
  COMMENT = 'Account default password policy';

-- ---------------------------------------------------------------------------
-- Account authentication policy
-- PASSWORD is still included so current admin users are not locked out before
-- SSO is verified end-to-end; tighten to ('SAML', 'KEYPAIR') after cutover and
-- give the break-glass user its own user-level policy allowing PASSWORD + MFA.
-- ---------------------------------------------------------------------------
CREATE AUTHENTICATION POLICY IF NOT EXISTS SECURITY_DB.POLICIES.ACCOUNT_AUTH_POLICY
  AUTHENTICATION_METHODS = ('SAML', 'KEYPAIR', 'PASSWORD')
  MFA_ENROLLMENT = REQUIRED
  MFA_AUTHENTICATION_METHODS = ('PASSWORD')
  CLIENT_TYPES = ('ALL')
  COMMENT = 'Account default authentication policy - SSO for humans, key pair for services';

-- ---------------------------------------------------------------------------
-- ACTIVATION - !! LOCKOUT RISK !!
-- Verify SSO (SAML2 integration) works for at least one admin, and that all
-- service users have RSA keys registered, before setting the account defaults.
-- ---------------------------------------------------------------------------
-- ALTER ACCOUNT SET AUTHENTICATION POLICY SECURITY_DB.POLICIES.ACCOUNT_AUTH_POLICY;
-- ALTER ACCOUNT SET PASSWORD POLICY SECURITY_DB.POLICIES.ACCOUNT_PASSWORD_POLICY;

-- rollback:
-- ALTER ACCOUNT UNSET AUTHENTICATION POLICY;
-- ALTER ACCOUNT UNSET PASSWORD POLICY;
