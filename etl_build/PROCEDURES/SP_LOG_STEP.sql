-- ADM.SP_LOG_STEP - helper: write ONE ADM.PPN_LOG row (used by every procedure).
-- Computes DURATION_MSEC from start/end. Looks RUN_ID up from ADM.PPN by PPN_ID
-- (RUN_ID is captured once by SP_CREATE_PPN), so callers never pass RUN_ID.
-- Handler-free so callers can guard the CALL (logging must never mask a real failure).

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_LOG_STEP(
    "P_PPN_ID"        NUMBER(38,0),
    "P_PHASE"         VARCHAR,
    "P_STATUS"        VARCHAR,                       -- START | SUCCESS | SKIP | ERROR | END
    "P_SOURCE_ID"     VARCHAR DEFAULT NULL,
    "P_TABLE_NAME"    VARCHAR DEFAULT NULL,
    "P_LOG_START"     TIMESTAMP_NTZ(9) DEFAULT NULL,
    "P_LOG_END"       TIMESTAMP_NTZ(9) DEFAULT NULL,
    "P_SOURCE_OBJECT" VARCHAR DEFAULT NULL,
    "P_TARGET_OBJECT" VARCHAR DEFAULT NULL,
    "P_ROW_COUNT"     NUMBER(38,0) DEFAULT NULL,
    "P_MESSAGE"       VARCHAR DEFAULT NULL,
    "P_DETAIL_JSON"   VARCHAR DEFAULT NULL           -- JSON string; ERROR block first per logging standard
)
RETURNS NUMBER(38,0)
LANGUAGE SQL
COMMENT = 'Helper: insert one ADM.PPN_LOG row (RUN_ID resolved from ADM.PPN). Returns rows inserted (1).'
EXECUTE AS CALLER
AS
DECLARE
    v_start TIMESTAMP_NTZ(9) DEFAULT COALESCE(P_LOG_START, CURRENT_TIMESTAMP());
    v_end   TIMESTAMP_NTZ(9) DEFAULT COALESCE(P_LOG_END, CURRENT_TIMESTAMP());
BEGIN
    INSERT INTO ADM.PPN_LOG (
        PPN_ID, RUN_ID, SOURCE_ID, TABLE_NAME, PHASE, STATUS,
        START_TS, END_TS, DURATION_MSEC,
        SOURCE_OBJECT, TARGET_OBJECT, ROW_COUNT, MESSAGE, DETAIL_JSON
    )
    SELECT
        :P_PPN_ID,
        (SELECT RUN_ID FROM ADM.PPN WHERE PPN_ID = :P_PPN_ID),
        :P_SOURCE_ID, :P_TABLE_NAME, :P_PHASE, :P_STATUS,
        :v_start, :v_end, DATEDIFF(MILLISECOND, :v_start, :v_end),
        :P_SOURCE_OBJECT, :P_TARGET_OBJECT, :P_ROW_COUNT, :P_MESSAGE, :P_DETAIL_JSON;
    RETURN SQLROWCOUNT;
END;
