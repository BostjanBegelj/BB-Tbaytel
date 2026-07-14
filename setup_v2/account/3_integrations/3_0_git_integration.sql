-- ============================================================================
-- Git API integration (GitHub OAuth)
-- Terraform mapping: snowflake_api_integration
-- Fixes vs. v1: single definition (was duplicated), no CREATE OR REPLACE
--   (replacing drops grants), usage granted to a specific role, not PUBLIC.
-- ============================================================================
USE ROLE ACCOUNTADMIN;
CREATE API INTEGRATION IF NOT EXISTS DATA_PIPELINE_GIT_INTEGRATION
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/BostjanBegelj/BB-Tbaytel.git') -- replace with Tbaytel org repo when moved
  API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
  ENABLED = TRUE;

GRANT USAGE ON INTEGRATION DATA_PIPELINE_GIT_INTEGRATION TO ROLE DEV_TRANSFORMER;
