/* ================================================================
   SP_LOAD_TO_HIST — only LOG_MESSAGE_DETAIL content reorganized.
   Envelope: ERROR / context / results (ERROR always renders first).
   Sync failure no longer concatenates the sync JSON into the message
   string; the short message is lifted and sync_result stays a proper
   nested object under results.
   ================================================================ */
CREATE OR REPLACE PROCEDURE ADM.SP_LOAD_TO_HIST(
    "P_PPN_ID"        NUMBER(38,0),
    "P_TABLE"         VARCHAR,
    "P_SOURCE_SCHEMA" VARCHAR,
    "P_SOURCE_ID"     VARCHAR DEFAULT 'N/A',
    "P_RUN_ID"        VARCHAR DEFAULT 'N/A'
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Loads <schema>.<table> into <schema>_HIST.<table>. Idempotent per PPN_ID: existing target rows for the same PPN_ID are deleted before insert. Logs SYNC STRUCTURES plus load SUCCESS/ERROR. Sync result is stored in LOG_MESSAGE_DETAIL.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20100, 'SP_LOAD_TO_HIST failed.');

    v_ppn_id        NUMBER DEFAULT P_PPN_ID;
    v_table         STRING DEFAULT UPPER(NULLIF(TRIM(P_TABLE), ''));
    v_source_schema STRING DEFAULT UPPER(NULLIF(TRIM(P_SOURCE_SCHEMA), ''));
    v_target_schema STRING DEFAULT UPPER(NULLIF(TRIM(P_SOURCE_SCHEMA), '')) || '_HIST';
    v_source_id     STRING DEFAULT COALESCE(NULLIF(TRIM(P_SOURCE_ID), ''), 'N/A');
    v_run_id        STRING DEFAULT COALESCE(NULLIF(TRIM(P_RUN_ID), ''), 'N/A');

    v_db            STRING DEFAULT UPPER(CURRENT_DATABASE());
    v_source_fq     STRING;
    v_target_fq     STRING;
    v_ppn_phase     STRING;

    v_phase         STRING DEFAULT 'INIT';
    v_started_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_last_sql      STRING DEFAULT '';
    v_error_msg     STRING;
    v_col_list      STRING;
    v_deleted       NUMBER DEFAULT 0;
    v_row_count     NUMBER DEFAULT 0;
    v_log_rows      NUMBER DEFAULT 0;

    v_sync_result        VARIANT;
    v_sync_status        STRING;
    v_sync_log_status    STRING;
    v_sync_change_count  NUMBER DEFAULT 0;
    v_sync_started_at    TIMESTAMP_NTZ(9);
    v_sync_ended_at      TIMESTAMP_NTZ(9);
BEGIN
    v_source_fq := '"' || v_db || '"."' || v_source_schema || '"."' || v_table || '"';
    v_target_fq := '"' || v_db || '"."' || v_target_schema || '"."' || v_table || '"';
    v_ppn_phase := 'LOAD FROM ' || v_source_schema || ' TO ' || v_target_schema;

    /* ============================================================
       1. VALIDATE INPUT PARAMETERS
       ============================================================ */
    v_phase := 'VALIDATE';
    IF (v_ppn_id IS NULL OR v_table IS NULL OR v_source_schema IS NULL) THEN
        v_error_msg := 'P_PPN_ID, P_TABLE and P_SOURCE_SCHEMA are required.';
        RAISE e_failed;
    END IF;

    IF (
        NOT REGEXP_LIKE(v_table, '^[A-Z][A-Z0-9_]*$')
        OR NOT REGEXP_LIKE(v_source_schema, '^[A-Z][A-Z0-9_]*$')
    ) THEN
        v_error_msg := 'Only simple unquoted identifiers are supported.';
        RAISE e_failed;
    END IF;

    /* ============================================================
       2. SYNCHRONIZE HISTORY TABLE STRUCTURE
       - SP_SYNC_TABLE_STRUCTURE remains a helper procedure.
       - This caller writes one dedicated SYNC STRUCTURES log row,
         similar to the DATA COMPARE logging in SP_RUN_LANDING_TO_STG.
       ============================================================ */
    v_phase := 'SYNC_TABLE_STRUCTURE';
    v_sync_started_at := CURRENT_TIMESTAMP();

    CALL ADM.SP_SYNC_TABLE_STRUCTURE(
        P_TABLE                 => :v_table,
        P_SOURCE_SCHEMA         => :v_source_schema,
        P_TARGET_SCHEMA         => :v_target_schema,
        P_HK => FALSE
    ) INTO :v_sync_result;

    v_sync_ended_at := CURRENT_TIMESTAMP();

    v_sync_status := UPPER(COALESCE(GET(v_sync_result, 'status')::STRING, 'ERROR'));

    IF (v_sync_status = 'ERROR') THEN
        -- Short, human-readable message; full sync_result is logged as a
        -- proper nested object in the ERROR log below (no JSON-in-string).
        v_error_msg := 'SP_SYNC_TABLE_STRUCTURE failed in phase [' ||
                       COALESCE(GET(v_sync_result, 'phase')::STRING, 'UNKNOWN') || ']: ' ||
                       COALESCE(GET(v_sync_result, 'message')::STRING, '(no detail)');
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
        LOG_MESSAGE        => :v_sync_log_status || ': Structure sync completed from ' || :v_source_schema || ' to ' || :v_target_schema || '.',
        LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT(
                'procedure', 'SP_LOAD_TO_HIST',
                'sync_procedure', 'SP_SYNC_TABLE_STRUCTURE',
                'sync_scope', :v_source_schema || '_TO_' || :v_target_schema,
                'table', :v_table,
                'source_schema', :v_source_schema,
                'target_schema', :v_target_schema,
                'ppn_id', :v_ppn_id,
                'run_id', :v_run_id
            ),
            'results', OBJECT_CONSTRUCT(
                'sync_log_status', :v_sync_log_status,
                'sync_change_count', :v_sync_change_count,
                'sync_result', :v_sync_result
            )
        )::STRING,
        RUN_ID             => :v_run_id
    ) INTO :v_log_rows;

    /* ============================================================
       3. BUILD SOURCE / TARGET COLUMN LIST
       ============================================================ */
    v_phase := 'BUILD_COLUMN_LIST';
    SELECT LISTAGG('"' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
      INTO :v_col_list
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_CATALOG = :v_db
      AND TABLE_SCHEMA  = :v_source_schema
      AND TABLE_NAME    = :v_table
      AND UPPER(COLUMN_NAME) <> 'PK_HK';

    IF (v_col_list IS NULL OR TRIM(v_col_list) = '') THEN
        v_error_msg := 'No source columns found for ' || v_source_fq || '.';
        RAISE e_failed;
    END IF;

    /* ============================================================
       4. DELETE EXISTING TARGET ROWS FOR THIS PPN_ID (IDEMPOTENT)
       - Makes the load safe to re-run for the same PPN_ID without
         duplicating history (e.g. SP_RERUN_RAW_HIST_TO_STG replaying
         PPNs that already exist in *_HIST).
       - If the target was just created by the sync step this deletes
         0 rows.
       ============================================================ */
    v_phase := 'DELETE_EXISTING_PPN';
    v_last_sql := 'DELETE FROM ' || v_target_fq || ' WHERE PPN_ID = ' || v_ppn_id;
    EXECUTE IMMEDIATE v_last_sql;
    v_deleted := SQLROWCOUNT;

    /* ============================================================
       5. INSERT INTO HISTORY TABLE
       ============================================================ */
    v_phase := 'INSERT_TO_HIST';
    v_last_sql := 'INSERT INTO ' || v_target_fq || ' (' || v_col_list || ') SELECT ' || v_col_list || ' FROM ' || v_source_fq;
    EXECUTE IMMEDIATE v_last_sql;
    v_row_count := SQLROWCOUNT;

    /* ============================================================
       6. WRITE SUCCESS LOG
       ============================================================ */
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_WRITE_PPN_LOG(
        PPN_ID             => :v_ppn_id,
        SOURCE_ID          => :v_source_id,
        PPN_PHASE          => :v_ppn_phase,
        LOG_START          => :v_started_at,
        LOG_END            => CURRENT_TIMESTAMP(),
        DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, CURRENT_TIMESTAMP()),
        LOG_STATUS         => 'SUCCESS',
        SOURCE_OBJECT      => :v_source_fq,
        TARGET_OBJECT      => :v_target_fq,
        ROW_COUNT          => :v_row_count,
        LOG_MESSAGE        => 'SUCCESS: Loaded data from ' || :v_source_schema || ' to ' || :v_target_schema || '.',
        LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT(
                'procedure', 'SP_LOAD_TO_HIST',
                'table', :v_table,
                'source_schema', :v_source_schema,
                'target_schema', :v_target_schema,
                'ppn_id', :v_ppn_id,
                'run_id', :v_run_id
            ),
            'results', OBJECT_CONSTRUCT(
                'rows_deleted', :v_deleted,
                'rows_inserted', :v_row_count,
                'sync_result', :v_sync_result,
                'last_sql', :v_last_sql
            )
        )::STRING,
        RUN_ID             => :v_run_id
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_LOAD_TO_HIST',
        'phase', v_ppn_phase,
        'source_object', v_source_fq,
        'target_object', v_target_fq,
        'rows_deleted', v_deleted,
        'rows_inserted', v_row_count,
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
                    PPN_PHASE          => :v_ppn_phase,
                    LOG_START          => :v_started_at,
                    LOG_END            => :v_end_ts,
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, :v_end_ts),
                    LOG_STATUS         => 'ERROR',
                    SOURCE_OBJECT      => :v_source_fq,
                    TARGET_OBJECT      => :v_target_fq,
                    ROW_COUNT          => NULL,
                    LOG_MESSAGE        => 'ERROR: Failed to load data from ' || :v_source_schema || ' to ' || :v_target_schema || '.',
                    /* ERROR block renders first in the stored JSON. */
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'ERROR', OBJECT_CONSTRUCT(
                            'source_procedure', 'SP_LOAD_TO_HIST',
                            'source_phase', :v_phase,
                            'message', :v_final_msg,
                            'sqlcode', IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                            'sqlstate', IFF(:v_error_msg IS NULL, :SQLSTATE, NULL),
                            'last_sql', NULLIF(:v_last_sql, '')
                        ),
                        'context', OBJECT_CONSTRUCT(
                            'procedure', 'SP_LOAD_TO_HIST',
                            'table', :v_table,
                            'source_schema', :v_source_schema,
                            'target_schema', :v_target_schema,
                            'ppn_id', :v_ppn_id,
                            'run_id', :v_run_id
                        ),
                        'results', OBJECT_CONSTRUCT(
                            'rows_deleted', :v_deleted,
                            'sync_result', :v_sync_result
                        )
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
            'procedure', 'SP_LOAD_TO_HIST',
            'phase', v_phase,
            'message', v_final_msg,
            'sqlcode', SQLCODE,
            'sqlstate', SQLSTATE,
            'rows_deleted', v_deleted,
            'sync_result', v_sync_result,
            'last_sql', v_last_sql
        );
END;
