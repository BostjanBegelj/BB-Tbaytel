-- ADM.SP_PREPARE_RUN - freeze the run plan for a PPN (FREEZE ONCE).
-- Seeds ADM.PPN_PROCESS with one PENDING row per ACTIVE ETL_TABLES entry (with LOAD_ORDER).
-- This procedure is the SOLE creator of PPN_PROCESS rows; SP_SET_PROCESS_STATE only updates.
--
-- Why: SP_GATE_CHECK can only judge rows that exist. Without a frozen plan, a table that is
-- never invoked (ADF loop bug, config change mid-run) leaves NO row -> invisible -> the gate
-- still PASSes. Seeding PENDING makes the omission visible: PENDING is not SUCCESS/SKIP, so
-- the existing gate fails automatically — no gate logic change needed.
--
-- FREEZE-ONCE semantics: if this PPN already has a plan, the existing plan is returned
-- UNCHANGED (action ALREADY_PREPARED). A retried call must never append tables that were added
-- to the config after the plan was frozen. First-time seeding runs in one transaction, so a
-- failure can never leave a half-frozen plan.
--
-- Scope of the freeze: table MEMBERSHIP + LOAD_ORDER for this PPN. Per-table execution config
-- (SOURCE_TYPE, TARGET_SCHEMA, LOAD_TYPE, PK_COLUMNS, PARTITION_COLUMN, stage/file settings)
-- is still read live by the loaders at execution time.
--
-- ADF iterates the plan (MUST exclude the run-level marker rows, or the DQ entry would enter
-- the per-table ForEach once P_INCLUDE_DQ is enabled):
--   SELECT SOURCE_ID, TABLE_NAME
--     FROM ADM.PPN_PROCESS
--    WHERE PPN_ID = ? AND SOURCE_ID <> '_RUN_'
--    ORDER BY LOAD_ORDER
--
-- Run order: SP_CREATE_PPN -> SP_VALIDATE_CONFIG -> SP_PREPARE_RUN -> per-table loads.
--
-- P_INCLUDE_DQ: seed the run-level DQ marker row (_RUN_/_DQ_) as PENDING. Leave FALSE until
-- SP_RUN_DQ_CHECKS (AntFarm) exists — otherwise every run would fail the gate on a DQ row that
-- nothing ever completes. Set TRUE once DQ is wired, and the gate enforces it automatically.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_PREPARE_RUN(
    "P_PPN_ID"     NUMBER(38,0),
    "P_INCLUDE_DQ" BOOLEAN DEFAULT FALSE
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Freeze the run plan ONCE: seed PPN_PROCESS with PENDING rows for all active tables (+ optional DQ marker).'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20240, 'SP_PREPARE_RUN failed.');

    v_ppn        NUMBER  DEFAULT P_PPN_ID;
    v_planned    NUMBER  DEFAULT 0;
    v_existing   NUMBER  DEFAULT 0;
    v_ppn_count  NUMBER  DEFAULT 0;
    v_txn_open   BOOLEAN DEFAULT FALSE;
    v_started_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_phase      STRING  DEFAULT 'INIT';
    v_error_msg  STRING;
    v_log        NUMBER  DEFAULT 0;
BEGIN
    v_phase := 'VALIDATE';
    IF (v_ppn IS NULL) THEN
        v_error_msg := 'P_PPN_ID is required.';
        RAISE e_failed;
    END IF;

    SELECT COUNT(*) INTO :v_ppn_count FROM ADM.PPN WHERE PPN_ID = :v_ppn;
    IF (v_ppn_count = 0) THEN
        v_error_msg := 'PPN_ID [' || TO_VARCHAR(v_ppn) || '] not found in ADM.PPN.';
        RAISE e_failed;
    END IF;

    /* FREEZE ONCE: if a plan already exists, return it untouched. */
    v_phase := 'CHECK_EXISTING';
    SELECT COUNT(*) INTO :v_existing FROM ADM.PPN_PROCESS WHERE PPN_ID = :v_ppn;

    IF (v_existing > 0) THEN
        CALL ADM.SP_LOG_STEP(
            P_PPN_ID      => :v_ppn,
            P_PHASE       => 'PREPARE_RUN',
            P_STATUS      => 'SKIP',
            P_LOG_START   => :v_started_at,
            P_LOG_END     => CURRENT_TIMESTAMP(),
            P_ROW_COUNT   => :v_existing,
            P_MESSAGE     => 'SKIP: run plan already frozen with ' || :v_existing || ' entry(ies); left unchanged.',
            P_DETAIL_JSON => OBJECT_CONSTRUCT(
                'context', OBJECT_CONSTRUCT('procedure','SP_PREPARE_RUN','ppn_id',:v_ppn),
                'results', OBJECT_CONSTRUCT('action','ALREADY_PREPARED','entries',:v_existing)
            )::STRING
        ) INTO :v_log;

        RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_PREPARE_RUN',
                                'action','ALREADY_PREPARED','entries',v_existing,'ppn_id',v_ppn);
    END IF;

    /* First-time seeding — atomic, so a failure cannot leave a half-frozen plan. */
    v_phase := 'SEED_PLAN';
    BEGIN TRANSACTION;
    v_txn_open := TRUE;

    INSERT INTO ADM.PPN_PROCESS (PPN_ID, SOURCE_ID, TABLE_NAME, STATUS, PHASE, LOAD_ORDER)
    SELECT :v_ppn, t.SOURCE_ID, t.TABLE_NAME, 'PENDING', 'PLANNED', t.LOAD_ORDER
      FROM ADM.ETL_TABLES t
      JOIN ADM.ETL_SOURCES s ON s.SOURCE_ID = t.SOURCE_ID
     WHERE t.ACTIVE_FLAG AND s.ACTIVE_FLAG;
    v_planned := SQLROWCOUNT;   -- capture immediately after the DML

    IF (v_planned = 0) THEN
        v_error_msg := 'No active ETL_TABLES rows to plan (nothing would be processed).';
        RAISE e_failed;          -- handler rolls back; no partial plan is left behind
    END IF;

    IF (P_INCLUDE_DQ) THEN
        v_phase := 'SEED_DQ';
        INSERT INTO ADM.PPN_PROCESS (PPN_ID, SOURCE_ID, TABLE_NAME, STATUS, PHASE, LOAD_ORDER)
        VALUES (:v_ppn, '_RUN_', '_DQ_', 'PENDING', 'PLANNED', 9999);
    END IF;

    COMMIT;
    v_txn_open := FALSE;

    v_phase := 'LOG';
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn,
        P_PHASE       => 'PREPARE_RUN',
        P_STATUS      => 'SUCCESS',
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_ROW_COUNT   => :v_planned,
        P_MESSAGE     => 'SUCCESS: run plan frozen with ' || :v_planned || ' table(s) PENDING.',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_PREPARE_RUN','ppn_id',:v_ppn),
            'results', OBJECT_CONSTRUCT('action','PREPARED','tables_planned',:v_planned,'dq_marker',:P_INCLUDE_DQ)
        )::STRING
    ) INTO :v_log;

    RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_PREPARE_RUN','action','PREPARED',
                            'tables_planned',v_planned,'dq_marker',P_INCLUDE_DQ,'ppn_id',v_ppn);

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
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
                P_PPN_ID      => :v_ppn,
                P_PHASE       => 'PREPARE_RUN',
                P_STATUS      => 'ERROR',
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR [SP_PREPARE_RUN/' || :v_phase || ']: ' || :v_final_msg,
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT('source_procedure','SP_PREPARE_RUN','source_phase',:v_phase,
                        'message',:v_final_msg,'sqlcode',IFF(:v_error_msg IS NULL,:SQLCODE,NULL),
                        'sqlstate',IFF(:v_error_msg IS NULL,:SQLSTATE,NULL)),
                    'context', OBJECT_CONSTRUCT('procedure','SP_PREPARE_RUN','ppn_id',:v_ppn)
                )::STRING
            ) INTO :v_log;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;
        RAISE;
END;
