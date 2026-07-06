CREATE OR REPLACE PROCEDURE ADM.SP_COMPARE_DATALOADS(
    P_TABLE  VARCHAR,
    P_RAW    BOOLEAN DEFAULT FALSE,
    P_PPN_ID NUMBER(38,0) DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Compares business-column row count and HASH_AGG between RAW/EX and RAW_HIST/EX_HIST for a given PPN_ID. A difference in the business column SET (a new or dropped column) is always treated as a MISMATCH.'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_db             STRING DEFAULT UPPER(CURRENT_DATABASE());

    v_raw            BOOLEAN DEFAULT COALESCE(P_RAW, FALSE);
    v_ppn_id         NUMBER(38,0) DEFAULT P_PPN_ID;
    v_ppn_id_last    NUMBER(38,0);

    v_schema         STRING;
    v_hist_schema    STRING;
    v_table          STRING DEFAULT UPPER(NULLIF(TRIM(P_TABLE), ''));

    v_source_fq      STRING;
    v_target_fq      STRING;

    v_phase          STRING DEFAULT 'INIT';
    v_sql            STRING DEFAULT '';
    v_sql_log        STRING DEFAULT '';
    v_warning_log    STRING DEFAULT '';

    v_source_cols    NUMBER DEFAULT 0;
    v_target_cols    NUMBER DEFAULT 0;
    v_col_list       STRING;

    -- FIX: column-set difference detection
    v_diff_cols      STRING;
    v_col_set_differs BOOLEAN DEFAULT FALSE;

    v_count_source   NUMBER DEFAULT 0;
    v_hash_source    STRING DEFAULT '';

    v_count_target   NUMBER DEFAULT 0;
    v_hash_target    STRING DEFAULT '';

    v_is_match       BOOLEAN DEFAULT FALSE;

    v_rs             RESULTSET;

    v_err            STRING;
    v_err_state      STRING;
    v_err_code       NUMBER;
BEGIN
    /* ============================================================
       1. VALIDATE INPUT PARAMETERS
       ============================================================ */
    v_phase := 'VALIDATE_INPUT';

    IF (v_table IS NULL OR v_ppn_id IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'P_TABLE and P_PPN_ID are required.',
            'table', v_table,
            'ppn_id', v_ppn_id
        );
    END IF;

    IF (NOT REGEXP_LIKE(v_table, '^[A-Z][A-Z0-9_]*$')) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'Only simple unquoted table identifiers are supported.',
            'table', v_table
        );
    END IF;

    IF (v_raw) THEN
        v_schema := 'RAW';
    ELSE
        v_schema := 'EX';
    END IF;

    v_hist_schema := v_schema || '_HIST';

    v_source_fq := '"' || v_db || '"."' || v_schema || '"."' || v_table || '"';
    v_target_fq := '"' || v_db || '"."' || v_hist_schema || '"."' || v_table || '"';


    /* ============================================================
       2. CHECK SOURCE AND TARGET TABLES
       ============================================================ */
    v_phase := 'CHECK_TABLES';

    SELECT COUNT(*)
      INTO :v_source_cols
      FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_CATALOG = :v_db
       AND TABLE_SCHEMA  = :v_schema
       AND TABLE_NAME    = :v_table;

    IF (v_source_cols = 0) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'Source table does not exist or has no columns.',
            'source_object', v_source_fq
        );
    END IF;

    SELECT COUNT(*)
      INTO :v_target_cols
      FROM INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_CATALOG = :v_db
       AND TABLE_SCHEMA  = :v_hist_schema
       AND TABLE_NAME    = :v_table;

    IF (v_target_cols = 0) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'Target history table does not exist or has no columns.',
            'source_object', v_source_fq,
            'target_object', v_target_fq
        );
    END IF;


    /* ============================================================
       3. GET COMMON BUSINESS COLUMNS
       ============================================================ */
    v_phase := 'GET_COMMON_BUSINESS_COLUMNS';

    SELECT LISTAGG('"' || REPLACE(c.COLUMN_NAME, '"', '""') || '"', ', ')
           WITHIN GROUP (ORDER BY c.COLUMN_NAME)
      INTO :v_col_list
      FROM (
            SELECT COLUMN_NAME
              FROM INFORMATION_SCHEMA.COLUMNS
             WHERE TABLE_CATALOG = :v_db
               AND TABLE_SCHEMA  = :v_schema
               AND TABLE_NAME    = :v_table

            INTERSECT

            SELECT COLUMN_NAME
              FROM INFORMATION_SCHEMA.COLUMNS
             WHERE TABLE_CATALOG = :v_db
               AND TABLE_SCHEMA  = :v_hist_schema
               AND TABLE_NAME    = :v_table
           ) c
     WHERE UPPER(c.COLUMN_NAME) NOT IN (
            'METADATA$FILENAME',
            'METADATA$FILE_ROW_NUMBER',
            'METADATA$FILE_CONTENT_KEY',
            'METADATA$FILE_LAST_MODIFIED',
            'METADATA$START_SCAN_TIME',
            'METADATA_FILENAME',
            'METADATA_FILE_ROW_NUMBER',
            'PPN_ID',
            'PPN_DT',
            'PPN_DATE',
            'PK_HK'
        );

    IF (v_col_list IS NULL OR v_col_list = '') THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'No common business columns found.',
            'source_object', v_source_fq,
            'target_object', v_target_fq
        );
    END IF;


    /* ============================================================
       3B. DETECT BUSINESS COLUMN-SET DIFFERENCES
       - Compares the SET of business columns on each side.
       - Any business column present on only one side (i.e. added or
         dropped) forces a MISMATCH later, so schema evolution can never
         be reported as "identical" merely because the overlapping
         columns happen to hash equal.
       - Technical / metadata columns are ignored (same exclude list as
         the common-column query above).
       ============================================================ */
    v_phase := 'CHECK_COLUMN_SET_DIFF';

    SELECT LISTAGG('"' || d.COLUMN_NAME || '"', ', ') WITHIN GROUP (ORDER BY d.COLUMN_NAME)
      INTO :v_diff_cols
      FROM (
            (
              SELECT COLUMN_NAME
                FROM INFORMATION_SCHEMA.COLUMNS
               WHERE TABLE_CATALOG = :v_db
                 AND TABLE_SCHEMA  = :v_schema
                 AND TABLE_NAME    = :v_table
              EXCEPT
              SELECT COLUMN_NAME
                FROM INFORMATION_SCHEMA.COLUMNS
               WHERE TABLE_CATALOG = :v_db
                 AND TABLE_SCHEMA  = :v_hist_schema
                 AND TABLE_NAME    = :v_table
            )
            UNION ALL
            (
              SELECT COLUMN_NAME
                FROM INFORMATION_SCHEMA.COLUMNS
               WHERE TABLE_CATALOG = :v_db
                 AND TABLE_SCHEMA  = :v_hist_schema
                 AND TABLE_NAME    = :v_table
              EXCEPT
              SELECT COLUMN_NAME
                FROM INFORMATION_SCHEMA.COLUMNS
               WHERE TABLE_CATALOG = :v_db
                 AND TABLE_SCHEMA  = :v_schema
                 AND TABLE_NAME    = :v_table
            )
           ) d
     WHERE UPPER(d.COLUMN_NAME) NOT IN (
            'METADATA$FILENAME',
            'METADATA$FILE_ROW_NUMBER',
            'METADATA$FILE_CONTENT_KEY',
            'METADATA$FILE_LAST_MODIFIED',
            'METADATA$START_SCAN_TIME',
            'METADATA_FILENAME',
            'METADATA_FILE_ROW_NUMBER',
            'PPN_ID',
            'PPN_DT',
            'PPN_DATE',
            'PK_HK'
        );

    v_col_set_differs := (NULLIF(v_diff_cols, '') IS NOT NULL);

    IF (v_col_set_differs) THEN
        v_warning_log := v_warning_log ||
                         'Business column sets differ between source and target history ' ||
                         '(forces MISMATCH). Differing columns: ' || v_diff_cols || '.' || CHR(10);
    END IF;


    /* ============================================================
       4. CALCULATE SOURCE COUNT AND HASH
       ============================================================ */
    v_phase := 'CALCULATE_SOURCE_HASH';

    v_sql :=
        'SELECT COUNT(*)::NUMBER AS ROW_COUNT, ' ||
        'HASH_AGG(' || v_col_list || ')::STRING AS HASH_VALUE ' ||
        'FROM ' || v_source_fq || ' ' ||
        'WHERE PPN_ID = ' || TO_VARCHAR(v_ppn_id);

    v_sql_log := v_sql_log || v_sql || ';' || CHR(10);

    v_rs := (EXECUTE IMMEDIATE :v_sql);

    FOR rec IN v_rs DO
        v_count_source := rec.ROW_COUNT;
        v_hash_source  := COALESCE(rec.HASH_VALUE, '');
    END FOR;

    IF (v_count_source = 0) THEN
        v_warning_log := v_warning_log ||
                         'Source table has zero rows for PPN_ID=' ||
                         TO_VARCHAR(v_ppn_id) || '.' || CHR(10);
    END IF;


    /* ============================================================
       5. GET LATEST TARGET HISTORY PPN_ID
       ============================================================ */
    v_phase := 'GET_LATEST_TARGET_PPN_ID';

    v_sql :=
        'SELECT MAX(PPN_ID)::NUMBER AS MAX_PPN_ID ' ||
        'FROM ' || v_target_fq;

    v_sql_log := v_sql_log || v_sql || ';' || CHR(10);

    v_rs := (EXECUTE IMMEDIATE :v_sql);

    FOR rec IN v_rs DO
        v_ppn_id_last := rec.MAX_PPN_ID;
    END FOR;

    IF (v_ppn_id_last IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'phase', v_phase,
            'message', 'No PPN_ID found in target history table.',
            'source_object', v_source_fq,
            'target_object', v_target_fq,
            'source_ppn_id', v_ppn_id,
            'sql_so_far', NULLIF(v_sql_log, ''),
            'warnings', NULLIF(v_warning_log, '')
        );
    END IF;


    /* ============================================================
       6. CALCULATE TARGET HISTORY COUNT AND HASH
       ============================================================ */
    v_phase := 'CALCULATE_TARGET_HASH';

    v_sql :=
        'SELECT COUNT(*)::NUMBER AS ROW_COUNT, ' ||
        'HASH_AGG(' || v_col_list || ')::STRING AS HASH_VALUE ' ||
        'FROM ' || v_target_fq || ' ' ||
        'WHERE PPN_ID = ' || TO_VARCHAR(v_ppn_id_last);

    v_sql_log := v_sql_log || v_sql || ';' || CHR(10);

    v_rs := (EXECUTE IMMEDIATE :v_sql);

    FOR rec IN v_rs DO
        v_count_target := rec.ROW_COUNT;
        v_hash_target  := COALESCE(rec.HASH_VALUE, '');
    END FOR;

    IF (v_count_target = 0) THEN
        v_warning_log := v_warning_log ||
                         'Target history table has zero rows for PPN_ID=' ||
                         TO_VARCHAR(v_ppn_id_last) || '.' || CHR(10);
    END IF;


    /* ============================================================
       7. COMPARE RESULTS
       - Identical requires: same row count, same HASH_AGG over the common
         business columns, AND no business column-set difference.
       ============================================================ */
    v_phase := 'COMPARE_RESULTS';

    v_is_match :=
        (
            v_count_source = v_count_target
            AND COALESCE(v_hash_source, '') = COALESCE(v_hash_target, '')
            AND NOT v_col_set_differs
        );

    IF (NOT v_is_match) THEN
        v_warning_log := v_warning_log ||
                         'Source and target history are not identical. ' ||
                         'Source count=' || TO_VARCHAR(v_count_source) ||
                         ', target count=' || TO_VARCHAR(v_count_target) ||
                         IFF(v_col_set_differs, ', column set differs', '') ||
                         '.' || CHR(10);
    END IF;


    /* ============================================================
       8. RETURN RESULT
       ============================================================ */
    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'action', IFF(v_is_match, 'MATCH', 'MISMATCH'),
        'phase', v_phase,
        'is_identical', v_is_match,

        'source_object', v_source_fq,
        'target_object', v_target_fq,

        'source_schema', v_schema,
        'target_schema', v_hist_schema,
        'table_name', v_table,

        'source_ppn_id', v_ppn_id,
        'target_ppn_id', v_ppn_id_last,

        'source_column_count', v_source_cols,
        'target_column_count', v_target_cols,

        'source_stats', OBJECT_CONSTRUCT(
            'row_count', v_count_source,
            'hash', v_hash_source
        ),

        'target_stats', OBJECT_CONSTRUCT(
            'row_count', v_count_target,
            'hash', v_hash_target
        ),

        'columns_compared', v_col_list,
        'column_set_differs', v_col_set_differs,
        'differing_columns', NULLIF(v_diff_cols, ''),
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
            'source_schema', v_schema,
            'target_schema', v_hist_schema,
            'table_name', v_table,
            'source_ppn_id', v_ppn_id,
            'target_ppn_id', v_ppn_id_last,
            'last_sql', v_sql,
            'sql_so_far', NULLIF(v_sql_log, ''),
            'warnings', NULLIF(v_warning_log, '')
        );
END;
$$;
