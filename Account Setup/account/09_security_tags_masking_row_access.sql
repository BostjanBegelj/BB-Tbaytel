-- ============================================================
-- SECURITY_DB - governance tags, masking policies, row access
-- RUN ONCE PER ACCOUNT.  (Standards v0.7, section 4.3)
-- Covers TBAY-191 AC5: "the masking, tagging and row-access policy
-- framework is created and ready for later assignment".
--
-- Supersedes 09_security_masking_row_access_templates.sql, which held
-- commented-out examples only. These objects are real and deployable.
-- ------------------------------------------------------------
-- DESIGN: tag-driven masking.
--
--   Data stewards tag a column.  The mask follows automatically.
--
-- A masking policy is attached ONCE to the PII_TYPE tag. From then on,
-- any column tagged PII_TYPE='EMAIL' (etc.) is masked without anyone
-- touching the table DDL. This is why the framework can be completed
-- now, before the Gold model exists: nothing here references a column.
--
-- One masking policy per DATA TYPE is the Snowflake limit per tag, so
-- the STRING policy branches on the tag VALUE internally rather than
-- defining a separate policy per PII category.
--
-- Running this file is safe on an empty account: no column is tagged,
-- so no data is masked until a steward tags something.
-- ============================================================


-- ============================================================
-- 0. Privileges for the policy owner
--    POLICY_ADMIN is created in 05_security_database.sql.
-- ============================================================
USE ROLE SECURITYADMIN;

GRANT CREATE TAG   ON SCHEMA SECURITY_DB.POLICIES TO ROLE POLICY_ADMIN;
-- CREATE TABLE: the row-access mapping table lives here and is owned by
-- POLICY_ADMIN, so the policy body can read it under the owner's rights.
GRANT CREATE TABLE ON SCHEMA SECURITY_DB.POLICIES TO ROLE POLICY_ADMIN;

USE ROLE ACCOUNTADMIN;
-- Account-level APPLY privileges: needed to bind a policy to a tag and
-- to tag columns in the environment databases.
GRANT APPLY MASKING POLICY    ON ACCOUNT TO ROLE POLICY_ADMIN;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE POLICY_ADMIN;
GRANT APPLY TAG               ON ACCOUNT TO ROLE POLICY_ADMIN;


-- ============================================================
-- 1. PII_READER - the exemption role
--    Masking policies unmask for this role only. Everyone else sees
--    the masked value, including ACCOUNTADMIN, by design.
--
--    The ELT roles MUST hold it: masking applies on read, so a
--    transform reading masked Silver would write masked Gold.
-- ============================================================
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS PII_READER
  COMMENT = 'Exempt from PII masking. Grant deliberately and review periodically.';

-- Deliberately NOT granted into the admin hierarchy: SECURITYADMIN holds
-- MANAGE GRANTS and can hand out PII_READER without inheriting it, so
-- administering the exemption does not imply being exempt.
USE ROLE SECURITYADMIN;

-- Per-environment grants. Uncomment per environment as it is built.
-- The pipeline roles need unmasked reads to produce correct downstream data.
-- GRANT ROLE PII_READER TO ROLE DEV_TRANSFORMER;
-- GRANT ROLE PII_READER TO ROLE DEV_DATA_LOADER;
-- GRANT ROLE PII_READER TO ROLE TEST_TRANSFORMER;
-- GRANT ROLE PII_READER TO ROLE TEST_DATA_LOADER;
-- GRANT ROLE PII_READER TO ROLE PROD_TRANSFORMER;
-- GRANT ROLE PII_READER TO ROLE PROD_DATA_LOADER;
--
-- Human access to unmasked PII should be granted through an Entra group
-- mapped to PII_READER, not by granting the role to a functional role.


-- ============================================================
-- 2. Governance tags
--    Two tags only. DATA_CLASSIFICATION is the inventory/reporting
--    dimension; PII_TYPE is what actually drives the mask.
-- ============================================================
USE ROLE POLICY_ADMIN;
USE SCHEMA SECURITY_DB.POLICIES;

CREATE TAG IF NOT EXISTS DATA_CLASSIFICATION
  ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED'
  COMMENT = 'Sensitivity of the object. Applied at table or column level. Reporting/inventory dimension.';

CREATE TAG IF NOT EXISTS PII_TYPE
  ALLOWED_VALUES
    'NAME', 'EMAIL', 'PHONE', 'ADDRESS', 'DOB',
    'GOVERNMENT_ID', 'PAYMENT_CARD', 'ACCOUNT_NUMBER',
    'IP_ADDRESS', 'GEOLOCATION'
  COMMENT = 'Category of personal data in the column. Drives the masking policy automatically.';


-- ============================================================
-- 3. Masking policies
--    One per data type. The STRING policy branches on the PII_TYPE
--    value so that partial masking stays useful for support and
--    reconciliation (last 4 digits, email domain) without exposing
--    the full value.
-- ============================================================

CREATE MASKING POLICY IF NOT EXISTS MP_PII_STRING
  AS (VAL STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    WHEN VAL IS NULL THEN NULL
    ELSE
      CASE SYSTEM$GET_TAG_ON_CURRENT_COLUMN('SECURITY_DB.POLICIES.PII_TYPE')
        -- keep the domain: enough to tell a consumer apart, not who they are
        WHEN 'EMAIL'          THEN '***@' || SPLIT_PART(VAL, '@', 2)
        -- last 4: what agents quote back to a customer
        WHEN 'PHONE'          THEN '***-***-' || RIGHT(VAL, 4)
        WHEN 'ACCOUNT_NUMBER' THEN '****' || RIGHT(VAL, 4)
        WHEN 'PAYMENT_CARD'   THEN '**** **** **** ' || RIGHT(VAL, 4)
        ELSE '***MASKED***'
      END
  END
  COMMENT = 'Tag-driven masking for STRING PII. Bound to the PII_TYPE tag, not to columns.';

CREATE MASKING POLICY IF NOT EXISTS MP_PII_DATE
  AS (VAL DATE) RETURNS DATE ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    -- year only: preserves age-band analysis, drops the identifying date
    ELSE DATE_TRUNC('YEAR', VAL)
  END
  COMMENT = 'Tag-driven masking for DATE PII (e.g. date of birth). Truncates to year.';

CREATE MASKING POLICY IF NOT EXISTS MP_PII_NUMBER
  AS (VAL NUMBER) RETURNS NUMBER ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    ELSE NULL
  END
  COMMENT = 'Tag-driven masking for NUMBER PII. No partial form is meaningful, so NULL.';


-- ============================================================
-- 4. Bind the policies to the tag
--    This is the step that makes tagging sufficient. One masking
--    policy per data type per tag is the Snowflake limit.
-- ============================================================
ALTER TAG PII_TYPE SET MASKING POLICY MP_PII_STRING;
ALTER TAG PII_TYPE SET MASKING POLICY MP_PII_DATE;
ALTER TAG PII_TYPE SET MASKING POLICY MP_PII_NUMBER;


-- ============================================================
-- 5. Row access policy
--    Phase 1 separates reporting domains by SCHEMA (GOLD_BILLING etc.)
--    and by role, so row-level filtering is not required yet. This is
--    provided so the mechanism exists the day a shared table has to
--    serve several domains from one set of rows.
--
--    Driven by a mapping table so that adding a domain is a row, not a
--    policy change - policy edits invalidate result caches.
-- ============================================================
CREATE TABLE IF NOT EXISTS SECURITY_DB.POLICIES.ROW_ACCESS_MAP (
  ROLE_NAME    STRING NOT NULL,
  DOMAIN_CODE  STRING NOT NULL,
  COMMENT_TEXT STRING,
  CONSTRAINT PK_ROW_ACCESS_MAP PRIMARY KEY (ROLE_NAME, DOMAIN_CODE)
)
COMMENT = 'Which role may see which domain rows. Read by RAP_DOMAIN.';

-- Seed for the roles that exist today. Extend per environment.
-- INSERT INTO SECURITY_DB.POLICIES.ROW_ACCESS_MAP VALUES
--   ('DEV_REPORTER_BILLING',   'BILLING',   'domain reporter'),
--   ('DEV_REPORTER_FINANCE',   'FINANCE',   'domain reporter'),
--   ('DEV_REPORTER_MARKETING', 'MARKETING', 'domain reporter');

-- NOTE: the policy argument must NOT be named DOMAIN_CODE. Inside the
-- subquery an identical name resolves to the mapping table's column and
-- the predicate silently becomes always-true.
CREATE ROW ACCESS POLICY IF NOT EXISTS RAP_DOMAIN
  AS (P_DOMAIN_CODE STRING) RETURNS BOOLEAN ->
  -- pipeline roles see every row
  IS_ROLE_IN_SESSION('PII_READER')
  OR EXISTS (
       SELECT 1
       FROM SECURITY_DB.POLICIES.ROW_ACCESS_MAP m
       WHERE m.DOMAIN_CODE = P_DOMAIN_CODE
         AND m.ROLE_NAME   = CURRENT_ROLE()
     )
  COMMENT = 'Restricts rows to the domains mapped to the callers role. Not attached to any table yet.';

-- CURRENT_ROLE() matches the documented Snowflake pattern and only
-- considers the primary role. If inherited or secondary roles must
-- count, swap the last predicate for IS_ROLE_IN_SESSION(m.ROLE_NAME)
-- and re-test - it is heavier and worth measuring before adopting.


-- ============================================================
-- 6. HOW TO USE (for the Gold build - no action now)
-- ============================================================
-- Tag a column; the mask applies immediately:
--   ALTER TABLE PROD_DB.GOLD.DIM_CUSTOMER MODIFY COLUMN EMAIL
--     SET TAG SECURITY_DB.POLICIES.PII_TYPE = 'EMAIL';
--
-- Classify a table for inventory/reporting:
--   ALTER TABLE PROD_DB.GOLD.DIM_CUSTOMER
--     SET TAG SECURITY_DB.POLICIES.DATA_CLASSIFICATION = 'RESTRICTED';
--
-- Attach the row access policy to a shared multi-domain table:
--   ALTER TABLE PROD_DB.GOLD.FCT_REVENUE
--     ADD ROW ACCESS POLICY SECURITY_DB.POLICIES.RAP_DOMAIN ON (DOMAIN_CODE);


-- ============================================================
-- 7. VALIDATION
-- ============================================================
USE ROLE POLICY_ADMIN;

SHOW TAGS IN SCHEMA SECURITY_DB.POLICIES;
SHOW MASKING POLICIES IN SCHEMA SECURITY_DB.POLICIES;
SHOW ROW ACCESS POLICIES IN SCHEMA SECURITY_DB.POLICIES;

-- Confirm each policy is bound to the tag (expect 3 rows once tagged objects exist).
SELECT POLICY_NAME, POLICY_KIND, TAG_NAME, TAG_DATABASE, TAG_SCHEMA
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE TAG_NAME = 'PII_TYPE';

-- Column inventory once the Gold model is tagged (AC8 evidence):
-- SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- WHERE TAG_NAME IN ('PII_TYPE','DATA_CLASSIFICATION') ORDER BY OBJECT_NAME, COLUMN_NAME;
