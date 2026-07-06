CREATE OR REPLACE PROCEDURE ADM.SP_CREATE_PPN()
RETURNS TABLE (
      STATUS   TEXT
    , PPN_ID   NUMBER(38,0)
    , PPN_DT TIMESTAMP_NTZ(9)
)
LANGUAGE SQL
COMMENT = 'Creates a new PPN_ID/PPN_DT in ADM.PPN and returns it. Raises on error (no sentinel row).'
EXECUTE AS CALLER
AS
DECLARE
    new_ppn_id   NUMBER(38,0);
    new_ppn_dt TIMESTAMP_NTZ(9);
    result_sql   RESULTSET;

BEGIN
    -- generate new PPN_ID / PPN_DT
    new_ppn_id   := (SELECT ADM.SQ_ADM_PPN__PPN_ID.NEXTVAL);
    new_ppn_dt := (SELECT CURRENT_TIMESTAMP());

    INSERT INTO ADM.PPN (PPN_ID, PPN_DT)
    VALUES (:new_ppn_id, :new_ppn_dt);

    result_sql := (SELECT 'OK' AS STATUS, :new_ppn_id AS PPN_ID, :new_ppn_dt AS PPN_DT);
    RETURN TABLE(result_sql);

    -- No EXCEPTION handler: any failure (sequence, insert, etc.) propagates
    -- to the caller as a hard error rather than returning a -1 sentinel.
END;