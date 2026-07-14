-- ============================================================================
-- Environment administration roles ({ENV}_SYSADMIN, {ENV}_USERADMIN)
-- Terraform mapping: snowflake_account_role + snowflake_grant_account_role
--                    + snowflake_grant_privileges_to_account_role
-- Run once per environment (DEV_, TEST_, PROD_).
-- ============================================================================

-- set the environment abbreviation variable
-- -----------------------------------------
SET ENV_ABBR = 'DEV_';
-- -----------------------------------------

SET ENV_SYSADMIN  = $ENV_ABBR || 'SYSADMIN';
SET ENV_USERADMIN = $ENV_ABBR || 'USERADMIN';

-- create environment administration roles
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_SYSADMIN);
CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_USERADMIN);

USE ROLE SECURITYADMIN;
GRANT ROLE IDENTIFIER($ENV_SYSADMIN)  TO ROLE SYSADMIN;
GRANT ROLE IDENTIFIER($ENV_USERADMIN) TO ROLE USERADMIN;

-- grant create database and create warehouse to the environment sysadmin role
USE ROLE SYSADMIN;
GRANT CREATE DATABASE  ON ACCOUNT TO ROLE IDENTIFIER($ENV_SYSADMIN);
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE IDENTIFIER($ENV_SYSADMIN);

-- grant create role to the environment useradmin role
USE ROLE SECURITYADMIN;
GRANT CREATE ROLE ON ACCOUNT TO ROLE IDENTIFIER($ENV_USERADMIN);
