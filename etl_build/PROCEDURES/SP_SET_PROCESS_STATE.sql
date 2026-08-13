-- ADM.SP_SET_PROCESS_STATE - helper: UPDATE the ADM.PPN_PROCESS state row for one
-- PPN_ID x SOURCE_ID x TABLE_NAME. PPN_PROCESS is authoritative run-time state and drives
-- the GOLD gate.
--
-- Creates the row on first touch (the calling table load "claims" itself) and updates it
-- thereafter. There is no pre-seeded run plan: the set of tables processed in a run is decided
-- by the schedule/orchestrator and can legitimately be a SUBSET of ETL_TABLES, so PPN_PROCESS
-- records what actually ran.
--
-- CONSEQUENCE (accepted, revisit with the GOLD gate decision): because rows only exist for
-- tables that were invoked, a table the orchestrator never called leaves NO trace here. Any
-- future completeness check therefore cannot rely on PPN_PROCESS alone - it needs the run's
-- intended table list from somewhere (a frozen plan, or the schedule).
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
COMMENT = 'Helper: upsert ADM.PPN_PROCESS for one run x table. Non-null args overwrite; nulls preserve.'
EXECUTE AS CALLER
AS
DECLARE
    v_now TIMESTAMP_NTZ(9) DEFAULT CURRENT_TIMESTAMP();
BEGIN
    MERGE INTO ADM.PPN_PROCESS t
    USING (SELECT :P_PPN_ID AS PPN_ID, :P_SOURCE_ID AS SOURCE_ID, :P_TABLE_NAME AS TABLE_NAME) s
       ON t.PPN_ID = s.PPN_ID AND t.SOURCE_ID = s.SOURCE_ID AND t.TABLE_NAME = s.TABLE_NAME
    WHEN MATCHED THEN UPDATE SET
        STATUS          = COALESCE(:P_STATUS, t.STATUS),
        PHASE           = COALESCE(:P_PHASE,  t.PHASE),
        -- a new RUNNING = fresh (re)attempt: reset the attempt fields + re-stamp START_TS
        ROWS_EXTRACTED  = IFF(:P_STATUS = 'RUNNING', NULL, COALESCE(:P_ROWS_EXTRACTED, t.ROWS_EXTRACTED)),
        ROWS_MERGED     = IFF(:P_STATUS = 'RUNNING', NULL, COALESCE(:P_ROWS_MERGED,    t.ROWS_MERGED)),
        ROWS_DELETED    = IFF(:P_STATUS = 'RUNNING', NULL, COALESCE(:P_ROWS_DELETED,   t.ROWS_DELETED)),
        WATERMARK_VALUE = COALESCE(:P_WATERMARK_VALUE, t.WATERMARK_VALUE),
        ERROR_MSG       = IFF(:P_STATUS = 'RUNNING', NULL, COALESCE(:P_ERROR_MSG, t.ERROR_MSG)),
        START_TS        = IFF(:P_STATUS = 'RUNNING', :v_now, t.START_TS),
        END_TS          = IFF(:P_STATUS = 'RUNNING', NULL, IFF(:P_SET_END, :v_now, t.END_TS))
    WHEN NOT MATCHED THEN INSERT
        (PPN_ID, SOURCE_ID, TABLE_NAME, STATUS, PHASE,
         ROWS_EXTRACTED, ROWS_MERGED, ROWS_DELETED,
         WATERMARK_VALUE, ERROR_MSG, START_TS, END_TS)
        VALUES
        (:P_PPN_ID, :P_SOURCE_ID, :P_TABLE_NAME, :P_STATUS, :P_PHASE,
         :P_ROWS_EXTRACTED, :P_ROWS_MERGED, :P_ROWS_DELETED,
         :P_WATERMARK_VALUE, :P_ERROR_MSG, :v_now, IFF(:P_SET_END, :v_now, NULL));

    RETURN SQLROWCOUNT;   -- captured immediately after the DML
END;
