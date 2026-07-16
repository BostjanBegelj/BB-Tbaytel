-- ============================================================
-- GIT INTEGRATION - GitHub
-- RUN ONCE PER ACCOUNT.  The API integration is account-level; the
-- SECRET and GIT REPOSITORY are schema objects in PLATFORM_DB.DEPLOYMENT
-- (CI/CD source is environment-neutral - one repo deploys to all envs).
--
-- Auth options (choose one):
--   A. PUBLIC repo      - no credentials at all (free, zero-setup test)
--   B. GitHub App OAuth - SNOWFLAKE_GITHUB_APP, per-user browser consent,
--                         works for private GitHub repos
--   C. PAT secret       - personal access token in a Snowflake SECRET
--
-- NOTE: verify syntax against current Snowflake docs before running -
-- this was written against the 2024/25 Git-integration feature set.
-- ============================================================


-- ============================================================
-- API INTEGRATION (account-level)
-- Keep API_USER_AUTHENTICATION for options A + B. For public-only
-- use it is harmless; remove it if you never use OAuth.
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE API INTEGRATION GITHUB_API_INTEGRATION
  API_PROVIDER            = git_https_api
  API_ALLOWED_PREFIXES    = ('https://github.com/BostjanBegelj')  -- your GitHub org/user
  API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)         -- remove for public-only
  ENABLED                 = TRUE;

-- SYSADMIN owns PLATFORM_DB.DEPLOYMENT and creates the git repository there.
GRANT USAGE ON INTEGRATION GITHUB_API_INTEGRATION TO ROLE SYSADMIN;


-- ------------------------------------------------------------
-- Option C: PAT-based integration (use INSTEAD of the block above).
-- Create the secret first, then allow it on the integration.
-- ------------------------------------------------------------
-- USE ROLE SYSADMIN;
-- CREATE OR REPLACE SECRET PLATFORM_DB.DEPLOYMENT.GITHUB_PAT
--   TYPE     = PASSWORD
--   USERNAME = 'BostjanBegelj'
--   PASSWORD = '<GITHUB_PERSONAL_ACCESS_TOKEN>';
--
-- USE ROLE ACCOUNTADMIN;
-- CREATE OR REPLACE API INTEGRATION GITHUB_API_INTEGRATION
--   API_PROVIDER                   = git_https_api
--   API_ALLOWED_PREFIXES           = ('https://github.com/BostjanBegelj')
--   ALLOWED_AUTHENTICATION_SECRETS = (PLATFORM_DB.DEPLOYMENT.GITHUB_PAT)
--   ENABLED                        = TRUE;
-- GRANT USAGE ON INTEGRATION GITHUB_API_INTEGRATION TO ROLE SYSADMIN;


-- ============================================================
-- GIT REPOSITORY (schema object) - PLATFORM_DB.DEPLOYMENT
-- For a PUBLIC repo, omit GIT_CREDENTIALS. For OAuth (option B) the
-- caller authorizes interactively via the GitHub App; no
-- GIT_CREDENTIALS needed. For a PAT (option C) add GIT_CREDENTIALS.
-- ============================================================
USE ROLE SYSADMIN;

CREATE OR REPLACE GIT REPOSITORY PLATFORM_DB.DEPLOYMENT.BB_TBAYTEL_REPO
  API_INTEGRATION = GITHUB_API_INTEGRATION
  ORIGIN          = 'https://github.com/BostjanBegelj/BB-Tbaytel.git';
  -- GIT_CREDENTIALS = PLATFORM_DB.DEPLOYMENT.GITHUB_PAT   -- add for a private repo via PAT


-- ============================================================
-- VALIDATION
-- ============================================================
SHOW GIT BRANCHES IN GIT REPOSITORY PLATFORM_DB.DEPLOYMENT.BB_TBAYTEL_REPO;
-- LS @PLATFORM_DB.DEPLOYMENT.BB_TBAYTEL_REPO/branches/main;
