-- set the environment abbreviation variable
-- -----------------------------------------
SET ENV_ABBR = 'DEV_';
-- -----------------------------------------

-- define environment administration roles
SET ENV_SYSADMIN = $ENV_ABBR || 'SYSADMIN';
SET ENV_USERADMIN = $ENV_ABBR || 'USERADMIN';

-- create environment administration roles
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_SYSADMIN);
GRANT ROLE IDENTIFIER($ENV_SYSADMIN) TO ROLE SYSADMIN;

CREATE ROLE IF NOT EXISTS IDENTIFIER($ENV_USERADMIN);
GRANT ROLE IDENTIFIER($ENV_USERADMIN) TO ROLE USERADMIN;

-- grant create database and create warehouse to the environment sysadmin role
USE ROLE SYSADMIN;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE IDENTIFIER($ENV_SYSADMIN);
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE IDENTIFIER($ENV_SYSADMIN);

-- grant create role to the environment useradmin role
USE ROLE SECURITYADMIN;
GRANT CREATE ROLE ON ACCOUNT TO ROLE IDENTIFIER($ENV_USERADMIN);