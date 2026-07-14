-- ============================================================================
-- Person users (SSO via Entra ID)
-- Terraform mapping: snowflake_user + snowflake_grant_account_role
-- Fixes vs. v1: test users with PASSWORD='111' and DEFAULT_ROLE=ACCOUNTADMIN
--   removed. Nobody gets ACCOUNTADMIN as a default role; grant it explicitly
--   to at most 2 named admins and require MFA.
-- Template: LOGIN_NAME must match the Entra ID email exactly.
-- ============================================================================

USE ROLE USERADMIN;
CREATE USER IF NOT EXISTS <USERNAME>
  LOGIN_NAME   = 'firstname.lastname@tbaytel.com' -- must match Entra ID
  DISPLAY_NAME = 'Firstname Lastname'
  EMAIL        = 'firstname.lastname@tbaytel.com'
  TYPE         = PERSON
  DEFAULT_ROLE = DEV_TRANSFORMER
  DEFAULT_WAREHOUSE = DEV_TRANSFORMER_WH;
  -- no PASSWORD: SSO only

USE ROLE DEV_USERADMIN;
GRANT ROLE DEV_TRANSFORMER TO USER <USERNAME>;
