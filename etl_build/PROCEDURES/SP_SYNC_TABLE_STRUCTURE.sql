-- ADM.SP_SYNC_TABLE_STRUCTURE - reconcile a persistent TARGET table's structure to a
-- SOURCE table (same DB, same table name, different schema). Used before writing to the
-- persistent layers (BRONZE_HIST, SILVER) so they survive source schema drift.
--
-- What it reconciles, in order:
--   * target missing                 -> CREATE TABLE target LIKE source.
--   * source col not in target       -> ALTER TABLE target ADD COLUMN (typed from source).
--   * target too NARROW for source   -> ALTER COLUMN SET DATA TYPE (widen). Snowflake permits
--                                       increasing VARCHAR length and NUMBER precision.
--   * unfixable difference           -> abort (return ERROR), change nothing:
--                                       - different base type (TEXT vs NUMBER, ...)
--                                       - different numeric SCALE (Snowflake cannot ALTER scale;
--                                         silently rounding data is worse than failing)
--                                       - different date/time precision (not alterable)
--   * target is WIDER than source    -> fine, left alone (source values still fit).
--   * target-only columns (PK_HK, audit, ...) are left untouched.
--
-- P_EXCLUDE_COLUMNS: comma-separated column names to ignore (e.g. SILVER excludes the BRONZE
-- lineage column). Spaces around names are tolerated.
-- Returns a status VARIANT (SUCCESS/ERROR) - caller decides whether to raise (child pattern).
-- Takes no PPN_ID on purpose: it does not log, the calling phase logs the returned result.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_SYNC_TABLE_STRUCTURE(
    "P_SOURCE_SCHEMA" VARCHAR,
    "P_TARGET_SCHEMA" VARCHAR,
    "P_TABLE_NAME"       VARCHAR,
    "P_EXCLUDE_COLUMNS"  VARCHAR DEFAULT NULL   -- comma-separated column names, spaces tolerated
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Reconcile TARGET structure to SOURCE: create-if-missing, add new columns, abort on incompatible base type. Returns status VARIANT.'
EXECUTE AS CALLER
AS
DECLARE
    v_src_sch STRING  DEFAULT UPPER(TRIM(P_SOURCE_SCHEMA));
    v_tgt_sch STRING  DEFAULT UPPER(TRIM(P_TARGET_SCHEMA));
    v_table   STRING  DEFAULT UPPER(TRIM(P_TABLE_NAME));
    v_db      STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_src_fq  STRING;
    v_tgt_fq  STRING;
    v_src_cnt NUMBER  DEFAULT 0;
    v_tgt_cnt NUMBER  DEFAULT 0;
    v_bad     STRING;
    v_add     STRING;
    v_widen   STRING;
    v_phase   STRING  DEFAULT 'INIT';
    v_sql     STRING;
    -- exclusion list, whitespace stripped so 'A, B' works as well as 'A,B'
    v_excl    ARRAY   DEFAULT SPLIT(UPPER(REPLACE(COALESCE(P_EXCLUDE_COLUMNS, ''), ' ', '')), ',');
BEGIN
    v_src_fq := '"' || v_db || '"."' || v_src_sch || '"."' || v_table || '"';
    v_tgt_fq := '"' || v_db || '"."' || v_tgt_sch || '"."' || v_table || '"';

    /* source must exist */
    v_phase := 'CHECK_SOURCE';
    SELECT COUNT(*) INTO :v_src_cnt
      FROM INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = :v_src_sch AND TABLE_NAME = :v_table;
    IF (v_src_cnt = 0) THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'message','Source table ' || v_src_fq || ' does not exist.');
    END IF;

    /* target missing -> create LIKE source */
    v_phase := 'CHECK_TARGET';
    SELECT COUNT(*) INTO :v_tgt_cnt
      FROM INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = :v_tgt_sch AND TABLE_NAME = :v_table;

    IF (v_tgt_cnt = 0) THEN
        v_phase := 'CREATE_LIKE';
        EXECUTE IMMEDIATE 'CREATE TABLE ' || v_tgt_fq || ' LIKE ' || v_src_fq;
        RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'action','CREATED','table',v_tgt_fq);
    END IF;

    /* UNFIXABLE differences on a common column -> abort, change nothing.
       Base type differs, numeric SCALE differs (Snowflake cannot ALTER scale, and silently
       rounding is worse than failing), or date/time precision differs (not alterable).      */
    v_phase := 'CHECK_TYPES';
    SELECT LISTAGG(s.COLUMN_NAME || ' (' ||
                   t.DATA_TYPE || COALESCE('(' || t.NUMERIC_PRECISION || ',' || t.NUMERIC_SCALE || ')', '')
                   || ' -> ' ||
                   s.DATA_TYPE || COALESCE('(' || s.NUMERIC_PRECISION || ',' || s.NUMERIC_SCALE || ')', '')
                   || ')', ', ')
      INTO :v_bad
      FROM INFORMATION_SCHEMA.COLUMNS s
      JOIN INFORMATION_SCHEMA.COLUMNS t
        ON t.TABLE_SCHEMA = :v_tgt_sch AND t.TABLE_NAME = :v_table AND t.COLUMN_NAME = s.COLUMN_NAME
     WHERE s.TABLE_SCHEMA = :v_src_sch AND s.TABLE_NAME = :v_table
       AND NOT ARRAY_CONTAINS(s.COLUMN_NAME::VARIANT, :v_excl)
       AND (    s.DATA_TYPE <> t.DATA_TYPE
             OR (s.DATA_TYPE = 'NUMBER' AND COALESCE(s.NUMERIC_SCALE,0) <> COALESCE(t.NUMERIC_SCALE,0))
             OR (s.DATA_TYPE IN ('TIMESTAMP_NTZ','TIMESTAMP_LTZ','TIMESTAMP_TZ','TIME')
                 AND COALESCE(s.DATETIME_PRECISION,9) <> COALESCE(t.DATETIME_PRECISION,9)) );

    IF (v_bad IS NOT NULL AND v_bad <> '') THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'message','Incompatible column change on ' || v_tgt_fq || ': ' || v_bad
                                       || '. Base type, numeric scale and date/time precision cannot be '
                                       || 'reconciled automatically - fix the target or the source.');
    END IF;

    /* TARGET TOO NARROW for source -> widen. Only same-base-type size increases, which
       Snowflake allows: VARCHAR length up, NUMBER precision up (scale already proven equal).
       Target wider than source is fine and left alone.                                     */
    v_phase := 'CHECK_WIDEN';
    SELECT LISTAGG('COLUMN "' || s.COLUMN_NAME || '" SET DATA TYPE ' ||
                   CASE s.DATA_TYPE
                     WHEN 'TEXT'   THEN 'VARCHAR(' || s.CHARACTER_MAXIMUM_LENGTH || ')'
                     WHEN 'NUMBER' THEN 'NUMBER('  || s.NUMERIC_PRECISION || ',' || s.NUMERIC_SCALE || ')'
                   END, ', ') WITHIN GROUP (ORDER BY s.ORDINAL_POSITION)
      INTO :v_widen
      FROM INFORMATION_SCHEMA.COLUMNS s
      JOIN INFORMATION_SCHEMA.COLUMNS t
        ON t.TABLE_SCHEMA = :v_tgt_sch AND t.TABLE_NAME = :v_table AND t.COLUMN_NAME = s.COLUMN_NAME
     WHERE s.TABLE_SCHEMA = :v_src_sch AND s.TABLE_NAME = :v_table
       AND NOT ARRAY_CONTAINS(s.COLUMN_NAME::VARIANT, :v_excl)
       AND s.DATA_TYPE = t.DATA_TYPE
       AND (    (s.DATA_TYPE = 'TEXT'   AND s.CHARACTER_MAXIMUM_LENGTH > t.CHARACTER_MAXIMUM_LENGTH)
             OR (s.DATA_TYPE = 'NUMBER' AND s.NUMERIC_PRECISION       > t.NUMERIC_PRECISION) );

    IF (v_widen IS NOT NULL AND v_widen <> '') THEN
        v_phase := 'ALTER_WIDEN';
        v_sql := 'ALTER TABLE ' || v_tgt_fq || ' ALTER ' || v_widen;
        EXECUTE IMMEDIATE v_sql;
    END IF;

    /* add source columns missing from target */
    v_phase := 'BUILD_ADD';
    SELECT LISTAGG(
             '"' || s.COLUMN_NAME || '" ' ||
             CASE
               WHEN s.DATA_TYPE = 'TEXT'   THEN 'VARCHAR(' || COALESCE(s.CHARACTER_MAXIMUM_LENGTH, 16777216) || ')'
               WHEN s.DATA_TYPE = 'NUMBER' THEN 'NUMBER('  || COALESCE(s.NUMERIC_PRECISION, 38) || ',' || COALESCE(s.NUMERIC_SCALE, 0) || ')'
               WHEN s.DATA_TYPE IN ('TIMESTAMP_NTZ','TIMESTAMP_LTZ','TIMESTAMP_TZ') THEN s.DATA_TYPE || '(' || COALESCE(s.DATETIME_PRECISION, 9) || ')'
               WHEN s.DATA_TYPE = 'TIME'   THEN 'TIME(' || COALESCE(s.DATETIME_PRECISION, 9) || ')'
               ELSE s.DATA_TYPE
             END, ', ') WITHIN GROUP (ORDER BY s.ORDINAL_POSITION)
      INTO :v_add
      FROM INFORMATION_SCHEMA.COLUMNS s
     WHERE s.TABLE_SCHEMA = :v_src_sch AND s.TABLE_NAME = :v_table
       AND NOT ARRAY_CONTAINS(s.COLUMN_NAME::VARIANT, :v_excl)
       AND NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS t
                        WHERE t.TABLE_SCHEMA = :v_tgt_sch AND t.TABLE_NAME = :v_table AND t.COLUMN_NAME = s.COLUMN_NAME);

    IF (v_add IS NOT NULL AND v_add <> '') THEN
        v_phase := 'ALTER_ADD';
        v_sql := 'ALTER TABLE ' || v_tgt_fq || ' ADD COLUMN ' || v_add;
        EXECUTE IMMEDIATE v_sql;
    END IF;

    /* one result covering both kinds of change */
    IF (COALESCE(v_add, '') <> '' OR COALESCE(v_widen, '') <> '') THEN
        RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'action','ALTERED','added',NULLIF(COALESCE(v_add,''),''),
                                'widened',NULLIF(COALESCE(v_widen,''),''),'table',v_tgt_fq);
    END IF;

    RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_SYNC_TABLE_STRUCTURE',
                            'action','NOCHANGE','table',v_tgt_fq);

EXCEPTION
    WHEN OTHER THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'phase',v_phase,'message',SQLERRM,'sqlcode',SQLCODE);
END;
