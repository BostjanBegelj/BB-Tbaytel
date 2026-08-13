-- ADM.SP_LOAD_SHARE_TO_BRONZE - DATASHARE load pattern: read one table directly from
-- an inbound shared database into <TARGET_SCHEMA>.<TABLE> (default BRONZE).
-- No stage / no COPY: a per-PPN snapshot via CREATE OR REPLACE TABLE ... AS SELECT,
-- so the batch is stable and idempotent per PPN. Config-driven, mirrors
-- SP_LOAD_FILE_TO_BRONZE (same helpers, same child error pattern).
-- Always lands a FULL snapshot of the shared object into BRONZE.
-- NOTE: WATERMARK_COLUMN is currently NOT used by this procedure or by SILVER - an INCR
-- data-share table is landed in full and then MERGEd (correct, just not optimised). Watermark-
-- bounded extraction is a future optimisation, not current behaviour.
-- Writes PPN_LOG only; PPN_PROCESS state is owned by SP_RUN_TABLE_LOAD.
-- RUN_ID is resolved from ADM.PPN by SP_LOG_STEP, so it is not a parameter here.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_LOAD_SHARE_TO_BRONZE(
    "P_PPN_ID"     NUMBER(38,0),
    "P_SOURCE_ID"  VARCHAR,
    "P_TABLE_NAME" VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'DATASHARE pattern: per-PPN snapshot from SHARE_DB.SOURCE_OBJECT into <TARGET_SCHEMA>.<TABLE>. Config-driven.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20800, 'SP_LOAD_SHARE_TO_BRONZE failed.');

    v_ppn_id      NUMBER  DEFAULT P_PPN_ID;
    v_source_id   STRING  DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_table       STRING  DEFAULT UPPER(NULLIF(TRIM(P_TABLE_NAME), ''));

    v_share_db    STRING;
    v_source_obj  STRING;
    v_target_sch  STRING;

    v_db          STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_target_fq   STRING;
    v_src_fq      STRING;
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
    SELECT COUNT(*), MAX(s.share_db), MAX(t.source_object),
           MAX(UPPER(COALESCE(t.target_schema, 'BRONZE')))
      INTO :v_cfg_count, :v_share_db, :v_source_obj, :v_target_sch
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
    IF (v_share_db IS NULL OR v_source_obj IS NULL) THEN
        v_error_msg := 'Config incomplete: DATASHARE needs SHARE_DB (source) and SOURCE_OBJECT (table).';
        RAISE e_failed;
    END IF;

    v_src_fq    := v_share_db || '.' || v_source_obj;                       -- e.g. SHARE_SIM_DB.WHOLESALE.PARTNER_ACCOUNT
    v_target_fq := '"' || v_db || '"."' || v_target_sch || '"."' || v_table || '"';

    SELECT PPN_TIMESTAMP INTO :v_ppn_ts FROM ADM.PPN WHERE PPN_ID = :v_ppn_id;

    /* 3. SNAPSHOT (CTAS) with lineage columns --------------------------- */
    v_phase := 'SNAPSHOT';
    v_sql := 'CREATE OR REPLACE TABLE ' || v_target_fq || ' AS
        SELECT s.*,
               ' || v_ppn_id || ' AS PPN_ID,
               ''' || TO_CHAR(v_ppn_ts, 'YYYY-MM-DD HH24:MI:SS.FF9') || '''::TIMESTAMP_NTZ(9) AS PPN_TIMESTAMP
        FROM ' || v_src_fq || ' s';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 4. COUNT ---------------------------------------------------------- */
    v_phase := 'COUNT';
    SELECT COUNT(*) INTO :v_row_count FROM IDENTIFIER(:v_target_fq) WHERE PPN_ID = :v_ppn_id;

    /* 5. LOG SUCCESS (state is owned by SP_RUN_TABLE_LOAD) -------------- */
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn_id,
        P_PHASE       => 'LOAD_SHARE_TO_BRONZE',
        P_STATUS      => 'SUCCESS',
        P_SOURCE_ID   => :v_source_id,
        P_TABLE_NAME  => :v_table,
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_SOURCE_OBJECT => :v_src_fq,
        P_TARGET_OBJECT => :v_target_fq,
        P_ROW_COUNT   => :v_row_count,
        P_MESSAGE     => 'SUCCESS: snapshot ' || :v_row_count || ' row(s) into ' || :v_target_sch || '.' || :v_table || '.',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_SHARE_TO_BRONZE','ppn_id',:v_ppn_id),
            'results', OBJECT_CONSTRUCT('source', :v_src_fq, 'rows_loaded', :v_row_count)
        )::STRING
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_LOAD_SHARE_TO_BRONZE',
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
                P_PHASE       => 'LOAD_SHARE_TO_BRONZE',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR [SP_LOAD_SHARE_TO_BRONZE/' || :v_phase || ']: ' || :v_final_msg,
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_LOAD_SHARE_TO_BRONZE',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'last_sql',         NULLIF(:v_last_sql, ''),
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_SHARE_TO_BRONZE','ppn_id',:v_ppn_id)
                )::STRING
            ) INTO :v_log_rows;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'procedure', 'SP_LOAD_SHARE_TO_BRONZE',
            'phase', v_phase,
            'message', v_final_msg,
            'last_sql', v_last_sql
        );
END;
