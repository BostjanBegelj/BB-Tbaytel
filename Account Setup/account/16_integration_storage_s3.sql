-- ============================================================
-- STORAGE INTEGRATION - AWS S3
-- RUN ONCE PER ACCOUNT.  The integration is account-level; the
-- external STAGE is a schema object (ETL / environment layer).
--
-- The storage integration needs your own AWS IAM role - no public
-- option. After creating it, run DESC and configure the IAM role's
-- trust policy with STORAGE_AWS_IAM_USER_ARN + STORAGE_AWS_EXTERNAL_ID.
--
-- For a FREE read-only test WITHOUT any integration or credentials,
-- see the public-bucket stage at the bottom.
--
-- NOTE: verify syntax against current Snowflake docs before running.
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE STORAGE INTEGRATION S3_INTEGRATION
  TYPE                      = EXTERNAL_STAGE
  STORAGE_PROVIDER          = 'S3'
  ENABLED                   = TRUE
  STORAGE_AWS_ROLE_ARN      = 'arn:aws:iam::<account-id>:role/<iam-role>'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<bucket>/');

-- Run DESC, then add STORAGE_AWS_IAM_USER_ARN + STORAGE_AWS_EXTERNAL_ID
-- to the IAM role's trust relationship.
DESC INTEGRATION S3_INTEGRATION;

GRANT USAGE ON INTEGRATION S3_INTEGRATION TO ROLE DEV_DATA_LOADER;
GRANT USAGE ON INTEGRATION S3_INTEGRATION TO ROLE DEV_TRANSFORMER;


-- ------------------------------------------------------------
-- Example external stage using the integration (move to ETL/env).
-- ------------------------------------------------------------
-- USE ROLE DEV_DATA_LOADER;
-- CREATE OR REPLACE STAGE DEV_DB.RAW.S3_STAGE
--   STORAGE_INTEGRATION = S3_INTEGRATION
--   URL                 = 's3://<bucket>/';
-- LIST @DEV_DB.RAW.S3_STAGE;


-- ------------------------------------------------------------
-- FREE TEST - read a PUBLIC S3 bucket with NO integration/creds.
-- Exercises LIST / COPY end-to-end with zero AWS setup.
-- ------------------------------------------------------------
-- USE ROLE DEV_DATA_LOADER;
-- CREATE OR REPLACE STAGE DEV_DB.RAW.PUBLIC_S3_TEST
--   URL         = 's3://sfquickstarts/'      -- Snowflake public quickstart bucket
--   FILE_FORMAT = (TYPE = CSV);
-- LIST @DEV_DB.RAW.PUBLIC_S3_TEST;
