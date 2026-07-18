-- ADM.SP_FINALIZE_RUN - one call to end a run: GATE -> (PASS: refresh GOLD | FAIL: skip) -> CLOSE.
-- ADF calls this after SP_RUN_DQ_CHECKS. It derives the final run status itself:
--   * gate PASS and GOLD ok -> SP_CLOSE_PPN(SUCCESS); returns a SUCCESS VARIANT.
--   * gate FAIL, or GOLD errors -> SP_CLOSE_PPN(ERROR) then RE-RAISE, so the ADF activity fails
--     and alerting fires (the run is already durably closed ERROR first).
-- SP_CLOSE_PPN stays standalone: ADF calls it directly to close early aborts (e.g. validate fail)
-- that never reach finalize.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_FINALIZE_RUN(
    "P_PPN_ID" NUMBER(38,0)
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Run finalize: gate -> GOLD (if pass) -> close. Returns on success; re-raises on a failed run.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20270, 'SP_FINALIZE_RUN failed: run did not complete successfully.');

    v_ppn          NUMBER  DEFAULT P_PPN_ID;
    v_gate         VARIANT;
    v_gold         VARIANT;
    v_close        VARIANT;
    v_gate_verdict STRING;
    v_run_status   STRING  DEFAULT 'ERROR';
    v_reason       STRING;
    v_phase        STRING  DEFAULT 'INIT';
    v_started_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_error_msg    STRING;
    v_log          NUMBER  DEFAULT 0;
BEGIN
    v_phase := 'VALIDATE';
    IF (v_ppn IS NULL) THEN
        v_error_msg := 'P_PPN_ID is required.';
        RAISE e_failed;
    END IF;

    /* 1. GATE ----------------------------------------------------------- */
    v_phase := 'GATE';
    CALL ADM.SP_GATE_CHECK(:v_ppn) INTO :v_gate;
    v_gate_verdict := UPPER(COALESCE(GET(v_gate, 'gate')::STRING, 'FAIL'));
    v_reason       := COALESCE(GET(v_gate, 'reason')::STRING, '');

    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn,
        P_PHASE       => 'GATE_CHECK',
        P_STATUS      => IFF(v_gate_verdict = 'PASS', 'SUCCESS', 'ERROR'),
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_MESSAGE     => 'GATE ' || v_gate_verdict || ': ' || v_reason,
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_FINALIZE_RUN','ppn_id',:v_ppn),
            'gate', v_gate
        )::STRING
    ) INTO :v_log;

    /* 2. GOLD (only if gate passed) ------------------------------------- */
    IF (v_gate_verdict = 'PASS') THEN
        v_phase := 'GOLD';
        CALL ADM.SP_REFRESH_GOLD(:v_ppn) INTO :v_gold;
        IF (UPPER(COALESCE(GET(v_gold, 'status')::STRING, 'ERROR')) = 'SUCCESS') THEN
            v_run_status := 'SUCCESS';
            v_reason     := 'Gate passed; GOLD refreshed.';
        ELSE
            v_run_status := 'ERROR';
            v_reason     := 'GOLD refresh failed: ' || COALESCE(GET(v_gold, 'message')::STRING, '(no message)');
        END IF;
    ELSE
        v_run_status := 'ERROR';
        v_reason     := 'Gate failed; GOLD skipped. ' || v_reason;
    END IF;

    /* 3. CLOSE (once, with the derived status) -------------------------- */
    v_phase := 'CLOSE';
    CALL ADM.SP_CLOSE_PPN(:v_ppn, :v_run_status, :v_reason) INTO :v_close;

    IF (v_run_status = 'ERROR') THEN
        v_error_msg := v_reason;   -- marks this as a controlled failure (run already closed ERROR)
        RAISE e_failed;
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_FINALIZE_RUN',
        'run_status', 'SUCCESS',
        'gate', v_gate,
        'gold_result', v_gold,
        'ppn_id', v_ppn
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final STRING := COALESCE(v_error_msg, SQLERRM);
        -- Controlled gate/GOLD failure (v_error_msg set) already closed the run ERROR -> just re-raise.
        -- Genuine unexpected engine error (v_error_msg NULL) may have left the run un-closed -> close it.
        IF (v_error_msg IS NULL) THEN
            BEGIN
                CALL ADM.SP_CLOSE_PPN(:v_ppn, 'ERROR', 'SP_FINALIZE_RUN failed: ' || v_final) INTO :v_close;
            EXCEPTION
                WHEN OTHER THEN NULL;
            END;
        END IF;
        RAISE;
END;
