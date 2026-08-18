-- ============================================================
-- Generic Snowflake HTML email notification
--
-- Deploy in environment database:
--   DEV_DB.ADM / TEST_DB.ADM / PROD_DB.ADM
--
-- Purpose:
--   Send an HTML email through a Snowflake email notification
--   integration.
--
-- This procedure contains no ETL- or DQ-specific logic.
--
-- Default integration:
--   EMAIL_INTEGRATION
--
-- Snowflake constraints:
--   * Email recipients must be verified Snowflake users in the
--     same account.
--   * If ALLOWED_RECIPIENTS is configured on the integration,
--     recipients must also be in that list.
--   * Subject length is limited to 256 characters.
-- ============================================================
use role dev_sysadmin;
use database dev_db;
use schema adm;


CREATE OR REPLACE PROCEDURE ADM.SP_SEND_NOTIFICATION(
    P_SUBJECT       VARCHAR,
    P_HTML_BODY     VARCHAR,
    P_RECIPIENTS_TO VARCHAR,
    P_RECIPIENTS_CC VARCHAR DEFAULT '',
    P_INTEGRATION   VARCHAR DEFAULT 'EMAIL_INTEGRATION'
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_phase              STRING DEFAULT 'INIT';

    v_to                 ARRAY;
    v_cc                 ARRAY;

    v_subject            STRING;
    v_subject_truncated  BOOLEAN;

    v_msg                STRING;
    v_cfg                STRING;
    v_resp               STRING;
BEGIN

    /* ========================================================
       1. VALIDATE
       ======================================================== */

    v_phase := 'VALIDATE';

    IF (P_RECIPIENTS_TO IS NULL OR TRIM(P_RECIPIENTS_TO) = '') THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'No TO recipients provided'
        );
    END IF;

    IF (P_HTML_BODY IS NULL OR TRIM(P_HTML_BODY) = '') THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_HTML_BODY is required'
        );
    END IF;

    IF (P_INTEGRATION IS NULL OR TRIM(P_INTEGRATION) = '') THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'P_INTEGRATION is required'
        );
    END IF;


    /* ========================================================
       2. SUBJECT

       Snowflake email subjects cannot exceed 256 characters.
       ======================================================== */

    v_subject :=
        IFF(
            P_SUBJECT IS NULL OR TRIM(P_SUBJECT) = '',
            'Snowflake notification',
            LEFT(P_SUBJECT, 256)
        );

    v_subject_truncated :=
        IFF(
            P_SUBJECT IS NULL,
            FALSE,
            LENGTH(P_SUBJECT) > 256
        );


    /* ========================================================
       3. PARSE RECIPIENTS

       Accept comma- or semicolon-separated strings.
       ======================================================== */

    v_phase := 'PARSE_RECIPIENTS';

    SELECT ARRAY_AGG(TRIM(value::STRING))
      INTO :v_to
    FROM TABLE(
        SPLIT_TO_TABLE(
            REPLACE(
                REGEXP_REPLACE(:P_RECIPIENTS_TO, '\\s+', ''),
                ';',
                ','
            ),
            ','
        )
    )
    WHERE TRIM(value::STRING) <> '';


    SELECT ARRAY_AGG(TRIM(value::STRING))
      INTO :v_cc
    FROM TABLE(
        SPLIT_TO_TABLE(
            REPLACE(
                REGEXP_REPLACE(
                    COALESCE(:P_RECIPIENTS_CC, ''),
                    '\\s+',
                    ''
                ),
                ';',
                ','
            ),
            ','
        )
    )
    WHERE TRIM(value::STRING) <> '';


    IF (v_to IS NULL OR ARRAY_SIZE(v_to) = 0) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'FAILED',
            'phase',   v_phase,
            'message', 'No valid TO recipients after parsing'
        );
    END IF;


    /* ========================================================
       4. BUILD MESSAGE + EMAIL CONFIGURATION
       ======================================================== */

    v_phase := 'BUILD_CONFIG';

    SELECT SNOWFLAKE.NOTIFICATION.TEXT_HTML(
               :P_HTML_BODY
           )
      INTO :v_msg;


    IF (v_cc IS NOT NULL AND ARRAY_SIZE(v_cc) > 0) THEN

        SELECT SNOWFLAKE.NOTIFICATION.EMAIL_INTEGRATION_CONFIG(
                   :P_INTEGRATION,
                   :v_subject,
                   :v_to,
                   :v_cc,
                   NULL
               )
          INTO :v_cfg;

    ELSE

        SELECT SNOWFLAKE.NOTIFICATION.EMAIL_INTEGRATION_CONFIG(
                   :P_INTEGRATION,
                   :v_subject,
                   :v_to
               )
          INTO :v_cfg;

    END IF;


    /* ========================================================
       5. SEND
       ======================================================== */

    v_phase := 'SEND';

    CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
        :v_msg,
        :v_cfg
    )
    INTO :v_resp;


    RETURN OBJECT_CONSTRUCT(
        'status',            'SUCCESS',
        'subject',           v_subject,
        'subject_truncated', v_subject_truncated,
        'to_count',          ARRAY_SIZE(v_to),
        'cc_count',          IFF(v_cc IS NULL, 0, ARRAY_SIZE(v_cc)),
        'response',          v_resp
    );


EXCEPTION
    WHEN OTHER THEN
        RETURN OBJECT_CONSTRUCT(
            'status',   'FAILED',
            'phase',    COALESCE(v_phase, 'UNKNOWN'),
            'message',  'Notification send failed',
            'sqlstate', SQLSTATE,
            'sqlcode',  SQLCODE,
            'sqlerrm',  SQLERRM,
            'subject',  v_subject
        );

END;
$$;


-- Example:
--
-- CALL ADM.SP_SEND_NOTIFICATION(
--     'Test notification',
--     '<html><body>Test message</body></html>',
--     'user1@example.com',
--     'user2@example.com'
-- );
