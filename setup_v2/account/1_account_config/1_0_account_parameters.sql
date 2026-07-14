-- ============================================================================
-- Account-level parameters
-- Terraform mapping: snowflake_account_parameter
-- ============================================================================
USE ROLE ACCOUNTADMIN;
ALTER ACCOUNT SET TIMEZONE = 'America/Toronto';
