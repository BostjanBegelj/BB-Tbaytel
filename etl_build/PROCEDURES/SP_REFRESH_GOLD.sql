-- ADM.SP_REFRESH_GOLD - STUB / placeholder. Called by SP_FINALIZE_RUN only after the gate PASSes.
-- Currently a no-op that logs one step and returns SUCCESS, so the end-to-end run can complete
-- while the GOLD layer is still being designed.
-- TODO: replace with the real refresh — cascade Gold Dynamic Tables into GOLD / GOLD_{domain},
--       or trigger dbt. Return status=ERROR (+ message) on failure so SP_FINALIZE_RUN closes ERROR.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_REFRESH_GOLD(
    "P_PPN_ID" NUMBER(38,0)
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'STUB: GOLD refresh placeholder (no-op). Replace with Dynamic Tables refresh / dbt trigger.'
EXECUTE AS CALLER
AS
DECLARE
    v_ppn NUMBER DEFAULT P_PPN_ID;
    v_log NUMBER DEFAULT 0;
BEGIN
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn,
        P_PHASE       => 'REFRESH_GOLD',
        P_STATUS      => 'SUCCESS',
        P_MESSAGE     => 'STUB: GOLD refresh placeholder (no-op).',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_REFRESH_GOLD','ppn_id',:v_ppn,'note','stub — not yet implemented')
        )::STRING
    ) INTO :v_log;

    RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_REFRESH_GOLD','action','STUB','ppn_id',:v_ppn);
END;
