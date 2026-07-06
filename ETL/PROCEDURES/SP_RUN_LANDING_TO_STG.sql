CREATE OR REPLACE PROCEDURE ADM.SP_RUN_LANDING_TO_STG(
    "P_PPN_ID"    NUMBER(38,0),
    "P_TABLE"     VARCHAR,
    "P_FILE"      VARCHAR,
    "P_LOAD_TYPE" VARCHAR DEFAULT 'FULL',
    "P_RAW"       BOOLEAN DEFAULT FALSE,
    "P_RUN_ID"    VARCHAR DEFAULT NULL,
    "P_SOURCE_ID" VARCHAR DEFAULT NULL,
    "P_OTHER"     VARCHAR DEFAULT NULL
    -- P_OTHER is used for getting pk and partition_column used in SP_EX_TO_STG,
    -- and stage_name and file_format used in SP_LANDING_TO_RAW and SP_LANDING_TO_EX.
    -- Example:
    -- {"pk":"ID, CO_ID", "partition_column":"VALUE_DATE", "stage_name":"@ADM.EXT_STAGE_ENDUR_SIM/", "file_format":"ADM.FILE_FORMAT_CSV_ENDUR_SIM"}
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Main ETL wrapper: landing -> RAW/EX -> HIST -> STG. Logs START/END/ERROR for overall process. Skips further processing when a new import is identical to the previous load.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20200, 'SP_RUN_LANDING_TO_STG failed.');

    v_ppn_id             NUMBER DEFAULT P_PPN_ID;
    v_table              STRING DEFAULT UPPER(NULLIF(TRIM(P_TABLE), ''));
    v_file               STRING DEFAULT NULLIF(TRIM(P_FILE), '');
    v_load_type          STRING DEFAULT UPPER(COALESCE(NULLIF(TRIM(P_LOAD_TYPE), ''), 'FULL'));
    v_raw                BOOLEAN DEFAULT COALESCE(P_RAW, FALSE);
    v_other              VARIANT DEFAULT TRY_PARSE_JSON(P_OTHER);
    v_source_id          STRING DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_run_id             STRING DEFAULT COALESCE(NULLIF(TRIM(P_RUN_ID), ''), REPLACE(UUID_STRING(), '-', ''));

    v_ppn_dt             TIMESTAMP_NTZ(9);
    v_ppn_count          NUMBER DEFAULT 0;
    v_ex_count           NUMBER DEFAULT 0;

    v_phase              STRING DEFAULT 'INIT';
    v_started_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_error_msg          STRING;
    v_log_rows           NUMBER DEFAULT 0;

    v_landing_result     VARIANT;
    v_raw_hist_result    VARIANT;
    v_ex_hist_result     VARIANT;
    v_stg_result         VARIANT;

    v_compare_result     VARIANT;
    v_compare_status     STRING;
    v_compare_action     STRING;
    v_compare_message    STRING;
    v_compare_identical  BOOLEAN DEFAULT FALSE;
    v_compare_no_prev    BOOLEAN DEFAULT FALSE;
    v_rows_compared      NUMBER DEFAULT 0;
    v_compare_started_at TIMESTAMP_NTZ(9);
    v_compare_ended_at   TIMESTAMP_NTZ(9);

BEGIN
    /* ============================================================
       1. VALIDATE INPUT PARAMETERS
       ============================================================ */
    v_phase := 'VALIDATE';

    IF (v_ppn_id IS NULL) THEN
        v_error_msg := 'P_PPN_ID is required.';
        RAISE e_failed;
    END IF;

    IF (v_source_id IS NULL) THEN
        v_error_msg := 'P_SOURCE_ID is required.';
        RAISE e_failed;
    END IF;

    IF (v_table IS NULL OR v_file IS NULL) THEN
        v_error_msg := 'P_TABLE and P_FILE are required.';
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


    /* ============================================================
       2. READ PPN CONTEXT
       ============================================================ */
    v_phase := 'GET_PPN';

    SELECT COUNT(*)
      INTO :v_ppn_count
      FROM ADM.PPN
     WHERE PPN_ID = :v_ppn_id;

    IF (v_ppn_count = 0) THEN
        v_error_msg := 'PPN_ID [' || TO_VARCHAR(v_ppn_id) || '] not found in ADM.PPN.';
        RAISE e_failed;
    END IF;

    SELECT PPN_DT
      INTO :v_ppn_dt
      FROM ADM.PPN
     WHERE PPN_ID = :v_ppn_id;


    /* ============================================================
       3. WRITE PROCESS START LOG
       ============================================================ */
    v_phase := 'PROCESS START';

    CALL ADM.SP_WRITE_PPN_LOG(
        PPN_ID             => :v_ppn_id,
        SOURCE_ID          => :v_source_id,
        PPN_PHASE          => 'PROCESS START',
        LOG_START          => :v_started_at,
        LOG_END            => CURRENT_TIMESTAMP(),
        DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, CURRENT_TIMESTAMP()),
        LOG_STATUS         => 'START',
        SOURCE_OBJECT      => :v_file,
        TARGET_OBJECT      => 'STG.' || :v_table,
        ROW_COUNT          => 0,
        LOG_MESSAGE        => 'START: ETL process started.',
        LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
            'procedure', 'SP_RUN_LANDING_TO_STG',
            'table', :v_table,
            'file', :v_file,
            'load_type', :v_load_type,
            'raw_mode', :v_raw,
            'ppn_id', :v_ppn_id,
            'ppn_dt', :v_ppn_dt,
            'run_id', :v_run_id
        )::STRING,
        RUN_ID             => :v_run_id
    ) INTO :v_log_rows;


    IF (v_raw) THEN

        /* ============================================================
           4. LOAD FROM LANDING TO RAW
           ============================================================ */
        v_phase := 'LOAD FROM LANDING TO RAW';

        CALL ADM.SP_LANDING_TO_RAW(
            P_TABLE     => :v_table,
            P_FILE      => :v_file,
            P_PPN_ID    => :v_ppn_id,
            P_RUN_ID    => :v_run_id,
            P_SOURCE_ID => :v_source_id,
            P_OTHER     => :P_OTHER
        ) INTO :v_landing_result;

        -- Parent procedure validates child status and raises a controlled exception
        -- so the process stops and one consistent PROCESS ERROR log is written.
        IF (UPPER(COALESCE(GET(v_landing_result, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
            v_error_msg := 'SP_LANDING_TO_RAW returned ERROR: ' || COALESCE(v_landing_result::STRING, '(null)');
            RAISE e_failed;
        END IF;


        /* ============================================================
           4.1 COMPARE RAW LOAD WITH LAST RAW_HIST LOAD
           ============================================================ */
        v_phase := 'COMPARE RAW DATALOAD';
        v_compare_started_at := CURRENT_TIMESTAMP();

        CALL ADM.SP_COMPARE_DATALOADS(
            P_TABLE  => :v_table,
            P_RAW    => TRUE,
            P_PPN_ID => :v_ppn_id
        ) INTO :v_compare_result;

        v_compare_ended_at := CURRENT_TIMESTAMP();

        v_compare_status :=
            UPPER(COALESCE(GET(v_compare_result, 'status')::STRING, 'ERROR'));

        v_compare_action :=
            UPPER(COALESCE(GET(v_compare_result, 'action')::STRING, ''));

        v_compare_message :=
            COALESCE(GET(v_compare_result, 'message')::STRING, '');

        v_compare_no_prev :=
            (
                v_compare_action IN ('NO_PREVIOUS_LOAD', 'NO_PREVIOUS_DATA')
                OR UPPER(v_compare_message) LIKE '%NO PPN_ID FOUND IN TARGET HISTORY TABLE%'
                OR UPPER(v_compare_message) LIKE '%TARGET HISTORY TABLE DOES NOT EXIST%'
                OR UPPER(v_compare_message) LIKE '%TARGET HISTORY TABLE DOES NOT EXIST OR HAS NO COLUMNS%'
            );

        IF (v_compare_status <> 'SUCCESS' AND NOT v_compare_no_prev) THEN
            v_error_msg := 'SP_COMPARE_DATALOADS(RAW) returned ERROR: ' || COALESCE(v_compare_result::STRING, '(null)');
            RAISE e_failed;
        END IF;

        IF (v_compare_no_prev) THEN

            CALL ADM.SP_WRITE_PPN_LOG(
                PPN_ID             => :v_ppn_id,
                SOURCE_ID          => :v_source_id,
                PPN_PHASE          => 'DATA COMPARE',
                LOG_START          => :v_compare_started_at,
                LOG_END            => :v_compare_ended_at,
                DURATION_MSEC      => DATEDIFF(millisecond, :v_compare_started_at, :v_compare_ended_at),
                LOG_STATUS         => 'SUCCESS',
                SOURCE_OBJECT      => 'RAW.' || :v_table,
                TARGET_OBJECT      => 'RAW_HIST.' || :v_table,
                ROW_COUNT          => NULL,
                LOG_MESSAGE        => 'SUCCESS: RAW data compare completed. No previous RAW_HIST load exists. Processing continues.',
                LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                    'procedure', 'SP_RUN_LANDING_TO_STG',
                    'compare_procedure', 'SP_COMPARE_DATALOADS',
                    'compare_scope', 'RAW_TO_RAW_HIST',
                    'action', 'DATA_COMPARE_SUCCESS_NO_PREVIOUS_LOAD',
                    'table', :v_table,
                    'file', :v_file,
                    'ppn_id', :v_ppn_id,
                    'run_id', :v_run_id,
                    'compare_result', :v_compare_result
                )::STRING,
                RUN_ID             => :v_run_id
            ) INTO :v_log_rows;

        ELSE
            v_rows_compared :=
                COALESCE(GET(GET(v_compare_result, 'source_stats'), 'row_count')::NUMBER, 0);

            v_compare_identical :=
                COALESCE(GET(v_compare_result, 'is_identical')::BOOLEAN, FALSE);

            IF (v_compare_identical) THEN

                CALL ADM.SP_WRITE_PPN_LOG(
                    PPN_ID             => :v_ppn_id,
                    SOURCE_ID          => :v_source_id,
                    PPN_PHASE          => 'DATA COMPARE',
                    LOG_START          => :v_compare_started_at,
                    LOG_END            => :v_compare_ended_at,
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_compare_started_at, :v_compare_ended_at),
                    LOG_STATUS         => 'SKIP_LOAD',
                    SOURCE_OBJECT      => 'RAW.' || :v_table,
                    TARGET_OBJECT      => 'RAW_HIST.' || :v_table,
                    ROW_COUNT          => :v_rows_compared,
                    LOG_MESSAGE        => 'SKIP_LOAD: New RAW import is identical to the last RAW_HIST load. Further processing skipped.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_RUN_LANDING_TO_STG',
                        'compare_procedure', 'SP_COMPARE_DATALOADS',
                        'compare_scope', 'RAW_TO_RAW_HIST',
                        'action', 'SKIP_LOAD_EQUAL_DATA',
                        'table', :v_table,
                        'file', :v_file,
                        'ppn_id', :v_ppn_id,
                        'run_id', :v_run_id,
                        'compare_result', :v_compare_result
                    )::STRING,
                    RUN_ID             => :v_run_id
                ) INTO :v_log_rows;

                v_phase := 'PROCESS END';

                CALL ADM.SP_WRITE_PPN_LOG(
                    PPN_ID             => :v_ppn_id,
                    SOURCE_ID          => :v_source_id,
                    PPN_PHASE          => 'PROCESS END',
                    LOG_START          => :v_started_at,
                    LOG_END            => CURRENT_TIMESTAMP(),
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, CURRENT_TIMESTAMP()),
                    LOG_STATUS         => 'END',
                    SOURCE_OBJECT      => :v_file,
                    TARGET_OBJECT      => 'STG.' || :v_table,
                    ROW_COUNT          => :v_rows_compared,
                    LOG_MESSAGE        => 'END: ETL process completed successfully. Processing skipped because new import is equal to the last load.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_RUN_LANDING_TO_STG',
                        'action', 'SKIP_LOAD_EQUAL_DATA',
                        'skipped_after_phase', 'LOAD FROM LANDING TO RAW',
                        'table', :v_table,
                        'file', :v_file,
                        'load_type', :v_load_type,
                        'raw_mode', :v_raw,
                        'ppn_id', :v_ppn_id,
                        'ppn_dt', :v_ppn_dt,
                        'run_id', :v_run_id,
                        'landing_result', :v_landing_result,
                        'compare_result', :v_compare_result
                    )::STRING,
                    RUN_ID             => :v_run_id
                ) INTO :v_log_rows;

                RETURN OBJECT_CONSTRUCT(
                    'status', 'SUCCESS',
                    'action', 'SKIPPED_EQUAL_DATA',
                    'procedure', 'SP_RUN_LANDING_TO_STG',
                    'message', 'New RAW import is identical to the last RAW_HIST load. Further processing skipped.',
                    'ppn_id', v_ppn_id,
                    'ppn_dt', v_ppn_dt,
                    'table', v_table,
                    'file', v_file,
                    'load_type', v_load_type,
                    'raw_mode', v_raw,
                    'run_id', v_run_id,
                    'source_id', v_source_id,
                    'landing_result', v_landing_result,
                    'compare_result', v_compare_result
                );
            ELSE
                CALL ADM.SP_WRITE_PPN_LOG(
                    PPN_ID             => :v_ppn_id,
                    SOURCE_ID          => :v_source_id,
                    PPN_PHASE          => 'DATA COMPARE',
                    LOG_START          => :v_compare_started_at,
                    LOG_END            => :v_compare_ended_at,
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_compare_started_at, :v_compare_ended_at),
                    LOG_STATUS         => 'SUCCESS',
                    SOURCE_OBJECT      => 'RAW.' || :v_table,
                    TARGET_OBJECT      => 'RAW_HIST.' || :v_table,
                    ROW_COUNT          => :v_rows_compared,
                    LOG_MESSAGE        => 'SUCCESS: RAW data compare completed. New RAW import differs from the last RAW_HIST load. Processing continues.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_RUN_LANDING_TO_STG',
                        'compare_procedure', 'SP_COMPARE_DATALOADS',
                        'compare_scope', 'RAW_TO_RAW_HIST',
                        'action', 'DATA_COMPARE_SUCCESS_DIFFERENT_DATA',
                        'table', :v_table,
                        'file', :v_file,
                        'ppn_id', :v_ppn_id,
                        'run_id', :v_run_id,
                        'compare_result', :v_compare_result
                    )::STRING,
                    RUN_ID             => :v_run_id
                ) INTO :v_log_rows;
            END IF;
        END IF;


        /* ============================================================
           5. LOAD FROM RAW TO RAW_HIST
           ============================================================ */
        v_phase := 'LOAD FROM RAW TO RAW_HIST';

        CALL ADM.SP_LOAD_TO_HIST(
            P_PPN_ID        => :v_ppn_id,
            P_TABLE         => :v_table,
            P_SOURCE_SCHEMA => 'RAW',
            P_SOURCE_ID     => :v_source_id,
            P_RUN_ID        => :v_run_id
        ) INTO :v_raw_hist_result;

        -- Parent procedure validates child status and raises a controlled exception
        -- so the process stops and one consistent PROCESS ERROR log is written.
        IF (UPPER(COALESCE(GET(v_raw_hist_result, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
            v_error_msg := 'SP_LOAD_TO_HIST(RAW) returned ERROR: ' || COALESCE(v_raw_hist_result::STRING, '(null)');
            RAISE e_failed;
        END IF;

    ELSE

        /* ============================================================
           6. LOAD FROM LANDING TO EX
           ============================================================ */
        v_phase := 'LOAD FROM LANDING TO EX';

        CALL ADM.SP_LANDING_TO_EX(
            P_TABLE     => :v_table,
            P_FILE      => :v_file,
            P_PPN_ID    => :v_ppn_id,
            P_RUN_ID    => :v_run_id,
            P_SOURCE_ID => :v_source_id,
            P_OTHER     => :P_OTHER
        ) INTO :v_landing_result;

        -- Parent procedure validates child status and raises a controlled exception
        -- so the process stops and one consistent PROCESS ERROR log is written.
        IF (UPPER(COALESCE(GET(v_landing_result, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
            v_error_msg := 'SP_LANDING_TO_EX returned ERROR: ' || COALESCE(v_landing_result::STRING, '(null)');
            RAISE e_failed;
        END IF;


        /* ============================================================
           6.1 COMPARE EX LOAD WITH LAST EX_HIST LOAD
           ============================================================ */
        v_phase := 'COMPARE EX DATALOAD';
        v_compare_started_at := CURRENT_TIMESTAMP();

        CALL ADM.SP_COMPARE_DATALOADS(
            P_TABLE  => :v_table,
            P_RAW    => FALSE,
            P_PPN_ID => :v_ppn_id
        ) INTO :v_compare_result;

        v_compare_ended_at := CURRENT_TIMESTAMP();

        v_compare_status :=
            UPPER(COALESCE(GET(v_compare_result, 'status')::STRING, 'ERROR'));

        v_compare_action :=
            UPPER(COALESCE(GET(v_compare_result, 'action')::STRING, ''));

        v_compare_message :=
            COALESCE(GET(v_compare_result, 'message')::STRING, '');

        v_compare_no_prev :=
            (
                v_compare_action IN ('NO_PREVIOUS_LOAD', 'NO_PREVIOUS_DATA')
                OR UPPER(v_compare_message) LIKE '%NO PPN_ID FOUND IN TARGET HISTORY TABLE%'
                OR UPPER(v_compare_message) LIKE '%TARGET HISTORY TABLE DOES NOT EXIST%'
                OR UPPER(v_compare_message) LIKE '%TARGET HISTORY TABLE DOES NOT EXIST OR HAS NO COLUMNS%'
            );

        IF (v_compare_status <> 'SUCCESS' AND NOT v_compare_no_prev) THEN
            v_error_msg := 'SP_COMPARE_DATALOADS(EX) returned ERROR: ' || COALESCE(v_compare_result::STRING, '(null)');
            RAISE e_failed;
        END IF;

        IF (v_compare_no_prev) THEN

            CALL ADM.SP_WRITE_PPN_LOG(
                PPN_ID             => :v_ppn_id,
                SOURCE_ID          => :v_source_id,
                PPN_PHASE          => 'DATA COMPARE',
                LOG_START          => :v_compare_started_at,
                LOG_END            => :v_compare_ended_at,
                DURATION_MSEC      => DATEDIFF(millisecond, :v_compare_started_at, :v_compare_ended_at),
                LOG_STATUS         => 'SUCCESS',
                SOURCE_OBJECT      => 'EX.' || :v_table,
                TARGET_OBJECT      => 'EX_HIST.' || :v_table,
                ROW_COUNT          => NULL,
                LOG_MESSAGE        => 'SUCCESS: EX data compare completed. No previous EX_HIST load exists. Processing continues.',
                LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                    'procedure', 'SP_RUN_LANDING_TO_STG',
                    'compare_procedure', 'SP_COMPARE_DATALOADS',
                    'compare_scope', 'EX_TO_EX_HIST',
                    'action', 'DATA_COMPARE_SUCCESS_NO_PREVIOUS_LOAD',
                    'table', :v_table,
                    'file', :v_file,
                    'ppn_id', :v_ppn_id,
                    'run_id', :v_run_id,
                    'compare_result', :v_compare_result
                )::STRING,
                RUN_ID             => :v_run_id
            ) INTO :v_log_rows;

        ELSE
            v_rows_compared :=
                COALESCE(GET(GET(v_compare_result, 'source_stats'), 'row_count')::NUMBER, 0);

            v_compare_identical :=
                COALESCE(GET(v_compare_result, 'is_identical')::BOOLEAN, FALSE);

            IF (v_compare_identical) THEN

                CALL ADM.SP_WRITE_PPN_LOG(
                    PPN_ID             => :v_ppn_id,
                    SOURCE_ID          => :v_source_id,
                    PPN_PHASE          => 'DATA COMPARE',
                    LOG_START          => :v_compare_started_at,
                    LOG_END            => :v_compare_ended_at,
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_compare_started_at, :v_compare_ended_at),
                    LOG_STATUS         => 'SKIP_LOAD',
                    SOURCE_OBJECT      => 'EX.' || :v_table,
                    TARGET_OBJECT      => 'EX_HIST.' || :v_table,
                    ROW_COUNT          => :v_rows_compared,
                    LOG_MESSAGE        => 'SKIP_LOAD: New EX import is identical to the last EX_HIST load. Further processing skipped.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_RUN_LANDING_TO_STG',
                        'compare_procedure', 'SP_COMPARE_DATALOADS',
                        'compare_scope', 'EX_TO_EX_HIST',
                        'action', 'SKIP_LOAD_EQUAL_DATA',
                        'table', :v_table,
                        'file', :v_file,
                        'ppn_id', :v_ppn_id,
                        'run_id', :v_run_id,
                        'compare_result', :v_compare_result
                    )::STRING,
                    RUN_ID             => :v_run_id
                ) INTO :v_log_rows;

                v_phase := 'PROCESS END';

                CALL ADM.SP_WRITE_PPN_LOG(
                    PPN_ID             => :v_ppn_id,
                    SOURCE_ID          => :v_source_id,
                    PPN_PHASE          => 'PROCESS END',
                    LOG_START          => :v_started_at,
                    LOG_END            => CURRENT_TIMESTAMP(),
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, CURRENT_TIMESTAMP()),
                    LOG_STATUS         => 'END',
                    SOURCE_OBJECT      => :v_file,
                    TARGET_OBJECT      => 'STG.' || :v_table,
                    ROW_COUNT          => :v_rows_compared,
                    LOG_MESSAGE        => 'END: ETL process completed successfully. Processing skipped because new import is equal to the last load.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_RUN_LANDING_TO_STG',
                        'action', 'SKIP_LOAD_EQUAL_DATA',
                        'skipped_after_phase', 'LOAD FROM LANDING TO EX',
                        'table', :v_table,
                        'file', :v_file,
                        'load_type', :v_load_type,
                        'raw_mode', :v_raw,
                        'ppn_id', :v_ppn_id,
                        'ppn_dt', :v_ppn_dt,
                        'run_id', :v_run_id,
                        'landing_result', :v_landing_result,
                        'compare_result', :v_compare_result
                    )::STRING,
                    RUN_ID             => :v_run_id
                ) INTO :v_log_rows;

                RETURN OBJECT_CONSTRUCT(
                    'status', 'SUCCESS',
                    'action', 'SKIPPED_EQUAL_DATA',
                    'procedure', 'SP_RUN_LANDING_TO_STG',
                    'message', 'New EX import is identical to the last EX_HIST load. Further processing skipped.',
                    'ppn_id', v_ppn_id,
                    'ppn_dt', v_ppn_dt,
                    'table', v_table,
                    'file', v_file,
                    'load_type', v_load_type,
                    'raw_mode', v_raw,
                    'run_id', v_run_id,
                    'source_id', v_source_id,
                    'landing_result', v_landing_result,
                    'compare_result', v_compare_result
                );
            ELSE
                CALL ADM.SP_WRITE_PPN_LOG(
                    PPN_ID             => :v_ppn_id,
                    SOURCE_ID          => :v_source_id,
                    PPN_PHASE          => 'DATA COMPARE',
                    LOG_START          => :v_compare_started_at,
                    LOG_END            => :v_compare_ended_at,
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_compare_started_at, :v_compare_ended_at),
                    LOG_STATUS         => 'SUCCESS',
                    SOURCE_OBJECT      => 'EX.' || :v_table,
                    TARGET_OBJECT      => 'EX_HIST.' || :v_table,
                    ROW_COUNT          => :v_rows_compared,
                    LOG_MESSAGE        => 'SUCCESS: EX data compare completed. New EX import differs from the last EX_HIST load. Processing continues.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_RUN_LANDING_TO_STG',
                        'compare_procedure', 'SP_COMPARE_DATALOADS',
                        'compare_scope', 'EX_TO_EX_HIST',
                        'action', 'DATA_COMPARE_SUCCESS_DIFFERENT_DATA',
                        'table', :v_table,
                        'file', :v_file,
                        'ppn_id', :v_ppn_id,
                        'run_id', :v_run_id,
                        'compare_result', :v_compare_result
                    )::STRING,
                    RUN_ID             => :v_run_id
                ) INTO :v_log_rows;
            END IF;
        END IF;

    END IF;


    /* ============================================================
       7. CHECK EX OBJECT EXISTS
       ============================================================ */
    v_phase := 'CHECK EX OBJECT';

    SELECT COUNT(*)
      INTO :v_ex_count
      FROM INFORMATION_SCHEMA.TABLES
     WHERE TABLE_CATALOG = CURRENT_DATABASE()
       AND TABLE_SCHEMA = 'EX'
       AND TABLE_NAME = :v_table;

    IF (v_ex_count = 0) THEN
        v_error_msg := 'EX.' || v_table || IFF(v_raw,
            ' does not exist. In RAW mode EX.<table> must exist as a view/table over RAW.',
            ' does not exist after SP_LANDING_TO_EX.'
        );
        RAISE e_failed;
    END IF;


    /* ============================================================
       8. LOAD FROM EX TO EX_HIST
       ============================================================ */
    v_phase := 'LOAD FROM EX TO EX_HIST';

    CALL ADM.SP_LOAD_TO_HIST(
        P_PPN_ID        => :v_ppn_id,
        P_TABLE         => :v_table,
        P_SOURCE_SCHEMA => 'EX',
        P_SOURCE_ID     => :v_source_id,
        P_RUN_ID        => :v_run_id
    ) INTO :v_ex_hist_result;

    -- Parent procedure validates child status and raises a controlled exception
    -- so the process stops and one consistent PROCESS ERROR log is written.
    IF (UPPER(COALESCE(GET(v_ex_hist_result, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
        v_error_msg := 'SP_LOAD_TO_HIST(EX) returned ERROR: ' || COALESCE(v_ex_hist_result::STRING, '(null)');
        RAISE e_failed;
    END IF;


    /* ============================================================
       9. LOAD FROM EX TO STG
       ============================================================ */
    v_phase := 'LOAD FROM EX TO STG';

    CALL ADM.SP_EX_TO_STG(
        P_PPN_ID    => :v_ppn_id,
        P_TABLE     => :v_table,
        P_LOAD_TYPE => :v_load_type,
        P_OTHER     => :P_OTHER,
        P_RUN_ID    => :v_run_id,
        P_SOURCE_ID => :v_source_id
    ) INTO :v_stg_result;

    -- Parent procedure validates child status and raises a controlled exception
    -- so the process stops and one consistent PROCESS ERROR log is written.
    IF (UPPER(COALESCE(GET(v_stg_result, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
        v_error_msg := 'SP_EX_TO_STG returned ERROR: ' || COALESCE(v_stg_result::STRING, '(null)');
        RAISE e_failed;
    END IF;


    /* ============================================================
       10. WRITE PROCESS END LOG
       ============================================================ */
    v_phase := 'PROCESS END';

    CALL ADM.SP_WRITE_PPN_LOG(
        PPN_ID             => :v_ppn_id,
        SOURCE_ID          => :v_source_id,
        PPN_PHASE          => 'PROCESS END',
        LOG_START          => :v_started_at,
        LOG_END            => CURRENT_TIMESTAMP(),
        DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, CURRENT_TIMESTAMP()),
        LOG_STATUS         => 'END',
        SOURCE_OBJECT      => :v_file,
        TARGET_OBJECT      => 'STG.' || :v_table,
        ROW_COUNT          => COALESCE(GET(:v_stg_result, 'rows_inserted')::NUMBER, 0),
        LOG_MESSAGE        => 'END: ETL process successfully completed.',
        LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
            'procedure', 'SP_RUN_LANDING_TO_STG',
            'landing_result', :v_landing_result,
            'raw_hist_result', :v_raw_hist_result,
            'ex_hist_result', :v_ex_hist_result,
            'stg_result', :v_stg_result,
            'compare_result', :v_compare_result
        )::STRING,
        RUN_ID             => :v_run_id
    ) INTO :v_log_rows;


    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'action', 'PROCESSED',
        'procedure', 'SP_RUN_LANDING_TO_STG',
        'ppn_id', v_ppn_id,
        'ppn_dt', v_ppn_dt,
        'table', v_table,
        'file', v_file,
        'load_type', v_load_type,
        'raw_mode', v_raw,
        'run_id', v_run_id,
        'source_id', v_source_id,
        'landing_result', v_landing_result,
        'raw_hist_result', v_raw_hist_result,
        'ex_hist_result', v_ex_hist_result,
        'stg_result', v_stg_result,
        'compare_result', v_compare_result
    );


EXCEPTION
    WHEN OTHER THEN
        LET v_end_ts    TIMESTAMP_NTZ := CURRENT_TIMESTAMP();
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);

        BEGIN
            IF (v_ppn_id IS NOT NULL) THEN
                CALL ADM.SP_WRITE_PPN_LOG(
                    PPN_ID             => :v_ppn_id,
                    SOURCE_ID          => COALESCE(:v_source_id, 'N/A'),
                    PPN_PHASE          => 'PROCESS ERROR',
                    LOG_START          => :v_started_at,
                    LOG_END            => :v_end_ts,
                    DURATION_MSEC      => DATEDIFF(millisecond, :v_started_at, :v_end_ts),
                    LOG_STATUS         => 'ERROR',
                    SOURCE_OBJECT      => :v_file,
                    TARGET_OBJECT      => 'STG.' || COALESCE(:v_table, 'UNKNOWN'),
                    ROW_COUNT          => NULL,
                    LOG_MESSAGE        => 'ERROR: ETL process failed.',
                    LOG_MESSAGE_DETAIL => OBJECT_CONSTRUCT(
                        'procedure', 'SP_RUN_LANDING_TO_STG',
                        'failed_phase', :v_phase,
                        'error_message', :v_final_msg,
                        'sqlcode', :SQLCODE,
                        'sqlstate', :SQLSTATE,
                        'sqlerrm', :SQLERRM,
                        'table', :v_table,
                        'file', :v_file,
                        'load_type', :v_load_type,
                        'raw_mode', :v_raw,
                        'landing_result', :v_landing_result,
                        'raw_hist_result', :v_raw_hist_result,
                        'ex_hist_result', :v_ex_hist_result,
                        'stg_result', :v_stg_result,
                        'compare_result', :v_compare_result
                    )::STRING,
                    RUN_ID             => :v_run_id
                ) INTO :v_log_rows;
            END IF;
        EXCEPTION
            WHEN OTHER THEN
                NULL;
        END;

        RAISE;
END;