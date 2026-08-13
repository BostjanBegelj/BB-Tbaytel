-- ADM.SP_LOAD_BRONZE_TO_HIST - append the current BRONZE data for this PPN into
-- BRONZE_HIST (the immutable per-load history / lineage). Idempotent per PPN:
-- rows for the PPN are deleted before insert, so re-running a PPN never duplicates.
-- Source-type agnostic (works for Parquet- and share-landed tables alike).
-- Writes PPN_LOG only; PPN_PROCESS state is owned by SP_RUN_TABLE_LOAD.
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
    v_cols_all    STRING;
    v_sync        VARIANT;
    v_txn_open    BOOLEAN DEFAULT FALSE;

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

    /* 2. READ CONFIG (target/source layer) ------------------------------ */
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
                    || '] at HIST time, found ' || v_cfg_count || ' (config changed mid-run?).';
        RAISE e_failed;
    END IF;

    v_hist_sch := v_src_sch || '_HIST';                                    -- BRONZE -> BRONZE_HIST
    v_src_fq   := '"' || v_db || '"."' || v_src_sch  || '"."' || v_table || '"';
    v_hist_fq  := '"' || v_db || '"."' || v_hist_sch || '"."' || v_table || '"';

    /* 3. RECONCILE HISTORY STRUCTURE TO BRONZE (create / add columns) --- */
    /*    DDL first — must run OUTSIDE the transaction below.             */
    v_phase := 'SYNC_HIST';
    CALL ADM.SP_SYNC_TABLE_STRUCTURE(
        P_SOURCE_SCHEMA => :v_src_sch, P_TARGET_SCHEMA => :v_hist_sch,
        P_TABLE_NAME => :v_table) INTO :v_sync;
    IF (GET(:v_sync, 'status')::STRING <> 'SUCCESS') THEN
        v_error_msg := 'Structure sync failed: ' || COALESCE(GET(:v_sync, 'message')::STRING, '(no message)');
        RAISE e_failed;
    END IF;
    -- audit structural changes only (CREATED / ALTERED); NOCHANGE stays quiet
    IF (GET(:v_sync, 'action')::STRING IN ('CREATED', 'ALTERED')) THEN
        CALL ADM.SP_LOG_STEP(
            P_PPN_ID        => :v_ppn_id,
            P_PHASE         => 'SYNC_HIST',
            P_STATUS        => 'SUCCESS',
            P_SOURCE_ID     => :v_source_id,
            P_TABLE_NAME    => :v_table,
            P_TARGET_OBJECT => :v_hist_fq,
            P_MESSAGE       => 'STRUCTURE ' || GET(:v_sync, 'action')::STRING || ' on ' || :v_hist_sch || '.' || :v_table || '.',
            P_DETAIL_JSON   => OBJECT_CONSTRUCT(
                'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_BRONZE_TO_HIST','ppn_id',:v_ppn_id),
                'sync', :v_sync
            )
        ) INTO :v_log_rows;
    END IF;

    -- all BRONZE columns (explicit list so extra history columns don't misalign)
    SELECT LISTAGG('"' || COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
      INTO :v_cols_all
      FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA = :v_src_sch AND TABLE_NAME = :v_table;

    /* 4. IDEMPOTENT APPEND (ATOMIC): delete this PPN, then insert ------- */
    /*    One transaction: a failure mid-way must not leave history with the
          old rows deleted and the new ones missing. Procedures are NOT atomic
          by default in Snowflake, so the transaction is explicit.           */
    v_phase := 'APPEND_TXN';
    BEGIN TRANSACTION;
    v_txn_open := TRUE;

    v_phase := 'DELETE_PPN';
    v_sql := 'DELETE FROM ' || v_hist_fq || ' WHERE PPN_ID = ' || v_ppn_id;
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    v_phase := 'INSERT_HIST';
    v_sql := 'INSERT INTO ' || v_hist_fq || ' (' || v_cols_all || ') SELECT ' || v_cols_all ||
             ' FROM ' || v_src_fq || ' WHERE PPN_ID = ' || v_ppn_id;
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    COMMIT;
    v_txn_open := FALSE;

    /* 5. COUNT ---------------------------------------------------------- */
    v_phase := 'COUNT';
    SELECT COUNT(*) INTO :v_row_count FROM IDENTIFIER(:v_hist_fq) WHERE PPN_ID = :v_ppn_id;

    /* 6. LOG SUCCESS (state is owned by SP_RUN_TABLE_LOAD) -------------- */
    v_phase := 'LOG_SUCCESS';
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
        )
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
        -- undo a half-finished append so history is never left mid-write
        IF (v_txn_open) THEN
            BEGIN
                ROLLBACK;
                v_txn_open := FALSE;
            EXCEPTION
                WHEN OTHER THEN NULL;
            END;
        END IF;
        BEGIN
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_ppn_id,
                P_PHASE       => 'LOAD_BRONZE_TO_HIST',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR [SP_LOAD_BRONZE_TO_HIST/' || :v_phase || ']: ' || :v_final_msg,
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
                )
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
