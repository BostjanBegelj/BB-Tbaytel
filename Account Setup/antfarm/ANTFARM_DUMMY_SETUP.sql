-- =====================================================================
-- TEMPORARY ANTFARM STUB FOR STANDALONE DQ DEMO
-- =====================================================================
--
-- PURPOSE
--   Drop-in stand-in for the Antfarm objects expected by:
--
--       <ENV_DB>.ADM.SP_DQ_EXECUTE
--       <ENV_DB>.ADM.SP_DQ_RESULT
--
--   while the real Antfarm solution is not yet deployed.
--
-- IMPORTANT
--   * This script creates objects with the FUTURE REAL Antfarm names in:
--
--         PLATFORM_DB.ANTFARM
--
--   * Do NOT run after the real Antfarm implementation exists.
--   * Before real Antfarm deployment, run ANTFARM_DUMMY_CLEANUP.sql.
--   * SP_DQ_EXECUTE and SP_DQ_RESULT require no demo-specific changes.
--
-- DEMO GROUPS
--
--   DQ_DEMO_OK
--       Technical SUCCESS, 0 DQ errors.
--
--   DQ_DEMO_ISSUES
--       Technical SUCCESS, 2 failed checks / 3 errors.
--
--   DQ_DEMO_RESULT_MISSING
--       Technical SUCCESS from Antfarm API but no DQ_LOG rows.
--       Used to prove top-level result-processing failure propagation.
--
--   DQ_DEMO_TECH_FAIL
--       Simulated Antfarm technical failure.
--
--   any unknown group name
--       API_RUN_DQ returns http_code 400 and no run_id.
--
-- DEMO CALLER
--
--   P_CALLER_ID = 'demo_meta_fail'
--       Works with any group. The metadata refresh procedures return
--       'Error executing SQL: ...' instead of raising, which is how
--       the real procedures report failure.
--
-- =====================================================================


USE DATABASE PLATFORM_DB;
USE ROLE SYSADMIN;

CREATE SCHEMA IF NOT EXISTS ANTFARM;


-- =====================================================================
-- 1. DUMMY DQ_RULES
--
-- Not used by SP_DQ_RESULT. Included only to make the temporary Antfarm
-- schema representative.
-- =====================================================================

CREATE OR REPLACE TABLE PLATFORM_DB.ANTFARM.DQ_RULES
(
    DQ_RULE_ID             VARCHAR,
    DQ_RULE_NAME           VARCHAR,
    DQ_GROUP_ID            VARCHAR,
    RULE_CODE              VARCHAR,
    RULE_TYPE              VARCHAR,
    RECORD_LIMIT           NUMBER,
    MODIFIED_DATE          TIMESTAMP_TZ,
    COMMENT                VARCHAR,
    SEVERITY_ID            VARCHAR,
    PARAMETERS             VARCHAR,
    IS_ACTIVE              BOOLEAN,
    DQ_RULE_MAIL_CC        VARCHAR,
    DQ_RULE_MAIL_TO        VARCHAR,
    CUSTOM_COLUMNS_VALUES  VARCHAR,
    API_ENDPOINT           VARCHAR,
    SQL_RULE               VARCHAR
);


INSERT INTO PLATFORM_DB.ANTFARM.DQ_RULES
(
    DQ_RULE_ID,
    DQ_RULE_NAME,
    DQ_GROUP_ID,
    RULE_CODE,
    RULE_TYPE,
    RECORD_LIMIT,
    MODIFIED_DATE,
    COMMENT,
    SEVERITY_ID,
    PARAMETERS,
    IS_ACTIVE,
    DQ_RULE_MAIL_CC,
    DQ_RULE_MAIL_TO,
    CUSTOM_COLUMNS_VALUES,
    API_ENDPOINT,
    SQL_RULE
)
SELECT
    COLUMN1, COLUMN2, COLUMN3, COLUMN4, COLUMN5, COLUMN6,
    CURRENT_TIMESTAMP(),
    COLUMN7, COLUMN8, COLUMN9, COLUMN10, COLUMN11, COLUMN12,
    COLUMN13, COLUMN14, COLUMN15
FROM VALUES
(
    'DEMO-RULE-OK-1',
    'Customer key must be populated',
    'DEMO-GRP-OK',
    'CUSTOMER_NOT_NULL',
    'SQL',
    1000,
    'Demo successful check',
    'DEMO-SEV-100',
    '{}',
    TRUE,
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'SELECT * FROM DEMO.ORDERS WHERE CUSTOMER_ID IS NULL'
),
(
    'DEMO-RULE-OK-2',
    'Amount must be non-negative',
    'DEMO-GRP-OK',
    'AMOUNT_NON_NEGATIVE',
    'SQL',
    1000,
    'Demo successful check',
    'DEMO-SEV-50',
    '{}',
    TRUE,
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'SELECT * FROM DEMO.ORDERS WHERE AMOUNT < 0'
),
(
    'DEMO-RULE-ISSUE-1',
    'Order ID must be populated',
    'DEMO-GRP-ISSUES',
    'ORDER_ID_NOT_NULL',
    'SQL',
    1000,
    'Demo clean rule in a mixed run',
    'DEMO-SEV-100',
    '{}',
    TRUE,
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'SELECT * FROM DEMO.ORDERS WHERE ORDER_ID IS NULL'
),
(
    'DEMO-RULE-ISSUE-2',
    'Customer key must be populated',
    'DEMO-GRP-ISSUES',
    'CUSTOMER_NOT_NULL',
    'SQL',
    1000,
    'Demo blocking issue',
    'DEMO-SEV-100',
    '{}',
    TRUE,
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'SELECT * FROM DEMO.ORDERS WHERE CUSTOMER_ID IS NULL'
),
(
    'DEMO-RULE-ISSUE-3',
    'Amount must be non-negative',
    'DEMO-GRP-ISSUES',
    'AMOUNT_NON_NEGATIVE',
    'SQL',
    1000,
    'Demo warning issue',
    'DEMO-SEV-50',
    '{}',
    TRUE,
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'SELECT * FROM DEMO.ORDERS WHERE AMOUNT < 0'
);


-- =====================================================================
-- 2. DUMMY DQ_LOG
-- =====================================================================

CREATE OR REPLACE TABLE PLATFORM_DB.ANTFARM.DQ_LOG
(
    DQ_LOG_ID                VARCHAR,
    QUEUE_TIME               TIMESTAMP_TZ,
    DQ_GROUP_ID              VARCHAR,
    DQ_GROUP_NAME            VARCHAR,
    DQ_RULE_ID               VARCHAR,
    DQ_RULE_NAME             VARCHAR,
    DQ_RULE_CODE             VARCHAR,
    DQ_CHECK_TYPE            VARCHAR,
    STATUS_ID                NUMBER,
    ERROR_MESSAGE            VARCHAR,
    SCHEMA_NAME              VARCHAR,
    TABLE_NAME               VARCHAR,
    COLUMN_NAME              VARCHAR,
    CHECK_SQL                VARCHAR,
    RUN_PARAMETERS           VARCHAR,
    START_TIME               TIMESTAMP_TZ,
    END_TIME                 TIMESTAMP_TZ,
    NUM_OF_ERRORS            NUMBER,
    ERROR_ROWS               VARCHAR,
    DQ_SEVERITY_LEVEL        NUMBER,
    DQ_SEVERITY_NAME         VARCHAR,
    RUN_ID                   VARCHAR,
    PROJECT                  VARCHAR,
    CALLER                   VARCHAR,
    DQ_TAG_NAMES             VARCHAR,
    MODIFIED_DATE            TIMESTAMP_TZ,
    DQ_LOG_MAIL_TO           VARCHAR,
    DQ_LOG_MAIL_CC           VARCHAR,
    DQ_CUSTOM_COLUMNS_GROUP  VARCHAR,
    DQ_CUSTOM_COLUMNS_RULE   VARCHAR,
    SF_QUERY_ID              VARCHAR,
    DQ_SEVERITY_ID           VARCHAR,
    DQ_TAG_IDS               VARCHAR,
    PROJECT_ID               VARCHAR,
    GENERATED_CHECK_SQL      VARCHAR
);


-- ---------------------------------------------------------------------
-- DQ_DEMO_OK: 2 checks, 0 errors.
-- ---------------------------------------------------------------------

INSERT INTO PLATFORM_DB.ANTFARM.DQ_LOG
(
    DQ_LOG_ID, QUEUE_TIME,
    DQ_GROUP_ID, DQ_GROUP_NAME,
    DQ_RULE_ID, DQ_RULE_NAME, DQ_RULE_CODE, DQ_CHECK_TYPE,
    STATUS_ID, ERROR_MESSAGE,
    SCHEMA_NAME, TABLE_NAME, COLUMN_NAME,
    CHECK_SQL, RUN_PARAMETERS,
    START_TIME, END_TIME,
    NUM_OF_ERRORS, ERROR_ROWS,
    DQ_SEVERITY_LEVEL, DQ_SEVERITY_NAME,
    RUN_ID, PROJECT, CALLER, DQ_TAG_NAMES,
    MODIFIED_DATE,
    DQ_LOG_MAIL_TO, DQ_LOG_MAIL_CC,
    DQ_CUSTOM_COLUMNS_GROUP, DQ_CUSTOM_COLUMNS_RULE,
    SF_QUERY_ID, DQ_SEVERITY_ID, DQ_TAG_IDS, PROJECT_ID,
    GENERATED_CHECK_SQL
)
VALUES
(
    'DEMO-LOG-OK-1',
    CURRENT_TIMESTAMP(),
    'DEMO-GRP-OK',
    'DQ_DEMO_OK',
    'DEMO-RULE-OK-1',
    'Customer key must be populated',
    'CUSTOMER_NOT_NULL',
    'not_null',
    1,
    NULL,
    'DEMO',
    'ORDERS',
    'CUSTOMER_ID',
    'SELECT * FROM DEMO.ORDERS WHERE CUSTOMER_ID IS NULL',
    '{"demo":true,"scenario":"ZERO_ERRORS"}',
    CURRENT_TIMESTAMP(),
    CURRENT_TIMESTAMP(),
    0,
    '[]',
    100,
    'ERROR',
    'DEMO_RUN_OK',
    'DWH',
    'antfarm_admin',
    '["DEMO","DQ"]',
    CURRENT_TIMESTAMP(),
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'DEMO-QUERY-OK-1',
    'DEMO-SEV-100',
    '["DEMO-TAG"]',
    'DEMO-PROJECT-DWH',
    'SELECT * FROM DEMO.ORDERS WHERE CUSTOMER_ID IS NULL'
),
(
    'DEMO-LOG-OK-2',
    CURRENT_TIMESTAMP(),
    'DEMO-GRP-OK',
    'DQ_DEMO_OK',
    'DEMO-RULE-OK-2',
    'Amount must be non-negative',
    'AMOUNT_NON_NEGATIVE',
    'custom_sql',
    1,
    NULL,
    'DEMO',
    'ORDERS',
    'AMOUNT',
    'SELECT * FROM DEMO.ORDERS WHERE AMOUNT < 0',
    '{"demo":true,"scenario":"ZERO_ERRORS"}',
    CURRENT_TIMESTAMP(),
    CURRENT_TIMESTAMP(),
    0,
    '[]',
    50,
    'WARNING',
    'DEMO_RUN_OK',
    'DWH',
    'antfarm_admin',
    '["DEMO","DQ"]',
    CURRENT_TIMESTAMP(),
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'DEMO-QUERY-OK-2',
    'DEMO-SEV-50',
    '["DEMO-TAG"]',
    'DEMO-PROJECT-DWH',
    'SELECT * FROM DEMO.ORDERS WHERE AMOUNT < 0'
);


-- ---------------------------------------------------------------------
-- DQ_DEMO_ISSUES: 3 checks, 2 failed, 3 total errors.
-- ---------------------------------------------------------------------

INSERT INTO PLATFORM_DB.ANTFARM.DQ_LOG
(
    DQ_LOG_ID, QUEUE_TIME,
    DQ_GROUP_ID, DQ_GROUP_NAME,
    DQ_RULE_ID, DQ_RULE_NAME, DQ_RULE_CODE, DQ_CHECK_TYPE,
    STATUS_ID, ERROR_MESSAGE,
    SCHEMA_NAME, TABLE_NAME, COLUMN_NAME,
    CHECK_SQL, RUN_PARAMETERS,
    START_TIME, END_TIME,
    NUM_OF_ERRORS, ERROR_ROWS,
    DQ_SEVERITY_LEVEL, DQ_SEVERITY_NAME,
    RUN_ID, PROJECT, CALLER, DQ_TAG_NAMES,
    MODIFIED_DATE,
    DQ_LOG_MAIL_TO, DQ_LOG_MAIL_CC,
    DQ_CUSTOM_COLUMNS_GROUP, DQ_CUSTOM_COLUMNS_RULE,
    SF_QUERY_ID, DQ_SEVERITY_ID, DQ_TAG_IDS, PROJECT_ID,
    GENERATED_CHECK_SQL
)
VALUES
(
    'DEMO-LOG-ISSUE-1',
    CURRENT_TIMESTAMP(),
    'DEMO-GRP-ISSUES',
    'DQ_DEMO_ISSUES',
    'DEMO-RULE-ISSUE-1',
    'Order ID must be populated',
    'ORDER_ID_NOT_NULL',
    'not_null',
    1,
    NULL,
    'DEMO',
    'ORDERS',
    'ORDER_ID',
    'SELECT * FROM DEMO.ORDERS WHERE ORDER_ID IS NULL',
    '{"demo":true,"scenario":"DQ_ISSUES"}',
    CURRENT_TIMESTAMP(),
    CURRENT_TIMESTAMP(),
    0,
    '[]',
    100,
    'ERROR',
    'DEMO_RUN_ISSUES',
    'DWH',
    'antfarm_admin',
    '["DEMO","DQ"]',
    CURRENT_TIMESTAMP(),
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'DEMO-QUERY-ISSUE-1',
    'DEMO-SEV-100',
    '["DEMO-TAG"]',
    'DEMO-PROJECT-DWH',
    'SELECT * FROM DEMO.ORDERS WHERE ORDER_ID IS NULL'
),
(
    'DEMO-LOG-ISSUE-2',
    CURRENT_TIMESTAMP(),
    'DEMO-GRP-ISSUES',
    'DQ_DEMO_ISSUES',
    'DEMO-RULE-ISSUE-2',
    'Customer key must be populated',
    'CUSTOMER_NOT_NULL',
    'not_null',
    2,
    'Demo DQ errors found',
    'DEMO',
    'ORDERS',
    'CUSTOMER_ID',
    'SELECT * FROM DEMO.ORDERS WHERE CUSTOMER_ID IS NULL',
    '{"demo":true,"scenario":"DQ_ISSUES"}',
    CURRENT_TIMESTAMP(),
    CURRENT_TIMESTAMP(),
    2,
    '[{"ORDER_ID":1002,"CUSTOMER_ID":null,"AMOUNT":125.50},{"ORDER_ID":1007,"CUSTOMER_ID":null,"AMOUNT":42.00}]',
    100,
    'ERROR',
    'DEMO_RUN_ISSUES',
    'DWH',
    'antfarm_admin',
    '["DEMO","DQ","CUSTOMER"]',
    CURRENT_TIMESTAMP(),
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'DEMO-QUERY-ISSUE-2',
    'DEMO-SEV-100',
    '["DEMO-TAG"]',
    'DEMO-PROJECT-DWH',
    'SELECT * FROM DEMO.ORDERS WHERE CUSTOMER_ID IS NULL'
),
(
    'DEMO-LOG-ISSUE-3',
    CURRENT_TIMESTAMP(),
    'DEMO-GRP-ISSUES',
    'DQ_DEMO_ISSUES',
    'DEMO-RULE-ISSUE-3',
    'Amount must be non-negative',
    'AMOUNT_NON_NEGATIVE',
    'custom_sql',
    2,
    'Demo DQ warning found',
    'DEMO',
    'ORDERS',
    'AMOUNT',
    'SELECT * FROM DEMO.ORDERS WHERE AMOUNT < 0',
    '{"demo":true,"scenario":"DQ_ISSUES"}',
    CURRENT_TIMESTAMP(),
    CURRENT_TIMESTAMP(),
    1,
    '[{"ORDER_ID":1011,"CUSTOMER_ID":5011,"AMOUNT":-25.50}]',
    50,
    'WARNING',
    'DEMO_RUN_ISSUES',
    'DWH',
    'antfarm_admin',
    '["DEMO","DQ","AMOUNT"]',
    CURRENT_TIMESTAMP(),
    '{"active":[],"inactive":[]}',
    '{"active":[],"inactive":[]}',
    '{}',
    '{}',
    'DEMO-QUERY-ISSUE-3',
    'DEMO-SEV-50',
    '["DEMO-TAG"]',
    'DEMO-PROJECT-DWH',
    'SELECT * FROM DEMO.ORDERS WHERE AMOUNT < 0'
);


-- =====================================================================
-- 3. DUMMY METADATA REFRESH PROCEDURES
--
-- Match the supplied real signatures:
--   (CALLER_ID VARCHAR) RETURNS VARCHAR
--
-- The real procedures return:
--   'All SQL statements executed successfully.'
-- or:
--   'Error executing SQL: ...'
--
-- The real procedures catch their own exceptions, so a failed
-- refresh is only visible in the returned text. CALLER_ID
-- 'demo_meta_fail' reproduces that so SP_DQ_EXECUTE's metadata
-- validation is actually exercised by the demo.
-- =====================================================================

CREATE OR REPLACE PROCEDURE PLATFORM_DB.ANTFARM.LOAD_API_INGESTION_META_DATA(
    P_CALLER_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    IF (LOWER(COALESCE(P_CALLER_ID, '')) = 'demo_meta_fail') THEN
        RETURN 'Error executing SQL: dummy LOAD_API_INGESTION_META_DATA failure';
    END IF;

    RETURN 'All SQL statements executed successfully.';
END;
$$;


CREATE OR REPLACE PROCEDURE PLATFORM_DB.ANTFARM.LOAD_API_DQ_META_DATA(
    P_CALLER_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    IF (LOWER(COALESCE(P_CALLER_ID, '')) = 'demo_meta_fail') THEN
        RETURN 'Error executing SQL: dummy LOAD_API_DQ_META_DATA failure';
    END IF;

    RETURN 'All SQL statements executed successfully.';
END;
$$;


CREATE OR REPLACE PROCEDURE PLATFORM_DB.ANTFARM.LOAD_API_PROJECT_META_DATA(
    P_CALLER_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    IF (LOWER(COALESCE(P_CALLER_ID, '')) = 'demo_meta_fail') THEN
        RETURN 'Error executing SQL: dummy LOAD_API_PROJECT_META_DATA failure';
    END IF;

    RETURN 'All SQL statements executed successfully.';
END;
$$;


-- =====================================================================
-- 4. DUMMY API_RUN_DQ
--
-- Match real signature:
--   API_RUN_DQ(VARCHAR) RETURNS VARCHAR
-- =====================================================================

CREATE OR REPLACE FUNCTION PLATFORM_DB.ANTFARM.API_RUN_DQ(
    P_PAYLOAD VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    TO_JSON(
        OBJECT_CONSTRUCT_KEEP_NULL(
            'http_code',
                CASE UPPER(TRY_PARSE_JSON(P_PAYLOAD):dq_group_name::STRING)
                    WHEN 'DQ_DEMO_OK'             THEN 200
                    WHEN 'DQ_DEMO_ISSUES'         THEN 200
                    WHEN 'DQ_DEMO_RESULT_MISSING' THEN 200
                    WHEN 'DQ_DEMO_TECH_FAIL'      THEN 200
                    ELSE 400
                END,

            'run_id',
                CASE UPPER(TRY_PARSE_JSON(P_PAYLOAD):dq_group_name::STRING)
                    WHEN 'DQ_DEMO_OK'             THEN 'DEMO_RUN_OK'
                    WHEN 'DQ_DEMO_ISSUES'         THEN 'DEMO_RUN_ISSUES'
                    WHEN 'DQ_DEMO_RESULT_MISSING' THEN 'DEMO_RUN_RESULT_MISSING'
                    WHEN 'DQ_DEMO_TECH_FAIL'      THEN 'DEMO_RUN_TECH_FAIL'
                    ELSE NULL
                END,

            'message',
                CASE UPPER(TRY_PARSE_JSON(P_PAYLOAD):dq_group_name::STRING)
                    WHEN 'DQ_DEMO_OK'             THEN 'Dummy Antfarm run started'
                    WHEN 'DQ_DEMO_ISSUES'         THEN 'Dummy Antfarm run started'
                    WHEN 'DQ_DEMO_RESULT_MISSING' THEN 'Dummy Antfarm run started'
                    WHEN 'DQ_DEMO_TECH_FAIL'      THEN 'Dummy Antfarm run started'
                    ELSE 'Unknown dummy DQ group'
                END,

            'stub',
                TRUE
        )
    )
$$;


-- =====================================================================
-- 5. DUMMY API_DQ_GET_LOG
--
-- Match real signature:
--   API_DQ_GET_LOG(VARCHAR,VARCHAR,VARCHAR) RETURNS VARCHAR
-- =====================================================================

CREATE OR REPLACE FUNCTION PLATFORM_DB.ANTFARM.API_DQ_GET_LOG(
    P_RUN_ID       VARCHAR,
    P_CALLER_ID    VARCHAR,
    P_PROJECT_NAME VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    TO_JSON(
        OBJECT_CONSTRUCT_KEEP_NULL(
            'http_code',
                CASE
                    WHEN P_RUN_ID IN (
                        'DEMO_RUN_OK',
                        'DEMO_RUN_ISSUES',
                        'DEMO_RUN_RESULT_MISSING',
                        'DEMO_RUN_TECH_FAIL'
                    )
                    THEN 200
                    ELSE 404
                END,

            'task_status',
                CASE P_RUN_ID
                    WHEN 'DEMO_RUN_OK'             THEN 'SUCCESS'
                    WHEN 'DEMO_RUN_ISSUES'         THEN 'SUCCESS'
                    WHEN 'DEMO_RUN_RESULT_MISSING' THEN 'SUCCESS'
                    WHEN 'DEMO_RUN_TECH_FAIL'      THEN 'FAILED'
                    ELSE NULL
                END,

            'run_id',
                P_RUN_ID,

            'caller_id',
                P_CALLER_ID,

            'project_name',
                P_PROJECT_NAME,

            'stub',
                TRUE
        )
    )
$$;


-- =====================================================================
-- 6. VALIDATE DUMMY DATA
-- =====================================================================

SELECT
    RUN_ID,
    DQ_GROUP_NAME,
    COUNT(*) AS TOTAL_CHECKS,
    COUNT_IF(NUM_OF_ERRORS > 0) AS FAILED_CHECKS,
    COALESCE(SUM(NUM_OF_ERRORS), 0) AS TOTAL_ERRORS
FROM PLATFORM_DB.ANTFARM.DQ_LOG
GROUP BY RUN_ID, DQ_GROUP_NAME
ORDER BY RUN_ID;


-- Expected:
--
-- DEMO_RUN_OK
--   TOTAL_CHECKS  = 2
--   FAILED_CHECKS = 0
--   TOTAL_ERRORS  = 0
--
-- DEMO_RUN_ISSUES
--   TOTAL_CHECKS  = 3
--   FAILED_CHECKS = 2
--   TOTAL_ERRORS  = 3
--
-- DEMO_RUN_RESULT_MISSING intentionally has no DQ_LOG rows.
-- =====================================================================
