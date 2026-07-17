-- ADM.SP_LOAD_BRONZE_TO_SILVER - load BRONZE.<table> (this PPN) into the cleansed
-- 1:1 SILVER.<table>, computing PK_HK + ROW_HK and applying IS_DELETED.
--   PK_HK  = MD5 of PK_COLUMNS  (or of ALL business cols when no PK is defined).
--   ROW_HK = MD5 of ALL business cols (change fingerprint / hashdiff).
--   Business cols = every BRONZE column except PPN_ID, PPN_TIMESTAMP, METADATA$FILENAME.
-- LOAD_TYPE:
--   FULL / INIT : MERGE (insert new, update where ROW_HK differs, un-delete on reappear),
--                 then soft-delete SILVER keys absent from the snapshot (IS_DELETED=TRUE).
--   INCR        : MERGE only (partial feed can't detect deletes).
--   PARTITION   : same MERGE, but soft-delete is scoped to only the PARTITION_COLUMN
--                 values present in this load (untouched partitions are left alone).
-- Config-driven; same helpers + child-error pattern. RUN_ID resolved by SP_LOG_STEP.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_LOAD_BRONZE_TO_SILVER(
    "P_PPN_ID"     NUMBER(38,0),
    "P_SOURCE_ID"  VARCHAR,
    "P_TABLE_NAME" VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Load BRONZE -> SILVER for one table: PK_HK/ROW_HK, MERGE upsert, IS_DELETED per LOAD_TYPE. Config-driven.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20990, 'SP_LOAD_BRONZE_TO_SILVER failed.');

    v_ppn_id      NUMBER  DEFAULT P_PPN_ID;
    v_source_id   STRING  DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_table       STRING  DEFAULT UPPER(NULLIF(TRIM(P_TABLE_NAME), ''));

    v_src_sch       STRING;
    v_load_type     STRING;
    v_pk_columns    STRING;
    v_partition_col STRING;
    v_scope         STRING  DEFAULT '';
    v_sync          VARIANT;
    v_db            STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_bronze_fq   STRING;
    v_silver_fq   STRING;

    v_cols        STRING;   -- "A", "B", ...
    v_src_cols    STRING;   -- src."A", src."B", ...
    v_update_set  STRING;   -- tgt."A" = src."A", ...
    v_row_concat  STRING;   -- COALESCE(TO_VARCHAR("A"),'') || '|~|' || ...
    v_row_hk      STRING;
    v_pk_hk       STRING;
    v_src_select  STRING;
    v_col_count   NUMBER  DEFAULT 0;

    v_cfg_count   NUMBER  DEFAULT 0;
    v_merged      NUMBER  DEFAULT 0;
    v_deleted     NUMBER  DEFAULT 0;
    v_started_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_phase       STRING  DEFAULT 'INIT';
    v_last_sql    STRING  DEFAULT '';
    v_error_msg   STRING;
    v_sql         STRING;
    v_log_rows    NUMBER  DEFAULT 0;
BEGIN
    /* 1. VALIDATE ------------------------------------------------------- */
    v_phase := 'VALIDATE';
    IF (v_ppn_id IS NULL OR v_source_id IS NULL OR v_table IS NULL) THEN
        v_error_msg := 'P_PPN_ID, P_SOURCE_ID and P_TABLE_NAME are required.';
        RAISE e_failed;
    END IF;
    IF (NOT REGEXP_LIKE(v_table, '^[A-Z][A-Z0-9_]*$')) THEN
        v_error_msg := 'Invalid P_TABLE_NAME [' || v_table || '].';
        RAISE e_failed;
    END IF;

    /* 2. READ CONFIG ---------------------------------------------------- */
    v_phase := 'READ_CONFIG';
    SELECT COUNT(*)
      INTO :v_cfg_count
      FROM ADM.ETL_TABLES t
      JOIN ADM.ETL_SOURCES s ON s.source_id = t.source_id
     WHERE t.source_id = :v_source_id AND t.table_name = :v_table
       AND t.active_flag AND s.active_flag;
    IF (v_cfg_count = 0) THEN
        v_error_msg := 'No active ETL_TABLES/ETL_SOURCES config for [' || v_source_id || '.' || v_table || '].';
        RAISE e_failed;
    END IF;

    SELECT UPPER(COALESCE(t.target_schema, 'BRONZE')), UPPER(t.load_type), t.pk_columns, t.partition_column
      INTO :v_src_sch, :v_load_type, :v_pk_columns, :v_partition_col
      FROM ADM.ETL_TABLES t
     WHERE t.source_id = :v_source_id AND t.table_name = :v_table AND t.active_flag;

    IF (v_load_type = 'PARTITION' AND (v_partition_col IS NULL OR TRIM(v_partition_col) = '')) THEN
        v_error_msg := 'LOAD_TYPE PARTITION requires PARTITION_COLUMN in ETL_TABLES.';
        RAISE e_failed;
    END IF;

    v_bronze_fq := '"' || v_db || '"."' || v_src_sch || '"."' || v_table || '"';
    v_silver_fq := '"' || v_db || '"."SILVER"."' || v_table || '"';

    /* 3. BUILD COLUMN-DRIVEN EXPRESSIONS -------------------------------- */
    v_phase := 'BUILD_EXPR';
    SELECT
        COUNT(*),
        LISTAGG('"' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION),
        LISTAGG('src."' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION),
        LISTAGG('tgt."' || COLUMN_NAME || '" = src."' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION),
        LISTAGG('COALESCE(TO_VARCHAR("' || COLUMN_NAME || '"), '''')', ' || ''|~|'' || ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
      INTO :v_col_count, :v_cols, :v_src_cols, :v_update_set, :v_row_concat
      FROM DEV_DB.INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = :v_src_sch
       AND TABLE_NAME = :v_table
       AND COLUMN_NAME NOT IN ('PPN_ID', 'PPN_TIMESTAMP', 'METADATA$FILENAME');

    IF (v_col_count = 0) THEN
        v_error_msg := 'BRONZE table ' || v_bronze_fq || ' has no business columns (load BRONZE first).';
        RAISE e_failed;
    END IF;

    v_row_hk := 'MD5(' || v_row_concat || ')';

    IF (v_pk_columns IS NOT NULL AND TRIM(v_pk_columns) <> '') THEN
        SELECT 'MD5(' || LISTAGG('COALESCE(TO_VARCHAR("' || TRIM(VALUE) || '"), '''')', ' || ''|~|'' || ')
                          WITHIN GROUP (ORDER BY INDEX) || ')'
          INTO :v_pk_hk
          FROM TABLE(SPLIT_TO_TABLE(:v_pk_columns, ','));
    ELSE
        v_pk_hk := v_row_hk;   -- no PK: whole-row identity
    END IF;

    -- deduplicated source snapshot (one row per PK_HK)
    v_src_select :=
        'SELECT ' || v_cols || ', ' || v_pk_hk || ' AS PK_HK, ' || v_row_hk || ' AS ROW_HK, PPN_ID, PPN_TIMESTAMP ' ||
        'FROM ' || v_bronze_fq || ' WHERE PPN_ID = ' || v_ppn_id ||
        ' QUALIFY ROW_NUMBER() OVER (PARTITION BY ' || v_pk_hk || ' ORDER BY 1) = 1';

    /* mark state RUNNING */
    CALL ADM.SP_SET_PROCESS_STATE(:v_ppn_id, :v_source_id, :v_table, 'RUNNING', 'LOAD_BRONZE_TO_SILVER');

    /* 4. ENSURE SILVER TABLE EXISTS (structure) ------------------------- */
    v_phase := 'CREATE_SILVER';
    v_sql := 'CREATE TABLE IF NOT EXISTS ' || v_silver_fq || ' AS SELECT ' || v_cols || ', ' ||
             v_pk_hk || ' AS PK_HK, ' || v_row_hk || ' AS ROW_HK, FALSE AS IS_DELETED, ' ||
             'PPN_ID, PPN_TIMESTAMP, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(9) AS DW_INSERTED_AT, ' ||
             'CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(9) AS DW_UPDATED_AT FROM ' || v_bronze_fq || ' WHERE 1=0';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 4b. RECONCILE SILVER STRUCTURE TO BRONZE business cols ------------ */
    v_phase := 'SYNC_SILVER';
    CALL ADM.SP_SYNC_TABLE_STRUCTURE(:v_src_sch, 'SILVER', :v_table, 'METADATA$FILENAME') INTO :v_sync;
    IF (GET(:v_sync, 'status')::STRING <> 'SUCCESS') THEN
        v_error_msg := 'Structure sync failed: ' || COALESCE(GET(:v_sync, 'message')::STRING, '(no message)');
        RAISE e_failed;
    END IF;

    /* 5. MERGE (insert / update-on-change / un-delete) ------------------ */
    v_phase := 'MERGE';
    v_sql := 'MERGE INTO ' || v_silver_fq || ' tgt USING (' || v_src_select || ') src ON tgt.PK_HK = src.PK_HK ' ||
             'WHEN MATCHED AND tgt.ROW_HK <> src.ROW_HK THEN UPDATE SET ' || v_update_set ||
                 ', ROW_HK = src.ROW_HK, IS_DELETED = FALSE, PPN_ID = src.PPN_ID, PPN_TIMESTAMP = src.PPN_TIMESTAMP, DW_UPDATED_AT = CURRENT_TIMESTAMP() ' ||
             'WHEN MATCHED AND tgt.IS_DELETED THEN UPDATE SET IS_DELETED = FALSE, PPN_ID = src.PPN_ID, PPN_TIMESTAMP = src.PPN_TIMESTAMP, DW_UPDATED_AT = CURRENT_TIMESTAMP() ' ||
             'WHEN NOT MATCHED THEN INSERT (' || v_cols || ', PK_HK, ROW_HK, IS_DELETED, PPN_ID, PPN_TIMESTAMP, DW_INSERTED_AT, DW_UPDATED_AT) ' ||
                 'VALUES (' || v_src_cols || ', src.PK_HK, src.ROW_HK, FALSE, src.PPN_ID, src.PPN_TIMESTAMP, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP())';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;
    v_merged := SQLROWCOUNT;

    /* 6. SOFT-DELETE missing keys (FULL / INIT whole-table; PARTITION scoped) */
    IF (v_load_type IN ('FULL', 'INIT', 'PARTITION')) THEN
        v_phase := 'SOFT_DELETE';
        -- PARTITION: restrict the delete sweep to the partitions present in this load.
        IF (v_load_type = 'PARTITION') THEN
            v_scope := 'AND "' || v_partition_col || '" IN (SELECT DISTINCT "' || v_partition_col ||
                       '" FROM ' || v_bronze_fq || ' WHERE PPN_ID = ' || v_ppn_id || ') ';
        END IF;
        v_sql := 'UPDATE ' || v_silver_fq || ' SET IS_DELETED = TRUE, DW_UPDATED_AT = CURRENT_TIMESTAMP() ' ||
                 'WHERE IS_DELETED = FALSE ' || v_scope ||
                 'AND PK_HK NOT IN (SELECT ' || v_pk_hk || ' FROM ' || v_bronze_fq || ' WHERE PPN_ID = ' || v_ppn_id || ')';
        v_last_sql := v_sql;
        EXECUTE IMMEDIATE v_sql;
        v_deleted := SQLROWCOUNT;
    END IF;

    /* 7. STATE + LOG SUCCESS ------------------------------------------- */
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_SET_PROCESS_STATE(:v_ppn_id, :v_source_id, :v_table, 'SUCCESS', 'LOAD_BRONZE_TO_SILVER',
                                  NULL, :v_merged, NULL, :v_deleted, NULL, NULL, TRUE);
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn_id,
        P_PHASE       => 'LOAD_BRONZE_TO_SILVER',
        P_STATUS      => 'SUCCESS',
        P_SOURCE_ID   => :v_source_id,
        P_TABLE_NAME  => :v_table,
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_SOURCE_OBJECT => :v_bronze_fq,
        P_TARGET_OBJECT => :v_silver_fq,
        P_ROW_COUNT   => :v_merged,
        P_MESSAGE     => 'SUCCESS: SILVER ' || :v_table || ' merged ' || :v_merged || ' row(s), soft-deleted ' || :v_deleted || ' (' || :v_load_type || ').',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_BRONZE_TO_SILVER','ppn_id',:v_ppn_id,'load_type',:v_load_type),
            'results', OBJECT_CONSTRUCT('rows_merged', :v_merged, 'rows_soft_deleted', :v_deleted)
        )::STRING
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_LOAD_BRONZE_TO_SILVER',
        'source_id', v_source_id,
        'table', v_table,
        'target_object', v_silver_fq,
        'load_type', v_load_type,
        'rows_merged', v_merged,
        'rows_soft_deleted', v_deleted,
        'ppn_id', v_ppn_id
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        BEGIN
            CALL ADM.SP_SET_PROCESS_STATE(:v_ppn_id, :v_source_id, :v_table, 'ERROR', :v_phase,
                                          NULL, NULL, NULL, NULL, NULL, :v_final_msg, TRUE);
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_ppn_id,
                P_PHASE       => 'LOAD_BRONZE_TO_SILVER',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR: SP_LOAD_BRONZE_TO_SILVER failed.',
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_LOAD_BRONZE_TO_SILVER',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'last_sql',         NULLIF(:v_last_sql, ''),
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_BRONZE_TO_SILVER','ppn_id',:v_ppn_id)
                )::STRING
            ) INTO :v_log_rows;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'procedure', 'SP_LOAD_BRONZE_TO_SILVER',
            'phase', v_phase,
            'message', v_final_msg,
            'last_sql', v_last_sql
        );
END;
