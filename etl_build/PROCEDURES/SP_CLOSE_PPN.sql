-- ADM.SP_CLOSE_PPN - finalise a run: set ADM.PPN.STATUS + END_TS and write the
-- run-level END (or ERROR) log row. Last step of every run.
-- RUN_ID is resolved from ADM.PPN by SP_LOG_STEP, so it is not a parameter here.
-- ERROR-first logging envelope; re-raises so the ADF activity also fails.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_CLOSE_PPN(
    "P_PPN_ID"  NUMBER(38,0),
    "P_STATUS"  VARCHAR DEFAULT 'SUCCESS',           -- SUCCESS | ERROR
    "P_MESSAGE" VARCHAR DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Finalise the run: overall status + end timestamp on ADM.PPN; write END/ERROR log. Re-raises on failure.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20500, 'SP_CLOSE_PPN failed.');

    v_ppn_id     NUMBER DEFAULT P_PPN_ID;
    v_status     STRING DEFAULT UPPER(COALESCE(NULLIF(TRIM(P_STATUS), ''), 'SUCCESS'));

    v_phase      STRING DEFAULT 'INIT';
    v_started_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_ppn_start  TIMESTAMP_NTZ(9);
    v_end_ts     TIMESTAMP_NTZ(9);
    v_ppn_count  NUMBER DEFAULT 0;
    v_error_msg  STRING;
    v_log_status STRING;
    v_log_rows   NUMBER DEFAULT 0;
BEGIN
    v_phase := 'VALIDATE';
    IF (v_ppn_id IS NULL) THEN
        v_error_msg := 'P_PPN_ID is required.';
        RAISE e_failed;
    END IF;
    IF (v_status NOT IN ('SUCCESS', 'ERROR')) THEN
        v_error_msg := 'P_STATUS must be SUCCESS or ERROR (received [' || v_status || ']).';
        RAISE e_failed;
    END IF;

    v_phase := 'CHECK_PPN';
    SELECT COUNT(*), MIN(START_TS)
      INTO :v_ppn_count, :v_ppn_start
      FROM ADM.PPN
     WHERE PPN_ID = :v_ppn_id;

    IF (v_ppn_count = 0) THEN
        v_error_msg := 'PPN_ID [' || TO_VARCHAR(v_ppn_id) || '] not found in ADM.PPN.';
        RAISE e_failed;
    END IF;

    v_phase := 'UPDATE_PPN';
    v_end_ts := CURRENT_TIMESTAMP();
    UPDATE ADM.PPN
       SET STATUS = :v_status, END_TS = :v_end_ts
     WHERE PPN_ID = :v_ppn_id;

    v_phase := 'LOG';
    v_log_status := IFF(v_status = 'ERROR', 'ERROR', 'END');
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn_id,
        P_PHASE       => 'CLOSE_PPN',
        P_STATUS      => :v_log_status,
        P_LOG_START   => :v_ppn_start,
        P_LOG_END     => :v_end_ts,
        P_MESSAGE     => COALESCE(:P_MESSAGE,
                            IFF(:v_status = 'ERROR',
                                'ERROR: run closed with errors.',
                                'END: run completed successfully.')),
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_CLOSE_PPN','ppn_id',:v_ppn_id,'run_status',:v_status)
        )::STRING
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_CLOSE_PPN',
        'ppn_id', v_ppn_id,
        'run_status', v_status
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        BEGIN
            IF (v_ppn_id IS NOT NULL) THEN
                CALL ADM.SP_LOG_STEP(
                    P_PPN_ID      => :v_ppn_id,
                    P_PHASE       => 'CLOSE_PPN',
                    P_STATUS      => 'ERROR',
                    P_LOG_START   => :v_started_at,
                    P_LOG_END     => CURRENT_TIMESTAMP(),
                    P_MESSAGE     => 'ERROR: SP_CLOSE_PPN failed.',
                    P_DETAIL_JSON => OBJECT_CONSTRUCT(
                        'ERROR', OBJECT_CONSTRUCT(
                            'source_procedure', 'SP_CLOSE_PPN',
                            'source_phase',     :v_phase,
                            'message',          :v_final_msg,
                            'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                            'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                        ),
                        'context', OBJECT_CONSTRUCT('procedure','SP_CLOSE_PPN','ppn_id',:v_ppn_id)
                    )::STRING
                ) INTO :v_log_rows;
            END IF;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;
        RAISE;
END;
