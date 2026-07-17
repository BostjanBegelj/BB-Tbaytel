-- ADM.SP_RUN_TABLE_LOAD - per-table orchestrator (the "wrapped" model). ADF calls this
-- ONCE per table; it chains the Snowflake phases and returns one result:
--   1. LANDING   -> SP_LOAD_FILE_TO_BRONZE (PARQUET) | SP_LOAD_SHARE_TO_BRONZE (DATASHARE)
--   2. CHANGE    -> SP_CHECK_DATA_CHANGE; if identical -> mark PPN_PROCESS SKIP and stop (no HIST/SILVER)
--   3. HIST      -> SP_LOAD_BRONZE_TO_HIST
--   4. SILVER    -> SP_LOAD_BRONZE_TO_SILVER
-- Failure isolation: child load procs already log + set PPN_PROCESS=ERROR and return an error
-- object. This wrapper checks each child's status and, on failure, STOPS this table and returns
-- an ERROR object WITHOUT raising - so one bad table doesn't abort the run; the run-level
-- SP_GATE_CHECK (fail-closed) blocks GOLD because the table's state is ERROR.
-- RUN_ID is resolved from ADM.PPN by SP_LOG_STEP (not a parameter here).

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_RUN_TABLE_LOAD(
    "P_PPN_ID"     NUMBER(38,0),
    "P_SOURCE_ID"  VARCHAR,
    "P_TABLE_NAME" VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Per-table orchestrator: landing -> check-change -> HIST -> SILVER. Returns SUCCESS/SKIPPED/ERROR.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20260, 'SP_RUN_TABLE_LOAD failed.');

    v_ppn_id      NUMBER  DEFAULT P_PPN_ID;
    v_source_id   STRING  DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_table       STRING  DEFAULT UPPER(NULLIF(TRIM(P_TABLE_NAME), ''));

    v_source_type STRING;
    v_cfg_count   NUMBER  DEFAULT 0;

    v_land        VARIANT;
    v_check       VARIANT;
    v_hist        VARIANT;
    v_silver      VARIANT;

    v_phase       STRING  DEFAULT 'INIT';
    v_error_msg   STRING;
    v_log_rows    NUMBER  DEFAULT 0;
BEGIN
    /* 1. VALIDATE + read source type ------------------------------------ */
    v_phase := 'READ_CONFIG';
    IF (v_ppn_id IS NULL OR v_source_id IS NULL OR v_table IS NULL) THEN
        v_error_msg := 'P_PPN_ID, P_SOURCE_ID and P_TABLE_NAME are required.';
        RAISE e_failed;
    END IF;

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

    SELECT UPPER(s.source_type)
      INTO :v_source_type
      FROM ADM.ETL_TABLES t
      JOIN ADM.ETL_SOURCES s ON s.source_id = t.source_id
     WHERE t.source_id = :v_source_id AND t.table_name = :v_table AND t.active_flag AND s.active_flag;

    /* 2. LANDING (dispatch by SOURCE_TYPE) ------------------------------ */
    v_phase := 'LANDING';
    IF (v_source_type = 'PARQUET') THEN
        CALL ADM.SP_LOAD_FILE_TO_BRONZE(:v_ppn_id, :v_source_id, :v_table) INTO :v_land;
    ELSEIF (v_source_type = 'DATASHARE') THEN
        CALL ADM.SP_LOAD_SHARE_TO_BRONZE(:v_ppn_id, :v_source_id, :v_table) INTO :v_land;
    ELSE
        v_error_msg := 'Unknown SOURCE_TYPE [' || COALESCE(v_source_type, '<null>') || '] for [' || v_source_id || '].';
        RAISE e_failed;
    END IF;
    IF (UPPER(COALESCE(GET(v_land, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_RUN_TABLE_LOAD','failed_phase','LANDING',
                                'source_id',v_source_id,'table',v_table,'ppn_id',v_ppn_id,'landing_result',v_land);
    END IF;

    /* 3. CHECK DATA CHANGE (skip HIST+SILVER if identical) -------------- */
    v_phase := 'CHECK';
    CALL ADM.SP_CHECK_DATA_CHANGE(:v_ppn_id, :v_source_id, :v_table) INTO :v_check;
    IF (UPPER(COALESCE(GET(v_check, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_RUN_TABLE_LOAD','failed_phase','CHECK',
                                'source_id',v_source_id,'table',v_table,'ppn_id',v_ppn_id,'check_result',v_check);
    END IF;

    IF (COALESCE(GET(v_check, 'is_identical')::BOOLEAN, FALSE)) THEN
        -- identical to last snapshot: mark table SKIP (counts as OK at the gate), skip HIST + SILVER
        CALL ADM.SP_SET_PROCESS_STATE(:v_ppn_id, :v_source_id, :v_table, 'SKIP', 'CHECK_DATA_CHANGE',
                                      NULL, NULL, NULL, NULL, NULL, NULL, TRUE) INTO :v_log_rows;
        RETURN OBJECT_CONSTRUCT('status','SUCCESS','action','SKIPPED_IDENTICAL','procedure','SP_RUN_TABLE_LOAD',
                                'source_id',v_source_id,'table',v_table,'ppn_id',v_ppn_id,
                                'landing_result',v_land,'check_result',v_check);
    END IF;

    /* 4. HIST ----------------------------------------------------------- */
    v_phase := 'HIST';
    CALL ADM.SP_LOAD_BRONZE_TO_HIST(:v_ppn_id, :v_source_id, :v_table) INTO :v_hist;
    IF (UPPER(COALESCE(GET(v_hist, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_RUN_TABLE_LOAD','failed_phase','HIST',
                                'source_id',v_source_id,'table',v_table,'ppn_id',v_ppn_id,'hist_result',v_hist);
    END IF;

    /* 5. SILVER --------------------------------------------------------- */
    v_phase := 'SILVER';
    CALL ADM.SP_LOAD_BRONZE_TO_SILVER(:v_ppn_id, :v_source_id, :v_table) INTO :v_silver;
    IF (UPPER(COALESCE(GET(v_silver, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_RUN_TABLE_LOAD','failed_phase','SILVER',
                                'source_id',v_source_id,'table',v_table,'ppn_id',v_ppn_id,'silver_result',v_silver);
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'status','SUCCESS','action','PROCESSED','procedure','SP_RUN_TABLE_LOAD',
        'source_id',v_source_id,'table',v_table,'ppn_id',v_ppn_id,
        'landing_result',v_land,'check_result',v_check,'hist_result',v_hist,'silver_result',v_silver
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        -- own (engine/config) failure: record ERROR state for the table so the gate blocks GOLD
        BEGIN
            CALL ADM.SP_SET_PROCESS_STATE(:v_ppn_id, :v_source_id, :v_table, 'ERROR', :v_phase,
                                          NULL, NULL, NULL, NULL, NULL, :v_final_msg, TRUE) INTO :v_log_rows;
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID => :v_ppn_id, P_PHASE => 'RUN_TABLE_LOAD', P_STATUS => 'ERROR',
                P_SOURCE_ID => :v_source_id, P_TABLE_NAME => :v_table,
                P_MESSAGE => 'ERROR: SP_RUN_TABLE_LOAD failed.',
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT('source_procedure','SP_RUN_TABLE_LOAD','source_phase',:v_phase,
                        'message',:v_final_msg,'sqlcode',IFF(:v_error_msg IS NULL,:SQLCODE,NULL),
                        'sqlstate',IFF(:v_error_msg IS NULL,:SQLSTATE,NULL)),
                    'context', OBJECT_CONSTRUCT('procedure','SP_RUN_TABLE_LOAD','ppn_id',:v_ppn_id)
                )::STRING
            ) INTO :v_log_rows;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_RUN_TABLE_LOAD','failed_phase',v_phase,
                                'source_id',v_source_id,'table',v_table,'ppn_id',v_ppn_id,'message',v_final_msg);
END;
