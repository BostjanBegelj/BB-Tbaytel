-- ============================================================================
-- GOLD.D_TIME - time-of-day dimension (1 row per second, 86,400 rows).
-- Same definition as the reference D_TIME script, placed in the GOLD schema.
-- Regular table: a time-of-day grid is static reference data, so it is built
-- once (not a Dynamic Table). Join event-level facts on their TIME_KEY (HHMMSS)
-- or FULL_TIME. The wholesale usage fact is daily, so it does not use D_TIME;
-- this is a conformed dimension provided for future intraday/event facts.
-- ============================================================================

use role dev_sysadmin;
use database dev_db;
use schema gold;

CREATE OR REPLACE TABLE GOLD.D_TIME (
    FULL_TIME                TIME           NOT NULL,   -- HH:MM:SS
    TIME_KEY                 NUMBER(6,0)    NOT NULL,   -- HHMMSS

    HOUR_24                  NUMBER(2,0)    NOT NULL,   -- 0-23
    HOUR_12                  NUMBER(2,0)    NOT NULL,   -- 1-12
    MINUTE_NUM               NUMBER(2,0)    NOT NULL,   -- 0-59
    SECOND_NUM               NUMBER(2,0)    NOT NULL,   -- 0-59

    AM_PM_FLAG               VARCHAR(2)     NOT NULL,   -- AM / PM
    HALF_DAY_NUM             NUMBER(1,0)    NOT NULL,   -- 1=AM, 2=PM

    SECOND_OF_DAY            NUMBER(5,0)    NOT NULL,   -- 0-86399
    MINUTE_OF_DAY            NUMBER(4,0)    NOT NULL,   -- 0-1439

    HOUR_START_TIME          TIME           NOT NULL,   -- HH:00:00
    MINUTE_START_TIME        TIME           NOT NULL,   -- HH:MI:00

    TIME_LABEL_24            VARCHAR(8)     NOT NULL,   -- HH:MM:SS
    TIME_LABEL_12            VARCHAR(11)    NOT NULL,   -- HH:MM:SS AM

    IS_BUSINESS_HOUR         BOOLEAN        NOT NULL,   -- example flag
    SHIFT_NAME               VARCHAR(20)    NOT NULL,   -- optional grouping

    PRIMARY KEY (TIME_KEY)
);

INSERT INTO GOLD.D_TIME (
    FULL_TIME,
    TIME_KEY,
    HOUR_24,
    HOUR_12,
    MINUTE_NUM,
    SECOND_NUM,
    AM_PM_FLAG,
    HALF_DAY_NUM,
    SECOND_OF_DAY,
    MINUTE_OF_DAY,
    HOUR_START_TIME,
    MINUTE_START_TIME,
    TIME_LABEL_24,
    TIME_LABEL_12,
    IS_BUSINESS_HOUR,
    SHIFT_NAME
)
WITH SECONDS AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS SECOND_OF_DAY
    FROM TABLE(GENERATOR(ROWCOUNT => 86400))
),
BASE AS (
    SELECT
        SECOND_OF_DAY,
        DATEADD(
            SECOND,
            SECOND_OF_DAY,
            TO_TIME('00:00:00')
        ) AS FULL_TIME
    FROM SECONDS
)
SELECT
    FULL_TIME                                                              AS FULL_TIME,
    TO_NUMBER(TO_CHAR(FULL_TIME, 'HH24MISS'))                              AS TIME_KEY,

    DATE_PART(HOUR, FULL_TIME)                                             AS HOUR_24,
    CASE
        WHEN DATE_PART(HOUR, FULL_TIME) % 12 = 0 THEN 12
        ELSE DATE_PART(HOUR, FULL_TIME) % 12
    END                                                                    AS HOUR_12,
    DATE_PART(MINUTE, FULL_TIME)                                           AS MINUTE_NUM,
    DATE_PART(SECOND, FULL_TIME)                                           AS SECOND_NUM,

    CASE
        WHEN DATE_PART(HOUR, FULL_TIME) < 12 THEN 'AM'
        ELSE 'PM'
    END                                                                    AS AM_PM_FLAG,

    CASE
        WHEN DATE_PART(HOUR, FULL_TIME) < 12 THEN 1
        ELSE 2
    END                                                                    AS HALF_DAY_NUM,

    SECOND_OF_DAY                                                          AS SECOND_OF_DAY,
    FLOOR(SECOND_OF_DAY / 60)                                              AS MINUTE_OF_DAY,

    DATE_TRUNC('HOUR', FULL_TIME)                                          AS HOUR_START_TIME,
    DATE_TRUNC('MINUTE', FULL_TIME)                                        AS MINUTE_START_TIME,

    TO_CHAR(FULL_TIME, 'HH24:MI:SS')                                       AS TIME_LABEL_24,
    TO_CHAR(FULL_TIME, 'HH12:MI:SS AM')                                    AS TIME_LABEL_12,

    CASE
        WHEN DATE_PART(HOUR, FULL_TIME) BETWEEN 8 AND 17 THEN TRUE
        ELSE FALSE
    END                                                                    AS IS_BUSINESS_HOUR,

    CASE
        WHEN DATE_PART(HOUR, FULL_TIME) BETWEEN 6 AND 13 THEN 'Morning'
        WHEN DATE_PART(HOUR, FULL_TIME) BETWEEN 14 AND 21 THEN 'Afternoon/Evening'
        ELSE 'Night'
    END                                                                    AS SHIFT_NAME
FROM BASE
ORDER BY TIME_KEY;
