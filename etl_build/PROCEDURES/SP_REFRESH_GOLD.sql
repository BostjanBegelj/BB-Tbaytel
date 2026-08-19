-- ADM.SP_REFRESH_GOLD - refresh the GOLD Dynamic Tables after the gate PASSes.
-- Called by SP_FINALIZE_RUN. GOLD is PIPELINE-ONLY: every GOLD dynamic table is
-- created with SCHEDULER = DISABLE (no automatic background refresh), so this
-- procedure is the single publish point - GOLD only changes when a gated run
-- reaches here.
--
-- How it works:
--   1. Enumerate the GOLD dynamic tables from INFORMATION_SCHEMA.DYNAMIC_TABLES
--      (nothing hardcoded; static tables like DIM_DATE/DIM_TIME are naturally
--      excluded because they are not dynamic tables). Uses CURRENT_DATABASE() so
--      it works in any environment.
--   2. Refresh them all in ONE combined  ALTER DYNAMIC TABLE a, b, c REFRESH  -
--      Snowflake refreshes the set at a common data timestamp, in dependency
--      order (dimension before fact), merging shared upstreams. Order of the
--      list therefore does not matter.
--   3. VERIFY the outcome via INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY:
--      a combined manual refresh is NOT all-or-nothing, so we independently check
--      that no GOLD table's latest refresh (since this call started) is
--      FAILED / CANCELLED / UPSTREAM_FAILED. (SUCCEEDED and SKIPPED are fine.)
--
-- Contract (unchanged): returns a VARIANT with status = 'SUCCESS' | 'ERROR'
-- (+ 'message' on failure) and does NOT raise - SP_FINALIZE_RUN turns an ERROR
-- into SP_CLOSE_PPN(ERROR) + re-raise, same child-error pattern as the loaders.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_REFRESH_GOLD(
    "P_PPN_ID" NUMBER(38,0)
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Refresh all GOLD dynamic tables in one combined manual refresh, then verify outcomes. Pipeline publish point.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20280, 'SP_REFRESH_GOLD failed.');

    v_ppn        NUMBER  DEFAULT P_PPN_ID;
    v_db         STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_schema     STRING  DEFAULT 'GOLD';
    v_count      NUMBER  DEFAULT 0;
    v_list       STRING;
    v_bad        NUMBER  DEFAULT 0;
    v_bad_list   STRING;
    v_phase      STRING  DEFAULT 'INIT';
    v_last_sql   STRING  DEFAULT '';
    v_started_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_start_ltz  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();   -- for the LTZ history filter
    v_error_msg  STRING;
    v_log        NUMBER  DEFAULT 0;
BEGIN
    v_phase := 'VALIDATE';
    IF (v_ppn IS NULL) THEN
        v_error_msg := 'P_PPN_ID is required.';
        RAISE e_failed;
    END IF;

    /* 1. ENUMERATE the GOLD dynamic tables (no hardcoding). ----------------- */
    v_phase := 'ENUMERATE';
    SELECT COUNT(*), LISTAGG(QUALIFIED_NAME, ', ')
      INTO :v_count, :v_list
      FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(RESULT_LIMIT => 10000))
     WHERE DATABASE_NAME = :v_db
       AND SCHEMA_NAME   = :v_schema;

    IF (v_count = 0) THEN
        CALL ADM.SP_LOG_STEP(
            P_PPN_ID      => :v_ppn,
            P_PHASE       => 'REFRESH_GOLD',
            P_STATUS      => 'SUCCESS',
            P_LOG_START   => :v_started_at,
            P_LOG_END     => CURRENT_TIMESTAMP(),
            P_ROW_COUNT   => 0,
            P_MESSAGE     => 'No GOLD dynamic tables found in ' || :v_db || '.' || :v_schema || '; nothing to refresh.',
            P_DETAIL_JSON => OBJECT_CONSTRUCT(
                'context', OBJECT_CONSTRUCT('procedure','SP_REFRESH_GOLD','ppn_id',:v_ppn),
                'results', OBJECT_CONSTRUCT('refreshed_count', 0)
            )
        ) INTO :v_log;
        RETURN OBJECT_CONSTRUCT('status','SUCCESS','procedure','SP_REFRESH_GOLD',
                                'refreshed_count',0,'note','no dynamic tables','ppn_id',v_ppn);
    END IF;

    /* 2. COMBINED MANUAL REFRESH (common data timestamp, dependency order). - */
    v_phase    := 'REFRESH';
    v_last_sql := 'ALTER DYNAMIC TABLE ' || v_list || ' REFRESH';
    EXECUTE IMMEDIATE v_last_sql;

    /* 3. VERIFY each GOLD table's latest refresh since this call started. ----
          The statement above is not guaranteed all-or-nothing across tables, so
          confirm none ended FAILED / CANCELLED / UPSTREAM_FAILED.              */
    v_phase := 'VERIFY';
    SELECT COUNT(*), LISTAGG(NAME || '=' || STATE, ', ') WITHIN GROUP (ORDER BY NAME)
      INTO :v_bad, :v_bad_list
      FROM (
          SELECT NAME, STATE,
                 ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY REFRESH_START_TIME DESC) AS RN
            FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(RESULT_LIMIT => 10000))
           WHERE DATABASE_NAME = :v_db
             AND SCHEMA_NAME   = :v_schema
             AND REFRESH_START_TIME >= :v_start_ltz
      )
     WHERE RN = 1
       AND STATE IN ('FAILED', 'CANCELLED', 'UPSTREAM_FAILED');

    IF (v_bad > 0) THEN
        v_error_msg := v_bad || ' GOLD dynamic table refresh(es) did not succeed: ' || v_bad_list;
        RAISE e_failed;
    END IF;

    /* 4. LOG SUCCESS -------------------------------------------------------- */
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
            'results', OBJECT_CONSTRUCT('refreshed_count', :v_count, 'objects', :v_list)
        )
    ) INTO :v_log;

    RETURN OBJECT_CONSTRUCT(
        'status',    'SUCCESS',
        'procedure', 'SP_REFRESH_GOLD',
        'refreshed_count', v_count,
        'objects',   v_list,
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
                    'context', OBJECT_CONSTRUCT('procedure','SP_REFRESH_GOLD','ppn_id',:v_ppn)
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
