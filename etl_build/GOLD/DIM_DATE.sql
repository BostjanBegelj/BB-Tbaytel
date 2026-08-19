-- ============================================================================
-- GOLD.DIM_DATE - date dimension (1 row per day), CANADIAN holidays.
-- Same column set as the reference D_DATE; the only change is the holiday
-- source: instead of joining a loaded RAW.DIM_DATE_STU table, the Canadian
-- (Ontario statutory + federal) holidays are COMPUTED IN SQL by rule for every
-- year in the spine - fixed dates, nth-weekday-of-month, and Good Friday via the
-- Easter computus. Self-contained: no CSV to load or maintain.
--
-- Holidays included (Thunder Bay, Ontario):
--   Ontario statutory : New Year's Day, Family Day (3rd Mon Feb, from 2008),
--                       Good Friday, Victoria Day (Mon before May 25),
--                       Canada Day, Labour Day (1st Mon Sep),
--                       Thanksgiving (2nd Mon Oct), Christmas Day, Boxing Day
--   Federal-only added: National Day for Truth and Reconciliation (Sep 30, from 2021),
--                       Remembrance Day (Nov 11)
--   NOT included: Civic/August holiday (1st Mon Aug) - not a statutory ON holiday.
--
-- Regular table (a calendar is static reference data - it does not need to be a
-- Dynamic Table). Built once; rebuild to extend the horizon.
-- ============================================================================

use role dev_sysadmin;
use database dev_db;
use schema gold;

CREATE OR REPLACE TABLE GOLD.DIM_DATE AS
WITH CTE_MY_DATE AS (
    SELECT
        DATEADD(
            DAY,
            ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1,
            TO_DATE('2000-01-01')
        )::DATE AS MY_DATE
    FROM TABLE(
        GENERATOR(
            ROWCOUNT => 40000
        )
    )
),

/* ----- Canadian holidays computed per year ------------------------------- */
YRS AS (
    SELECT DISTINCT YEAR(MY_DATE) AS YR FROM CTE_MY_DATE
),

/* Easter Sunday via the Anonymous Gregorian algorithm (Meeus/Jones/Butcher).
   Good Friday = Easter Sunday - 2 days.                                      */
EC AS (
    SELECT YR,
           MOD(YR, 19)     AS A,
           FLOOR(YR / 100) AS B,
           MOD(YR, 100)    AS C
      FROM YRS
),
EC2 AS (
    SELECT YR, A, B, C,
           FLOOR(B / 4)        AS D,
           MOD(B, 4)           AS E,
           FLOOR((B + 8) / 25) AS F
      FROM EC
),
EC3 AS (
    SELECT YR, A, B, C, D, E, F,
           FLOOR((B - F + 1) / 3) AS G,
           FLOOR(C / 4)           AS I,
           MOD(C, 4)              AS K
      FROM EC2
),
EC4 AS (
    SELECT YR, A, E, I, K, G,
           MOD(19 * A + B - D - G + 15, 30) AS H
      FROM EC3
),
EC5 AS (
    SELECT YR, A, H,
           MOD(32 + 2 * E + 2 * I - H - K, 7) AS L
      FROM EC4
),
EC6 AS (
    SELECT YR, H, L,
           FLOOR((A + 11 * H + 22 * L) / 451) AS M
      FROM EC5
),
EASTER AS (
    SELECT YR,
           DATE_FROM_PARTS(
               YR,
               FLOOR((H + L - 7 * M + 114) / 31),          -- month (3=Mar, 4=Apr)
               MOD(H + L - 7 * M + 114, 31) + 1            -- day
           ) AS EASTER_SUNDAY
      FROM EC6
),

HOL AS (
    /* fixed-date holidays */
    SELECT DATE_FROM_PARTS(YR, 1, 1)   AS DATE, 'New Year''s Day'  AS HOLIDAY_NAME FROM YRS
    UNION ALL SELECT DATE_FROM_PARTS(YR, 7, 1),   'Canada Day'        FROM YRS
    UNION ALL SELECT DATE_FROM_PARTS(YR, 12, 25), 'Christmas Day'     FROM YRS
    UNION ALL SELECT DATE_FROM_PARTS(YR, 12, 26), 'Boxing Day'        FROM YRS
    UNION ALL SELECT DATE_FROM_PARTS(YR, 11, 11), 'Remembrance Day'   FROM YRS
    UNION ALL SELECT DATE_FROM_PARTS(YR, 9, 30),  'National Day for Truth and Reconciliation'
                FROM YRS WHERE YR >= 2021

    /* nth-weekday-of-month holidays (ISO Mon=1). first Monday of a month =
       month-start + ((1 - dow_of_start + 7) mod 7); then add whole weeks.       */
    -- Family Day: 3rd Monday of February (Ontario, since 2008)
    UNION ALL
    SELECT DATEADD(DAY, 14,
             DATEADD(DAY, MOD(1 - DAYOFWEEKISO(DATE_FROM_PARTS(YR, 2, 1)) + 7, 7),
                     DATE_FROM_PARTS(YR, 2, 1))),
           'Family Day'
      FROM YRS WHERE YR >= 2008
    -- Labour Day: 1st Monday of September
    UNION ALL
    SELECT DATEADD(DAY, MOD(1 - DAYOFWEEKISO(DATE_FROM_PARTS(YR, 9, 1)) + 7, 7),
                   DATE_FROM_PARTS(YR, 9, 1)),
           'Labour Day'
      FROM YRS
    -- Thanksgiving (Canada): 2nd Monday of October
    UNION ALL
    SELECT DATEADD(DAY, 7,
             DATEADD(DAY, MOD(1 - DAYOFWEEKISO(DATE_FROM_PARTS(YR, 10, 1)) + 7, 7),
                     DATE_FROM_PARTS(YR, 10, 1))),
           'Thanksgiving'
      FROM YRS
    -- Victoria Day: the Monday PRECEDING May 25 (i.e. last Monday on/before May 24)
    UNION ALL
    SELECT DATEADD(DAY, -MOD(DAYOFWEEKISO(DATE_FROM_PARTS(YR, 5, 24)) - 1 + 7, 7),
                   DATE_FROM_PARTS(YR, 5, 24)),
           'Victoria Day'
      FROM YRS

    /* Easter-based */
    -- Good Friday: Friday before Easter Sunday
    UNION ALL
    SELECT DATEADD(DAY, -2, EASTER_SUNDAY), 'Good Friday' FROM EASTER
)

SELECT
      /* keys / references */
    --  TO_NUMBER(TO_CHAR(D.MY_DATE, 'YYYYMMDD'))                                           AS DATE_ID
     D.MY_DATE                                                                            AS DATE
  --  , D.MY_DATE                                                                            AS DATE_NAME
  --  , D.MY_DATE                                                                            AS EXT_REFR

      /* year / half-year / quarter / month */
    , YEAR(D.MY_DATE)                                                                      AS YEAR
    --, YEAR(D.MY_DATE)                                                                      AS YEAR_NAME
    , IFF(MONTH(D.MY_DATE) <= 6, 1, 2)                                                     AS HALF_YEAR
    , 'H' || IFF(MONTH(D.MY_DATE) <= 6, 1, 2)                                              AS HALF_YEAR_NAME
    , IFF(MONTH(D.MY_DATE) <= 6, 1, 2) || 'H ' || YEAR(D.MY_DATE)                          AS HALF_YEAR_NAME_FULL
    , QUARTER(D.MY_DATE)                                                                   AS QUARTER
    , 'Q' || QUARTER(D.MY_DATE)                                                            AS QUARTER_NAME
    , 'Q' || QUARTER(D.MY_DATE) || ' ' || YEAR(D.MY_DATE)                                  AS QUARTER_NAME_FULL
    , MONTH(D.MY_DATE)                                                                     AS MONTH
    , MONTHNAME(D.MY_DATE)                                                                 AS MONTH_NAME_SHORT
    , DECODE(
          MONTHNAME(D.MY_DATE),
          'Jan','January',
          'Feb','February',
          'Mar','March',
          'Apr','April',
          'May','May',
          'Jun','June',
          'Jul','July',
          'Aug','August',
          'Sep','September',
          'Oct','October',
          'Nov','November',
          'Dec','December'
      )                                                                                    AS MONTH_NAME
    , DECODE(
          MONTHNAME(D.MY_DATE),
          'Jan','January',
          'Feb','February',
          'Mar','March',
          'Apr','April',
          'May','May',
          'Jun','June',
          'Jul','July',
          'Aug','August',
          'Sep','September',
          'Oct','October',
          'Nov','November',
          'Dec','December'
      )                                                                                    AS MONTH_NAME_FULL
    , TO_NUMBER(TO_CHAR(D.MY_DATE, 'YYYYMM'))                                              AS YEAR_MONTH_KEY
    , TO_CHAR(D.MY_DATE, 'YYYY-MM')                                                        AS YEAR_MONTH
    , DECODE(
          MONTHNAME(D.MY_DATE),
          'Jan','January',
          'Feb','February',
          'Mar','March',
          'Apr','April',
          'May','May',
          'Jun','June',
          'Jul','July',
          'Aug','August',
          'Sep','September',
          'Oct','October',
          'Nov','November',
          'Dec','December'
      ) || ' ' || YEAR(D.MY_DATE)                                                          AS MONTH_NAME_YEAR
    , MONTH(D.MY_DATE) || '-' || YEAR(D.MY_DATE)                                           AS MONTH_NUMBER_YEAR
    , TO_CHAR(D.MY_DATE, 'YYYY-MM')                                                        AS YEAR_MONTH_NUMBER

      /* week */
    , WEEK(D.MY_DATE)                                                                      AS WEEK
    , WEEKISO(D.MY_DATE)                                                                   AS WEEK_OF_YEAR
    , 'W' || WEEKISO(D.MY_DATE)                                                            AS WEEK_OF_YEAR_NAME
    , 'W' || WEEKISO(D.MY_DATE) || ' ' || YEAROFWEEKISO(D.MY_DATE)                         AS WEEK_OF_YEAR_NAME_FULL

      /* day */
    , DAYOFMONTH(D.MY_DATE)                                                                AS DAY_OF_MONTH
    , CASE
          WHEN MOD(DAYOFMONTH(D.MY_DATE), 100) IN (11, 12, 13) THEN DAYOFMONTH(D.MY_DATE) || 'th'
          WHEN MOD(DAYOFMONTH(D.MY_DATE), 10) = 1 THEN DAYOFMONTH(D.MY_DATE) || 'st'
          WHEN MOD(DAYOFMONTH(D.MY_DATE), 10) = 2 THEN DAYOFMONTH(D.MY_DATE) || 'nd'
          WHEN MOD(DAYOFMONTH(D.MY_DATE), 10) = 3 THEN DAYOFMONTH(D.MY_DATE) || 'rd'
          ELSE DAYOFMONTH(D.MY_DATE) || 'th'
      END                                                                                  AS DAY_OF_MONTH_NAME
    , DAYNAME(D.MY_DATE)                                                                   AS DAY_NAME
    , DAYOFWEEKISO(D.MY_DATE)                                                              AS DAY_OF_WEEK
    , DAYNAME(D.MY_DATE)                                                                   AS DAY_OF_WEEK_NAME
    , DECODE(
          DAYNAME(D.MY_DATE),
          'Mon','Monday',
          'Tue','Tuesday',
          'Wed','Wednesday',
          'Thu','Thursday',
          'Fri','Friday',
          'Sat','Saturday',
          'Sun','Sunday'
      )                                                                                    AS DAY_OF_WEEK_NAME_FULL

      /* holiday / weekend / working day */
    , IFF(H.DATE IS NOT NULL, 1, 0)                                                     AS IS_HOLIDAY
    , H.HOLIDAY_NAME                                                                       AS HOLIDAY_NAME
    , IFF(DAYNAME(D.MY_DATE) IN ('Sat', 'Sun'), 1, 0)                                      AS IS_WEEKEND
    , IFF(DAYNAME(D.MY_DATE) IN ('Sat', 'Sun') OR H.DATE IS NOT NULL, 0, 1)            AS IS_WORKING_DAY

      /* boundary dates */
    , DATE_TRUNC('MONTH', D.MY_DATE)::DATE                                                 AS FIRST_DAY_OF_MONTH
    , DATE_TRUNC('WEEK', D.MY_DATE)::DATE                                                  AS FIRST_DAY_OF_WEEK
    , LAST_DAY(D.MY_DATE, 'WEEK')::DATE                                                    AS LAST_DAY_OF_WEEK
    , LAST_DAY(D.MY_DATE, 'MONTH')::DATE                                                   AS LAST_DAY_OF_MONTH

      /* period end flags */
    , IFF(D.MY_DATE = LAST_DAY(D.MY_DATE, 'MONTH')::DATE, 1, 0)                            AS IS_LAST_DAY_OF_MONTH
    , IFF(D.MY_DATE = LAST_DAY(D.MY_DATE, 'QUARTER')::DATE, 1, 0)                          AS IS_LAST_DAY_OF_QUARTER
    , IFF(
          D.MY_DATE = IFF(
              MONTH(D.MY_DATE) <= 6,
              TO_DATE(YEAR(D.MY_DATE) || '-06-30'),
              TO_DATE(YEAR(D.MY_DATE) || '-12-31')
          ),
          1,
          0
      )                                                                                    AS IS_LAST_DAY_OF_HALF_YEAR
    , IFF(D.MY_DATE = TO_DATE(YEAR(D.MY_DATE) || '-12-31'), 1, 0)                          AS IS_LAST_DAY_OF_YEAR

      /* business / working day flags */
    , IFF(D.MY_DATE = DATEADD(DAY, -2, LAST_DAY(D.MY_DATE, 'WEEK')), 1, 0)                 AS IS_LAST_BUSINESS_DAY_OF_WEEK

    , CASE
          WHEN DAYNAME(LAST_DAY(D.MY_DATE, 'MONTH')) NOT IN ('Sat', 'Sun')
               AND D.MY_DATE = LAST_DAY(D.MY_DATE, 'MONTH') THEN 1
          WHEN DAYNAME(LAST_DAY(D.MY_DATE, 'MONTH')) = 'Sat'
               AND D.MY_DATE = DATEADD(DAY, -1, LAST_DAY(D.MY_DATE, 'MONTH')) THEN 1
          WHEN DAYNAME(LAST_DAY(D.MY_DATE, 'MONTH')) = 'Sun'
               AND D.MY_DATE = DATEADD(DAY, -2, LAST_DAY(D.MY_DATE, 'MONTH')) THEN 1
          ELSE 0
      END                                                                                  AS IS_LAST_BUSINESS_DAY_OF_MONTH

    , IFF(
          D.MY_DATE = MAX(IFF(DAYNAME(D.MY_DATE) NOT IN ('Sat', 'Sun') AND H.DATE IS NULL, D.MY_DATE, NULL))
                      OVER (PARTITION BY YEAR(D.MY_DATE), MONTH(D.MY_DATE)),
          1,
          0
      )                                                                                    AS IS_LAST_WORKING_DAY_OF_MONTH

    , IFF(
          D.MY_DATE = MAX(IFF(DAYNAME(D.MY_DATE) NOT IN ('Sat', 'Sun') AND H.DATE IS NULL, D.MY_DATE, NULL))
                      OVER (PARTITION BY YEAR(D.MY_DATE), QUARTER(D.MY_DATE)),
          1,
          0
      )                                                                                    AS IS_LAST_WORKING_DAY_OF_QUARTER

    , IFF(
          D.MY_DATE = MAX(IFF(DAYNAME(D.MY_DATE) NOT IN ('Sat', 'Sun') AND H.DATE IS NULL, D.MY_DATE, NULL))
                      OVER (PARTITION BY YEAR(D.MY_DATE), IFF(MONTH(D.MY_DATE) <= 6, 1, 2)),
          1,
          0
      )                                                                                    AS IS_LAST_WORKING_DAY_OF_HALF_YEAR

    , IFF(
          D.MY_DATE = MAX(IFF(DAYNAME(D.MY_DATE) NOT IN ('Sat', 'Sun') AND H.DATE IS NULL, D.MY_DATE, NULL))
                      OVER (PARTITION BY YEAR(D.MY_DATE)),
          1,
          0
      )                                                                                    AS IS_LAST_WORKING_DAY_OF_YEAR

      /* relative periods */
 /*   , DATEDIFF(DAY, CURRENT_DATE(), D.MY_DATE)                                             AS DAY_RELATIVE
    , DATEDIFF(WEEK, CURRENT_DATE(), D.MY_DATE)                                            AS WEEK_RELATIVE
    , DATEDIFF(MONTH, CURRENT_DATE(), D.MY_DATE)                                           AS MONTH_RELATIVE
    , DATEDIFF(QUARTER, CURRENT_DATE(), D.MY_DATE)                                         AS QUARTER_RELATIVE
    , DATEDIFF(YEAR, CURRENT_DATE(), D.MY_DATE)                                            AS YEAR_RELATIVE
*/
      /* numeric period keys */
    , TO_NUMBER(TO_CHAR(D.MY_DATE, 'YYYYMMDD'))                                            AS DAY_OF_YEAR_NUMBER
    , TO_NUMBER(YEAR(D.MY_DATE) || LPAD(WEEK(D.MY_DATE)::VARCHAR, 2, '0'))                 AS WEEK_OF_YEAR_NUMBER
    , TO_NUMBER(YEAROFWEEKISO(D.MY_DATE) || LPAD(WEEKISO(D.MY_DATE)::VARCHAR, 2, '0'))     AS WEEKISO_OF_YEAR_NUMBER
    , TO_NUMBER(YEAR(D.MY_DATE) || LPAD(MONTH(D.MY_DATE)::VARCHAR, 2, '0'))                AS MONTH_OF_YEAR_NUMBER
    , TO_NUMBER(YEAR(D.MY_DATE) || LPAD(QUARTER(D.MY_DATE)::VARCHAR, 2, '0'))              AS QUARTER_OF_YEAR_NUMBER

FROM CTE_MY_DATE D
LEFT JOIN (SELECT DATE, LISTAGG(DISTINCT HOLIDAY_NAME, ', ') WITHIN GROUP (ORDER BY HOLIDAY_NAME) AS HOLIDAY_NAME
             FROM HOL GROUP BY DATE) H
    ON H.DATE = D.MY_DATE

UNION ALL

SELECT
   --   -1                    AS DATE_ID
     TO_DATE('1900-01-01') AS DATE
    --, TO_DATE('1900-01-01') AS DATE_NAME
    --, TO_DATE('1900-01-01') AS EXT_REFR
    , -1                    AS YEAR
    --, -1                    AS YEAR_NAME
    , -1                    AS HALF_YEAR
    , 'N/A'                 AS HALF_YEAR_NAME
    , 'N/A'                 AS HALF_YEAR_NAME_FULL
    , -1                    AS QUARTER
    , 'N/A'                 AS QUARTER_NAME
    , 'N/A'                 AS QUARTER_NAME_FULL
    , -1                    AS MONTH
    , 'N/A'                 AS MONTH_NAME_SHORT
    , 'N/A'                 AS MONTH_NAME
    , 'N/A'                 AS MONTH_NAME_FULL
    , -1                    AS YEAR_MONTH_KEY
    , 'N/A'                 AS YEAR_MONTH
    , 'N/A'                 AS MONTH_NAME_YEAR
    , 'N/A'                 AS MONTH_NUMBER_YEAR
    , 'N/A'                 AS YEAR_MONTH_NUMBER
    , -1                    AS WEEK
    , -1                    AS WEEK_OF_YEAR
    , 'N/A'                 AS WEEK_OF_YEAR_NAME
    , 'N/A'                 AS WEEK_OF_YEAR_NAME_FULL
    , -1                    AS DAY_OF_MONTH
    , 'N/A'                 AS DAY_OF_MONTH_NAME
    , 'N/A'                 AS DAY_NAME
    , -1                    AS DAY_OF_WEEK
    , 'N/A'                 AS DAY_OF_WEEK_NAME
    , 'N/A'                 AS DAY_OF_WEEK_NAME_FULL
    , -1                    AS IS_HOLIDAY
    , 'N/A'                 AS HOLIDAY_NAME
    , -1                    AS IS_WEEKEND
    , -1                    AS IS_WORKING_DAY
    , TO_DATE('1900-01-01') AS FIRST_DAY_OF_MONTH
    , TO_DATE('1900-01-01') AS FIRST_DAY_OF_WEEK
    , TO_DATE('1900-01-01') AS LAST_DAY_OF_WEEK
    , TO_DATE('1900-01-01') AS LAST_DAY_OF_MONTH
    , -1                    AS IS_LAST_DAY_OF_MONTH
    , -1                    AS IS_LAST_DAY_OF_QUARTER
    , -1                    AS IS_LAST_DAY_OF_HALF_YEAR
    , -1                    AS IS_LAST_DAY_OF_YEAR
    , -1                    AS IS_LAST_BUSINESS_DAY_OF_WEEK
    , -1                    AS IS_LAST_BUSINESS_DAY_OF_MONTH
    , -1                    AS IS_LAST_WORKING_DAY_OF_MONTH
    , -1                    AS IS_LAST_WORKING_DAY_OF_QUARTER
    , -1                    AS IS_LAST_WORKING_DAY_OF_HALF_YEAR
    , -1                    AS IS_LAST_WORKING_DAY_OF_YEAR
 /*   , -1                    AS DAY_RELATIVE
    , -1                    AS WEEK_RELATIVE
    , -1                    AS MONTH_RELATIVE
    , -1                    AS QUARTER_RELATIVE
    , -1                    AS YEAR_RELATIVE
    */
    , -1                    AS DAY_OF_YEAR_NUMBER
    , -1                    AS WEEK_OF_YEAR_NUMBER
    , -1                    AS WEEKISO_OF_YEAR_NUMBER
    , -1                    AS MONTH_OF_YEAR_NUMBER
    , -1                    AS QUARTER_OF_YEAR_NUMBER
    , -1                    AS IS_SEASON
;
