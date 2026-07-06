CREATE OR REPLACE PROCEDURE ADM.SP_SYNC_TABLE_STRUCTURE(
    "P_TABLE"          VARCHAR,
    "P_SOURCE_SCHEMA"  VARCHAR,
    "P_TARGET_SCHEMA"  VARCHAR,
    "P_HK"             BOOLEAN DEFAULT FALSE
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Synchronizes missing columns and supported column type widening from source schema to target schema. Creates target table if missing. Optionally maintains target-only PK_HK column. Stops on unsupported type-family changes.'
EXECUTE AS CALLER
AS
DECLARE
    v_db                    STRING DEFAULT UPPER(CURRENT_DATABASE());
    v_table                 STRING DEFAULT UPPER(NULLIF(TRIM(P_TABLE), ''));
    v_source_schema         STRING DEFAULT UPPER(NULLIF(TRIM(P_SOURCE_SCHEMA), ''));
    v_target_schema         STRING DEFAULT UPPER(NULLIF(TRIM(P_TARGET_SCHEMA), ''));

    v_source_fq             STRING;
    v_target_fq             STRING;

    v_phase                 STRING DEFAULT 'INIT';
    v_sql                   STRING DEFAULT '';
    v_sql_log               STRING DEFAULT '';
    v_warning_log           STRING DEFAULT '';

    v_source_cols           NUMBER DEFAULT 0;
    v_target_cols           NUMBER DEFAULT 0;
    v_added_cols            NUMBER DEFAULT 0;
    v_altered_cols          NUMBER DEFAULT 0;
    v_hk_added              NUMBER DEFAULT 0;
    v_hk_altered            NUMBER DEFAULT 0;
    v_unsupported_changes   NUMBER DEFAULT 0;

    v_target_created        BOOLEAN DEFAULT FALSE;
    v_create_cols           STRING DEFAULT '';

    v_hk_exists             NUMBER DEFAULT 0;
    v_hk_data_type          STRING;
    v_hk_char_length        NUMBER;

    v_err                   STRING;
    v_err_state             STRING;
    v_err_code              NUMBER;
BEGIN
    /* ============================================================
       1. VALIDATE INPUT PARAMETERS
       ============================================================ */
    v_phase := 'VALIDATE_INPUT';

    IF (v_table IS NULL OR v_source_schema IS NULL OR v_target_schema IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'P_TABLE, P_SOURCE_SCHEMA and P_TARGET_SCHEMA are required.'
        );
    END IF;

    IF (
        NOT REGEXP_LIKE(v_table, '^[A-Z][A-Z0-9_]*$')
        OR NOT REGEXP_LIKE(v_source_schema, '^[A-Z][A-Z0-9_]*$')
        OR NOT REGEXP_LIKE(v_target_schema, '^[A-Z][A-Z0-9_]*$')
    ) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'Only simple unquoted identifiers are supported.',
            'table', v_table,
            'source_schema', v_source_schema,
            'target_schema', v_target_schema
        );
    END IF;

    v_source_fq := '"' || v_db || '"."' || v_source_schema || '"."' || v_table || '"';
    v_target_fq := '"' || v_db || '"."' || v_target_schema || '"."' || v_table || '"';


    /* ============================================================
       2. CHECK SOURCE AND TARGET TABLES
       ============================================================ */
    v_phase := 'CHECK_TABLES';

    SELECT COUNT(*)
      INTO :v_source_cols
      FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_CATALOG = :v_db
       AND TABLE_SCHEMA  = :v_source_schema
       AND TABLE_NAME    = :v_table
       AND UPPER(COLUMN_NAME) <> 'PK_HK';

    IF (v_source_cols = 0) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'Source table does not exist or has no non-PK_HK columns.',
            'source_object', v_source_fq
        );
    END IF;

    SELECT COUNT(*)
      INTO :v_target_cols
      FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_CATALOG = :v_db
       AND TABLE_SCHEMA  = :v_target_schema
       AND TABLE_NAME    = :v_table;


    /* ============================================================
       3. CAPTURE UNSUPPORTED TYPE-FAMILY CHANGES
       - This check runs before any DDL changes.
       - If unsupported changes exist, procedure stops with ERROR.
       - PK_HK is excluded because it is controlled by P_HK.
       ============================================================ */
    v_phase := 'CAPTURE_UNSUPPORTED_TYPE_CHANGES';

    IF (v_target_cols > 0) THEN

        LET rs_skip RESULTSET := (
            WITH SRC AS (
                SELECT
                    REGEXP_REPLACE(UPPER(COLUMN_NAME), '/', '_') AS COLUMN_NAME,
                    UPPER(DATA_TYPE) AS DATA_TYPE,
                    CASE
                        WHEN UPPER(DATA_TYPE) IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'STRING') THEN 'TEXT'
                        WHEN UPPER(DATA_TYPE) IN ('NUMBER', 'DECIMAL', 'NUMERIC') THEN 'NUMBER'
                        WHEN UPPER(DATA_TYPE) IN ('TIME', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') THEN 'DATETIME'
                        ELSE UPPER(DATA_TYPE)
                    END AS TYPE_FAMILY
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_CATALOG = :v_db
                  AND TABLE_SCHEMA  = :v_source_schema
                  AND TABLE_NAME    = :v_table
                  AND UPPER(COLUMN_NAME) <> 'PK_HK'
            ),
            TGT AS (
                SELECT
                    REGEXP_REPLACE(UPPER(COLUMN_NAME), '/', '_') AS COLUMN_NAME,
                    UPPER(DATA_TYPE) AS DATA_TYPE,
                    CASE
                        WHEN UPPER(DATA_TYPE) IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'STRING') THEN 'TEXT'
                        WHEN UPPER(DATA_TYPE) IN ('NUMBER', 'DECIMAL', 'NUMERIC') THEN 'NUMBER'
                        WHEN UPPER(DATA_TYPE) IN ('TIME', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') THEN 'DATETIME'
                        ELSE UPPER(DATA_TYPE)
                    END AS TYPE_FAMILY
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_CATALOG = :v_db
                  AND TABLE_SCHEMA  = :v_target_schema
                  AND TABLE_NAME    = :v_table
                  AND UPPER(COLUMN_NAME) <> 'PK_HK'
            )
            SELECT
                SRC.COLUMN_NAME,
                SRC.DATA_TYPE AS SOURCE_DATA_TYPE,
                TGT.DATA_TYPE AS TARGET_DATA_TYPE
            FROM SRC
            JOIN TGT
                ON SRC.COLUMN_NAME = TGT.COLUMN_NAME
            WHERE SRC.TYPE_FAMILY <> TGT.TYPE_FAMILY
            ORDER BY SRC.COLUMN_NAME
        );

        LET cur_skip CURSOR FOR rs_skip;

        FOR rec IN cur_skip DO
            v_warning_log := v_warning_log ||
                             'Unsupported type-family change for column "' || rec.COLUMN_NAME ||
                             '": source=' || rec.SOURCE_DATA_TYPE ||
                             ', target=' || rec.TARGET_DATA_TYPE ||
                             '. Manual handling required.' || CHR(10);

            v_unsupported_changes := v_unsupported_changes + 1;
        END FOR;

        IF (v_unsupported_changes > 0) THEN
            RETURN OBJECT_CONSTRUCT(
                'status', 'ERROR',
                'phase', v_phase,
                'message', 'Unsupported type-family changes detected. Manual handling required before continuing.',
                'source_object', v_source_fq,
                'target_object', v_target_fq,
                'unsupported_type_changes', v_unsupported_changes,
                'warnings', NULLIF(v_warning_log, ''),
                'sql_so_far', NULLIF(v_sql_log, ''),
                'p_hk', COALESCE(P_HK, FALSE)
            );
        END IF;

    END IF;


    /* ============================================================
       4. CREATE TARGET TABLE IF IT DOES NOT EXIST
       - Target is created from source structure.
       - PK_HK is added only when P_HK = TRUE.
       ============================================================ */
    v_phase := 'CREATE_TARGET_IF_MISSING';

    IF (v_target_cols = 0) THEN

        SELECT
            LISTAGG(
                '"' || REGEXP_REPLACE(UPPER(COLUMN_NAME), '/', '_') || '" ' ||
                CASE
                    WHEN UPPER(DATA_TYPE) IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'STRING')
                        THEN 'VARCHAR(' || COALESCE(CHARACTER_MAXIMUM_LENGTH, 16777216) || ')'
                    WHEN UPPER(DATA_TYPE) IN ('NUMBER', 'DECIMAL', 'NUMERIC')
                        THEN 'NUMBER(' || COALESCE(NUMERIC_PRECISION, 38) || ',' || COALESCE(NUMERIC_SCALE, 0) || ')'
                    WHEN UPPER(DATA_TYPE) IN ('TIME', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ')
                        THEN UPPER(DATA_TYPE) || IFF(DATETIME_PRECISION IS NOT NULL, '(' || DATETIME_PRECISION || ')', '')
                    ELSE UPPER(DATA_TYPE)
                END,
                ', '
            ) WITHIN GROUP (ORDER BY ORDINAL_POSITION)
          INTO :v_create_cols
          FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_CATALOG = :v_db
           AND TABLE_SCHEMA  = :v_source_schema
           AND TABLE_NAME    = :v_table
           AND UPPER(COLUMN_NAME) <> 'PK_HK';

        IF (COALESCE(P_HK, FALSE)) THEN
            v_create_cols := v_create_cols || ', "PK_HK" VARCHAR(16777216)';
            v_hk_added := 1;
        END IF;

        v_sql := 'CREATE TABLE ' || v_target_fq || ' (' || v_create_cols || ')';
        v_sql_log := v_sql_log || v_sql || ';' || CHR(10);

        EXECUTE IMMEDIATE v_sql;

        v_target_created := TRUE;
        v_added_cols := v_source_cols;

        SELECT COUNT(*)
          INTO :v_target_cols
          FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_CATALOG = :v_db
           AND TABLE_SCHEMA  = :v_target_schema
           AND TABLE_NAME    = :v_table;

    END IF;


    /* ============================================================
       5. MAINTAIN TARGET-ONLY HASH KEY COLUMN
       - PK_HK is not compared to the source.
       - If P_HK = TRUE, target must contain PK_HK VARCHAR(16777216).
       ============================================================ */
    v_phase := 'MAINTAIN_PK_HK';

    IF (COALESCE(P_HK, FALSE)) THEN

        SELECT COUNT(*)
          INTO :v_hk_exists
          FROM INFORMATION_SCHEMA.COLUMNS
         WHERE TABLE_CATALOG = :v_db
           AND TABLE_SCHEMA  = :v_target_schema
           AND TABLE_NAME    = :v_table
           AND UPPER(COLUMN_NAME) = 'PK_HK';

        IF (v_hk_exists = 0) THEN
            v_sql := 'ALTER TABLE ' || v_target_fq || ' ADD COLUMN "PK_HK" VARCHAR(16777216)';
            v_sql_log := v_sql_log || v_sql || ';' || CHR(10);

            EXECUTE IMMEDIATE v_sql;

            v_hk_added := 1;

        ELSE
            SELECT
                UPPER(DATA_TYPE),
                CHARACTER_MAXIMUM_LENGTH
              INTO
                :v_hk_data_type,
                :v_hk_char_length
              FROM INFORMATION_SCHEMA.COLUMNS
             WHERE TABLE_CATALOG = :v_db
               AND TABLE_SCHEMA  = :v_target_schema
               AND TABLE_NAME    = :v_table
               AND UPPER(COLUMN_NAME) = 'PK_HK';

            IF (
                v_hk_data_type IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'STRING')
                AND COALESCE(v_hk_char_length, 0) < 16777216
            ) THEN
                v_sql := 'ALTER TABLE ' || v_target_fq || ' ALTER COLUMN "PK_HK" SET DATA TYPE VARCHAR(16777216)';
                v_sql_log := v_sql_log || v_sql || ';' || CHR(10);

                EXECUTE IMMEDIATE v_sql;

                v_hk_altered := 1;

            ELSEIF (
                v_hk_data_type NOT IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'STRING')
            ) THEN
                v_warning_log := v_warning_log ||
                                 'PK_HK exists but is not a text column. Current type=' ||
                                 COALESCE(v_hk_data_type, 'UNKNOWN') ||
                                 '. Manual handling required.' || CHR(10);

                RETURN OBJECT_CONSTRUCT(
                    'status', 'ERROR',
                    'phase', v_phase,
                    'message', 'PK_HK exists but has unsupported data type. Manual handling required before continuing.',
                    'source_object', v_source_fq,
                    'target_object', v_target_fq,
                    'warnings', NULLIF(v_warning_log, ''),
                    'sql_so_far', NULLIF(v_sql_log, ''),
                    'p_hk', COALESCE(P_HK, FALSE)
                );
            END IF;
        END IF;
    END IF;


    /* ============================================================
       6. ADD MISSING SOURCE COLUMNS
       - Compare by column name only.
       - PK_HK is excluded because it is controlled by P_HK.
       ============================================================ */
    v_phase := 'ADD_MISSING_COLUMNS';

    LET rs_add RESULTSET := (
        WITH SRC AS (
            SELECT
                REGEXP_REPLACE(UPPER(COLUMN_NAME), '/', '_') AS COLUMN_NAME,
                ORDINAL_POSITION,
                UPPER(DATA_TYPE) AS DATA_TYPE,
                CHARACTER_MAXIMUM_LENGTH,
                NUMERIC_PRECISION,
                NUMERIC_SCALE,
                DATETIME_PRECISION,
                CASE
                    WHEN UPPER(DATA_TYPE) IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'STRING')
                        THEN 'VARCHAR(' || COALESCE(CHARACTER_MAXIMUM_LENGTH, 16777216) || ')'
                    WHEN UPPER(DATA_TYPE) IN ('NUMBER', 'DECIMAL', 'NUMERIC')
                        THEN 'NUMBER(' || COALESCE(NUMERIC_PRECISION, 38) || ',' || COALESCE(NUMERIC_SCALE, 0) || ')'
                    WHEN UPPER(DATA_TYPE) IN ('TIME', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ')
                        THEN UPPER(DATA_TYPE) || IFF(DATETIME_PRECISION IS NOT NULL, '(' || DATETIME_PRECISION || ')', '')
                    ELSE UPPER(DATA_TYPE)
                END AS TYPE_DEF
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_CATALOG = :v_db
              AND TABLE_SCHEMA  = :v_source_schema
              AND TABLE_NAME    = :v_table
              AND UPPER(COLUMN_NAME) <> 'PK_HK'
        ),
        TGT AS (
            SELECT
                REGEXP_REPLACE(UPPER(COLUMN_NAME), '/', '_') AS COLUMN_NAME
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_CATALOG = :v_db
              AND TABLE_SCHEMA  = :v_target_schema
              AND TABLE_NAME    = :v_table
        )
        SELECT
            SRC.COLUMN_NAME,
            SRC.TYPE_DEF,
            'ALTER TABLE ' || :v_target_fq ||
            ' ADD COLUMN "' || SRC.COLUMN_NAME || '" ' || SRC.TYPE_DEF AS ALTER_SQL
        FROM SRC
        LEFT JOIN TGT
            ON SRC.COLUMN_NAME = TGT.COLUMN_NAME
        WHERE TGT.COLUMN_NAME IS NULL
        ORDER BY SRC.ORDINAL_POSITION
    );

    LET cur_add CURSOR FOR rs_add;

    FOR rec IN cur_add DO
        v_sql := rec.ALTER_SQL;
        v_sql_log := v_sql_log || v_sql || ';' || CHR(10);

        EXECUTE IMMEDIATE v_sql;

        v_added_cols := v_added_cols + 1;
    END FOR;


    /* ============================================================
       7. ALTER SUPPORTED SOURCE COLUMN TYPE CHANGES
       - VARCHAR/TEXT: widen length only.
       - NUMBER: widen precision and/or scale only.
       - TIMESTAMP/TIME: increase precision only.
       - PK_HK is excluded because it is controlled by P_HK.
       ============================================================ */
    v_phase := 'ALTER_CHANGED_COLUMN_TYPES';

    LET rs_alter RESULTSET := (
        WITH SRC AS (
            SELECT
                REGEXP_REPLACE(UPPER(COLUMN_NAME), '/', '_') AS COLUMN_NAME,
                UPPER(DATA_TYPE) AS DATA_TYPE,
                CHARACTER_MAXIMUM_LENGTH,
                NUMERIC_PRECISION,
                NUMERIC_SCALE,
                DATETIME_PRECISION,
                CASE
                    WHEN UPPER(DATA_TYPE) IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'STRING') THEN 'TEXT'
                    WHEN UPPER(DATA_TYPE) IN ('NUMBER', 'DECIMAL', 'NUMERIC') THEN 'NUMBER'
                    WHEN UPPER(DATA_TYPE) IN ('TIME', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') THEN 'DATETIME'
                    ELSE UPPER(DATA_TYPE)
                END AS TYPE_FAMILY
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_CATALOG = :v_db
              AND TABLE_SCHEMA  = :v_source_schema
              AND TABLE_NAME    = :v_table
              AND UPPER(COLUMN_NAME) <> 'PK_HK'
        ),
        TGT AS (
            SELECT
                REGEXP_REPLACE(UPPER(COLUMN_NAME), '/', '_') AS COLUMN_NAME,
                UPPER(DATA_TYPE) AS DATA_TYPE,
                CHARACTER_MAXIMUM_LENGTH,
                NUMERIC_PRECISION,
                NUMERIC_SCALE,
                DATETIME_PRECISION,
                CASE
                    WHEN UPPER(DATA_TYPE) IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER', 'STRING') THEN 'TEXT'
                    WHEN UPPER(DATA_TYPE) IN ('NUMBER', 'DECIMAL', 'NUMERIC') THEN 'NUMBER'
                    WHEN UPPER(DATA_TYPE) IN ('TIME', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') THEN 'DATETIME'
                    ELSE UPPER(DATA_TYPE)
                END AS TYPE_FAMILY
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_CATALOG = :v_db
              AND TABLE_SCHEMA  = :v_target_schema
              AND TABLE_NAME    = :v_table
              AND UPPER(COLUMN_NAME) <> 'PK_HK'
        ),
        CHANGES AS (
            SELECT
                SRC.COLUMN_NAME,
                CASE
                    WHEN SRC.TYPE_FAMILY = 'TEXT'
                         AND TGT.TYPE_FAMILY = 'TEXT'
                         AND COALESCE(SRC.CHARACTER_MAXIMUM_LENGTH, 0) > COALESCE(TGT.CHARACTER_MAXIMUM_LENGTH, 0)
                        THEN 'VARCHAR(' || SRC.CHARACTER_MAXIMUM_LENGTH || ')'

                    WHEN SRC.TYPE_FAMILY = 'NUMBER'
                         AND TGT.TYPE_FAMILY = 'NUMBER'
                         AND (
                                COALESCE(SRC.NUMERIC_PRECISION, 0) > COALESCE(TGT.NUMERIC_PRECISION, 0)
                             OR COALESCE(SRC.NUMERIC_SCALE, 0) > COALESCE(TGT.NUMERIC_SCALE, 0)
                         )
                        THEN 'NUMBER(' ||
                             GREATEST(COALESCE(SRC.NUMERIC_PRECISION, 38), COALESCE(TGT.NUMERIC_PRECISION, 38)) ||
                             ',' ||
                             GREATEST(COALESCE(SRC.NUMERIC_SCALE, 0), COALESCE(TGT.NUMERIC_SCALE, 0)) ||
                             ')'

                    WHEN SRC.TYPE_FAMILY = 'DATETIME'
                         AND TGT.TYPE_FAMILY = 'DATETIME'
                         AND COALESCE(SRC.DATETIME_PRECISION, 0) > COALESCE(TGT.DATETIME_PRECISION, 0)
                        THEN SRC.DATA_TYPE || '(' || SRC.DATETIME_PRECISION || ')'
                END AS TARGET_TYPE_DEF
            FROM SRC
            JOIN TGT
                ON SRC.COLUMN_NAME = TGT.COLUMN_NAME
        )
        SELECT
            COLUMN_NAME,
            TARGET_TYPE_DEF,
            'ALTER TABLE ' || :v_target_fq ||
            ' ALTER COLUMN "' || COLUMN_NAME || '" SET DATA TYPE ' || TARGET_TYPE_DEF AS ALTER_SQL
        FROM CHANGES
        WHERE TARGET_TYPE_DEF IS NOT NULL
        ORDER BY COLUMN_NAME
    );

    LET cur_alter CURSOR FOR rs_alter;

    FOR rec IN cur_alter DO
        v_sql := rec.ALTER_SQL;
        v_sql_log := v_sql_log || v_sql || ';' || CHR(10);

        EXECUTE IMMEDIATE v_sql;

        v_altered_cols := v_altered_cols + 1;
    END FOR;


    /* ============================================================
       8. RETURN RESULT
       ============================================================ */
    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'action', IFF(
            v_target_created
            OR v_added_cols + v_altered_cols + v_hk_added + v_hk_altered > 0,
            'SYNCED',
            'NO_CHANGE'
        ),
        'source_object', v_source_fq,
        'target_object', v_target_fq,
        'target_created', v_target_created,
        'source_column_count', v_source_cols,
        'target_column_count_before_sync', v_target_cols,
        'columns_added', v_added_cols,
        'columns_altered', v_altered_cols,
        'p_hk', COALESCE(P_HK, FALSE),
        'pk_hk_added', v_hk_added,
        'pk_hk_altered', v_hk_altered,
        'unsupported_type_changes', v_unsupported_changes,
        'warnings', NULLIF(v_warning_log, ''),
        'sql', NULLIF(v_sql_log, '')
    );


EXCEPTION
    WHEN OTHER THEN
        v_err       := SQLERRM;
        v_err_state := SQLSTATE;
        v_err_code  := SQLCODE;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', v_err,
            'sqlstate', v_err_state,
            'sqlcode', v_err_code,
            'source_object', v_source_fq,
            'target_object', v_target_fq,
            'target_created', v_target_created,
            'last_sql', v_sql,
            'sql_so_far', v_sql_log,
            'warnings', NULLIF(v_warning_log, ''),
            'p_hk', COALESCE(P_HK, FALSE)
        );
END
;
