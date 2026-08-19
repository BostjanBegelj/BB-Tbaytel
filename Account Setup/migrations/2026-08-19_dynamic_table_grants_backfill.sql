-- ============================================================
-- MIGRATION - backfill dynamic-table grants on EXISTING schemas
-- Date: 2026-08-19
--
-- CONTEXT
--   account/03_platform_rbac_procedures.sql (CREATE_SCHEMA) now grants,
--   for every NEW schema:
--     RO_AR : SELECT + MONITOR on ALL/FUTURE DYNAMIC TABLES
--     RW_AR : OPERATE        on ALL/FUTURE DYNAMIC TABLES   (RW inherits RO; FULL inherits RW)
--   Dynamic tables are a DISTINCT object type, so the pre-existing
--   "ON ALL/FUTURE TABLES" grants never covered them. OPERATE is what lets
--   the pipeline run  ALTER DYNAMIC TABLE ... REFRESH  (GOLD pipeline-only
--   refresh, called by SP_FINALIZE_RUN as {ENV}_DATA_LOADER, which holds
--   FULL_AR -> inherits RW_AR -> OPERATE).
--
--   Schemas created BEFORE that change do not have these grants. This script
--   applies them retroactively.
--
-- SCOPE / SAFETY
--   * RUN ONCE PER ENVIRONMENT DATABASE. Set ENV_ABBR below (DEV_/TEST_/PROD_).
--   * Idempotent - GRANT is a no-op if the privilege is already present, and
--     "ON ALL DYNAMIC TABLES" on a schema with none is a harmless no-op.
--   * Only touches schemas that HAVE _RO_AR/_RW_AR database roles (i.e. schemas
--     created via PLATFORM_DB.RBAC.CREATE_SCHEMA). Any other schema is skipped.
--     PLATFORM_DB's own schemas are not created that way and are not a target
--     of this script (run it against the environment databases).
--   * Runs as {ENV}_SYSADMIN: it owns the environment schemas (managed access,
--     so the schema owner administers all grants), owns the access roles, and
--     owns the GOLD dynamic tables - so it can grant on them.
-- ============================================================
SET ENV_ABBR = 'DEV_';                 -- <<< change per environment and re-run

SET DB_NAME      = $ENV_ABBR || 'DB';
SET ENV_SYSADMIN = $ENV_ABBR || 'SYSADMIN';

USE ROLE IDENTIFIER($ENV_SYSADMIN);
USE WAREHOUSE PLATFORM_WH;
USE DATABASE IDENTIFIER($DB_NAME);

DECLARE
    v_db      STRING;
    v_granted NUMBER DEFAULT 0;
    v_skipped NUMBER DEFAULT 0;
    c_schemas CURSOR FOR
        SELECT SCHEMA_NAME
        FROM   INFORMATION_SCHEMA.SCHEMATA
        WHERE  SCHEMA_NAME NOT IN ('INFORMATION_SCHEMA', 'PUBLIC')
        ORDER  BY SCHEMA_NAME;
BEGIN
    v_db := CURRENT_DATABASE();

    FOR rec IN c_schemas DO
        LET v_schema STRING := rec.SCHEMA_NAME;
        LET v_fqn    STRING := v_db || '.' || v_schema;
        LET v_ro     STRING := v_db || '.' || v_schema || '_RO_AR';
        LET v_rw     STRING := v_db || '.' || v_schema || '_RW_AR';
        BEGIN
            -- RO: read + refresh-state visibility
            EXECUTE IMMEDIATE 'GRANT SELECT  ON ALL    DYNAMIC TABLES IN SCHEMA ' || v_fqn || ' TO DATABASE ROLE ' || v_ro;
            EXECUTE IMMEDIATE 'GRANT SELECT  ON FUTURE DYNAMIC TABLES IN SCHEMA ' || v_fqn || ' TO DATABASE ROLE ' || v_ro;
            EXECUTE IMMEDIATE 'GRANT MONITOR ON ALL    DYNAMIC TABLES IN SCHEMA ' || v_fqn || ' TO DATABASE ROLE ' || v_ro;
            EXECUTE IMMEDIATE 'GRANT MONITOR ON FUTURE DYNAMIC TABLES IN SCHEMA ' || v_fqn || ' TO DATABASE ROLE ' || v_ro;
            -- RW: refresh (OPERATE). RW inherits RO's SELECT/MONITOR.
            EXECUTE IMMEDIATE 'GRANT OPERATE ON ALL    DYNAMIC TABLES IN SCHEMA ' || v_fqn || ' TO DATABASE ROLE ' || v_rw;
            EXECUTE IMMEDIATE 'GRANT OPERATE ON FUTURE DYNAMIC TABLES IN SCHEMA ' || v_fqn || ' TO DATABASE ROLE ' || v_rw;
            v_granted := v_granted + 1;
        EXCEPTION
            WHEN OTHER THEN
                -- No _RO_AR/_RW_AR database roles for this schema (not created via
                -- CREATE_SCHEMA) -> nothing to grant to, skip it.
                v_skipped := v_skipped + 1;
        END;
    END FOR;

    RETURN 'Dynamic-table grants backfilled on ' || v_db
        || ': ' || v_granted || ' schema(s) updated, '
        || v_skipped || ' skipped (no access roles).';
END;


-- ============================================================
-- VALIDATION (run after; expect OPERATE for RW_AR, SELECT/MONITOR for RO_AR)
-- ============================================================
-- SHOW GRANTS TO DATABASE ROLE IDENTIFIER($DB_NAME || '.GOLD_RW_AR');
-- SHOW GRANTS TO DATABASE ROLE IDENTIFIER($DB_NAME || '.GOLD_RO_AR');
--
-- End-to-end proof that {ENV}_DATA_LOADER (FULL_AR -> RW_AR -> OPERATE) can refresh:
-- USE ROLE IDENTIFIER($ENV_ABBR || 'DATA_LOADER');
-- USE WAREHOUSE IDENTIFIER($ENV_ABBR || 'DATA_LOADER_WH');
-- ALTER DYNAMIC TABLE IDENTIFIER($DB_NAME || '.GOLD.DIM_PARTNER') REFRESH;
