-- template for creating a user with SSO authentication
-- the user email must match the Entra ID
/*
USE ROLE USERADMIN;
CREATE USER <username> 
PASSWORD = '' 
LOGIN_NAME = '...@example.com' -- replace with actual user email
DISPLAY_NAME = 'Firstname Lastname' -- replace with actual user details
DEFAULT_ROLE = DEV_DATA_ENGINEER;

USE ROLE DEV_USERADMIN;
GRANT ROLE DEV_DATA_ENGINEER TO USER <username>;
*/
/*
USE ROLE USERADMIN;
CREATE USER BRANKOZ
PASSWORD = '111' 
LOGIN_NAME = 'BRANKOZ' -- replace with actual user email
DISPLAY_NAME = 'BRANKOZ' -- replace with actual user details
DEFAULT_ROLE = ACCOUNTADMIN;

USE ROLE DEV_USERADMIN;
GRANT ROLE ACCOUNTADMIN TO USER BRANKOZ;
*/


-- set the environment abbreviation variable
-- -----------------------------------------
SET ENV_ABBR = 'DEV_';
-- -----------------------------------------
SET F_ROLE = 'TRANSFORMER';


USE ROLE USERADMIN;
CREATE USER 'BLEND_' || $F_ROLE
PASSWORD = '111' 
LOGIN_NAME = 'BLEND_' || $F_ROLE
DISPLAY_NAME = 'BLEND_' || $F_ROLE
DEFAULT_ROLE = $ENV_ABBR || $F_ROLE;

USE ROLE  $ENV_ABBR || USERADMIN;
GRANT ROLE ACCOUNTADMIN TO USER 'BLEND_' || $F_ROLE;



- TRANSFORMER (DATA_ENGINEER)
- ANALYST
- DATA_LOADER (for ADF)
- REPORTER (for BI)
    - REPORTER_BILLING (for PBI Direct Query SSO)
    - REPORTER_FINANCE (for PBI Direct Query SSO)
    - REPORTER_MARKETING (for PBI Direct Query SSO)
- IT_GOVERNANCE


ACCOUNTADMIN
TRANSFORMER
ANALYST
DATA_LOADER
REPORTER
REPORTER_BILLING
REPORTER_FINANCE
REPORTER_MARKETING
IT_GOVERNANCE