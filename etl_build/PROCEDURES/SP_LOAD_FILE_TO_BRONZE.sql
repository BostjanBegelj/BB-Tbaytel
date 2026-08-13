-- ADM.SP_LOAD_FILE_TO_BRONZE - FILE load pattern: COPY the file(s) for one table from the
-- configured stage into <TARGET_SCHEMA>.<TABLE> (default BRONZE).
-- Format-agnostic: the source's FILE_FORMAT decides Parquet / CSV / JSON / ... - this
-- procedure only passes it to COPY.
-- Config-driven: reads the ETL_SOURCES + ETL_TABLES row for (SOURCE_ID, TABLE_NAME),
-- so it runs standalone (no orchestrator needed) and is called per-table later.
-- Single responsibility = land the file(s). Schema handling is Snowflake-native
-- (INFER_SCHEMA + ENABLE_SCHEMA_EVOLUTION); change detection lives in SP_CHECK_DATA_CHANGE.
-- RUN_ID is resolved from ADM.PPN by SP_LOG_STEP, so it is not a parameter here.
-- Child pattern: writes PPN_LOG only and RETURNS a status object. PPN_PROCESS state is owned
-- solely by SP_RUN_TABLE_LOAD, so a partially-completed table can never look complete.
-- (Called standalone it still loads + logs; it just won't set table state.)

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_LOAD_FILE_TO_BRONZE(
    "P_PPN_ID"     NUMBER(38,0),
    "P_SOURCE_ID"  VARCHAR,
    "P_TABLE_NAME" VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'FILE pattern: COPY the configured file(s) for one table from the stage into <TARGET_SCHEMA>.<TABLE>. Config-driven.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20700, 'SP_LOAD_FILE_TO_BRONZE failed.');

    v_ppn_id      NUMBER  DEFAULT P_PPN_ID;
    v_source_id   STRING  DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_table       STRING  DEFAULT UPPER(NULLIF(TRIM(P_TABLE_NAME), ''));

    v_stage       STRING;
    v_stage_root  STRING;
    v_format      STRING;
    v_pattern     STRING;
    v_pattern_esc STRING;
    v_target_sch  STRING;

    v_db          STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_target_fq   STRING;
    v_file_list   STRING;
    v_ppn_ts      TIMESTAMP_NTZ(9);

    v_cfg_count   NUMBER  DEFAULT 0;
    v_row_count   NUMBER  DEFAULT 0;
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
    /*    SP_RUN_TABLE_LOAD owns the authoritative config validation (and dispatches on
          SOURCE_TYPE, so no source-type check is repeated here). This is only a guard on
          THIS procedure's own read - it catches config removed mid-run and standalone calls. */
    v_phase := 'READ_CONFIG';
    SELECT COUNT(*), MAX(s.stage_name), MAX(s.file_format), MAX(t.file_pattern),
           MAX(UPPER(COALESCE(t.target_schema, 'BRONZE')))
      INTO :v_cfg_count, :v_stage, :v_format, :v_pattern, :v_target_sch
      FROM ADM.ETL_TABLES t
      JOIN ADM.ETL_SOURCES s ON s.source_id = t.source_id
     WHERE t.source_id = :v_source_id
       AND t.table_name = :v_table
       AND t.active_flag
       AND s.active_flag;

    IF (v_cfg_count <> 1) THEN
        v_error_msg := 'Expected exactly 1 active config row for [' || v_source_id || '.' || v_table
                    || '] at landing time, found ' || v_cfg_count || ' (config changed mid-run?).';
        RAISE e_failed;
    END IF;
    IF (v_stage IS NULL OR v_format IS NULL OR v_pattern IS NULL) THEN
        v_error_msg := 'Config incomplete: FILE needs STAGE_NAME + FILE_FORMAT (source) and FILE_PATTERN (table).';
        RAISE e_failed;
    END IF;

    -- stage root = the stage object without any path prefix (for INFER_SCHEMA FILES).
    v_stage_root  := SPLIT_PART(v_stage, '/', 1) || '/';
    v_pattern_esc := REPLACE(v_pattern, '\\', '\\\\');
    v_target_fq   := '"' || v_db || '"."' || v_target_sch || '"."' || v_table || '"';

    SELECT PPN_TIMESTAMP INTO :v_ppn_ts FROM ADM.PPN WHERE PPN_ID = :v_ppn_id;

    /* 3. FIND FILES ----------------------------------------------------- */
    v_phase := 'FIND_FILES';
    v_sql := 'LIST ' || v_stage || ' PATTERN = ''' || v_pattern_esc || '''';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    -- LIST returns "name" WITH the stage name as its first segment
    -- (e.g. ext_stage_azure/BSS_ORA/.../file). INFER_SCHEMA FILES are relative to
    -- LOCATION (the stage root), so strip that first segment.
    SELECT LISTAGG('''' || REGEXP_REPLACE("name", '^[^/]+/', '') || '''', ',')
      INTO :v_file_list
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    IF (v_file_list IS NULL OR v_file_list = '') THEN
        v_error_msg := 'No files in ' || v_stage || ' matching pattern [' || v_pattern || '].';
        RAISE e_failed;
    END IF;

    /* 4. CREATE TARGET FROM INFERRED SCHEMA ----------------------------- */
    v_phase := 'CREATE_TARGET';
    v_sql := 'CREATE OR REPLACE TABLE ' || v_target_fq || '
        USING TEMPLATE (
            SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
                     ''COLUMN_NAME'', REPLACE(REGEXP_REPLACE(COLUMN_NAME, ''["().]'', ''''), '' '', ''_''),
                     ''TYPE'', TYPE, ''NULLABLE'', TRUE))
            FROM TABLE(INFER_SCHEMA(
                     LOCATION    => ''' || v_stage_root || ''',
                     FILES       => (' || v_file_list || '),
                     FILE_FORMAT => ''' || v_format || ''',
                     IGNORE_CASE => TRUE)))
        ENABLE_SCHEMA_EVOLUTION = TRUE';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 5. ADD LINEAGE COLUMNS ------------------------------------------- */
    v_phase := 'ADD_METADATA';
    v_sql := 'ALTER TABLE ' || v_target_fq || ' ADD COLUMN IF NOT EXISTS ' ||
             'METADATA$FILENAME STRING, PPN_ID NUMBER(38,0), PPN_TIMESTAMP TIMESTAMP_NTZ(9)';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 6. COPY ----------------------------------------------------------- */
    v_phase := 'COPY';
    v_sql := 'COPY INTO ' || v_target_fq || '
        FROM ' || v_stage || '
        PATTERN = ''' || v_pattern_esc || '''
        FILE_FORMAT = (FORMAT_NAME = ' || v_format || ')
        MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
        INCLUDE_METADATA = (METADATA$FILENAME = METADATA$FILENAME)
        ON_ERROR = ABORT_STATEMENT';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 7. STAMP PPN ------------------------------------------------------ */
    v_phase := 'STAMP_PPN';
    v_sql := 'UPDATE ' || v_target_fq || '
        SET PPN_ID = ' || v_ppn_id || ',
            PPN_TIMESTAMP = ''' || TO_CHAR(v_ppn_ts, 'YYYY-MM-DD HH24:MI:SS.FF9') || '''
        WHERE PPN_ID IS NULL';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 8. COUNT ---------------------------------------------------------- */
    v_phase := 'COUNT';
    SELECT COUNT(*) INTO :v_row_count FROM IDENTIFIER(:v_target_fq) WHERE PPN_ID = :v_ppn_id;

    /* 9. LOG SUCCESS (state is owned by SP_RUN_TABLE_LOAD) -------------- */
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn_id,
        P_PHASE       => 'LOAD_FILE_TO_BRONZE',
        P_STATUS      => 'SUCCESS',
        P_SOURCE_ID   => :v_source_id,
        P_TABLE_NAME  => :v_table,
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_SOURCE_OBJECT => :v_stage,
        P_TARGET_OBJECT => :v_target_fq,
        P_ROW_COUNT   => :v_row_count,
        P_MESSAGE     => 'SUCCESS: loaded ' || :v_row_count || ' row(s) into ' || :v_target_sch || '.' || :v_table || '.',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_FILE_TO_BRONZE','ppn_id',:v_ppn_id),
            'results', OBJECT_CONSTRUCT('files', :v_file_list, 'rows_loaded', :v_row_count)
        )
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_LOAD_FILE_TO_BRONZE',
        'source_id', v_source_id,
        'table', v_table,
        'target_object', v_target_fq,
        'rows_loaded', v_row_count,
        'ppn_id', v_ppn_id
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        BEGIN
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_ppn_id,
                P_PHASE       => 'LOAD_FILE_TO_BRONZE',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR [SP_LOAD_FILE_TO_BRONZE/' || :v_phase || ']: ' || :v_final_msg,
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_LOAD_FILE_TO_BRONZE',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'last_sql',         NULLIF(:v_last_sql, ''),
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_FILE_TO_BRONZE','ppn_id',:v_ppn_id)
                )
            ) INTO :v_log_rows;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'procedure', 'SP_LOAD_FILE_TO_BRONZE',
            'phase', v_phase,
            'message', v_final_msg,
            'last_sql', v_last_sql
        );
END;
