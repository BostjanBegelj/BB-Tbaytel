-- template for creating a user with SSO authentication
-- the user email must match the Entra ID

USE ROLE USERADMIN;
CREATE USER <username> 
PASSWORD = '' 
LOGIN_NAME = '...@example.com' -- replace with actual user email
DISPLAY_NAME = 'Firstname Lastname' -- replace with actual user details
DEFAULT_ROLE = DEV_DATA_ENGINEER;

USE ROLE DEV_USERADMIN;
GRANT ROLE DEV_DATA_ENGINEER TO USER <username>;


USE ROLE USERADMIN;
CREATE USER BRANKOZ
PASSWORD = '111' 
LOGIN_NAME = 'BRANKOZ' -- replace with actual user email
DISPLAY_NAME = 'BRANKOZ' -- replace with actual user details
DEFAULT_ROLE = ACCOUNTADMIN;

USE ROLE DEV_USERADMIN;
GRANT ROLE ACCOUNTADMIN TO USER BRANKOZ;



USE ROLE USERADMIN;
CREATE USER BLEND_TEST
PASSWORD = '111' 
LOGIN_NAME = 'BLEND_TEST' -- replace with actual user email
DISPLAY_NAME = 'BLEND_TEST' -- replace with actual user details
DEFAULT_ROLE = ACCOUNTADMIN;

USE ROLE DEV_USERADMIN;
GRANT ROLE ACCOUNTADMIN TO USER BLEND_TEST;