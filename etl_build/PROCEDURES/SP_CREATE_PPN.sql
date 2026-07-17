-- ADM.SP_CREATE_PPN - allocate a new PPN_ID + PPN_TIMESTAMP from the sequence and
-- insert the run header into ADM.PPN (STATUS = RUNNING). Captures ADF's RUN_ID once
-- into ADM.PPN; downstream procedures use PPN_ID only (RUN_ID is resolved from PPN).
-- Returns the new PPN. First step of every run.
-- Core insert has NO handler: a real failure propagates as a hard error (no sentinel).

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_CREATE_PPN(
    "P_RUN_ID" VARCHAR DEFAULT 'N/A'
)
RETURNS TABLE (STATUS TEXT, PPN_ID NUMBER(38,0), PPN_TIMESTAMP TIMESTAMP_NTZ(9))
LANGUAGE SQL
COMMENT = 'Allocate PPN_ID + PPN_TIMESTAMP; insert the ADM.PPN run header (RUNNING) with RUN_ID. Returns the new PPN.'
EXECUTE AS CALLER
AS
DECLARE
    v_ppn_id   NUMBER(38,0);
    v_ppn_ts   TIMESTAMP_NTZ(9);
    v_run_id   STRING DEFAULT COALESCE(NULLIF(TRIM(P_RUN_ID), ''), 'N/A');
    v_log_rows NUMBER DEFAULT 0;
    result_sql RESULTSET;
BEGIN
    v_ppn_id := (SELECT ADM.SQ_ADM_PPN__PPN_ID.NEXTVAL);
    v_ppn_ts := (SELECT CURRENT_TIMESTAMP());

    INSERT INTO ADM.PPN (PPN_ID, PPN_TIMESTAMP, RUN_ID, STATUS, START_TS)
    VALUES (:v_ppn_id, :v_ppn_ts, :v_run_id, 'RUNNING', :v_ppn_ts);

    -- Run-level START log (guarded: logging failure must not undo the created PPN).
    BEGIN
        CALL ADM.SP_LOG_STEP(
            P_PPN_ID      => :v_ppn_id,
            P_PHASE       => 'CREATE_PPN',
            P_STATUS      => 'START',
            P_LOG_START   => :v_ppn_ts,
            P_LOG_END     => :v_ppn_ts,
            P_MESSAGE     => 'START: run created.',
            P_DETAIL_JSON => OBJECT_CONSTRUCT(
                'context', OBJECT_CONSTRUCT('procedure','SP_CREATE_PPN','ppn_id',:v_ppn_id)
            )::STRING
        ) INTO :v_log_rows;
    EXCEPTION
        WHEN OTHER THEN NULL;
    END;

    result_sql := (SELECT 'OK' AS STATUS, :v_ppn_id AS PPN_ID, :v_ppn_ts AS PPN_TIMESTAMP);
    RETURN TABLE(result_sql);
END;
