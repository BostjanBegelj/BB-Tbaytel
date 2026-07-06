-- set the environment abbreviation variable
-- -----------------------------------------
SET ENV_ABBR = 'DEV_';
-- -----------------------------------------
-- define the database name
SET DB_NAME = $ENV_ABBR || 'DB';

-- define environment administration roles
SET ENV_SYSADMIN = $ENV_ABBR || 'SYSADMIN';
SET ENV_WH = 'PLATFORM_WH';
SET ENV_DB = 'PLATFORM_DB';

-- create a database
USE ROLE IDENTIFIER($ENV_SYSADMIN);
USE WAREHOUSE IDENTIFIER($ENV_WH);
USE DATABASE IDENTIFIER($ENV_DB);
USE SCHEMA RBAC;
CALL CREATE_DATABASE($DB_NAME);