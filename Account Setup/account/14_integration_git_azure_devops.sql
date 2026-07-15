-- ============================================================
-- GIT INTEGRATION - Azure DevOps
-- RUN ONCE PER ACCOUNT.
--
-- Azure DevOps repos are private, so a Personal Access Token (PAT)
-- stored in a Snowflake SECRET is REQUIRED - there is no anonymous
-- / public option. The GitHub App OAuth flow does NOT work here.
--
-- Origin URL format:
--   https://dev.azure.com/<org>/<project>/_git/<repo>
--
-- NOTE: verify syntax against current Snowflake docs before running.
-- ============================================================


-- ============================================================
-- 1) SECRET holding the Azure DevOps PAT (schema object).
--    USERNAME can be any non-empty value; the PAT goes in PASSWORD.
--    Never commit a real PAT to source control.
-- ============================================================
USE ROLE DEV_TRANSFORMER;

CREATE OR REPLACE SECRET DEV_DB.ADM.AZDO_PAT
  TYPE     = PASSWORD
  USERNAME = 'tbaytel'
  PASSWORD = '<AZURE_DEVOPS_PAT>';


-- ============================================================
-- 2) API INTEGRATION (account-level), allowing the secret.
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE API INTEGRATION AZDO_API_INTEGRATION
  API_PROVIDER                   = git_https_api
  API_ALLOWED_PREFIXES           = ('https://dev.azure.com/<org>')   -- your Azure DevOps org
  ALLOWED_AUTHENTICATION_SECRETS = (DEV_DB.ADM.AZDO_PAT)
  ENABLED                        = TRUE;

GRANT USAGE ON INTEGRATION AZDO_API_INTEGRATION TO ROLE DEV_TRANSFORMER;


-- ============================================================
-- 3) GIT REPOSITORY (schema object).
-- ============================================================
USE ROLE DEV_TRANSFORMER;

CREATE OR REPLACE GIT REPOSITORY DEV_DB.ADM.AZDO_REPO
  API_INTEGRATION = AZDO_API_INTEGRATION
  ORIGIN          = 'https://dev.azure.com/<org>/<project>/_git/<repo>'
  GIT_CREDENTIALS = DEV_DB.ADM.AZDO_PAT;


-- ============================================================
-- VALIDATION
-- ============================================================
SHOW GIT BRANCHES IN GIT REPOSITORY DEV_DB.ADM.AZDO_REPO;
