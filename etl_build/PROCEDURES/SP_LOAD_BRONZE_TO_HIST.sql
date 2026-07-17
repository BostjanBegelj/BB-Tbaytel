-- ADM.SP_LOAD_BRONZE_TO_HIST - append the current BRONZE data for this PPN into
-- BRONZE_HIST (the immutable per-load history / lineage). Idempotent per PPN:
-- rows for the PPN are deleted before insert, so re-running a PPN never duplicates.
-- Source-type agnostic (works for Parquet- and share-landed tables alike).
-- History schema is derived as <TARGET_SCHEMA>_HIST (BRONZE -> BRONZE_HIST).
-- RUN_ID is resolved from ADM.PPN by SP_LOG_STEP, so it is not a parameter here.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_LOAD_BRONZE_TO_HIST(
    "P_PPN_ID"     NUMBER(38,0),
    "P_SOURCE_ID"  VARCHAR,
    "P_TABLE_NAME" VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Append BRONZE.<table> (this PPN) into BRONZE_HIST.<table>. Idempotent per PPN. Config-driven.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20900, 'SP_LOAD_BRONZE_TO_HIST failed.');

    v_ppn_id      NUMBER  DEFAULT P_PPN_ID;
    v_source_id   STRING  DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_table       STRING  DEFAULT UPPER(NULLIF(TRIM(P_TABLE_NAME), ''));

    v_src_sch     STRING;
    v_hist_sch    STRING;
    v_db          STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_src_fq      STRING;
    v_hist_fq     STRING;

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
    IF (NOT REGEXP_LIKE(v_table, '^[A-Z][A-Z0-9_]*$')) THEN
        v_error_msg := 'Invalid P_TABLE_NAME [' || v_table || '].';
        RAISE e_failed;
    END IF;

    /* 2. READ CONFIG (target/source layer) ------------------------------ */
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

    SELECT UPPER(COALESCE(t.target_schema, 'BRONZE'))
      INTO :v_src_sch
      FROM ADM.ETL_TABLES t
     WHERE t.source_id = :v_source_id AND t.table_name = :v_table AND t.active_flag;

    v_hist_sch := v_src_sch || '_HIST';                                    -- BRONZE -> BRONZE_HIST
    v_src_fq   := '"' || v_db || '"."' || v_src_sch  || '"."' || v_table || '"';
    v_hist_fq  := '"' || v_db || '"."' || v_hist_sch || '"."' || v_table || '"';

    /* mark state RUNNING */
    CALL ADM.SP_SET_PROCESS_STATE(:v_ppn_id, :v_source_id, :v_table, 'RUNNING', 'LOAD_BRONZE_TO_HIST');

    /* 3. ENSURE HISTORY TABLE EXISTS (structure mirrors BRONZE) --------- */
    v_phase := 'CREATE_HIST';
    v_sql := 'CREATE TABLE IF NOT EXISTS ' || v_hist_fq || ' LIKE ' || v_src_fq;
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 4. IDEMPOTENT APPEND: delete this PPN, then insert --------------- */
    v_phase := 'DELETE_PPN';
    v_sql := 'DELETE FROM ' || v_hist_fq || ' WHERE PPN_ID = ' || v_ppn_id;
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    v_phase := 'INSERT_HIST';
    v_sql := 'INSERT INTO ' || v_hist_fq || ' SELECT * FROM ' || v_src_fq || ' WHERE PPN_ID = ' || v_ppn_id;
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 5. COUNT ---------------------------------------------------------- */
    v_phase := 'COUNT';
    SELECT COUNT(*) INTO :v_row_count FROM IDENTIFIER(:v_hist_fq) WHERE PPN_ID = :v_ppn_id;

    /* 6. STATE + LOG SUCCESS ------------------------------------------- */
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_SET_PROCESS_STATE(:v_ppn_id, :v_source_id, :v_table, 'SUCCESS', 'LOAD_BRONZE_TO_HIST',
                                  NULL, :v_row_count, NULL, NULL, NULL, NULL, TRUE);
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn_id,
        P_PHASE       => 'LOAD_BRONZE_TO_HIST',
        P_STATUS      => 'SUCCESS',
        P_SOURCE_ID   => :v_source_id,
        P_TABLE_NAME  => :v_table,
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_SOURCE_OBJECT => :v_src_fq,
        P_TARGET_OBJECT => :v_hist_fq,
        P_ROW_COUNT   => :v_row_count,
        P_MESSAGE     => 'SUCCESS: appended ' || :v_row_count || ' row(s) into ' || :v_hist_sch || '.' || :v_table || '.',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_BRONZE_TO_HIST','ppn_id',:v_ppn_id),
            'results', OBJECT_CONSTRUCT('rows_appended', :v_row_count)
        )::STRING
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_LOAD_BRONZE_TO_HIST',
        'source_id', v_source_id,
        'table', v_table,
        'target_object', v_hist_fq,
        'rows_appended', v_row_count,
        'ppn_id', v_ppn_id
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        BEGIN
            CALL ADM.SP_SET_PROCESS_STATE(:v_ppn_id, :v_source_id, :v_table, 'ERROR', :v_phase,
                                          NULL, NULL, NULL, NULL, NULL, :v_final_msg, TRUE);
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_ppn_id,
                P_PHASE       => 'LOAD_BRONZE_TO_HIST',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR: SP_LOAD_BRONZE_TO_HIST failed.',
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_LOAD_BRONZE_TO_HIST',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'last_sql',         NULLIF(:v_last_sql, ''),
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_BRONZE_TO_HIST','ppn_id',:v_ppn_id)
                )::STRING
            ) INTO :v_log_rows;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'procedure', 'SP_LOAD_BRONZE_TO_HIST',
            'phase', v_phase,
            'message', v_final_msg,
            'last_sql', v_last_sql
        );
END;
