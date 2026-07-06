-- ---------------------------------------------------------------------------------
-- Set up GIT integration for all users
-- works with GitHub OAuth authentication and only for repositories hosted on GitHub
-- ---------------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
CREATE OR REPLACE API INTEGRATION DATA_PIPELINE_GIT_INTEGRATION
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/...') -- replace with actual GitHub URL
  API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
  ENABLED = TRUE;
-- grant usage on the API integration to all users
GRANT USAGE ON INTEGRATION DATA_PIPELINE_GIT_INTEGRATION TO ROLE PUBLIC;




CREATE OR REPLACE API INTEGRATION DATA_PIPELINE_GIT_INTEGRATION
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/BostjanBegelj/BB-Tbaytel.git') -- replace with actual GitHub URL
  API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
  ENABLED = TRUE;
-- grant usage on the API integration to all users
GRANT USAGE ON INTEGRATION DATA_PIPELINE_GIT_INTEGRATION TO ROLE PUBLIC;