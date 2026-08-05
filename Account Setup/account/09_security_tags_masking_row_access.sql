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
-- TWO RULES THAT MATTER, because breaking either fails SILENTLY:
--
--   1. PII_TYPE IS A COLUMN-LEVEL TAG ONLY. Tags propagate down the
--      object hierarchy, but SYSTEM$GET_TAG_ON_CURRENT_COLUMN returns
--      NULL for an inherited tag - so setting PII_TYPE on a TABLE would
--      push every string column in it to the full-mask branch.
--      Use DATA_CLASSIFICATION for table-level classification.
--
--   2. A TAG-BOUND MASKING POLICY ONLY ATTACHES WHERE THE COLUMN TYPE
--      MATCHES A POLICY SIGNATURE. On a mismatch Snowflake attaches
--      nothing and raises no error - the column stays readable.
--      Supported below: VARCHAR, NUMBER, FLOAT, DATE, TIMESTAMP_NTZ.
--      Section 7 has the query that finds tagged columns with no
--      matching policy. Run it after every Gold release.
--
-- Running this file is safe on an empty account: no column is tagged,
-- so no data is masked until a steward tags something. It is also
-- re-runnable - the ALTER TAG statements use FORCE.
-- ============================================================


-- ============================================================
-- 0. Privileges for the policy owner
--    POLICY_ADMIN is created in 05_security_database.sql.
--    SECURITYADMIN holds MANAGE GRANTS, so no ACCOUNTADMIN needed
--    for the account-level APPLY privileges.
-- ============================================================
USE ROLE SECURITYADMIN;

-- POLICY_ADMIN and its schema-level CREATE grants come from 05.
-- Account-level APPLY privileges: needed to bind a policy to a tag and
-- to tag columns in the environment databases.
GRANT APPLY MASKING POLICY    ON ACCOUNT TO ROLE POLICY_ADMIN;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE POLICY_ADMIN;
GRANT APPLY TAG               ON ACCOUNT TO ROLE POLICY_ADMIN;

-- POLICY_ADMIN needs compute to run the validation queries in section 7.
USE ROLE SYSADMIN;
GRANT USAGE ON WAREHOUSE PLATFORM_WH TO ROLE POLICY_ADMIN;

-- ACCOUNT_USAGE access for the periodic coverage controls. Only
-- ACCOUNTADMIN can share the SNOWFLAKE database.
USE ROLE ACCOUNTADMIN;
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE POLICY_ADMIN;


-- ============================================================
-- 1. PII_READER - the column-masking exemption role
--    Masking policies unmask for this role only. Everyone else sees
--    the masked value, including ACCOUNTADMIN, by design.
--
--    Scope note: this role exempts from COLUMN MASKING only. Row-level
--    visibility is a separate control driven by ROW_ACCESS_MAP, so
--    granting an analyst unmasked PII does not also hand them every
--    domain's rows.
-- ============================================================
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS PII_READER
  COMMENT = 'Exempt from PII column masking. Grant deliberately and review periodically.';

-- Deliberately NOT granted into the admin hierarchy: SECURITYADMIN holds
-- MANAGE GRANTS and can hand out PII_READER without inheriting it, so
-- administering the exemption does not imply being exempt.
USE ROLE SECURITYADMIN;

-- Per-environment grants. Run for each environment AFTER its roles exist
-- (environment/02). The pipeline roles need unmasked reads: masking
-- applies on read, so a transform reading masked Silver writes masked Gold.
-- These grants are structural, not discretionary.
-- GRANT ROLE PII_READER TO ROLE DEV_TRANSFORMER;
-- GRANT ROLE PII_READER TO ROLE DEV_DATA_LOADER;
-- GRANT ROLE PII_READER TO ROLE DEV_DEPLOYER;
--
-- Human access to unmasked PII should be granted through an Entra group
-- mapped to PII_READER, not by granting the role to a functional role.


-- ============================================================
-- 2. Governance tags
--    DATA_CLASSIFICATION is an INVENTORY dimension - it drives no
--    enforcement on its own. PII_TYPE is what actually masks.
--    A RESTRICTED column with no PII_TYPE is therefore readable;
--    section 7 has the control that finds exactly that case.
-- ============================================================
USE ROLE POLICY_ADMIN;
USE WAREHOUSE PLATFORM_WH;
USE SCHEMA SECURITY_DB.POLICIES;

CREATE TAG IF NOT EXISTS DATA_CLASSIFICATION
  ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED'
  COMMENT = 'Sensitivity of the object. Table or column level. Inventory dimension - no enforcement.';

CREATE TAG IF NOT EXISTS PII_TYPE
  ALLOWED_VALUES
    'NAME', 'EMAIL', 'PHONE', 'ADDRESS', 'DOB',
    'GOVERNMENT_ID', 'PAYMENT_CARD', 'ACCOUNT_NUMBER',
    'IP_ADDRESS', 'GEOLOCATION'
  COMMENT = 'Category of personal data in the column. COLUMN LEVEL ONLY. Drives masking automatically.';


-- ============================================================
-- 3. Masking policies - one signature per physical data type
--    The policy body branches on the PII_TYPE value, so partial
--    masking stays useful for support and reconciliation (last 4
--    digits, email domain) without exposing the full value.
-- ============================================================

CREATE MASKING POLICY IF NOT EXISTS MP_PII_STRING
  AS (VAL STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    WHEN VAL IS NULL THEN NULL
    -- too short for a partial form to be safe
    WHEN LENGTH(VAL) <= 4 THEN '***MASKED***'
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

CREATE MASKING POLICY IF NOT EXISTS MP_PII_NUMBER
  AS (VAL NUMBER) RETURNS NUMBER ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    WHEN VAL IS NULL THEN NULL
    -- numeric phone / account / card: keep the last four digits so the
    -- masked form matches the STRING policy for the same category
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('SECURITY_DB.POLICIES.PII_TYPE')
         IN ('PHONE', 'ACCOUNT_NUMBER', 'PAYMENT_CARD')
      THEN MOD(ABS(VAL), 10000)
    ELSE NULL
  END
  COMMENT = 'Tag-driven masking for NUMBER PII (numeric MSISDN, account and card identifiers).';

CREATE MASKING POLICY IF NOT EXISTS MP_PII_FLOAT
  AS (VAL FLOAT) RETURNS FLOAT ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    ELSE NULL
  END
  COMMENT = 'Tag-driven masking for FLOAT PII (e.g. latitude/longitude). No partial form is safe.';

CREATE MASKING POLICY IF NOT EXISTS MP_PII_DATE
  AS (VAL DATE) RETURNS DATE ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    WHEN VAL IS NULL THEN NULL
    -- year only: preserves age-band analysis, drops the identifying date
    ELSE DATE_TRUNC('YEAR', VAL)
  END
  COMMENT = 'Tag-driven masking for DATE PII (e.g. date of birth). Truncates to year.';

-- Dates arriving from ADF are frequently typed as TIMESTAMP_NTZ. Without
-- this signature such a column would be tagged and left fully readable.
CREATE MASKING POLICY IF NOT EXISTS MP_PII_TIMESTAMP_NTZ
  AS (VAL TIMESTAMP_NTZ) RETURNS TIMESTAMP_NTZ ->
  CASE
    WHEN IS_ROLE_IN_SESSION('PII_READER') THEN VAL
    WHEN VAL IS NULL THEN NULL
    ELSE DATE_TRUNC('YEAR', VAL)
  END
  COMMENT = 'Tag-driven masking for TIMESTAMP_NTZ PII. Truncates to year.';

-- If a PII column ever lands as TIMESTAMP_LTZ / TIMESTAMP_TZ / VARIANT,
-- add the matching signature here BEFORE tagging it - see rule 2 in the
-- header. The coverage query in section 7 detects the gap.


-- ============================================================
-- 4. Bind the policies to the tag
--    One masking policy per data type per tag is the Snowflake limit.
--    FORCE makes the file re-runnable after any policy edit.
-- ============================================================
ALTER TAG PII_TYPE SET MASKING POLICY MP_PII_STRING        FORCE;
ALTER TAG PII_TYPE SET MASKING POLICY MP_PII_NUMBER        FORCE;
ALTER TAG PII_TYPE SET MASKING POLICY MP_PII_FLOAT         FORCE;
ALTER TAG PII_TYPE SET MASKING POLICY MP_PII_DATE          FORCE;
ALTER TAG PII_TYPE SET MASKING POLICY MP_PII_TIMESTAMP_NTZ FORCE;


-- ============================================================
-- 5. Row access policy
--    Phase 1 separates reporting domains by SCHEMA (GOLD_BILLING etc.)
--    and by role, so row-level filtering is not required yet. This is
--    provided so the mechanism exists the day a shared table has to
--    serve several domains from one set of rows.
--
--    Driven by a mapping table so that adding a domain is a row, not a
--    policy change - policy edits invalidate result caches.
--    DOMAIN_CODE = '*' means "all rows" and is how pipeline roles are
--    exempted. PII_READER is deliberately NOT a bypass here: column
--    masking and row visibility are separate approvals.
-- ============================================================
CREATE TABLE IF NOT EXISTS SECURITY_DB.POLICIES.ROW_ACCESS_MAP (
  ROLE_NAME    STRING NOT NULL,
  DOMAIN_CODE  STRING NOT NULL,   -- '*' = every domain
  COMMENT_TEXT STRING,
  -- Snowflake does not enforce primary keys. Declared for documentation
  -- only; the policy uses EXISTS, so duplicate rows are harmless.
  CONSTRAINT PK_ROW_ACCESS_MAP PRIMARY KEY (ROLE_NAME, DOMAIN_CODE)
)
COMMENT = 'Which role may see which domain rows. Read by RAP_DOMAIN. PK is not enforced.';

-- Seed per environment once its roles exist. Pipeline roles need '*',
-- otherwise a full refresh would silently write a truncated row set.
-- INSERT INTO SECURITY_DB.POLICIES.ROW_ACCESS_MAP VALUES
--   ('DEV_TRANSFORMER',        '*',         'pipeline - must see all rows'),
--   ('DEV_DATA_LOADER',        '*',         'pipeline - must see all rows'),
--   ('DEV_DEPLOYER',           '*',         'CI/CD full refresh'),
--   ('DEV_REPORTER',           '*',         'Power BI service account'),
--   ('DEV_REPORTER_BILLING',   'BILLING',   'domain reporter'),
--   ('DEV_REPORTER_FINANCE',   'FINANCE',   'domain reporter'),
--   ('DEV_REPORTER_MARKETING', 'MARKETING', 'domain reporter');

-- NOTE: the policy argument must NOT be named DOMAIN_CODE. Inside the
-- subquery an identical name resolves to the mapping table's column and
-- the predicate silently becomes always-true.
CREATE ROW ACCESS POLICY IF NOT EXISTS RAP_DOMAIN
  AS (P_DOMAIN_CODE STRING) RETURNS BOOLEAN ->
  EXISTS (
    SELECT 1
    FROM SECURITY_DB.POLICIES.ROW_ACCESS_MAP m
    WHERE m.ROLE_NAME = CURRENT_ROLE()
      AND (m.DOMAIN_CODE = P_DOMAIN_CODE OR m.DOMAIN_CODE = '*')
  )
  COMMENT = 'Restricts rows to the domains mapped to the callers role. Not attached to any table yet.';

-- CURRENT_ROLE() matches the documented Snowflake pattern and only
-- considers the primary role. If inherited or secondary roles must
-- count, swap it for IS_ROLE_IN_SESSION(m.ROLE_NAME) and re-test -
-- it is heavier and worth measuring before adopting.


-- ============================================================
-- 6. HOW TO USE (for the Gold build - no action now)
-- ============================================================
-- Tag a COLUMN; the mask applies without rebuilding the table:
--   ALTER TABLE PROD_DB.GOLD.DIM_CUSTOMER MODIFY COLUMN EMAIL
--     SET TAG SECURITY_DB.POLICIES.PII_TYPE = 'EMAIL';
--
-- Classify a TABLE for inventory/reporting:
--   ALTER TABLE PROD_DB.GOLD.DIM_CUSTOMER
--     SET TAG SECURITY_DB.POLICIES.DATA_CLASSIFICATION = 'RESTRICTED';
--
-- Attach the row access policy to a shared multi-domain table:
--   ALTER TABLE PROD_DB.GOLD.FCT_REVENUE
--     ADD ROW ACCESS POLICY SECURITY_DB.POLICIES.RAP_DOMAIN ON (DOMAIN_CODE);
--
-- The role doing the tagging needs APPLY on the tag plus USAGE on the
-- database and schema. Run per environment after environment/02:
--   USE ROLE SECURITYADMIN;
--   GRANT USAGE ON DATABASE SECURITY_DB           TO ROLE DEV_TRANSFORMER;
--   GRANT USAGE ON SCHEMA   SECURITY_DB.POLICIES  TO ROLE DEV_TRANSFORMER;
--   GRANT APPLY ON TAG SECURITY_DB.POLICIES.PII_TYPE            TO ROLE DEV_TRANSFORMER;
--   GRANT APPLY ON TAG SECURITY_DB.POLICIES.DATA_CLASSIFICATION TO ROLE DEV_TRANSFORMER;
--   (repeat for DEV_DEPLOYER if CI/CD applies the tags)


-- ============================================================
-- 7. VALIDATION + ongoing controls
-- ============================================================
USE ROLE POLICY_ADMIN;
USE WAREHOUSE PLATFORM_WH;

SHOW TAGS               IN SCHEMA SECURITY_DB.POLICIES;
SHOW MASKING POLICIES   IN SCHEMA SECURITY_DB.POLICIES;
SHOW ROW ACCESS POLICIES IN SCHEMA SECURITY_DB.POLICIES;

-- Confirm all five masking policies are bound to PII_TYPE.
-- INFORMATION_SCHEMA is real-time; ACCOUNT_USAGE lags up to ~2 hours.
SELECT POLICY_NAME, POLICY_KIND
FROM TABLE(
  SNOWFLAKE.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME   => 'SECURITY_DB.POLICIES.PII_TYPE',
    REF_ENTITY_DOMAIN => 'TAG'
  )
);

-- ---------------------------------------------------------------------
-- Periodic controls. Run after every Gold release; schedule as a task
-- once the Gold model exists.
-- ---------------------------------------------------------------------
-- C1. Tagged columns whose data type has NO matching policy signature.
--     These are silently unmasked - the single most dangerous state.
-- SELECT t.OBJECT_DATABASE, t.OBJECT_SCHEMA, t.OBJECT_NAME,
--        t.COLUMN_NAME, t.TAG_VALUE, c.DATA_TYPE
-- FROM   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
-- JOIN   SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
--        ON  c.TABLE_CATALOG = t.OBJECT_DATABASE
--        AND c.TABLE_SCHEMA  = t.OBJECT_SCHEMA
--        AND c.TABLE_NAME    = t.OBJECT_NAME
--        AND c.COLUMN_NAME   = t.COLUMN_NAME
--        AND c.DELETED IS NULL
-- WHERE  t.TAG_NAME     = 'PII_TYPE'
--   AND  t.TAG_DATABASE = 'SECURITY_DB'
--   AND  t.TAG_SCHEMA   = 'POLICIES'
--   AND  t.OBJECT_DELETED IS NULL
--   AND  c.DATA_TYPE NOT IN ('TEXT','NUMBER','FLOAT','DATE','TIMESTAMP_NTZ');

-- C2. Columns classified RESTRICTED but carrying no PII_TYPE tag.
--     DATA_CLASSIFICATION enforces nothing, so these are readable.
-- WITH restricted AS (
--   SELECT OBJECT_DATABASE, OBJECT_SCHEMA, OBJECT_NAME, COLUMN_NAME
--   FROM   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
--   WHERE  TAG_NAME = 'DATA_CLASSIFICATION' AND TAG_VALUE = 'RESTRICTED'
--     AND  COLUMN_NAME IS NOT NULL AND OBJECT_DELETED IS NULL
-- ), pii AS (
--   SELECT OBJECT_DATABASE, OBJECT_SCHEMA, OBJECT_NAME, COLUMN_NAME
--   FROM   SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
--   WHERE  TAG_NAME = 'PII_TYPE' AND OBJECT_DELETED IS NULL
-- )
-- SELECT r.* FROM restricted r
-- LEFT JOIN pii p USING (OBJECT_DATABASE, OBJECT_SCHEMA, OBJECT_NAME, COLUMN_NAME)
-- WHERE p.COLUMN_NAME IS NULL;

-- C3. PII_TYPE set at TABLE level (no COLUMN_NAME) - mass-masks the table.
-- SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
-- WHERE TAG_NAME = 'PII_TYPE' AND COLUMN_NAME IS NULL
--   AND OBJECT_DELETED IS NULL;

-- C4. Current PII_READER membership - review each cycle.
-- SHOW GRANTS OF ROLE PII_READER;
