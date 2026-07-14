-- Masking / row-access policy TEMPLATES (Snowflake Standards v0.6, section 4.3)
-- Policies are defined centrally in SECURITY_DB.POLICIES and APPLIED to columns/
-- tables in the environment databases. Business Critical edition supports both.
-- These are templates - copy, rename and adapt per data domain; do not run as-is.

USE ROLE SECURITYADMIN;

-- ---------------------------------------------------------------------------
-- Column masking policy template (e.g. customer PII in GOLD)
-- ---------------------------------------------------------------------------
-- CREATE MASKING POLICY IF NOT EXISTS SECURITY_DB.POLICIES.MASK_PII_STRING
--   AS (VAL STRING) RETURNS STRING ->
--   CASE
--     WHEN IS_DATABASE_ROLE_IN_SESSION('GOLD_FULL_AR') THEN VAL
--     ELSE '***MASKED***'
--   END
--   COMMENT = 'Masks PII strings for roles without full GOLD access';

-- apply (run as the environment owner role, e.g. PROD_SYSADMIN):
-- ALTER TABLE PROD_DB.GOLD.DIM_CUSTOMER
--   MODIFY COLUMN EMAIL SET MASKING POLICY SECURITY_DB.POLICIES.MASK_PII_STRING;

-- ---------------------------------------------------------------------------
-- Row access policy template (e.g. per-domain reporter separation)
-- ---------------------------------------------------------------------------
-- CREATE ROW ACCESS POLICY IF NOT EXISTS SECURITY_DB.POLICIES.RAP_DOMAIN
--   AS (DOMAIN_CODE STRING) RETURNS BOOLEAN ->
--   CURRENT_ROLE() IN ('PROD_REPORTER')            -- service account sees all
--   OR DOMAIN_CODE = <mapping of role to domain>   -- TODO implement mapping
--   COMMENT = 'Restricts rows to the callers reporting domain';
