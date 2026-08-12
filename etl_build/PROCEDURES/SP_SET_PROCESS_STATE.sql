-- ADM.SP_SET_PROCESS_STATE - helper: UPDATE the ADM.PPN_PROCESS state row for one
-- PPN_ID x SOURCE_ID x TABLE_NAME. PPN_PROCESS is authoritative run-time state and drives
-- the GOLD gate.
--
-- INVARIANT: this procedure NEVER inserts. SP_PREPARE_RUN is the sole creator of
-- PPN_PROCESS rows (the frozen run plan). If no planned row exists this RAISES, which:
--   * catches a run where SP_PREPARE_RUN was never called (otherwise runtime would create
--     rows for the tables it happened to process and the gate would PASS while never-invoked
--     tables stayed invisible - the exact hole the frozen plan exists to close);
--   * blocks processing a table that is not part of this PPN's plan.
--
-- Semantics: non-null args OVERWRITE; null args PRESERVE the existing value.
-- P_STATUS='RUNNING' marks a fresh (re)attempt: clears ERROR_MSG, END_TS and the row-count
-- fields and re-stamps START_TS, so a retry never shows stale error/end/counts.
-- P_SET_END stamps END_TS.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_SET_PROCESS_STATE(
    "P_PPN_ID"          NUMBER(38,0),
    "P_SOURCE_ID"       VARCHAR,
    "P_TABLE_NAME"      VARCHAR,
    "P_STATUS"          VARCHAR DEFAULT NULL,        -- RUNNING | SUCCESS | SKIP | ERROR
    "P_PHASE"           VARCHAR DEFAULT NULL,
    "P_ROWS_EXTRACTED"  NUMBER(38,0) DEFAULT NULL,
    "P_ROWS_MERGED"     NUMBER(38,0) DEFAULT NULL,   -- MERGE affects inserts AND updates
    "P_ROWS_DELETED"    NUMBER(38,0) DEFAULT NULL,
    "P_WATERMARK_VALUE" VARCHAR DEFAULT NULL,
    "P_ERROR_MSG"       VARCHAR DEFAULT NULL,
    "P_SET_END"         BOOLEAN DEFAULT FALSE
)
RETURNS NUMBER(38,0)
LANGUAGE SQL
COMMENT = 'Helper: UPDATE ADM.PPN_PROCESS (never inserts). Raises if the table is not in the frozen run plan.'
EXECUTE AS CALLER
AS
DECLARE
    e_not_planned EXCEPTION (-20230,
        'PPN_PROCESS row does not exist: the run was not prepared (SP_PREPARE_RUN) or this table is not part of the frozen plan.');

    v_now  TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP();
    v_rows NUMBER DEFAULT 0;
BEGIN
    UPDATE ADM.PPN_PROCESS
       SET STATUS          = COALESCE(:P_STATUS, STATUS),
           PHASE           = COALESCE(:P_PHASE,  PHASE),
           -- a new RUNNING = fresh (re)attempt: reset the attempt fields + re-stamp START_TS
           ROWS_EXTRACTED  = IFF(:P_STATUS = 'RUNNING', NULL, COALESCE(:P_ROWS_EXTRACTED, ROWS_EXTRACTED)),
           ROWS_MERGED     = IFF(:P_STATUS = 'RUNNING', NULL, COALESCE(:P_ROWS_MERGED,    ROWS_MERGED)),
           ROWS_DELETED    = IFF(:P_STATUS = 'RUNNING', NULL, COALESCE(:P_ROWS_DELETED,   ROWS_DELETED)),
           WATERMARK_VALUE = COALESCE(:P_WATERMARK_VALUE, WATERMARK_VALUE),
           ERROR_MSG       = IFF(:P_STATUS = 'RUNNING', NULL, COALESCE(:P_ERROR_MSG, ERROR_MSG)),
           START_TS        = IFF(:P_STATUS = 'RUNNING', :v_now, START_TS),
           END_TS          = IFF(:P_STATUS = 'RUNNING', NULL, IFF(:P_SET_END, :v_now, END_TS))
     WHERE PPN_ID = :P_PPN_ID
       AND SOURCE_ID = :P_SOURCE_ID
       AND TABLE_NAME = :P_TABLE_NAME;

    v_rows := SQLROWCOUNT;   -- capture immediately after the DML

    IF (v_rows <> 1) THEN
        RAISE e_not_planned;
    END IF;

    RETURN v_rows;
END;
