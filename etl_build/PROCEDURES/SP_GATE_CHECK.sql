-- ADM.SP_GATE_CHECK - the pre-GOLD gate. Pure read of ADM.PPN_PROCESS; runs no data logic.
-- PASS iff: there is at least one PPN_PROCESS entry for the PPN AND none has a STATUS
-- outside (SUCCESS, SKIP). Fail-closed: any ERROR/RUNNING/unknown/null, or zero entries, = FAIL.
--
-- This single rule uniformly covers three things, with no special-casing here:
--   * per-table entries written by the loaders;
--   * NEVER-INVOKED tables — SP_PREPARE_RUN freezes the plan by seeding every active table as
--     PENDING, and PENDING is not SUCCESS/SKIP, so a table the ADF loop skipped fails the gate;
--   * the DQ verdict — when SP_RUN_DQ_CHECKS (AntFarm, pending) records a PPN_PROCESS entry
--     (SOURCE_ID='_RUN_', TABLE_NAME='_DQ_') with SUCCESS/SKIP (pass) or ERROR (blocking).

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_GATE_CHECK(
    "P_PPN_ID" NUMBER(38,0)
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Pre-GOLD gate (fail-closed): PASS iff >=1 PPN_PROCESS entry and none outside SUCCESS/SKIP. Pure read.'
EXECUTE AS CALLER
AS
DECLARE
    v_ppn    NUMBER  DEFAULT P_PPN_ID;
    v_total   NUMBER  DEFAULT 0;
    v_bad     NUMBER  DEFAULT 0;
    v_pending NUMBER  DEFAULT 0;
    v_gate    STRING;
    v_reason  STRING;
BEGIN
    IF (v_ppn IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status','ERROR','procedure','SP_GATE_CHECK','message','P_PPN_ID is required.');
    END IF;

    SELECT COUNT(*),
           COUNT_IF(UPPER(COALESCE(STATUS, '')) NOT IN ('SUCCESS', 'SKIP')),
           COUNT_IF(UPPER(COALESCE(STATUS, '')) = 'PENDING')
      INTO :v_total, :v_bad, :v_pending
      FROM ADM.PPN_PROCESS
     WHERE PPN_ID = :v_ppn;

    IF (v_total = 0) THEN
        v_gate := 'FAIL';
        v_reason := 'No PPN_PROCESS entries for this PPN (run plan never frozen — call SP_PREPARE_RUN).';
    ELSEIF (v_bad > 0) THEN
        v_gate := 'FAIL';
        v_reason := v_bad || ' of ' || v_total || ' entries not SUCCESS/SKIP' ||
                    IFF(v_pending > 0, ' (' || v_pending || ' still PENDING — never processed)', '') || '.';
    ELSE
        v_gate := 'PASS';
        v_reason := 'All ' || v_total || ' entries SUCCESS/SKIP.';
    END IF;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_GATE_CHECK',
        'gate', v_gate,
        'entries_total', v_total,
        'entries_not_ok', v_bad,
        'entries_pending', v_pending,
        'reason', v_reason,
        'ppn_id', v_ppn
    );
END;
