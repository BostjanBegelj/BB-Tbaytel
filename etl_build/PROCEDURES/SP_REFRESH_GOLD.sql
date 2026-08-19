-- ADM.SP_REFRESH_GOLD - refresh the GOLD Dynamic Tables after the gate PASSes.
-- Called by SP_FINALIZE_RUN. Refreshes the dimension first, then the fact
-- (a fact REFRESH would cascade to a DOWNSTREAM dim anyway, but refreshing the
-- dim explicitly keeps it current for direct dimension queries too, and makes
-- the order/audit explicit). Static reference dims (DIM_DATE, DIM_TIME) are
-- built once and are NOT refreshed here.
--
-- Contract (unchanged): returns a VARIANT with status = 'SUCCESS' | 'ERROR'.
-- On failure it does NOT raise - it returns status='ERROR' + 'message', and
-- SP_FINALIZE_RUN turns that into SP_CLOSE_PPN(ERROR) + re-raise. Same child-
-- error pattern as the loaders.
--
-- To add a GOLD Dynamic Table, copy a refresh block (dimensions before facts).

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_REFRESH_GOLD(
    "P_PPN_ID" NUMBER(38,0)
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Refresh GOLD Dynamic Tables (DIM_PARTNER then FCT_WHOLESALE_USAGE) after the gate passes.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20280, 'SP_REFRESH_GOLD failed.');

    v_ppn        NUMBER  DEFAULT P_PPN_ID;
    v_count      NUMBER  DEFAULT 0;
    v_phase      STRING  DEFAULT 'INIT';
    v_last_sql   STRING  DEFAULT '';
    v_started_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_error_msg  STRING;
    v_log        NUMBER  DEFAULT 0;
BEGIN
    v_phase := 'VALIDATE';
    IF (v_ppn IS NULL) THEN
        v_error_msg := 'P_PPN_ID is required.';
        RAISE e_failed;
    END IF;

    /* ALTER ... REFRESH is synchronous, so on return each table is current. */

    -- 1) Dimension
    v_phase    := 'REFRESH_DIM_PARTNER';
    v_last_sql := 'ALTER DYNAMIC TABLE DEV_DB.GOLD.DIM_PARTNER REFRESH';
    EXECUTE IMMEDIATE v_last_sql;
    v_count := v_count + 1;
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID        => :v_ppn,
        P_PHASE         => 'REFRESH_GOLD',
        P_STATUS        => 'SUCCESS',
        P_TARGET_OBJECT => 'DEV_DB.GOLD.DIM_PARTNER',
        P_MESSAGE       => 'Refreshed dynamic table DEV_DB.GOLD.DIM_PARTNER.',
        P_DETAIL_JSON   => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_REFRESH_GOLD','ppn_id',:v_ppn),
            'results', OBJECT_CONSTRUCT('object','DEV_DB.GOLD.DIM_PARTNER')
        )
    ) INTO :v_log;

    -- 2) Fact (depends on the dimension)
    v_phase    := 'REFRESH_FCT_WHOLESALE_USAGE';
    v_last_sql := 'ALTER DYNAMIC TABLE DEV_DB.GOLD.FCT_WHOLESALE_USAGE REFRESH';
    EXECUTE IMMEDIATE v_last_sql;
    v_count := v_count + 1;
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID        => :v_ppn,
        P_PHASE         => 'REFRESH_GOLD',
        P_STATUS        => 'SUCCESS',
        P_TARGET_OBJECT => 'DEV_DB.GOLD.FCT_WHOLESALE_USAGE',
        P_MESSAGE       => 'Refreshed dynamic table DEV_DB.GOLD.FCT_WHOLESALE_USAGE.',
        P_DETAIL_JSON   => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_REFRESH_GOLD','ppn_id',:v_ppn),
            'results', OBJECT_CONSTRUCT('object','DEV_DB.GOLD.FCT_WHOLESALE_USAGE')
        )
    ) INTO :v_log;

    -- Summary
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn,
        P_PHASE       => 'REFRESH_GOLD',
        P_STATUS      => 'SUCCESS',
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_ROW_COUNT   => :v_count,
        P_MESSAGE     => 'SUCCESS: refreshed ' || :v_count || ' GOLD dynamic table(s).',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_REFRESH_GOLD','ppn_id',:v_ppn),
            'results', OBJECT_CONSTRUCT('refreshed_count', :v_count)
        )
    ) INTO :v_log;

    RETURN OBJECT_CONSTRUCT(
        'status',    'SUCCESS',
        'procedure', 'SP_REFRESH_GOLD',
        'refreshed_count', v_count,
        'ppn_id',    v_ppn
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        BEGIN
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_ppn,
                P_PHASE       => 'REFRESH_GOLD',
                P_STATUS      => 'ERROR',
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR [SP_REFRESH_GOLD/' || :v_phase || ']: ' || :v_final_msg,
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_REFRESH_GOLD',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'last_sql',         NULLIF(:v_last_sql, ''),
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_REFRESH_GOLD','ppn_id',:v_ppn,
                                                'refreshed_before_error', :v_count)
                )
            ) INTO :v_log;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;

        -- Child-error pattern: return ERROR (do NOT raise); SP_FINALIZE_RUN closes ERROR + re-raises.
        RETURN OBJECT_CONSTRUCT(
            'status',    'ERROR',
            'procedure', 'SP_REFRESH_GOLD',
            'phase',     v_phase,
            'message',   v_final_msg,
            'last_sql',  v_last_sql,
            'ppn_id',    v_ppn
        );
END;
