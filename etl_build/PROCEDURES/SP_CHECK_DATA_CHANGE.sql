-- ADM.SP_CHECK_DATA_CHANGE - decide whether this PPN's BRONZE load is IDENTICAL to the
-- last snapshot already in BRONZE_HIST, so the caller can skip HIST append + SILVER.
-- Comparison = row COUNT + order-independent content HASH_AGG over BUSINESS columns only
-- (excludes PPN_ID, PPN_TIMESTAMP, METADATA$FILENAME, which change every load).
-- Returns a status VARIANT (child pattern); writes PPN_LOG only - PPN_PROCESS state is owned
-- by SP_RUN_TABLE_LOAD. Does NOT itself skip anything: the caller reads is_identical.
--
-- Decision order (first match wins):
--   1. RETRY_FORCE   - BRONZE_HIST already has rows for THIS PPN => a rerun. Never skip:
--                      the previous attempt may have written HIST and then failed at SILVER,
--                      and comparing against an OLDER PPN could wrongly report IDENTICAL and
--                      leave HIST/SILVER inconsistent with this PPN's input. HIST (delete+
--                      insert per PPN) and SILVER (MERGE) are idempotent, so reprocessing is safe.
--   2. NO_PREVIOUS   - no history table / no earlier PPN to compare with => proceed.
--   3. SCHEMA_CHANGED- BRONZE vs BRONZE_HIST business column sets differ (e.g. the source added
--                      a column). Hashing here would fail, because the HIST table has not been
--                      structure-synced yet (SP_SYNC_TABLE_STRUCTURE runs later, inside
--                      SP_LOAD_BRONZE_TO_HIST). A structural change IS a change, so report
--                      DIFFERENT and let HIST/SILVER sync then load.
--   4. IDENTICAL / DIFFERENT - count + HASH_AGG comparison against the previous snapshot.

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
COMMENT = 'Compare current BRONZE vs last BRONZE_HIST snapshot (count + HASH_AGG). Returns is_identical + action.'
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
    v_cols_hist   STRING;

    v_cfg_count   NUMBER  DEFAULT 0;
    v_hist_exists NUMBER  DEFAULT 0;
    v_self_rows   NUMBER  DEFAULT 0;
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
    /*    Authoritative validation lives in SP_RUN_TABLE_LOAD; this only guards this
          procedure's own read (config removed mid-run / standalone call).            */
    v_phase := 'READ_CONFIG';
    SELECT COUNT(*), MAX(UPPER(COALESCE(t.target_schema, 'BRONZE')))
      INTO :v_cfg_count, :v_src_sch
      FROM ADM.ETL_TABLES t
      JOIN ADM.ETL_SOURCES s ON s.source_id = t.source_id
     WHERE t.source_id = :v_source_id
       AND t.table_name = :v_table
       AND t.active_flag
       AND s.active_flag;

    IF (v_cfg_count <> 1) THEN
        v_error_msg := 'Expected exactly 1 active config row for [' || v_source_id || '.' || v_table
                    || '] at change-check time, found ' || v_cfg_count || ' (config changed mid-run?).';
        RAISE e_failed;
    END IF;

    v_hist_sch  := v_src_sch || '_HIST';
    v_bronze_fq := '"' || v_db || '"."' || v_src_sch  || '"."' || v_table || '"';
    v_hist_fq   := '"' || v_db || '"."' || v_hist_sch || '"."' || v_table || '"';

    /* 3. DOES A HISTORY TABLE EXIST? ------------------------------------ */
    v_phase := 'CHECK_HIST';
    SELECT COUNT(*) INTO :v_hist_exists
      FROM INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = :v_hist_sch AND TABLE_NAME = :v_table;

    IF (v_hist_exists > 0) THEN
        -- rows already written for THIS PPN? (i.e. this is a rerun)
        v_sql := 'SELECT COUNT(*) FROM ' || v_hist_fq || ' WHERE PPN_ID = ' || v_ppn_id;
        EXECUTE IMMEDIATE v_sql;
        SELECT $1 INTO :v_self_rows FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

        -- newest earlier snapshot to compare against
        v_sql := 'SELECT MAX(PPN_ID) FROM ' || v_hist_fq || ' WHERE PPN_ID <> ' || v_ppn_id;
        EXECUTE IMMEDIATE v_sql;
        SELECT $1 INTO :v_prev_ppn FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    END IF;

    IF (v_self_rows > 0) THEN
        /* --- 1. RERUN: never skip ------------------------------------- */
        v_action     := 'RETRY_FORCE';
        v_identical  := FALSE;
        v_log_status := 'SUCCESS';
        v_msg := 'SUCCESS: BRONZE_HIST already holds ' || v_self_rows || ' row(s) for this PPN (rerun); ' ||
                 'forcing HIST + SILVER so they match this PPN''s current input.';

    ELSEIF (v_hist_exists = 0 OR v_prev_ppn IS NULL) THEN
        /* --- 2. nothing to compare with ------------------------------- */
        v_action     := 'NO_PREVIOUS';
        v_identical  := FALSE;
        v_log_status := 'SUCCESS';
        v_msg := 'SUCCESS: no previous BRONZE_HIST snapshot; treated as changed (proceed).';

    ELSE
        /* --- business column sets (both sides) ------------------------ */
        v_phase := 'BUILD_COLS';
        SELECT LISTAGG('"' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
          INTO :v_cols
          FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_SCHEMA = :v_src_sch AND TABLE_NAME = :v_table
           AND COLUMN_NAME NOT IN ('PPN_ID', 'PPN_TIMESTAMP', 'METADATA$FILENAME');

        -- name sets, order-independent, for a structural comparison
        SELECT LISTAGG(COLUMN_NAME, ',') WITHIN GROUP (ORDER BY COLUMN_NAME)
          INTO :v_cols_hist
          FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_SCHEMA = :v_hist_sch AND TABLE_NAME = :v_table
           AND COLUMN_NAME NOT IN ('PPN_ID', 'PPN_TIMESTAMP', 'METADATA$FILENAME');

        LET v_cols_bronze STRING;
        SELECT LISTAGG(COLUMN_NAME, ',') WITHIN GROUP (ORDER BY COLUMN_NAME)
          INTO :v_cols_bronze
          FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_SCHEMA = :v_src_sch AND TABLE_NAME = :v_table
           AND COLUMN_NAME NOT IN ('PPN_ID', 'PPN_TIMESTAMP', 'METADATA$FILENAME');

        IF (NOT EQUAL_NULL(v_cols_bronze, v_cols_hist)) THEN
            /* --- 3. structural change: do NOT hash (HIST not synced yet) */
            v_action     := 'SCHEMA_CHANGED';
            v_identical  := FALSE;
            v_log_status := 'SUCCESS';
            v_msg := 'SUCCESS: BRONZE and BRONZE_HIST column sets differ (schema drift); ' ||
                     'treated as changed so HIST/SILVER structure-sync then load.';
        ELSE
            /* --- 4. content comparison ------------------------------- */
            v_phase := 'COMPARE';
            v_sql := 'SELECT COUNT(*), HASH_AGG(' || v_cols || ') FROM ' || v_bronze_fq || ' WHERE PPN_ID = ' || v_ppn_id;
            EXECUTE IMMEDIATE v_sql;
            SELECT $1, $2 INTO :v_new_cnt, :v_new_hash FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

            v_sql := 'SELECT COUNT(*), HASH_AGG(' || v_cols || ') FROM ' || v_hist_fq || ' WHERE PPN_ID = ' || v_prev_ppn;
            EXECUTE IMMEDIATE v_sql;
            SELECT $1, $2 INTO :v_prev_cnt, :v_prev_hash FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

            v_identical  := (v_new_cnt = v_prev_cnt) AND EQUAL_NULL(v_new_hash, v_prev_hash);
            v_action     := IFF(v_identical, 'IDENTICAL', 'DIFFERENT');
            v_log_status := IFF(v_identical, 'SKIP', 'SUCCESS');
            v_msg := IFF(v_identical,
                         'SKIP: BRONZE identical to last BRONZE_HIST snapshot (prev ppn ' || v_prev_ppn || '); caller may skip HIST+SILVER.',
                         'SUCCESS: BRONZE differs from last snapshot (prev ppn ' || v_prev_ppn || '); proceed.');
        END IF;
    END IF;

    /* 5. LOG ------------------------------------------------------------ */
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
                                        'prev_ppn',:v_prev_ppn,'self_hist_rows',:v_self_rows,
                                        'new_count',:v_new_cnt,'prev_count',:v_prev_cnt)
        )
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_CHECK_DATA_CHANGE',
        'source_id', v_source_id,
        'table', v_table,
        'action', v_action,
        'is_identical', v_identical,
        'prev_ppn', v_prev_ppn,
        'self_hist_rows', v_self_rows,
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
                P_MESSAGE     => 'ERROR [SP_CHECK_DATA_CHANGE/' || :v_phase || ']: ' || :v_final_msg,
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_CHECK_DATA_CHANGE',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_CHECK_DATA_CHANGE','ppn_id',:v_ppn_id)
                )
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
