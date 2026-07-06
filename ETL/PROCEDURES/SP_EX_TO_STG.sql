CREATE OR REPLACE PROCEDURE ADM.SP_EX_TO_STG(
    "P_PPN_ID"    NUMBER(38,0),
    "P_TABLE"     VARCHAR,
    "P_LOAD_TYPE" VARCHAR,
    "P_OTHER"     VARCHAR DEFAULT NULL, -- used for getting pk and  partition_column from JSON, exemple: {"pk":"ID, CO_ID", "partition_column":"VALUE_DATE"}
    "P_RUN_ID"    VARCHAR DEFAULT 'N/A',
    "P_SOURCE_ID" VARCHAR DEFAULT 'N/A'
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Loads EX.<table> into STG.<table>. Logs SYNC STRUCTURES plus load SUCCESS/ERROR. Sync result is stored in LOG_MESSAGE_DETAIL.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20300, 'SP_EX_TO_STG failed.');

    v_ppn_id       NUMBER DEFAULT P_PPN_ID;
    v_table        STRING DEFAULT UPPER(NULLIF(TRIM(P_TABLE), ''));
    v_load_type    STRING DEFAULT UPPER(COALESCE(NULLIF(TRIM(P_LOAD_TYPE), ''), 'FULL'));
    v_other        VARIANT DEFAULT TRY_PARSE_JSON(P_OTHER);
    v_source_id    STRING DEFAULT COALESCE(NULLIF(TRIM(P_SOURCE_ID), ''), 'N/A');
    v_run_id       STRING DEFAULT COALESCE(NULLIF(TRIM(P_RUN_ID), ''), 'N/A');

    v_db           STRING DEFAULT UPPER(CURRENT_DATABASE());
    v_source_fq    STRING;
    v_target_fq    STRING;

    v_pk           STRING;
    v_pk_cols_expr STRING;
    v_part_col     STRING;
    v_part_col_q   STRING;
    v_pk_hk_expr   STRING;
    v_hash_exclude STRING;

    v_source_cols  STRING;
    v_target_cols  STRING;
    v_select_exprs STRING;

    v_phase        STRING DEFAULT 'INIT';
    v_started_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_last_sql     STRING DEFAULT '';
    v_error_msg    STRING;

    v_sync_result        VARIANT;
    v_sync_status        STRING;
    v_sync_log_status    STRING;
    v_sync_change_count  NUMBER DEFAULT 0;
    v_sync_started_at    TIMESTAMP_NTZ(9);
    v_sync_ended_at      TIMESTAMP_NTZ(9);

    v_deleted      NUMBER DEFAULT 0;
    v_inserted     NUMBER DEFAULT 0;
    v_log_rows     NUMBER DEFAULT 0;
BEGIN
    v_source_fq := '"' || v_db || '"."EX"."'  || v_table || '"';
    v_target_fq := '"' || v_db || '"."STG"."' || v_table || '"';

    /* ============================================================
       1. VALIDATE INPUT PARAMETERS
       ============================================================ */
    v_phase := 'VALIDATE';
    IF (v_ppn_id IS NULL OR v_table IS NULL OR v_load_type IS NULL) THEN
        v_error_msg := 'P_PPN_ID, P_TABLE and P_LOAD_TYPE are required.';
        RAISE e_failed;
    END IF;

    IF (NOT REGEXP_LIKE(v_table, '^[A-Z][A-Z0-9_]*$')) THEN
        v_error_msg := 'Invalid P_TABLE [' || v_table || '].';
        RAISE e_failed;
    END IF;

    IF (v_load_type NOT IN ('FULL', 'INIT', 'INCR', 'PARTITION')) THEN
        v_error_msg := 'Unsupported P_LOAD_TYPE [' || v_load_type || ']. Expected FULL, INIT, INCR or PARTITION.';
        RAISE e_failed;
    END IF;

    IF (P_OTHER IS NOT NULL AND v_other IS NULL) THEN
        v_error_msg := 'P_OTHER must be valid JSON when provided.';
        RAISE e_failed;
    END IF;

    v_pk       := NULLIF(TRIM(COALESCE(GET(v_other, 'pk')::STRING, '')), '');
    v_part_col := UPPER(NULLIF(TRIM(COALESCE(GET(v_other, 'partition_column')::STRING, '')), ''));

    IF (v_load_type = 'PARTITION' AND v_part_col IS NULL) THEN
        v_error_msg := 'partition_column is required in P_OTHER for PARTITION load.';
        RAISE e_failed;
    END IF;

    IF (v_pk IS NOT NULL AND NOT REGEXP_LIKE(v_pk, '^[A-Za-z_][A-Za-z0-9_]*(\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*$')) THEN
        v_error_msg := 'P_OTHER.pk must be a comma-separated list of simple column names.';
        RAISE e_failed;
    END IF;

    IF (v_part_col IS NOT NULL AND NOT REGEXP_LIKE(v_part_col, '^[A-Z][A-Z0-9_]*$')) THEN
        v_error_msg := 'partition_column must be a simple column name.';
        RAISE e_failed;
    END IF;

    IF (v_pk IS NOT NULL) THEN
        v_pk_cols_expr := '"' || REPLACE(REGEXP_REPLACE(UPPER(v_pk), '\s*,\s*', ','), ',', '","') || '"';
        v_pk_hk_expr   := 'TO_VARCHAR(MD5_NUMBER_LOWER64(CONCAT_WS(''|'', ' || v_pk_cols_expr || ')))';
    ELSE
        /* ------------------------------------------------------------
           FIX: Fallback hash key must NOT include file-load metadata.
           Metadata columns (METADATA$FILENAME, METADATA$FILE_ROW_NUMBER,
           METADATA$FILE_CONTENT_KEY, METADATA$FILE_LAST_MODIFIED,
           METADATA$START_SCAN_TIME, ...) change on every load. Including
           them made PK_HK effectively row-unique and broke INCR
           de-duplication (unchanged rows arriving in a new file no longer
           matched and accumulated as duplicates).

           The exclude list is built dynamically from columns that actually
           exist in the source, so "* EXCLUDE (...)" never references a
           missing identifier (important in RAW mode where EX may be a view).
           PPN_ID / PPN_DT / PK_HK are always excluded; any column named
           METADATA$... or METADATA_... is excluded as well.
           ------------------------------------------------------------ */
        SELECT LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
          INTO :v_hash_exclude
          FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_CATALOG = :v_db
           AND TABLE_SCHEMA  = 'EX'
           AND TABLE_NAME    = :v_table
           AND (
                    UPPER(COLUMN_NAME) IN ('PPN_ID', 'PPN_DT', 'PK_HK')
                 OR REGEXP_LIKE(UPPER(COLUMN_NAME), '^METADATA[$_].*$')
               );

        v_hash_exclude := COALESCE(NULLIF(TRIM(v_hash_exclude), ''), 'PPN_ID, PPN_DT');

        v_pk_hk_expr := 'TO_VARCHAR(MD5_NUMBER_LOWER64(TO_VARCHAR(' ||
                        'OBJECT_CONSTRUCT_KEEP_NULL(* EXCLUDE (' || v_hash_exclude || ')))))';
    END IF;

    IF (v_part_col IS NOT NULL) THEN
        v_part_col_q := '"' || v_part_col || '"';
    END IF;

    /* ============================================================
       2. SYNCHRONIZE STAGING TABLE STRUCTURE AND PRIMARY KEY
       - SP_SYNC_TABLE_STRUCTURE remains a helper procedure.
       - This caller writes one dedicated SYNC STRUCTURES log row,
         similar to the DATA COMPARE logging in SP_RUN_LANDING_TO_STG.
       ============================================================ */
    v_phase := 'SYNC_TABLE_STRUCTURE';
    v_sync_started_at := CURRENT_TIMESTAMP();

    CALL ADM.SP_SYNC_TABLE_STRUCTURE(
        P_TABLE                 => :v_table,
        P_SOURCE_SCHEMA         => 'EX',
        P_TARGET_SCHEMA         => 'STG',
        P_HK => TRUE
    ) INTO :v_sync_result;

    v_sync_ended_at := CURRENT_TIMESTAMP();

    v_sync_status := UPPER(COALESCE(GET(v_sync_result, 'status')::STRING, 'ERROR'));

    IF (v_sync_status = 'ERROR') THEN
        v_error_msg := 'Structure sync failed: ' || COALESCE(v_sync_result::STRING, '(no detail)');
        RAISE e_failed;
    END IF;

    v_sync_change_count :=
          COALESCE(GET(v_sync_result, 'columns_added')::NUMBER, 0)
        + COALESCE(GET(v_sync_result, 'columns_altered')::NUMBER, 0)
        + COALESCE(GET(v_sync_result, 'pk_hk_added')::NUMBER, 0)
        + COALESCE(GET(v_sync_result, 'pk_hk_altered')::NUMBER, 0);

    v_sync_log_status := IFF(
        COALESCE(GET(v_sync_result, 'target_created')::BOOLEAN, FALSE),
        'CREATE',
        IFF(v_sync_change_count > 0, 'ALTER', 'SUCCESS')
    );

    CALL ADM.SP_WRITE_PPN_LOG(
        PPN_ID             => :v_ppn_id,
        SOURCE_ID          => :v_source_id,
        PPN_PHASE          => 'SYNC STRUCTURES',
        LOG_START          => :v_sync_started_at,
        LOG_END            => :v_sync_ended_at,
        DURATION_MSEC      => DATEDIFF(millisecond, :v_sync_started_at, :v_sync_ended_at),
        LOG_STATUS         => :v_sync_log_status,
        SOURCE_OBJECT      => :v_source_fq,
        TARGET_OBJECT      => :v_target_fq,
        ROW_COUNT          => :v_sync_change_count,
        LOG_MESSAGE        => :v_sync_log_status || ': Structure sync completed from EX to STG.',
        LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
            'procedure', 'SP_EX_TO_STG',
            'sync_procedure', 'SP_SYNC_TABLE_STRUCTURE',
            'sync_scope', 'EX_TO_STG',
            'table', :v_table,
            'source_schema', 'EX',
            'target_schema', 'STG',
            'sync_log_status', :v_sync_log_status,
            'sync_change_count', :v_sync_change_count,
            'sync_result', :v_sync_result
        )::STRING,
        RUN_ID             => :v_run_id
    ) INTO :v_log_rows;

    /* ============================================================
       3. BUILD SOURCE / TARGET COLUMN LIST
       ============================================================ */
    v_phase := 'BUILD_COLUMN_LIST';
    SELECT LISTAGG('"' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
      INTO :v_source_cols
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_CATALOG = :v_db
      AND TABLE_SCHEMA  = 'EX'
      AND TABLE_NAME    = :v_table
      AND UPPER(COLUMN_NAME) <> 'PK_HK';

    IF (v_source_cols IS NULL OR TRIM(v_source_cols) = '') THEN
        v_error_msg := 'No source columns found for ' || v_source_fq || '.';
        RAISE e_failed;
    END IF;

    v_target_cols  := v_source_cols || ', "PK_HK"';
    v_select_exprs := v_source_cols || ', ' || v_pk_hk_expr || ' AS "PK_HK"';

    IF (v_load_type IN ('FULL', 'INIT')) THEN
        /* ============================================================
           4. TRUNCATE TARGET TABLE FOR FULL LOAD
           ============================================================ */
        v_phase := 'TRUNCATE_TARGET';
        v_last_sql := 'TRUNCATE TABLE ' || v_target_fq;
        EXECUTE IMMEDIATE v_last_sql;

    ELSEIF (v_load_type = 'INCR') THEN
        /* ============================================================
           5. DELETE MATCHING TARGET KEYS FOR INCREMENTAL LOAD
           ============================================================ */
        v_phase := 'DELETE_INCREMENTAL_KEYS';
        v_last_sql := 'DELETE FROM ' || v_target_fq || ' tgt ' ||
                      'USING (SELECT DISTINCT ' || v_pk_hk_expr || ' AS PK_HK FROM ' || v_source_fq || ') src ' ||
                      'WHERE tgt."PK_HK" = src.PK_HK';
        EXECUTE IMMEDIATE v_last_sql;
        v_deleted := SQLROWCOUNT;

    ELSEIF (v_load_type = 'PARTITION') THEN
        /* ============================================================
           6. DELETE TARGET PARTITIONS
           ============================================================ */
        v_phase := 'DELETE_PARTITIONS';
        v_last_sql := 'DELETE FROM ' || v_target_fq ||
                      ' WHERE ' || v_part_col_q || ' IN (SELECT DISTINCT ' || v_part_col_q || ' FROM ' || v_source_fq || ')';
        EXECUTE IMMEDIATE v_last_sql;
        v_deleted := SQLROWCOUNT;
    END IF;

    /* ============================================================
       7. INSERT INTO STAGING TABLE
       ============================================================ */
    v_phase := 'INSERT_TO_STG';
    v_last_sql := 'INSERT INTO ' || v_target_fq || ' (' || v_target_cols || ') ' ||
                  'SELECT ' || v_select_exprs || ' FROM ' || v_source_fq;
    EXECUTE IMMEDIATE v_last_sql;
    v_inserted := SQLROWCOUNT;

    /* ============================================================
       8. WRITE SUCCESS LOG
       ============================================================ */
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_WRITE_PPN_LOG(
        PPN_ID             => :v_ppn_id,
        SOURCE_ID          => :v_source_id,
        PPN_PHASE          => 'LOAD FROM EX TO STG',
        LOG_START          => :v_started_at,
        LOG_END            => CURRENT_TIMESTAMP(),
        DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, CURRENT_TIMESTAMP()),
        LOG_STATUS         => 'SUCCESS',
        SOURCE_OBJECT      => :v_source_fq,
        TARGET_OBJECT      => :v_target_fq,
        ROW_COUNT          => :v_inserted,
        LOG_MESSAGE        => 'SUCCESS: Loaded data from EX to STG.',
        LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
            'procedure', 'SP_EX_TO_STG',
            'load_type', :v_load_type,
            'rows_deleted', :v_deleted,
            'rows_inserted', :v_inserted,
            'pk', :v_pk,
            'pk_hk_uses_metadata', FALSE,
            'hash_exclude', :v_hash_exclude,
            'partition_column', :v_part_col,
            'sync_result', :v_sync_result,
            'last_sql', :v_last_sql
        )::STRING,
        RUN_ID             => :v_run_id
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_EX_TO_STG',
        'source_object', v_source_fq,
        'target_object', v_target_fq,
        'load_type', v_load_type,
        'rows_deleted', v_deleted,
        'rows_inserted', v_inserted,
        'sync_result', v_sync_result
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_end_ts    TIMESTAMP_NTZ := CURRENT_TIMESTAMP();
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);

        BEGIN
            IF (v_ppn_id IS NOT NULL) THEN
                CALL ADM.SP_WRITE_PPN_LOG(
                    PPN_ID             => :v_ppn_id,
                    SOURCE_ID          => :v_source_id,
                    PPN_PHASE          => 'LOAD FROM EX TO STG',
                    LOG_START          => :v_started_at,
                    LOG_END            => :v_end_ts,
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, :v_end_ts),
                    LOG_STATUS         => 'ERROR',
                    SOURCE_OBJECT      => :v_source_fq,
                    TARGET_OBJECT      => :v_target_fq,
                    ROW_COUNT          => NULL,
                    LOG_MESSAGE        => 'ERROR: Failed to load data from EX to STG.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_EX_TO_STG',
                        'failed_phase', :v_phase,
                        'error_message', :v_final_msg,
                        'sqlcode', :SQLCODE,
                        'sqlstate', :SQLSTATE,
                        'sqlerrm', :SQLERRM,
                        'load_type', :v_load_type,
                        'rows_deleted', :v_deleted,
                        'rows_inserted', :v_inserted,
                        'sync_result', :v_sync_result,
                        'last_sql', :v_last_sql
                    )::STRING,
                    RUN_ID             => :v_run_id
                ) INTO :v_log_rows;
            END IF;
        EXCEPTION
            WHEN OTHER THEN
                NULL;
        END;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'procedure', 'SP_EX_TO_STG',
            'phase', v_phase,
            'message', v_final_msg,
            'sqlcode', SQLCODE,
            'sqlstate', SQLSTATE,
            'load_type', v_load_type,
            'rows_deleted', v_deleted,
            'rows_inserted', v_inserted,
            'sync_result', v_sync_result,
            'last_sql', v_last_sql
        );
END;
