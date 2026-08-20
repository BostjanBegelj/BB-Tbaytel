-- ADM.SP_REPLAY_FROM_HIST - RECOVERY: deterministically rebuild SILVER.<table> from the
-- immutable per-load history in BRONZE_HIST.<table>, by REPLAYING each stored PPN snapshot
-- through the existing SILVER logic (SP_LOAD_BRONZE_TO_SILVER) in ascending PPN_ID order.
--
-- WHY THIS EXISTS
--   BRONZE is transient: every load CREATE-OR-REPLACEs it, so it only ever holds the CURRENT
--   snapshot. SILVER is not a snapshot - it is stateful (ROW_HK change detection, IS_DELETED
--   sweeps and un-deletes, DW_* stamps) and is built one PPN at a time. The only durable,
--   replayable record of the full history is BRONZE_HIST. This procedure is therefore the
--   disaster-recovery / reprocessing tool for the SILVER layer.
--
-- WHEN TO USE IT
--   * SILVER transformation or hash logic changed (e.g. PK_HK/ROW_HK formula): DROP SILVER and
--     replay so the whole history is recomputed under the new rules. A normal run would only
--     re-apply the latest PPN, silently losing history and mis-detecting deletes.
--   * SILVER corrupted / dropped / a bad manual DML, discovered outside the Time Travel window
--     (SILVER retention is short; BRONZE_HIST is the long-lived truth).
--   * Schema change that must be applied across all history.
--   * Seeding SILVER for a table that was previously land-and-HIST only.
--   * Point-in-time rebuild "as of PPN N" (P_TO_PPN), or a bounded resume/backfill (P_RECREATE
--     = FALSE with P_FROM_PPN/P_TO_PPN) against an existing SILVER.
--
-- WHY NOT JUST RE-RUN THE LOADERS
--   The source is not reproducible (ADF folders get cleaned; a DATABASE/share source only ever
--   exposes its LATEST state). And order matters: collapsing all history into one MERGE breaks
--   FULL delete-detection and picks arbitrary row versions. Replay re-applies each snapshot with
--   its own per-PPN semantics, exactly as production did.
--
-- WHY NOT TIME TRAVEL
--   Time Travel is bounded, and it only restores the SAME OUTPUT of the SAME logic - it cannot
--   help when the defect is in the transformation itself. Replay re-derives SILVER from the
--   untouched HIST snapshots using the CURRENT (fixed) logic.
--
-- HOW IT WORKS
--   Reuses the production SILVER logic verbatim - no duplicated transformation code:
--     for each stored PPN (ascending):
--        1. CREATE OR REPLACE BRONZE.<table> from BRONZE_HIST.<table> for that PPN   (stage the snapshot)
--        2. CALL SP_LOAD_BRONZE_TO_SILVER(<that PPN>, ...)                            (apply it)
--   The ORIGINAL historical PPN_ID is passed through, so SILVER's PPN_ID / PPN_TIMESTAMP
--   lineage and each snapshot's PPN_LOG rows stay attached to their real snapshot. The replay
--   RUN itself gets its own controlling PPN (SP_CREATE_PPN) so the operation is auditable as a
--   whole and per-snapshot progress is logged under it.
--
-- NOT ATOMIC ACROSS PPNs (by design): DDL auto-commits and a single transaction over all of
--   history is neither feasible nor desirable. Each snapshot IS applied atomically (the SILVER
--   MERGE + soft-delete are one transaction inside SP_LOAD_BRONZE_TO_SILVER). If replay fails
--   part-way, SILVER is left rebuilt through the last good PPN; fix the cause and re-run.
--
-- SIDE EFFECT: BRONZE.<table> is overwritten (it is transient anyway; the next normal run rebuilds
--   it). SILVER is dropped first only when P_RECREATE = TRUE.
--
-- DEPENDENCY: the table must have exactly one ACTIVE ETL_TABLES row under an ACTIVE ETL_SOURCES
--   row (SP_LOAD_BRONZE_TO_SILVER reads config the same way). Replaying a de-configured table is
--   refused.
--
-- Config-driven; same helpers + ERROR-first envelope. Returns SUCCESS/ERROR VARIANT (does NOT
-- raise) - this is an operator-run recovery tool; the durable replay PPN records the outcome.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_REPLAY_FROM_HIST(
    "P_SOURCE_ID"       VARCHAR,
    "P_TABLE_NAME"      VARCHAR,
    "P_FROM_PPN"        NUMBER(38,0) DEFAULT NULL,   -- inclusive lower bound (NULL = earliest)
    "P_TO_PPN"          NUMBER(38,0) DEFAULT NULL,   -- inclusive upper bound (NULL = latest)
    "P_RECREATE_SILVER" BOOLEAN      DEFAULT TRUE,   -- TRUE = DROP SILVER first (full rebuild); FALSE = replay in place
    "P_RUN_ID"          VARCHAR      DEFAULT 'REPLAY'
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'RECOVERY: rebuild SILVER.<table> from BRONZE_HIST by replaying stored PPNs through SP_LOAD_BRONZE_TO_SILVER in order.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20950, 'SP_REPLAY_FROM_HIST failed.');

    v_source_id   STRING  DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_table       STRING  DEFAULT UPPER(NULLIF(TRIM(P_TABLE_NAME), ''));
    v_from_ppn    NUMBER  DEFAULT P_FROM_PPN;
    v_to_ppn      NUMBER  DEFAULT P_TO_PPN;
    v_recreate    BOOLEAN DEFAULT COALESCE(P_RECREATE_SILVER, TRUE);
    v_run_id      STRING  DEFAULT COALESCE(NULLIF(TRIM(P_RUN_ID), ''), 'REPLAY');

    v_db          STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_src_sch     STRING;                 -- BRONZE landing schema (from config TARGET_SCHEMA)
    v_hist_sch    STRING;                 -- <src_sch>_HIST
    v_bronze_fq   STRING;
    v_hist_fq     STRING;
    v_silver_fq   STRING;

    v_cfg_count   NUMBER  DEFAULT 0;
    v_hist_exists NUMBER  DEFAULT 0;
    v_window      STRING  DEFAULT '';
    v_from_note   STRING  DEFAULT NULL;    -- warning surfaced when a partial rebuild is requested

    v_ppn_arr     ARRAY;
    v_ppn_count   NUMBER  DEFAULT 0;
    v_i           NUMBER  DEFAULT 0;
    v_cur_ppn     NUMBER;
    v_first_ppn   NUMBER;
    v_last_ppn    NUMBER;

    v_create_res  VARIANT;
    v_replay_ppn  NUMBER;
    v_silver      VARIANT;

    v_merged_total  NUMBER DEFAULT 0;
    v_deleted_total NUMBER DEFAULT 0;
    v_step_merged   NUMBER DEFAULT 0;
    v_step_deleted  NUMBER DEFAULT 0;

    v_started_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_phase       STRING  DEFAULT 'INIT';
    v_last_sql    STRING  DEFAULT '';
    v_error_msg   STRING;
    v_sql         STRING;
    v_log_rows    NUMBER  DEFAULT 0;
BEGIN
    /* 1. VALIDATE ------------------------------------------------------- */
    v_phase := 'VALIDATE';
    IF (v_source_id IS NULL OR v_table IS NULL) THEN
        v_error_msg := 'P_SOURCE_ID and P_TABLE_NAME are required.';
        RAISE e_failed;
    END IF;
    -- table name is embedded into dynamic SQL, so it must be a plain SQL identifier
    IF (NOT REGEXP_LIKE(v_table, '^[A-Z][A-Z0-9_]*$')) THEN
        v_error_msg := 'Invalid P_TABLE_NAME [' || v_table || '] - must be a plain identifier.';
        RAISE e_failed;
    END IF;
    IF (v_from_ppn IS NOT NULL AND v_to_ppn IS NOT NULL AND v_from_ppn > v_to_ppn) THEN
        v_error_msg := 'P_FROM_PPN (' || v_from_ppn || ') is greater than P_TO_PPN (' || v_to_ppn || ').';
        RAISE e_failed;
    END IF;
    -- A full rebuild that starts above the earliest history yields a SILVER that is missing the
    -- history below P_FROM_PPN. Allowed (occasionally intended), but surfaced loudly.
    IF (v_recreate AND v_from_ppn IS NOT NULL) THEN
        v_from_note := 'P_RECREATE_SILVER=TRUE with P_FROM_PPN set: SILVER is dropped and rebuilt '
                    || 'ONLY from PPN ' || v_from_ppn || ' onward - earlier history is NOT included.';
    END IF;

    /* 2. READ CONFIG (same authoritative check as the load path) --------
          Exactly one ACTIVE ETL_TABLES row under an ACTIVE ETL_SOURCES row; TARGET_SCHEMA drives
          the BRONZE / HIST schema names (SILVER schema is always SILVER).                       */
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
        v_error_msg := 'Expected exactly 1 active ETL_TABLES/ETL_SOURCES config row for ['
                    || v_source_id || '.' || v_table || '], found ' || v_cfg_count
                    || '. Cannot replay a table that is not (uniquely, actively) configured.';
        RAISE e_failed;
    END IF;

    v_hist_sch  := v_src_sch || '_HIST';                                     -- BRONZE -> BRONZE_HIST
    v_bronze_fq := '"' || v_db || '"."' || v_src_sch  || '"."' || v_table || '"';
    v_hist_fq   := '"' || v_db || '"."' || v_hist_sch || '"."' || v_table || '"';
    v_silver_fq := '"' || v_db || '"."SILVER"."' || v_table || '"';

    /* 3. HISTORY MUST EXIST --------------------------------------------- */
    v_phase := 'CHECK_HIST';
    SELECT COUNT(*) INTO :v_hist_exists
      FROM INFORMATION_SCHEMA.TABLES
     WHERE TABLE_SCHEMA = :v_hist_sch AND TABLE_NAME = :v_table;
    IF (v_hist_exists = 0) THEN
        v_error_msg := 'History table ' || v_hist_fq || ' does not exist - nothing to replay '
                    || '(SILVER can only be rebuilt from BRONZE_HIST).';
        RAISE e_failed;
    END IF;

    /* 4. BUILD THE REPLAY PLAN: ordered distinct PPNs in the window ------ */
    v_phase := 'BUILD_PLAN';
    IF (v_from_ppn IS NOT NULL) THEN v_window := v_window || ' AND PPN_ID >= ' || v_from_ppn; END IF;
    IF (v_to_ppn   IS NOT NULL) THEN v_window := v_window || ' AND PPN_ID <= ' || v_to_ppn;   END IF;

    v_sql := 'SELECT ARRAY_AGG(PPN_ID) WITHIN GROUP (ORDER BY PPN_ID) FROM '
          || '(SELECT DISTINCT PPN_ID FROM ' || v_hist_fq || ' WHERE 1=1' || v_window || ')';
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;
    SELECT $1 INTO :v_ppn_arr FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    v_ppn_count := COALESCE(ARRAY_SIZE(v_ppn_arr), 0);

    -- No snapshots in the window: do NOTHING destructive (never drop SILVER only to leave it empty).
    IF (v_ppn_count = 0) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'SUCCESS',
            'action', 'NO_HISTORY',
            'procedure', 'SP_REPLAY_FROM_HIST',
            'source_id', v_source_id,
            'table', v_table,
            'message', 'No PPNs found in ' || v_hist_fq || ' for the requested window; SILVER left untouched.',
            'ppns_replayed', 0
        );
    END IF;

    v_first_ppn := GET(v_ppn_arr, 0)::NUMBER;
    v_last_ppn  := GET(v_ppn_arr, v_ppn_count - 1)::NUMBER;

    /* 5. OPEN THE REPLAY RUN (its own controlling PPN for auditability) -- */
    v_phase := 'CREATE_REPLAY_PPN';
    CALL ADM.SP_CREATE_PPN(:v_run_id) INTO :v_create_res;
    v_replay_ppn := GET(v_create_res, 'ppn_id')::NUMBER;

    v_phase := 'LOG_PLAN';
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_replay_ppn,
        P_PHASE       => 'REPLAY_PLAN',
        P_STATUS      => 'START',
        P_SOURCE_ID   => :v_source_id,
        P_TABLE_NAME  => :v_table,
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_SOURCE_OBJECT => :v_hist_fq,
        P_TARGET_OBJECT => :v_silver_fq,
        P_ROW_COUNT   => :v_ppn_count,
        P_MESSAGE     => 'START: replay ' || :v_ppn_count || ' PPN(s) [' || :v_first_ppn || '..' || :v_last_ppn
                      || '] from ' || :v_hist_fq || ' into SILVER.' || :v_table
                      || ' (recreate=' || :v_recreate::STRING || ')' || COALESCE(' WARNING: ' || :v_from_note, ''),
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_REPLAY_FROM_HIST','replay_ppn',:v_replay_ppn),
            'plan', OBJECT_CONSTRUCT('source_id',:v_source_id,'table',:v_table,'recreate',:v_recreate,
                                     'from_ppn',:v_from_ppn,'to_ppn',:v_to_ppn,
                                     'ppns_in_window',:v_ppn_count,'first_ppn',:v_first_ppn,'last_ppn',:v_last_ppn,
                                     'warning',:v_from_note)
        )
    ) INTO :v_log_rows;

    /* 6. RECREATE SILVER (only after we know there IS history to rebuild) */
    IF (v_recreate) THEN
        v_phase := 'DROP_SILVER';
        v_sql := 'DROP TABLE IF EXISTS ' || v_silver_fq;
        v_last_sql := v_sql;
        EXECUTE IMMEDIATE v_sql;
        -- SP_LOAD_BRONZE_TO_SILVER re-creates SILVER on the first replayed PPN (and logs the creation).
    END IF;

    /* 7. REPLAY EACH SNAPSHOT IN ORDER ---------------------------------- */
    v_i := 0;
    WHILE (v_i < v_ppn_count) DO
        v_cur_ppn := GET(v_ppn_arr, v_i)::NUMBER;

        -- 7a. stage this snapshot back into BRONZE (BRONZE is transient; overwrite is expected)
        v_phase := 'STAGE_PPN_' || v_cur_ppn;
        v_sql := 'CREATE OR REPLACE TABLE ' || v_bronze_fq || ' AS SELECT * FROM ' || v_hist_fq
              || ' WHERE PPN_ID = ' || v_cur_ppn;
        v_last_sql := v_sql;
        EXECUTE IMMEDIATE v_sql;

        -- 7b. apply the production SILVER logic for this snapshot (original PPN_ID preserved)
        v_phase := 'SILVER_PPN_' || v_cur_ppn;
        CALL ADM.SP_LOAD_BRONZE_TO_SILVER(
            P_PPN_ID => :v_cur_ppn, P_SOURCE_ID => :v_source_id, P_TABLE_NAME => :v_table) INTO :v_silver;

        IF (UPPER(COALESCE(GET(v_silver, 'status')::STRING, 'ERROR')) <> 'SUCCESS') THEN
            v_error_msg := 'SILVER replay failed at PPN ' || v_cur_ppn || ': '
                        || COALESCE(GET(v_silver, 'message')::STRING, '(no message)')
                        || '. SILVER is rebuilt through the previous PPN only; fix the cause and re-run replay.';
            RAISE e_failed;
        END IF;

        v_step_merged  := COALESCE(GET(v_silver, 'rows_merged')::NUMBER, 0);
        v_step_deleted := COALESCE(GET(v_silver, 'rows_soft_deleted')::NUMBER, 0);
        v_merged_total  := v_merged_total  + v_step_merged;
        v_deleted_total := v_deleted_total + v_step_deleted;

        -- concise per-snapshot progress under the replay PPN (SILVER's own detailed logs stay
        -- under the historical PPN they belong to)
        CALL ADM.SP_LOG_STEP(
            P_PPN_ID      => :v_replay_ppn,
            P_PHASE       => 'REPLAY_STEP',
            P_STATUS      => 'SUCCESS',
            P_SOURCE_ID   => :v_source_id,
            P_TABLE_NAME  => :v_table,
            P_TARGET_OBJECT => :v_silver_fq,
            P_ROW_COUNT   => :v_step_merged,
            P_MESSAGE     => 'SUCCESS: replayed PPN ' || :v_cur_ppn || ' (' || (:v_i + 1) || '/' || :v_ppn_count
                          || '): merged ' || :v_step_merged || ', soft-deleted ' || :v_step_deleted || '.',
            P_DETAIL_JSON => OBJECT_CONSTRUCT(
                'context', OBJECT_CONSTRUCT('procedure','SP_REPLAY_FROM_HIST','replay_ppn',:v_replay_ppn),
                'step', OBJECT_CONSTRUCT('historical_ppn',:v_cur_ppn,'seq',(:v_i + 1),'of',:v_ppn_count,
                                         'rows_merged',:v_step_merged,'rows_soft_deleted',:v_step_deleted)
            )
        ) INTO :v_log_rows;

        v_i := v_i + 1;
    END WHILE;

    /* 8. CLOSE THE REPLAY RUN (SUCCESS) --------------------------------- */
    v_phase := 'FINALIZE';
    CALL ADM.SP_CLOSE_PPN(
        P_PPN_ID  => :v_replay_ppn,
        P_STATUS  => 'SUCCESS',
        P_MESSAGE => 'END: replayed ' || :v_ppn_count || ' PPN(s) into SILVER.' || :v_table
                  || '; merged ' || :v_merged_total || ', soft-deleted ' || :v_deleted_total || ' (cumulative).'
    ) INTO :v_create_res;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'action', IFF(v_recreate, 'REBUILT', 'REPLAYED_IN_PLACE'),
        'procedure', 'SP_REPLAY_FROM_HIST',
        'source_id', v_source_id,
        'table', v_table,
        'target_object', v_silver_fq,
        'replay_ppn_id', v_replay_ppn,
        'recreate_silver', v_recreate,
        'from_ppn', v_from_ppn,
        'to_ppn', v_to_ppn,
        'ppns_replayed', v_ppn_count,
        'first_ppn', v_first_ppn,
        'last_ppn', v_last_ppn,
        'rows_merged_total', v_merged_total,
        'rows_soft_deleted_total', v_deleted_total,
        'warning', v_from_note
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        -- durably record the outcome on the replay PPN if one was opened
        IF (v_replay_ppn IS NOT NULL) THEN
            BEGIN
                CALL ADM.SP_CLOSE_PPN(
                    P_PPN_ID  => :v_replay_ppn,
                    P_STATUS  => 'ERROR',
                    P_MESSAGE => 'ERROR [SP_REPLAY_FROM_HIST/' || :v_phase || ']: ' || :v_final_msg
                ) INTO :v_create_res;
            EXCEPTION
                WHEN OTHER THEN NULL;
            END;
        END IF;
        -- and always leave a standalone error log row (covers failures before the replay PPN exists)
        BEGIN
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_replay_ppn,
                P_PHASE       => 'REPLAY_FROM_HIST',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR [SP_REPLAY_FROM_HIST/' || :v_phase || ']: ' || :v_final_msg,
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_REPLAY_FROM_HIST',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'last_sql',         NULLIF(:v_last_sql, ''),
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_REPLAY_FROM_HIST','replay_ppn',:v_replay_ppn,
                                                'source_id',:v_source_id,'table',:v_table)
                )
            ) INTO :v_log_rows;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'procedure', 'SP_REPLAY_FROM_HIST',
            'phase', v_phase,
            'source_id', v_source_id,
            'table', v_table,
            'replay_ppn_id', v_replay_ppn,
            'message', v_final_msg,
            'last_sql', v_last_sql
        );
END;
