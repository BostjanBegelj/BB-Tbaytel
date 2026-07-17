-- ADM.SP_CHECK_DATA_CHANGE - decide whether this PPN's BRONZE load is IDENTICAL to the
-- last snapshot already in BRONZE_HIST, so the caller can skip HIST append + SILVER.
-- Comparison = row COUNT + order-independent content HASH_AGG over BUSINESS columns only
-- (excludes PPN_ID, PPN_TIMESTAMP, METADATA$FILENAME, which change every load).
-- "Previous" = MAX(PPN_ID) in BRONZE_HIST for the table, excluding the current PPN.
-- No history yet -> NO_PREVIOUS (treat as changed; proceed). Logs one CHECK_DATA_CHANGE row.
-- Returns a status VARIANT (child pattern). Does NOT itself skip anything - the orchestrator
-- reads is_identical and decides.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_CHECK_DATA_CHANGE(
    "P_PPN_ID"     NUMBER(38,0),
    "P_SOURCE_ID"  VARCHAR,
    "P_TABLE_NAME" VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Compare current BRONZE vs last BRONZE_HIST snapshot (count + HASH_AGG on business cols). Returns is_identical.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20250, 'SP_CHECK_DATA_CHANGE failed.');

    v_ppn_id      NUMBER  DEFAULT P_PPN_ID;
    v_source_id   STRING  DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_table       STRING  DEFAULT UPPER(NULLIF(TRIM(P_TABLE_NAME), ''));

    v_src_sch     STRING;
    v_hist_sch    STRING;
    v_db          STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_bronze_fq   STRING;
    v_hist_fq     STRING;
    v_cols        STRING;

    v_cfg_count   NUMBER  DEFAULT 0;
    v_hist_exists NUMBER  DEFAULT 0;
    v_prev_ppn    NUMBER;
    v_new_cnt     NUMBER  DEFAULT 0;
    v_prev_cnt    NUMBER  DEFAULT 0;
    v_new_hash    NUMBER;
    v_prev_hash   NUMBER;
    v_identical   BOOLEAN DEFAULT FALSE;
    v_action      STRING  DEFAULT 'DIFFERENT';

    v_started_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_phase       STRING  DEFAULT 'INIT';
    v_error_msg   STRING;
    v_sql         STRING;
    v_log_rows    NUMBER  DEFAULT 0;
    v_log_status  STRING;
    v_msg         STRING;
BEGIN
    /* 1. VALIDATE ------------------------------------------------------- */
    v_phase := 'VALIDATE';
    IF (v_ppn_id IS NULL OR v_source_id IS NULL OR v_table IS NULL) THEN
        v_error_msg := 'P_PPN_ID, P_SOURCE_ID and P_TABLE_NAME are required.';
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

    SELECT UPPER(COALESCE(target_schema, 'BRONZE'))
      INTO :v_src_sch
      FROM ADM.ETL_TABLES
     WHERE source_id = :v_source_id AND table_name = :v_table AND active_flag;

    v_hist_sch  := v_src_sch || '_HIST';
    v_bronze_fq := '"' || v_db || '"."' || v_src_sch  || '"."' || v_table || '"';
    v_hist_fq   := '"' || v_db || '"."' || v_hist_sch || '"."' || v_table || '"';

    /* 3. NO HISTORY TABLE YET -> no previous snapshot ------------------- */
    v_phase := 'CHECK_HIST';
    SELECT COUNT(*) INTO :v_hist_exists
      FROM DEV_DB.INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = :v_hist_sch AND TABLE_NAME = :v_table;

    IF (v_hist_exists > 0) THEN
        v_sql := 'SELECT MAX(PPN_ID) FROM ' || v_hist_fq || ' WHERE PPN_ID <> ' || v_ppn_id;
        EXECUTE IMMEDIATE v_sql;
        SELECT $1 INTO :v_prev_ppn FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    END IF;

    IF (v_hist_exists = 0 OR v_prev_ppn IS NULL) THEN
        v_action := 'NO_PREVIOUS';
        v_identical := FALSE;
        v_msg := 'SUCCESS: no previous BRONZE_HIST snapshot; treated as changed (proceed).';
        v_log_status := 'SUCCESS';
    ELSE
        /* 4. BUILD BUSINESS COLUMN LIST --------------------------------- */
        v_phase := 'BUILD_COLS';
        SELECT LISTAGG('"' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
          INTO :v_cols
          FROM DEV_DB.INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_SCHEMA = :v_src_sch AND TABLE_NAME = :v_table
           AND COLUMN_NAME NOT IN ('PPN_ID', 'PPN_TIMESTAMP', 'METADATA$FILENAME');

        /* 5. COUNT + HASH each side ------------------------------------- */
        v_phase := 'COMPARE';
        v_sql := 'SELECT COUNT(*), HASH_AGG(' || v_cols || ') FROM ' || v_bronze_fq || ' WHERE PPN_ID = ' || v_ppn_id;
        EXECUTE IMMEDIATE v_sql;
        SELECT $1, $2 INTO :v_new_cnt, :v_new_hash FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

        v_sql := 'SELECT COUNT(*), HASH_AGG(' || v_cols || ') FROM ' || v_hist_fq || ' WHERE PPN_ID = ' || v_prev_ppn;
        EXECUTE IMMEDIATE v_sql;
        SELECT $1, $2 INTO :v_prev_cnt, :v_prev_hash FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

        v_identical := (v_new_cnt = v_prev_cnt) AND EQUAL_NULL(v_new_hash, v_prev_hash);
        v_action    := IFF(v_identical, 'IDENTICAL', 'DIFFERENT');
        v_log_status := IFF(v_identical, 'SKIP', 'SUCCESS');
        v_msg := IFF(v_identical,
                     'SKIP: BRONZE identical to last BRONZE_HIST snapshot (prev ppn ' || v_prev_ppn || '); caller may skip HIST+SILVER.',
                     'SUCCESS: BRONZE differs from last snapshot (prev ppn ' || v_prev_ppn || '); proceed.');
    END IF;

    /* 6. LOG ------------------------------------------------------------ */
    v_phase := 'LOG';
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID        => :v_ppn_id,
        P_PHASE         => 'CHECK_DATA_CHANGE',
        P_STATUS        => :v_log_status,
        P_SOURCE_ID     => :v_source_id,
        P_TABLE_NAME    => :v_table,
        P_LOG_START     => :v_started_at,
        P_LOG_END       => CURRENT_TIMESTAMP(),
        P_SOURCE_OBJECT => :v_bronze_fq,
        P_TARGET_OBJECT => :v_hist_fq,
        P_ROW_COUNT     => :v_new_cnt,
        P_MESSAGE       => :v_msg,
        P_DETAIL_JSON   => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_CHECK_DATA_CHANGE','ppn_id',:v_ppn_id),
            'results', OBJECT_CONSTRUCT('action',:v_action,'is_identical',:v_identical,
                                        'prev_ppn',:v_prev_ppn,'new_count',:v_new_cnt,'prev_count',:v_prev_cnt)
        )::STRING
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_CHECK_DATA_CHANGE',
        'source_id', v_source_id,
        'table', v_table,
        'action', v_action,
        'is_identical', v_identical,
        'prev_ppn', v_prev_ppn,
        'new_count', v_new_cnt,
        'prev_count', v_prev_cnt,
        'ppn_id', v_ppn_id
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        BEGIN
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_ppn_id,
                P_PHASE       => 'CHECK_DATA_CHANGE',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR: SP_CHECK_DATA_CHANGE failed.',
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_CHECK_DATA_CHANGE',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_CHECK_DATA_CHANGE','ppn_id',:v_ppn_id)
                )::STRING
            ) INTO :v_log_rows;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'procedure', 'SP_CHECK_DATA_CHANGE',
            'phase', v_phase,
            'message', v_final_msg
        );
END;
