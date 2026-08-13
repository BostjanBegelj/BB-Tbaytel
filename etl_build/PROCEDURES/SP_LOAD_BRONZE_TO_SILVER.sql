-- ADM.SP_LOAD_BRONZE_TO_SILVER - load BRONZE.<table> (this PPN) into the cleansed
-- 1:1 SILVER.<table>, computing PK_HK + ROW_HK and applying IS_DELETED.
--   PK_HK  = MD5 of PK_COLUMNS  (or of ALL business cols when no PK is defined).
--   ROW_HK = MD5 of ALL business cols (change fingerprint / hashdiff).
--   Business cols = every BRONZE column except the technical ones: PPN_ID, PPN_TIMESTAMP, SRC_FILE_NAME.
-- LOAD_TYPE:
--   FULL / INIT : MERGE (insert new, update where ROW_HK differs, un-delete on reappear),
--                 then soft-delete SILVER keys absent from the snapshot (IS_DELETED=TRUE).
--   INCR        : MERGE only (partial feed can't detect deletes).
--   WATERMARK   : identical to INCR here - a watermark-bounded delta is still a partial feed,
--                 so deletes cannot be inferred. The watermark only bounds EXTRACTION (landing).
--   PARTITION   : same MERGE, but soft-delete is scoped to only the PARTITION_COLUMN
--                 values present in this load (untouched partitions are left alone).
-- Config-driven; same helpers + child-error pattern. RUN_ID resolved by SP_LOG_STEP.
-- Writes PPN_LOG only; PPN_PROCESS state is owned by SP_RUN_TABLE_LOAD.

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
    v_silver_existed NUMBER DEFAULT 0;
    v_txn_open      BOOLEAN DEFAULT FALSE;
    v_db            STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_bronze_fq   STRING;
    v_silver_fq   STRING;

    v_cols        STRING;   -- "A", "B", ...
    v_src_cols    STRING;   -- src."A", src."B", ...
    v_update_set  STRING;   -- tgt."A" = src."A", ...
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

    /* 2. READ CONFIG ---------------------------------------------------- */
    /*    Authoritative validation lives in SP_RUN_TABLE_LOAD; this only guards this
          procedure's own read (config removed mid-run / standalone call).            */
    v_phase := 'READ_CONFIG';
    SELECT COUNT(*), MAX(UPPER(COALESCE(t.target_schema, 'BRONZE'))), MAX(UPPER(t.load_type)),
           MAX(t.pk_columns), MAX(t.partition_column)
      INTO :v_cfg_count, :v_src_sch, :v_load_type, :v_pk_columns, :v_partition_col
      FROM ADM.ETL_TABLES t
      JOIN ADM.ETL_SOURCES s ON s.source_id = t.source_id
     WHERE t.source_id = :v_source_id
       AND t.table_name = :v_table
       AND t.active_flag
       AND s.active_flag;

    IF (v_cfg_count <> 1) THEN
        v_error_msg := 'Expected exactly 1 active config row for [' || v_source_id || '.' || v_table
                    || '] at SILVER time, found ' || v_cfg_count || ' (config changed mid-run?).';
        RAISE e_failed;
    END IF;

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
        LISTAGG('tgt."' || COLUMN_NAME || '" = src."' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
      INTO :v_col_count, :v_cols, :v_src_cols, :v_update_set
      FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = :v_src_sch
       AND TABLE_NAME = :v_table
       AND COLUMN_NAME NOT IN ('PPN_ID', 'PPN_TIMESTAMP', 'SRC_FILE_NAME');

    IF (v_col_count = 0) THEN
        v_error_msg := 'BRONZE table ' || v_bronze_fq || ' has no business columns (load BRONZE first).';
        RAISE e_failed;
    END IF;

    -- NULL-safe + delimiter-safe: JSON-serialize the column array before hashing.
    -- SQL NULL renders as `undefined` inside the array (NOT JSON null) - what matters is that
    -- it stays DISTINCT from an empty string; the array removes delimiter ambiguity.
    -- NOTE: intended for relational types. Do NOT reuse as-is for OBJECT/VARIANT values -
    -- JSON key order is not a stability contract, so those need canonicalising first.
    v_row_hk := 'MD5(TO_JSON(ARRAY_CONSTRUCT(' || v_cols || ')))';

    IF (v_pk_columns IS NOT NULL AND TRIM(v_pk_columns) <> '') THEN
        SELECT 'MD5(TO_JSON(ARRAY_CONSTRUCT(' ||
                 LISTAGG('"' || TRIM(VALUE) || '"', ', ') WITHIN GROUP (ORDER BY INDEX) || ')))'
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

    /* 4. ENSURE SILVER TABLE EXISTS (structure) -------------------------
          DDL — must run OUTSIDE the transaction below.
          The SILVER table cannot be created by SP_SYNC_TABLE_STRUCTURE (a LIKE of BRONZE would
          miss PK_HK / ROW_HK / IS_DELETED / DW_* ), so it is created here. Note existence FIRST,
          so a first-time creation still produces a structure-change log row - otherwise the sync
          below would find the table already present, report NOCHANGE, and the creation would go
          unlogged (BRONZE_HIST creation is logged because sync itself creates it).            */
    v_phase := 'CREATE_SILVER';
    SELECT COUNT(*) INTO :v_silver_existed
      FROM INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = 'SILVER' AND TABLE_NAME = :v_table;

    v_sql := 'CREATE TABLE IF NOT EXISTS ' || v_silver_fq || ' AS SELECT ' || v_cols || ', ' ||
             v_pk_hk || ' AS PK_HK, ' || v_row_hk || ' AS ROW_HK, FALSE AS IS_DELETED, ' ||
             'PPN_ID, PPN_TIMESTAMP, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(9) AS DW_INSERTED_AT, ' ||
             'CURRENT_TIMESTAMP()::TIMESTAMP_NTZ(9) AS DW_UPDATED_AT FROM ' || v_bronze_fq || ' WHERE 1=0';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    -- log the creation (same PHASE as sync-driven changes, so one query finds them all)
    IF (v_silver_existed = 0) THEN
        CALL ADM.SP_LOG_STEP(
            P_PPN_ID        => :v_ppn_id,
            P_PHASE         => 'SYNC_SILVER',
            P_STATUS        => 'SUCCESS',
            P_SOURCE_ID     => :v_source_id,
            P_TABLE_NAME    => :v_table,
            P_TARGET_OBJECT => :v_silver_fq,
            P_MESSAGE       => 'STRUCTURE CREATED on SILVER.' || :v_table || '.',
            P_DETAIL_JSON   => OBJECT_CONSTRUCT(
                'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_BRONZE_TO_SILVER','ppn_id',:v_ppn_id),
                'sync', OBJECT_CONSTRUCT('action','CREATED','table',:v_silver_fq,
                                         'note','created from BRONZE + PK_HK/ROW_HK/IS_DELETED/DW_* columns')
            )
        ) INTO :v_log_rows;
    END IF;

    /* 4b. RECONCILE SILVER STRUCTURE TO BRONZE business cols ------------ */
    v_phase := 'SYNC_SILVER';
    CALL ADM.SP_SYNC_TABLE_STRUCTURE(
        P_SOURCE_SCHEMA => :v_src_sch, P_TARGET_SCHEMA => 'SILVER',
        P_TABLE_NAME => :v_table, P_EXCLUDE_COLUMNS => 'SRC_FILE_NAME') INTO :v_sync;
    IF (GET(:v_sync, 'status')::STRING <> 'SUCCESS') THEN
        v_error_msg := 'Structure sync failed: ' || COALESCE(GET(:v_sync, 'message')::STRING, '(no message)');
        RAISE e_failed;
    END IF;
    -- audit structural changes only (CREATED / ALTERED); NOCHANGE stays quiet
    IF (GET(:v_sync, 'action')::STRING IN ('CREATED', 'ALTERED')) THEN
        CALL ADM.SP_LOG_STEP(
            P_PPN_ID        => :v_ppn_id,
            P_PHASE         => 'SYNC_SILVER',
            P_STATUS        => 'SUCCESS',
            P_SOURCE_ID     => :v_source_id,
            P_TABLE_NAME    => :v_table,
            P_TARGET_OBJECT => :v_silver_fq,
            P_MESSAGE       => 'STRUCTURE ' || GET(:v_sync, 'action')::STRING || ' on SILVER.' || :v_table || '.',
            P_DETAIL_JSON   => OBJECT_CONSTRUCT(
                'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_BRONZE_TO_SILVER','ppn_id',:v_ppn_id),
                'sync', :v_sync
            )
        ) INTO :v_log_rows;
    END IF;

    /* 5. MERGE + SOFT-DELETE (ATOMIC) ----------------------------------- */
    /*    One transaction: the merge and the soft-delete sweep are a single
          logical state change; a failure between them would leave SILVER with
          upserts applied but deletions unflagged. Procedures are NOT atomic by
          default in Snowflake, so the transaction is explicit.              */
    v_phase := 'SILVER_TXN';
    BEGIN TRANSACTION;
    v_txn_open := TRUE;

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

    COMMIT;
    v_txn_open := FALSE;

    /* 7. LOG SUCCESS (state is owned by SP_RUN_TABLE_LOAD) -------------- */
    v_phase := 'LOG_SUCCESS';
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
        )
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
        -- undo a half-applied SILVER change (merge without its delete sweep)
        IF (v_txn_open) THEN
            BEGIN
                ROLLBACK;
                v_txn_open := FALSE;
            EXCEPTION
                WHEN OTHER THEN NULL;
            END;
        END IF;
        BEGIN
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_ppn_id,
                P_PHASE       => 'LOAD_BRONZE_TO_SILVER',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR [SP_LOAD_BRONZE_TO_SILVER/' || :v_phase || ']: ' || :v_final_msg,
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
                )
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
