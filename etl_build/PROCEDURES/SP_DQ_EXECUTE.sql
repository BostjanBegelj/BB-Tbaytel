-- ============================================================
-- Standalone Antfarm DQ execution
--
-- Deploy in environment database:
--   DEV_DB.ADM / TEST_DB.ADM / PROD_DB.ADM
--
-- Antfarm is centralized in:
--   PLATFORM_DB.ANTFARM
--
-- Purpose:
--   1. Refresh Antfarm metadata.
--   2. Trigger a DQ group.
--   3. Poll Antfarm until the execution reaches a terminal state.
--   4. Optionally call ADM.SP_DQ_RESULT for JSON or EMAIL output.
--
-- Session context:
--   ADM.* is schema-qualified only, as everywhere else in this
--   framework. The caller must have the environment database set
--   (ADF connects as {ENV}_DATA_LOADER with the environment DB).
--
-- Status semantics:
--   * status = SUCCESS means technical execution succeeded.
--   * DQ findings are returned separately in dq_result.
-- ============================================================

CREATE OR REPLACE PROCEDURE ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME  VARCHAR,
    P_CALLER_ID      VARCHAR DEFAULT 'antfarm_admin',
    P_PROJECT_NAME   VARCHAR DEFAULT 'DWH',
    P_TIMEOUT_S      NUMBER  DEFAULT 3600,
    P_SLEEP_S        NUMBER  DEFAULT 60,
    P_OUTPUT_TYPE    VARCHAR DEFAULT NULL,
    P_MAX_ERROR_ROWS NUMBER  DEFAULT 20
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_phase           STRING DEFAULT 'INIT';

    v_payload         VARIANT;

    v_meta_ingestion  STRING;
    v_meta_dq         STRING;
    v_meta_project    STRING;

    v_raw_run         STRING;
    v_run             VARIANT;
    v_run_id          STRING;
    v_http_run        NUMBER;

    v_raw_log         STRING;
    v_log             VARIANT;
    v_http_log        NUMBER;
    v_task_status     STRING;

    v_output_type     STRING;
    v_dq_result       VARIANT;
    v_result_status   STRING;

    v_dq_started_at   TIMESTAMP_NTZ;
    v_elapsed_s       NUMBER;
BEGIN

    /* ========================================================
       1. VALIDATE INPUT
       ======================================================== */

    v_phase := 'VALIDATE_INPUT';

    IF (P_DQ_GROUP_NAME IS NULL OR TRIM(P_DQ_GROUP_NAME) = '') THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_DQ_GROUP_NAME is required'
        );
    END IF;

    IF (P_CALLER_ID IS NULL OR TRIM(P_CALLER_ID) = '') THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_CALLER_ID is required'
        );
    END IF;

    IF (P_PROJECT_NAME IS NULL OR TRIM(P_PROJECT_NAME) = '') THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_PROJECT_NAME is required'
        );
    END IF;

    IF (P_TIMEOUT_S IS NULL OR P_TIMEOUT_S <= 0) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_TIMEOUT_S must be greater than 0'
        );
    END IF;

    IF (P_SLEEP_S IS NULL OR P_SLEEP_S <= 0) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_SLEEP_S must be greater than 0'
        );
    END IF;

    v_output_type :=
        IFF(
            P_OUTPUT_TYPE IS NULL,
            NULL,
            UPPER(TRIM(P_OUTPUT_TYPE))
        );

    IF (
        v_output_type IS NOT NULL
        AND v_output_type NOT IN ('JSON', 'EMAIL')
    ) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_OUTPUT_TYPE must be NULL, JSON or EMAIL'
        );
    END IF;

    /* Passed straight through to SP_DQ_RESULT. Same range. */
    IF (
        P_MAX_ERROR_ROWS IS NULL
        OR P_MAX_ERROR_ROWS <= 0
        OR P_MAX_ERROR_ROWS > 1000
    ) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_MAX_ERROR_ROWS must be between 1 and 1000'
        );
    END IF;


    /* ========================================================
       2. BUILD ANTFARM PAYLOAD
       ======================================================== */

    v_phase := 'BUILD_PAYLOAD';

    v_payload := OBJECT_CONSTRUCT(
        'caller_id',     P_CALLER_ID,
        'project_name',  P_PROJECT_NAME,
        'dq_group_name', P_DQ_GROUP_NAME
    );


    /* ========================================================
       3. REFRESH ANTFARM METADATA

       The real LOAD_API_* procedures return VARCHAR and catch
       their own exceptions. Therefore the returned text must be
       checked explicitly.
       ======================================================== */

    v_phase := 'REFRESH_METADATA';

    CALL PLATFORM_DB.ANTFARM.LOAD_API_INGESTION_META_DATA(
        :P_CALLER_ID
    )
    INTO :v_meta_ingestion;

    IF (
        v_meta_ingestion IS NULL
        OR v_meta_ingestion ILIKE 'Error executing SQL:%'
    ) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',        'FAILED',
            'phase',         v_phase,
            'dq_group_name', P_DQ_GROUP_NAME,
            'message',       'Antfarm ingestion metadata refresh failed',
            'response',      v_meta_ingestion
        );
    END IF;


    CALL PLATFORM_DB.ANTFARM.LOAD_API_DQ_META_DATA(
        :P_CALLER_ID
    )
    INTO :v_meta_dq;

    IF (
        v_meta_dq IS NULL
        OR v_meta_dq ILIKE 'Error executing SQL:%'
    ) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',        'FAILED',
            'phase',         v_phase,
            'dq_group_name', P_DQ_GROUP_NAME,
            'message',       'Antfarm DQ metadata refresh failed',
            'response',      v_meta_dq
        );
    END IF;


    CALL PLATFORM_DB.ANTFARM.LOAD_API_PROJECT_META_DATA(
        :P_CALLER_ID
    )
    INTO :v_meta_project;

    IF (
        v_meta_project IS NULL
        OR v_meta_project ILIKE 'Error executing SQL:%'
    ) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',        'FAILED',
            'phase',         v_phase,
            'dq_group_name', P_DQ_GROUP_NAME,
            'message',       'Antfarm project metadata refresh failed',
            'response',      v_meta_project
        );
    END IF;


    /* ========================================================
       4. START DQ

       The DQ timeout clock starts here. Metadata refresh time is
       intentionally not counted against P_TIMEOUT_S.
       ======================================================== */

    v_phase         := 'RUN_DQ';
    v_dq_started_at := CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;

    SELECT PLATFORM_DB.ANTFARM.API_RUN_DQ(
               TO_JSON(:v_payload)
           )
      INTO :v_raw_run;

    v_run := TRY_PARSE_JSON(v_raw_run);

    IF (v_run IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',        'FAILED',
            'phase',         v_phase,
            'dq_group_name', P_DQ_GROUP_NAME,
            'message',       'API_RUN_DQ returned a non-JSON response',
            'response',      v_raw_run
        );
    END IF;

    v_http_run := TRY_TO_NUMBER(v_run:"http_code"::STRING);
    v_run_id   := v_run:"run_id"::STRING;

    IF (
        v_http_run IS NULL
        OR v_http_run <> 200
        OR v_run_id IS NULL
        OR TRIM(v_run_id) = ''
    ) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',        'FAILED',
            'phase',         v_phase,
            'dq_group_name', P_DQ_GROUP_NAME,
            'http_code',     v_http_run,
            'message',       'Antfarm DQ run could not be started',
            'response',      v_run
        );
    END IF;


    /* ========================================================
       5. WAIT FOR DQ COMPLETION
       ======================================================== */

    v_phase := 'WAIT_FOR_DQ';

    LOOP

        v_elapsed_s :=
            DATEDIFF(
                'second',
                v_dq_started_at,
                CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
            );

        IF (v_elapsed_s >= P_TIMEOUT_S) THEN
            RETURN OBJECT_CONSTRUCT(
                'status',        'TIMEOUT',
                'phase',         v_phase,
                'run_id',        v_run_id,
                'dq_group_name', P_DQ_GROUP_NAME,
                'elapsed_s',     v_elapsed_s,
                'message',       'Timeout waiting for Antfarm DQ completion'
            );
        END IF;


        SELECT PLATFORM_DB.ANTFARM.API_DQ_GET_LOG(
                   :v_run_id,
                   :P_CALLER_ID,
                   :P_PROJECT_NAME
               )
          INTO :v_raw_log;

        v_log := TRY_PARSE_JSON(v_raw_log);

        IF (v_log IS NULL) THEN
            RETURN OBJECT_CONSTRUCT(
                'status',        'FAILED',
                'phase',         v_phase,
                'run_id',        v_run_id,
                'dq_group_name', P_DQ_GROUP_NAME,
                'message',       'API_DQ_GET_LOG returned a non-JSON response',
                'response',      v_raw_log
            );
        END IF;

        v_http_log := TRY_TO_NUMBER(v_log:"http_code"::STRING);

        /* 404 means the Antfarm result/log is not ready yet. */
        IF (v_http_log = 404) THEN
            CALL SYSTEM$WAIT(:P_SLEEP_S);
            CONTINUE;
        END IF;

        IF (v_http_log IS NULL OR v_http_log <> 200) THEN
            RETURN OBJECT_CONSTRUCT(
                'status',        'FAILED',
                'phase',         v_phase,
                'run_id',        v_run_id,
                'dq_group_name', P_DQ_GROUP_NAME,
                'http_code',     v_http_log,
                'message',       'API_DQ_GET_LOG returned an error',
                'response',      v_log
            );
        END IF;


        v_task_status :=
            UPPER(
                COALESCE(
                    v_log:"task_status"::STRING,
                    v_log:"data"[0]:"task_status"::STRING
                )
            );

        /* Fail fast on an unexpected successful HTTP payload. */
        IF (
            v_task_status IS NULL
            OR TRIM(v_task_status) = ''
        ) THEN
            RETURN OBJECT_CONSTRUCT(
                'status',        'FAILED',
                'phase',         v_phase,
                'run_id',        v_run_id,
                'dq_group_name', P_DQ_GROUP_NAME,
                'message',       'API_DQ_GET_LOG returned HTTP 200 without task_status',
                'response',      v_log
            );
        END IF;


        IF (v_task_status IN ('STARTED', 'RUNNING')) THEN
            CALL SYSTEM$WAIT(:P_SLEEP_S);
            CONTINUE;
        END IF;

        IF (v_task_status = 'SUCCESS') THEN
            EXIT;
        END IF;

        RETURN OBJECT_CONSTRUCT(
            'status',        'FAILED',
            'phase',         v_phase,
            'run_id',        v_run_id,
            'dq_group_name', P_DQ_GROUP_NAME,
            'task_status',   v_task_status,
            'message',       'Antfarm DQ finished with a non-success status',
            'response',      v_log
        );

    END LOOP;


    v_elapsed_s :=
        DATEDIFF(
            'second',
            v_dq_started_at,
            CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
        );


    /* ========================================================
       6. OPTIONAL RESULT PROCESSING

       If result retrieval / EMAIL processing fails technically,
       the top-level execution also returns FAILED. DQ findings
       themselves do not cause a technical failure.
       ======================================================== */

    IF (v_output_type IS NOT NULL) THEN

        v_phase := 'GET_RESULT';

        CALL ADM.SP_DQ_RESULT(
            :v_run_id,
            :v_output_type,
            :P_MAX_ERROR_ROWS
        )
        INTO :v_dq_result;

        v_result_status :=
            UPPER(
                COALESCE(
                    v_dq_result:"status"::STRING,
                    'FAILED'
                )
            );

        IF (v_result_status <> 'SUCCESS') THEN
            RETURN OBJECT_CONSTRUCT(
                'status',        'FAILED',
                'phase',         v_phase,
                'run_id',        v_run_id,
                'dq_group_name', P_DQ_GROUP_NAME,
                'project_name',  P_PROJECT_NAME,
                'caller_id',     P_CALLER_ID,
                'task_status',   v_task_status,
                'elapsed_s',     v_elapsed_s,
                'output_type',   v_output_type,
                'message',       'DQ execution succeeded but result processing failed',
                'dq_result',     v_dq_result
            );
        END IF;

        RETURN OBJECT_CONSTRUCT(
            'status',        'SUCCESS',
            'run_id',        v_run_id,
            'dq_group_name', P_DQ_GROUP_NAME,
            'project_name',  P_PROJECT_NAME,
            'caller_id',     P_CALLER_ID,
            'task_status',   v_task_status,
            'elapsed_s',     v_elapsed_s,
            'output_type',   v_output_type,
            'dq_result',     v_dq_result
        );

    END IF;


    /* ========================================================
       7. EXECUTION-ONLY RETURN
       ======================================================== */

    RETURN OBJECT_CONSTRUCT(
        'status',        'SUCCESS',
        'run_id',        v_run_id,
        'dq_group_name', P_DQ_GROUP_NAME,
        'project_name',  P_PROJECT_NAME,
        'caller_id',     P_CALLER_ID,
        'task_status',   v_task_status,
        'elapsed_s',     v_elapsed_s
    );


EXCEPTION
    WHEN OTHER THEN
        RETURN OBJECT_CONSTRUCT(
            'status',        'FAILED',
            'phase',         v_phase,
            'run_id',        v_run_id,
            'dq_group_name', P_DQ_GROUP_NAME,
            'sqlstate',      SQLSTATE,
            'sqlcode',       SQLCODE,
            'message',       SQLERRM
        );

END;
$$;


-- Examples:
--
-- CALL ADM.SP_DQ_EXECUTE('DQ_STG_PAS');
--
-- CALL ADM.SP_DQ_EXECUTE(
--     P_DQ_GROUP_NAME => 'DQ_STG_PAS',
--     P_OUTPUT_TYPE   => 'JSON'
-- );
--
-- CALL ADM.SP_DQ_EXECUTE(
--     P_DQ_GROUP_NAME => 'DQ_STG_PAS',
--     P_OUTPUT_TYPE   => 'EMAIL'
-- );
--
-- Larger error-row sample in the returned payload:
--
-- CALL ADM.SP_DQ_EXECUTE(
--     P_DQ_GROUP_NAME  => 'DQ_STG_PAS',
--     P_OUTPUT_TYPE    => 'JSON',
--     P_MAX_ERROR_ROWS => 100
-- );
