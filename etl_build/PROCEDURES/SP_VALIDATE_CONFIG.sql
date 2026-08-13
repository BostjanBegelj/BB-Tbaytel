-- ADM.SP_VALIDATE_CONFIG - pre-flight validation of the IN-SCOPE config rows before a run.
--
-- SCOPE: active ETL_SOURCES, plus active ETL_TABLES rows whose source is ALSO active.
--   Switching off a source or a table removes its config from validation completely, so a
--   parked / half-finished row can never block the nightly run. There is no table-list
--   parameter: a run may process a varying subset of tables, but the config is validated as
--   a whole once per PPN (cheap, set-based, and catches drift in rows scheduled for later).
--
-- Checks (set-based, all in-scope rows at once):
--   * ETL_SOURCES: SOURCE_TYPE valid; FILE has STAGE_NAME + FILE_FORMAT; DATABASE has SOURCE_DB.
--   * ETL_TABLES : LOAD_TYPE valid; INCR/WATERMARK have PK_COLUMNS; WATERMARK has WATERMARK_COLUMN
--                  + a valid WATERMARK_TYPE (TIMESTAMP|DATE|NUMBER); WATERMARK_OVERLAP >= 0
--                  (>= 1 for DATE); PARTITION has PARTITION_COLUMN; FILE has FILE_PATTERN;
--                  DATABASE has SOURCE_OBJECT.
--   * ORPHAN     : an active table whose SOURCE_ID does not exist in ETL_SOURCES at all.
--                  (An active table under an INACTIVE source is out of scope, not an error.)
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
COMMENT = 'Pre-flight: validate active ETL_SOURCES + active ETL_TABLES of active sources. Logs + raises on any violation.'
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
    /* SCOPE: only ACTIVE sources, and only ACTIVE tables belonging to an ACTIVE source.
       Deactivating a source or a table takes its config entirely out of scope - a half-finished
       row that is switched off must never block a run. Defined once in the CTEs below so no
       individual check can forget half of the condition.                                     */
    SELECT ARRAY_AGG(reason) INTO :v_violations
    FROM (
        WITH src AS (            -- active sources
            SELECT * FROM ADM.ETL_SOURCES WHERE active_flag
        ),
        tbl AS (                 -- active tables whose source is also active
            SELECT t.*, UPPER(s.source_type) AS src_type
              FROM ADM.ETL_TABLES t
              JOIN src s ON s.source_id = t.source_id
             WHERE t.active_flag
        )
        -- ETL_SOURCES ------------------------------------------------------
        SELECT 'ETL_SOURCES [' || source_id || '] invalid SOURCE_TYPE [' || COALESCE(source_type, '<null>') || ']' AS reason
          FROM src
         WHERE UPPER(COALESCE(source_type, '')) NOT IN ('FILE', 'DATABASE')
        UNION ALL
        SELECT 'ETL_SOURCES [' || source_id || '] FILE requires STAGE_NAME and FILE_FORMAT'
          FROM src
         WHERE UPPER(source_type) = 'FILE' AND (stage_name IS NULL OR file_format IS NULL)
        UNION ALL
        SELECT 'ETL_SOURCES [' || source_id || '] DATABASE requires SOURCE_DB'
          FROM src
         WHERE UPPER(source_type) = 'DATABASE' AND source_db IS NULL
        UNION ALL
        -- ETL_TABLES (in-scope rows only) ----------------------------------
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] invalid LOAD_TYPE [' || COALESCE(load_type, '<null>') || ']'
          FROM tbl
         WHERE UPPER(COALESCE(load_type, '')) NOT IN ('FULL', 'INIT', 'INCR', 'PARTITION', 'WATERMARK')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] LOAD_TYPE ' || UPPER(load_type) || ' requires PK_COLUMNS'
          FROM tbl
         WHERE UPPER(load_type) IN ('INCR', 'WATERMARK')
           AND (pk_columns IS NULL OR TRIM(pk_columns) = '')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] LOAD_TYPE WATERMARK requires WATERMARK_COLUMN'
          FROM tbl
         WHERE UPPER(load_type) = 'WATERMARK'
           AND (watermark_column IS NULL OR TRIM(watermark_column) = '')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] LOAD_TYPE WATERMARK requires WATERMARK_TYPE'
          FROM tbl
         WHERE UPPER(load_type) = 'WATERMARK'
           AND (watermark_type IS NULL OR TRIM(watermark_type) = '')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] invalid WATERMARK_TYPE ['
               || watermark_type || '] - expected TIMESTAMP | DATE | NUMBER'
          FROM tbl
         WHERE watermark_type IS NOT NULL
           AND UPPER(watermark_type) NOT IN ('TIMESTAMP', 'DATE', 'NUMBER')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] WATERMARK_OVERLAP must be >= 0'
          FROM tbl
         WHERE COALESCE(watermark_overlap, 0) < 0
        UNION ALL
        -- A DATE watermark compares at DAY grain with ">", so OVERLAP 0 permanently skips every
        -- row dated exactly on the recorded bound (rows added later the same day are lost, and
        -- tomorrow's bound is higher still). DATE watermarks need at least a 1-day lookback.
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] WATERMARK_TYPE DATE requires '
               || 'WATERMARK_OVERLAP >= 1 (with 0 the same-day rows on the bound are never loaded)'
          FROM tbl
         WHERE UPPER(load_type) = 'WATERMARK'
           AND UPPER(watermark_type) = 'DATE' AND COALESCE(watermark_overlap, 0) < 1
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] LOAD_TYPE PARTITION requires PARTITION_COLUMN'
          FROM tbl
         WHERE UPPER(load_type) = 'PARTITION' AND (partition_column IS NULL OR TRIM(partition_column) = '')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] FILE requires FILE_PATTERN'
          FROM tbl
         WHERE src_type = 'FILE' AND (file_pattern IS NULL OR TRIM(file_pattern) = '')
        UNION ALL
        SELECT 'ETL_TABLES [' || source_id || '.' || table_name || '] DATABASE requires SOURCE_OBJECT'
          FROM tbl
         WHERE src_type = 'DATABASE' AND (source_object IS NULL OR TRIM(source_object) = '')
        UNION ALL
        -- ORPHAN: an active table whose SOURCE_ID does not exist at all is a genuine config
        -- error (typo / deleted source). An active table under an INACTIVE source is NOT an
        -- error - that is a deliberate switch-off and is simply out of scope above.
        SELECT 'ETL_TABLES [' || t.source_id || '.' || t.table_name || '] references SOURCE_ID that does not exist in ETL_SOURCES'
          FROM ADM.ETL_TABLES t
         WHERE t.active_flag
           AND NOT EXISTS (SELECT 1 FROM ADM.ETL_SOURCES s WHERE s.source_id = t.source_id)
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
        )
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
                    )
                ) INTO :v_log_rows;
            END IF;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;
        RAISE;
END;
