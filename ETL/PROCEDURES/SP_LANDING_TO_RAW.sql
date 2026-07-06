CREATE OR REPLACE PROCEDURE ADM.SP_LANDING_TO_RAW(
    P_TABLE     VARCHAR,
    P_FILE      VARCHAR,
    P_PPN_ID    NUMBER(38,0),
    P_RUN_ID    VARCHAR DEFAULT 'N/A',
    P_SOURCE_ID VARCHAR DEFAULT 'N/A',
    P_OTHER     VARCHAR DEFAULT NULL -- used for getting stage_name and file_format from JSON, e.g. {"stage_name":"@ADM.EXT_STAGE_ENDUR_SIM/", "file_format":"ADM.FILE_FORMAT_CSV_ENDUR_SIM"}
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Loads files from external stage to RAW.<table>. Does not load RAW_HIST.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20400, 'SP_LANDING_TO_RAW failed.');

    --v_stage_name  STRING DEFAULT '@ADM.EXT_STAGE_ENDUR_SIM/';
    --v_file_format STRING DEFAULT 'ADM.FILE_FORMAT_CSV_ENDUR_SIM';
    v_stage_name  STRING;
    v_file_format STRING;


    v_table       STRING DEFAULT UPPER(NULLIF(TRIM(P_TABLE), ''));
    v_file_regex  STRING DEFAULT NULLIF(TRIM(P_FILE), '');
    v_ppn_id      NUMBER DEFAULT P_PPN_ID;
    v_run_id      STRING DEFAULT COALESCE(NULLIF(TRIM(P_RUN_ID), ''), 'N/A');
    v_source_id   STRING DEFAULT COALESCE(NULLIF(TRIM(P_SOURCE_ID), ''), 'N/A');
    v_other          VARIANT DEFAULT TRY_PARSE_JSON(P_OTHER);

    v_db          STRING DEFAULT UPPER(CURRENT_DATABASE());
    v_target_fq   STRING;
    v_file_list   STRING;
    

    v_ppn_dt      TIMESTAMP_NTZ(9);
    v_ppn_count   NUMBER DEFAULT 0;

    v_phase       STRING DEFAULT 'INIT';
    v_started_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_last_sql    STRING DEFAULT '';
    v_error_msg   STRING;

    v_sql         STRING DEFAULT '';
    v_row_count   NUMBER DEFAULT 0;
    v_log_rows    NUMBER DEFAULT 0;
BEGIN
    v_target_fq := '"' || v_db || '"."RAW"."' || v_table || '"';

    /* ============================================================
       1. VALIDATE INPUT PARAMETERS
       ============================================================ */
    v_phase := 'VALIDATE';
    IF (v_table IS NULL OR v_file_regex IS NULL OR v_ppn_id IS NULL) THEN
        v_error_msg := 'P_TABLE, P_FILE and P_PPN_ID are required.';
        RAISE e_failed;
    END IF;

    IF (NOT REGEXP_LIKE(v_table, '^[A-Z][A-Z0-9_]*$')) THEN
        v_error_msg := 'Invalid P_TABLE [' || v_table || '].';
        RAISE e_failed;
    END IF;

    v_stage_name := NULLIF(TRIM(COALESCE(GET(v_other, 'stage_name')::STRING, '')), '');
    v_file_format := NULLIF(TRIM(COALESCE(GET(v_other, 'file_format')::STRING, '')), '');

    IF (v_stage_name IS NULL OR v_file_format IS NULL) THEN
        v_error_msg := 'P_OTHER must contain "stage_name" and "file_format" (received: ' || COALESCE(P_OTHER, 'NULL') || ')';
        RAISE e_failed;
    END IF;    

    /* ============================================================
       2. READ PPN CONTEXT
       ============================================================ */
    v_phase := 'GET_PPN';
    SELECT COUNT(*) INTO :v_ppn_count
    FROM ADM.PPN
    WHERE PPN_ID = :v_ppn_id;

    IF (v_ppn_count = 0) THEN
        v_error_msg := 'PPN_ID [' || TO_VARCHAR(v_ppn_id) || '] not found in ADM.PPN.';
        RAISE e_failed;
    END IF;

    SELECT PPN_DT INTO :v_ppn_dt
    FROM ADM.PPN
    WHERE PPN_ID = :v_ppn_id;

    /* ============================================================
       3. FIND MATCHING LANDING FILES
       ============================================================ */
    v_phase := 'FIND_FILES';
    v_sql := 'LIST ' || v_stage_name || ' PATTERN = ''' || REPLACE(v_file_regex, '\\', '\\\\') || '''';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    SELECT LISTAGG(CONCAT('''', SPLIT_PART("name", '/', -1), ''''), ',')
      INTO :v_file_list
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
    LIMIT 10;

    IF (v_file_list IS NULL OR v_file_list = '') THEN
        v_error_msg := 'No files found in ' || v_stage_name || ' matching pattern: ' || v_file_regex;
        RAISE e_failed;
    END IF;

    /* ============================================================
       4. CREATE RAW TABLE FROM INFERRED SCHEMA
       ============================================================ */
    v_phase := 'CREATE_RAW_TABLE';
    v_sql := '
        CREATE OR REPLACE TABLE ' || v_target_fq || '
        USING TEMPLATE (
            SELECT ARRAY_AGG(
                OBJECT_CONSTRUCT(
                    ''COLUMN_NAME'', REPLACE(REGEXP_REPLACE(COLUMN_NAME, ''["().]'', ''''), '' '', ''_''),
                    ''TYPE'', TYPE,
                    ''NULLABLE'', TRUE
                )
            )
            FROM TABLE(
                INFER_SCHEMA(
                    LOCATION=>''' || v_stage_name || ''',
                    FILES => (' || v_file_list || '),
                    FILE_FORMAT=>''' || v_file_format || ''',
                    IGNORE_CASE=>TRUE
                )
            )
        )
        ENABLE_SCHEMA_EVOLUTION = TRUE';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* ============================================================
       5. ADD TECHNICAL METADATA COLUMNS
       ============================================================ */
    v_phase := 'ADD_METADATA_COLUMNS';
    v_sql := 'ALTER TABLE ' || v_target_fq || ' ADD COLUMN IF NOT EXISTS ' ||
             'METADATA$FILENAME STRING, ' ||
             'METADATA$FILE_ROW_NUMBER NUMBER(18,0), ' ||
             'METADATA$FILE_CONTENT_KEY STRING, ' ||
             'METADATA$FILE_LAST_MODIFIED TIMESTAMP_NTZ(3), ' ||
             'METADATA$START_SCAN_TIME TIMESTAMP_LTZ(9), ' ||
             'PPN_ID NUMBER(38,0), ' ||
             'PPN_DT TIMESTAMP_NTZ(9)';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* ============================================================
       6. COPY DATA FROM STAGE
       ============================================================ */
    v_phase := 'COPY_DATA';
    v_sql := '
        COPY INTO ' || v_target_fq || '
        FROM ' || v_stage_name || '
        PATTERN = ''' || REPLACE(v_file_regex, '\\', '\\\\') || '''
        MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
        FILE_FORMAT = (FORMAT_NAME = ' || v_file_format || ')
        INCLUDE_METADATA = (
            METADATA$FILENAME = METADATA$FILENAME,
            METADATA$FILE_ROW_NUMBER = METADATA$FILE_ROW_NUMBER,
            METADATA$FILE_CONTENT_KEY = METADATA$FILE_CONTENT_KEY,
            METADATA$FILE_LAST_MODIFIED = METADATA$FILE_LAST_MODIFIED,
            METADATA$START_SCAN_TIME = METADATA$START_SCAN_TIME
        )';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* ============================================================
       7. UPDATE PPN TECHNICAL COLUMNS
       ============================================================ */
    v_phase := 'UPDATE_PPN_COLUMNS';
    v_sql := 'UPDATE ' || v_target_fq || '
              SET PPN_ID = ' || v_ppn_id || ',
                  PPN_DT = ''' || TO_CHAR(v_ppn_dt, 'YYYY-MM-DD HH24:MI:SS.FF9') || '''
              WHERE PPN_ID IS NULL';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* ============================================================
       8. COUNT LOADED ROWS
       ============================================================ */
    v_phase := 'COUNT_ROWS';
    SELECT COUNT(*) INTO :v_row_count
    FROM IDENTIFIER(:v_target_fq)
    WHERE PPN_ID = :v_ppn_id;

    /* ============================================================
       9. WRITE SUCCESS LOG
       ============================================================ */
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_WRITE_PPN_LOG(
        PPN_ID             => :v_ppn_id,
        SOURCE_ID          => :v_source_id,
        PPN_PHASE          => 'LOAD FROM LANDING TO RAW',
        LOG_START          => :v_started_at,
        LOG_END            => CURRENT_TIMESTAMP(),
        DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, CURRENT_TIMESTAMP()),
        LOG_STATUS         => 'SUCCESS',
        SOURCE_OBJECT      => :v_stage_name,
        TARGET_OBJECT      => :v_target_fq,
        ROW_COUNT          => :v_row_count,
        LOG_MESSAGE        => 'SUCCESS: Loaded data from LANDING to RAW.',
        LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
            'procedure', 'SP_LANDING_TO_RAW',
            'table', :v_table,
            'file_pattern', :v_file_regex,
            'files_used_for_infer_schema', :v_file_list,
            'last_sql', :v_last_sql
        )::STRING,
        RUN_ID             => :v_run_id
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_LANDING_TO_RAW',
        'table', v_table,
        'target_object', v_target_fq,
        'rows_loaded', v_row_count,
        'ppn_id', v_ppn_id
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
                    PPN_PHASE          => 'LOAD FROM LANDING TO RAW',
                    LOG_START          => :v_started_at,
                    LOG_END            => :v_end_ts,
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, :v_end_ts),
                    LOG_STATUS         => 'ERROR',
                    SOURCE_OBJECT      => :v_stage_name,
                    TARGET_OBJECT      => :v_target_fq,
                    ROW_COUNT          => NULL,
                    LOG_MESSAGE        => 'ERROR: Failed to load data from LANDING to RAW.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_LANDING_TO_RAW',
                        'failed_phase', :v_phase,
                        'error_message', :v_final_msg,
                        'sqlcode', :SQLCODE,
                        'sqlstate', :SQLSTATE,
                        'sqlerrm', :SQLERRM,
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
            'procedure', 'SP_LANDING_TO_RAW',
            'phase', v_phase,
            'message', v_final_msg,
            'sqlcode', SQLCODE,
            'sqlstate', SQLSTATE,
            'last_sql', v_last_sql
        );
END;
