-- ADM.SP_VALIDATE_CONFIG - pre-flight validation of the ACTIVE config rows before a run.
-- Checks (set-based, all active rows at once):
--   * ETL_SOURCES: SOURCE_TYPE valid; PARQUET has STAGE_NAME + FILE_FORMAT; DATASHARE has SHARE_DB.
--   * ETL_TABLES : LOAD_TYPE valid; INCR has PK_COLUMNS; PARTITION has PARTITION_COLUMN;
--                  SOURCE_ID resolves to an active source; PARQUET has FILE_PATTERN; DATASHARE has SOURCE_OBJECT.
-- Physical file/stage presence is checked at load time by the load procedure (it LISTs the stage).
-- RUN_ID is resolved from ADM.PPN by SP_LOG_STEP, so it is not a parameter here.
-- All violations are collected, logged once in the ERROR-first envelope, then raised.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_VALIDATE_CONFIG(
    "P_PPN_ID" NUMBER(38,0)
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Pre-flight: validate active ETL_SOURCES / ETL_TABLES rows. Logs + raises on any violation.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20600, 'SP_VALIDATE_CONFIG failed: configuration invalid.');

    v_ppn_id     NUMBER DEFAULT P_PPN_ID;
    v_phase      STRING DEFAULT 'INIT';
    v_started_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_violations ARRAY;
    v_count      NUMBER DEFAULT 0;
    v_error_msg  STRING;
    v_log_rows   NUMBER DEFAULT 0;
BEGIN
    v_phase := 'VALIDATE';
    IF (v_ppn_id IS NULL) THEN
        v_error_msg := 'P_PPN_ID is required.';
        RAISE e_failed;
    END IF;

    v_phase := 'COLLECT_VIOLATIONS';
    SELECT ARRAY_AGG(reason) INTO :v_violations
    FROM (
        -- ETL_SOURCES ------------------------------------------------------
        SELECT 'ETL_SOURCES [' || source_id || '] invalid SOURCE_TYPE [' || COALESCE(source_type, '<null>') || ']' AS reason
          FROM ADM.ETL_SOURCES
         WHERE active_flag AND UPPER(COALESCE(source_type, '')) NOT IN ('PARQUET', 'DATASHARE')
        UNION ALL
        SELECT 'ETL_SOURCES [' || source_id || '] PARQUET requires STAGE_NAME and FILE_FORMAT'
          FROM ADM.ETL_SOURCES
         WHERE active_flag AND UPPER(source_type) = 'PARQUET' AND (stage_name IS NULL OR file_format IS NULL)
        UNION ALL
        SELECT 'ETL_SOURCES [' || source_id || '] DATASHARE requires SHARE_DB'
          FROM ADM.ETL_SOURCES
         WHERE active_flag AND UPPER(source_type) = 'DATASHARE' AND share_db IS NULL
        UNION ALL
        -- ETL_TABLES -------------------------------------------------------
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] invalid LOAD_TYPE [' || COALESCE(load_type, '<null>') || ']'
          FROM ADM.ETL_TABLES
         WHERE active_flag AND UPPER(COALESCE(load_type, '')) NOT IN ('FULL', 'INIT', 'INCR', 'PARTITION')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] LOAD_TYPE INCR requires PK_COLUMNS'
          FROM ADM.ETL_TABLES
         WHERE active_flag AND UPPER(load_type) = 'INCR' AND (pk_columns IS NULL OR TRIM(pk_columns) = '')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] LOAD_TYPE PARTITION requires PARTITION_COLUMN'
          FROM ADM.ETL_TABLES
         WHERE active_flag AND UPPER(load_type) = 'PARTITION' AND (partition_column IS NULL OR TRIM(partition_column) = '')
        UNION ALL
        SELECT 'ETL_TABLES [' || t.source_id || '.' || t.table_name || '] references unknown/inactive SOURCE_ID'
          FROM ADM.ETL_TABLES t
         WHERE t.active_flag
           AND NOT EXISTS (SELECT 1 FROM ADM.ETL_SOURCES s WHERE s.source_id = t.source_id AND s.active_flag)
        UNION ALL
        SELECT 'ETL_TABLES [' || t.source_id || '.' || t.table_name || '] PARQUET requires FILE_PATTERN'
          FROM ADM.ETL_TABLES t JOIN ADM.ETL_SOURCES s ON s.source_id = t.source_id
         WHERE t.active_flag AND s.active_flag AND UPPER(s.source_type) = 'PARQUET'
           AND (t.file_pattern IS NULL OR TRIM(t.file_pattern) = '')
        UNION ALL
        SELECT 'ETL_TABLES [' || t.source_id || '.' || t.table_name || '] DATASHARE requires SOURCE_OBJECT'
          FROM ADM.ETL_TABLES t JOIN ADM.ETL_SOURCES s ON s.source_id = t.source_id
         WHERE t.active_flag AND s.active_flag AND UPPER(s.source_type) = 'DATASHARE'
           AND (t.source_object IS NULL OR TRIM(t.source_object) = '')
    );

    v_count := ARRAY_SIZE(COALESCE(v_violations, ARRAY_CONSTRUCT()));

    IF (v_count > 0) THEN
        v_error_msg := 'Configuration validation failed with ' || v_count || ' issue(s).';
        RAISE e_failed;   -- single ERROR log written by the handler (with the violations list)
    END IF;

    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn_id,
        P_PHASE       => 'VALIDATE_CONFIG',
        P_STATUS      => 'SUCCESS',
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_ROW_COUNT   => 0,
        P_MESSAGE     => 'SUCCESS: configuration valid.',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_VALIDATE_CONFIG','ppn_id',:v_ppn_id)
        )::STRING
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_VALIDATE_CONFIG',
        'violations', 0
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        BEGIN
            IF (v_ppn_id IS NOT NULL) THEN
                CALL ADM.SP_LOG_STEP(
                    P_PPN_ID      => :v_ppn_id,
                    P_PHASE       => 'VALIDATE_CONFIG',
                    P_STATUS      => 'ERROR',
                    P_LOG_START   => :v_started_at,
                    P_LOG_END     => CURRENT_TIMESTAMP(),
                    P_ROW_COUNT   => :v_count,
                    P_MESSAGE     => 'ERROR [SP_VALIDATE_CONFIG/' || :v_phase || ']: ' || :v_final_msg,
                    P_DETAIL_JSON => OBJECT_CONSTRUCT(
                        'ERROR', OBJECT_CONSTRUCT(
                            'source_procedure', 'SP_VALIDATE_CONFIG',
                            'source_phase',     :v_phase,
                            'message',          :v_final_msg,
                            'violations',       :v_violations,
                            'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                            'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                        ),
                        'context', OBJECT_CONSTRUCT('procedure','SP_VALIDATE_CONFIG','ppn_id',:v_ppn_id)
                    )::STRING
                ) INTO :v_log_rows;
            END IF;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;
        RAISE;
END;
