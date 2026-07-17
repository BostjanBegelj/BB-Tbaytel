-- ADM.SP_SYNC_TABLE_STRUCTURE - reconcile a persistent TARGET table's structure to a
-- SOURCE table (same DB, same table name, different schema). Used before writing to the
-- persistent layers (BRONZE_HIST, SILVER) so they survive additive source schema drift.
--   * target missing        -> CREATE TABLE target LIKE source.
--   * source col not in tgt  -> ALTER TABLE target ADD COLUMN (typed from source).
--   * common col, base type differs -> abort (return ERROR); no auto-widen yet.
--   * target-only columns (e.g. PK_HK, audit) are left untouched.
-- P_EXCLUDE_CSV: source columns to ignore (e.g. SILVER excludes METADATA$FILENAME).
-- Returns a status VARIANT (SUCCESS/ERROR) - caller decides whether to raise (child pattern).

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_SYNC_TABLE_STRUCTURE(
    "P_SOURCE_SCHEMA" VARCHAR,
    "P_TARGET_SCHEMA" VARCHAR,
    "P_TABLE_NAME"    VARCHAR,
    "P_EXCLUDE_CSV"   VARCHAR DEFAULT NULL
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
    v_phase   STRING  DEFAULT 'INIT';
    v_sql     STRING;
BEGIN
    v_src_fq := '"' || v_db || '"."' || v_src_sch || '"."' || v_table || '"';
    v_tgt_fq := '"' || v_db || '"."' || v_tgt_sch || '"."' || v_table || '"';

    /* source must exist */
    v_phase := 'CHECK_SOURCE';
    SELECT COUNT(*) INTO :v_src_cnt
      FROM DEV_DB.INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = :v_src_sch AND TABLE_NAME = :v_table;
    IF (v_src_cnt = 0) THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'message','Source table ' || v_src_fq || ' does not exist.');
    END IF;

    /* target missing -> create LIKE source */
    v_phase := 'CHECK_TARGET';
    SELECT COUNT(*) INTO :v_tgt_cnt
      FROM DEV_DB.INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = :v_tgt_sch AND TABLE_NAME = :v_table;

    IF (v_tgt_cnt = 0) THEN
        v_phase := 'CREATE_LIKE';
        EXECUTE IMMEDIATE 'CREATE TABLE ' || v_tgt_fq || ' LIKE ' || v_src_fq;
        RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'action','CREATED','table',v_tgt_fq);
    END IF;

    /* incompatible base-type change on a common column -> abort */
    v_phase := 'CHECK_TYPES';
    SELECT LISTAGG(s.COLUMN_NAME || ' (' || t.DATA_TYPE || ' -> ' || s.DATA_TYPE || ')', ', ')
      INTO :v_bad
      FROM DEV_DB.INFORMATION_SCHEMA.COLUMNS s
      JOIN DEV_DB.INFORMATION_SCHEMA.COLUMNS t
        ON t.TABLE_SCHEMA = :v_tgt_sch AND t.TABLE_NAME = :v_table AND t.COLUMN_NAME = s.COLUMN_NAME
     WHERE s.TABLE_SCHEMA = :v_src_sch AND s.TABLE_NAME = :v_table
       AND s.DATA_TYPE <> t.DATA_TYPE
       AND (:P_EXCLUDE_CSV IS NULL OR NOT ARRAY_CONTAINS(s.COLUMN_NAME::VARIANT, SPLIT(UPPER(:P_EXCLUDE_CSV), ',')));

    IF (v_bad IS NOT NULL AND v_bad <> '') THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'message','Incompatible column type change on ' || v_tgt_fq || ': ' || v_bad);
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
      FROM DEV_DB.INFORMATION_SCHEMA.COLUMNS s
     WHERE s.TABLE_SCHEMA = :v_src_sch AND s.TABLE_NAME = :v_table
       AND (:P_EXCLUDE_CSV IS NULL OR NOT ARRAY_CONTAINS(s.COLUMN_NAME::VARIANT, SPLIT(UPPER(:P_EXCLUDE_CSV), ',')))
       AND NOT EXISTS (SELECT 1 FROM DEV_DB.INFORMATION_SCHEMA.COLUMNS t
                        WHERE t.TABLE_SCHEMA = :v_tgt_sch AND t.TABLE_NAME = :v_table AND t.COLUMN_NAME = s.COLUMN_NAME);

    IF (v_add IS NOT NULL AND v_add <> '') THEN
        v_phase := 'ALTER_ADD';
        v_sql := 'ALTER TABLE ' || v_tgt_fq || ' ADD COLUMN ' || v_add;
        EXECUTE IMMEDIATE v_sql;
        RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'action','ALTERED','added',v_add,'table',v_tgt_fq);
    END IF;

    RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_SYNC_TABLE_STRUCTURE',
                            'action','NOCHANGE','table',v_tgt_fq);

EXCEPTION
    WHEN OTHER THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_SYNC_TABLE_STRUCTURE',
                                'phase',v_phase,'message',SQLERRM,'sqlcode',SQLCODE);
END;
