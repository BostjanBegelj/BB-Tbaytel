-- ADM.SP_LOAD_DATABASE_TO_BRONZE - DATABASE load pattern: read one table directly from another
-- Snowflake database (SOURCE_DB.SOURCE_OBJECT) into <TARGET_SCHEMA>.<TABLE> (default BRONZE).
-- The source database may be an inbound data share or an ordinary database - identical to this
-- procedure either way; only SELECT access matters.
-- No stage / no COPY: a per-PPN snapshot via CREATE OR REPLACE TABLE ... AS SELECT,
-- so the batch is stable and idempotent per PPN. Config-driven, mirrors
-- SP_LOAD_FILE_TO_BRONZE (same helpers, same child error pattern).
-- Always lands a FULL snapshot of the source object into BRONZE.
-- NOTE: WATERMARK_COLUMN is currently NOT used by this procedure or by SILVER - an INCR
-- data-share table is landed in full and then MERGEd (correct, just not optimised). Watermark-
-- bounded extraction is a future optimisation, not current behaviour.
-- Writes PPN_LOG only; PPN_PROCESS state is owned by SP_RUN_TABLE_LOAD.
-- RUN_ID is resolved from ADM.PPN by SP_LOG_STEP, so it is not a parameter here.

use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_LOAD_DATABASE_TO_BRONZE(
    "P_PPN_ID"     NUMBER(38,0),
    "P_SOURCE_ID"  VARCHAR,
    "P_TABLE_NAME" VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'DATABASE pattern: per-PPN snapshot from SOURCE_DB.SOURCE_OBJECT into <TARGET_SCHEMA>.<TABLE>. Config-driven.'
EXECUTE AS CALLER
AS
DECLARE
    e_failed EXCEPTION (-20800, 'SP_LOAD_DATABASE_TO_BRONZE failed.');

    v_ppn_id      NUMBER  DEFAULT P_PPN_ID;
    v_source_id   STRING  DEFAULT NULLIF(TRIM(P_SOURCE_ID), '');
    v_table       STRING  DEFAULT UPPER(NULLIF(TRIM(P_TABLE_NAME), ''));

    v_source_db   STRING;
    v_source_obj  STRING;
    v_target_sch  STRING;
    v_load_type   STRING;
    v_wm_col      STRING;
    v_wm_type     STRING;
    v_wm_overlap  NUMBER  DEFAULT 0;
    v_wm_last     STRING;
    v_wm_ppn      NUMBER;
    v_wm_new      STRING;
    v_wm_bound    STRING;                  -- SQL expression for the effective lower bound
    v_wm_expr     STRING;                  -- SQL expression rendering MAX(col) as text
    v_where       STRING  DEFAULT '';

    v_db          STRING  DEFAULT UPPER(CURRENT_DATABASE());
    v_target_fq   STRING;
    v_src_fq      STRING;
    v_ppn_ts      TIMESTAMP_NTZ(9);

    v_cfg_count   NUMBER  DEFAULT 0;
    v_ppn_count   NUMBER  DEFAULT 0;
    v_row_count   NUMBER  DEFAULT 0;
    v_started_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_phase       STRING  DEFAULT 'INIT';
    v_last_sql    STRING  DEFAULT '';
    v_error_msg   STRING;
    v_sql         STRING;
    v_log_rows    NUMBER  DEFAULT 0;
BEGIN
    /* 1. VALIDATE ------------------------------------------------------- */
    v_phase := 'VALIDATE';
    IF (v_ppn_id IS NULL OR v_source_id IS NULL OR v_table IS NULL) THEN
        v_error_msg := 'P_PPN_ID, P_SOURCE_ID and P_TABLE_NAME are required.';
        RAISE e_failed;
    END IF;

    /* 2. READ CONFIG ---------------------------------------------------- */
    /*    SP_RUN_TABLE_LOAD owns the authoritative config validation (and dispatches on
          SOURCE_TYPE, so no source-type check is repeated here). This is only a guard on
          THIS procedure's own read - it catches config removed mid-run and standalone calls. */
    v_phase := 'READ_CONFIG';
    SELECT COUNT(*), MAX(s.source_db), MAX(t.source_object),
           MAX(UPPER(COALESCE(t.target_schema, 'BRONZE'))),
           MAX(UPPER(t.load_type)), MAX(t.watermark_column),
           MAX(UPPER(t.watermark_type)), MAX(COALESCE(t.watermark_overlap, 0))
      INTO :v_cfg_count, :v_source_db, :v_source_obj, :v_target_sch,
           :v_load_type, :v_wm_col, :v_wm_type, :v_wm_overlap
      FROM ADM.ETL_TABLES t
      JOIN ADM.ETL_SOURCES s ON s.source_id = t.source_id
     WHERE t.source_id = :v_source_id
       AND t.table_name = :v_table
       AND t.active_flag
       AND s.active_flag;

    IF (v_cfg_count <> 1) THEN
        v_error_msg := 'Expected exactly 1 active config row for [' || v_source_id || '.' || v_table
                    || '] at landing time, found ' || v_cfg_count || ' (config changed mid-run?).';
        RAISE e_failed;
    END IF;
    IF (v_source_db IS NULL OR v_source_obj IS NULL) THEN
        v_error_msg := 'Config incomplete: DATABASE needs SOURCE_DB (source) and SOURCE_OBJECT (table).';
        RAISE e_failed;
    END IF;

    -- SOURCE_DB / SOURCE_OBJECT are interpolated into dynamic SQL, so validate their shape the
    -- same way the wrapper validates the table name: plain identifiers, dot-separated.
    v_phase := 'VALIDATE_SOURCE_NAMES';
    IF (NOT REGEXP_LIKE(UPPER(v_source_db), '^[A-Z_][A-Z0-9_$]*$')) THEN
        v_error_msg := 'Invalid SOURCE_DB [' || v_source_db || '] - must be a plain identifier.';
        RAISE e_failed;
    END IF;
    IF (NOT REGEXP_LIKE(UPPER(v_source_obj), '^[A-Z_][A-Z0-9_$]*(\\.[A-Z_][A-Z0-9_$]*)*$')) THEN
        v_error_msg := 'Invalid SOURCE_OBJECT [' || v_source_obj || '] - expected SCHEMA.TABLE of plain identifiers.';
        RAISE e_failed;
    END IF;

    v_src_fq    := v_source_db || '.' || v_source_obj;                       -- e.g. SHARE_SIM_DB.WHOLESALE.PARTNER_ACCOUNT
    v_target_fq := '"' || v_db || '"."' || v_target_sch || '"."' || v_table || '"';

    /* PPN context - guard explicitly: a missing PPN would otherwise leave v_ppn_ts NULL, make the
       whole concatenated CTAS string NULL, and fail with a baffling message. */
    v_phase := 'GET_PPN';
    SELECT COUNT(*), MAX(PPN_TIMESTAMP)
      INTO :v_ppn_count, :v_ppn_ts
      FROM ADM.PPN WHERE PPN_ID = :v_ppn_id;
    IF (v_ppn_count <> 1 OR v_ppn_ts IS NULL) THEN
        v_error_msg := 'PPN_ID [' || TO_VARCHAR(v_ppn_id) || '] not found in ADM.PPN (call SP_CREATE_PPN first).';
        RAISE e_failed;
    END IF;

    /* NOTE (accepted risk): the CTAS below adds PPN_ID / PPN_TIMESTAMP next to s.*, so a source
       column with one of those names would raise a duplicate-column error. Not pre-checked -
       the probability is negligible and it would cost a metadata query on every load. */

    /* 2b. WATERMARK LOWER BOUND (LOAD_TYPE = WATERMARK only) -------------
          Read the high value reached by the most recent successful run for this table.
          Two aggregate steps so neither can throw on "no rows yet", and so the pick is
          "latest PPN" rather than a string MAX (WATERMARK_VALUE is VARCHAR, so a string
          MAX would be wrong for numeric watermarks).                              */
    IF (v_load_type = 'WATERMARK' AND v_wm_col IS NOT NULL) THEN
        v_phase := 'WATERMARK_READ';
        SELECT MAX(PPN_ID)
          INTO :v_wm_ppn
          FROM ADM.PPN_PROCESS
         WHERE SOURCE_ID = :v_source_id AND TABLE_NAME = :v_table
           AND PPN_ID <> :v_ppn_id
           AND UPPER(STATUS) IN ('SUCCESS', 'SKIP')
           AND WATERMARK_VALUE IS NOT NULL;

        IF (v_wm_ppn IS NOT NULL) THEN
            SELECT MAX(WATERMARK_VALUE)
              INTO :v_wm_last
              FROM ADM.PPN_PROCESS
             WHERE SOURCE_ID = :v_source_id AND TABLE_NAME = :v_table AND PPN_ID = :v_wm_ppn;
        END IF;

        -- First ever run has no lower bound: load everything, then record the MAX reached.
        -- WATERMARK_TYPE (declared in config, not derived - the source's INFORMATION_SCHEMA may
        -- not be visible for a shared DB) decides how the bound is built and how WATERMARK_OVERLAP
        -- is interpreted: DAYS for TIMESTAMP/DATE, raw units for NUMBER.
        IF (v_wm_last IS NOT NULL) THEN
            v_wm_bound := CASE v_wm_type
                WHEN 'TIMESTAMP' THEN 'DATEADD(day, -' || v_wm_overlap || ', ''' || v_wm_last || '''::TIMESTAMP_NTZ)'
                WHEN 'DATE'      THEN 'DATEADD(day, -' || v_wm_overlap || ', ''' || v_wm_last || '''::DATE)'
                WHEN 'NUMBER'    THEN '(' || v_wm_last || ' - ' || v_wm_overlap || ')'
                ELSE NULL
            END;
            IF (v_wm_bound IS NULL) THEN
                v_error_msg := 'Invalid WATERMARK_TYPE [' || COALESCE(v_wm_type, '<null>')
                            || '] for [' || v_source_id || '.' || v_table || '] - expected TIMESTAMP | DATE | NUMBER.';
                RAISE e_failed;
            END IF;
            v_where := ' WHERE s."' || v_wm_col || '" > ' || v_wm_bound;
        END IF;
    END IF;

    /* 3. SNAPSHOT (CTAS) with lineage columns --------------------------- */
    v_phase := 'SNAPSHOT';
    v_sql := 'CREATE OR REPLACE TABLE ' || v_target_fq || ' AS
        SELECT s.*,
               ' || v_ppn_id || ' AS PPN_ID,
               ''' || TO_CHAR(v_ppn_ts, 'YYYY-MM-DD HH24:MI:SS.FF9') || '''::TIMESTAMP_NTZ(9) AS PPN_TIMESTAMP
        FROM ' || v_src_fq || ' s' || v_where;
    v_last_sql := v_sql;
    EXECUTE IMMEDIATE v_sql;

    /* 4. COUNT + record the watermark reached --------------------------- */
    v_phase := 'COUNT';
    SELECT COUNT(*) INTO :v_row_count FROM IDENTIFIER(:v_target_fq) WHERE PPN_ID = :v_ppn_id;

    -- Derive the new high value from the DATA that landed (never from the clock, which would
    -- open gaps if source and warehouse clocks differ or rows commit late).
    -- Render with an EXPLICIT format per declared type, so the stored text does not depend on
    -- session TIMESTAMP/DATE output formats and always re-parses on the next run.
    IF (v_wm_col IS NOT NULL AND v_row_count > 0) THEN
        v_phase := 'WATERMARK_WRITE';
        v_wm_expr := CASE v_wm_type
            WHEN 'TIMESTAMP' THEN 'TO_VARCHAR(MAX("' || v_wm_col || '"), ''YYYY-MM-DD HH24:MI:SS.FF9'')'
            WHEN 'DATE'      THEN 'TO_VARCHAR(MAX("' || v_wm_col || '"), ''YYYY-MM-DD'')'
            ELSE                  'TO_VARCHAR(MAX("' || v_wm_col || '"))'
        END;
        v_sql := 'SELECT ' || v_wm_expr || ' FROM ' || v_target_fq || ' WHERE PPN_ID = ' || v_ppn_id;
        v_last_sql := v_sql;
        EXECUTE IMMEDIATE v_sql;
        SELECT $1 INTO :v_wm_new FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    END IF;

    /* 5. LOG SUCCESS (state is owned by SP_RUN_TABLE_LOAD) -------------- */
    v_phase := 'LOG_SUCCESS';
    CALL ADM.SP_LOG_STEP(
        P_PPN_ID      => :v_ppn_id,
        P_PHASE       => 'LOAD_DATABASE_TO_BRONZE',
        P_STATUS      => 'SUCCESS',
        P_SOURCE_ID   => :v_source_id,
        P_TABLE_NAME  => :v_table,
        P_LOG_START   => :v_started_at,
        P_LOG_END     => CURRENT_TIMESTAMP(),
        P_SOURCE_OBJECT => :v_src_fq,
        P_TARGET_OBJECT => :v_target_fq,
        P_ROW_COUNT   => :v_row_count,
        P_MESSAGE     => 'SUCCESS: ' || IFF(:v_where = '', 'full snapshot ', 'watermarked delta ')
                      || :v_row_count || ' row(s) into ' || :v_target_sch || '.' || :v_table || '.',
        P_DETAIL_JSON => OBJECT_CONSTRUCT(
            'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_DATABASE_TO_BRONZE','ppn_id',:v_ppn_id,
                                        'load_type',:v_load_type),
            'results', OBJECT_CONSTRUCT('source', :v_src_fq, 'rows_loaded', :v_row_count,
                                        'watermark_column', :v_wm_col,
                                        'watermark_type', :v_wm_type,
                                        'watermark_overlap', :v_wm_overlap,
                                        'watermark_last_recorded', :v_wm_last,
                                        'watermark_bound_sql', :v_wm_bound,
                                        'watermark_to', :v_wm_new)
        )
    ) INTO :v_log_rows;

    RETURN OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'procedure', 'SP_LOAD_DATABASE_TO_BRONZE',
        'source_id', v_source_id,
        'table', v_table,
        'target_object', v_target_fq,
        'rows_loaded', v_row_count,
        'watermark_value', v_wm_new,     -- new high value; wrapper stores it in PPN_PROCESS
        'ppn_id', v_ppn_id
    );

EXCEPTION
    WHEN OTHER THEN
        LET v_final_msg STRING := COALESCE(v_error_msg, SQLERRM);
        BEGIN
            CALL ADM.SP_LOG_STEP(
                P_PPN_ID      => :v_ppn_id,
                P_PHASE       => 'LOAD_DATABASE_TO_BRONZE',
                P_STATUS      => 'ERROR',
                P_SOURCE_ID   => :v_source_id,
                P_TABLE_NAME  => :v_table,
                P_LOG_START   => :v_started_at,
                P_LOG_END     => CURRENT_TIMESTAMP(),
                P_MESSAGE     => 'ERROR [SP_LOAD_DATABASE_TO_BRONZE/' || :v_phase || ']: ' || :v_final_msg,
                P_DETAIL_JSON => OBJECT_CONSTRUCT(
                    'ERROR', OBJECT_CONSTRUCT(
                        'source_procedure', 'SP_LOAD_DATABASE_TO_BRONZE',
                        'source_phase',     :v_phase,
                        'message',          :v_final_msg,
                        'last_sql',         NULLIF(:v_last_sql, ''),
                        'sqlcode',          IFF(:v_error_msg IS NULL, :SQLCODE, NULL),
                        'sqlstate',         IFF(:v_error_msg IS NULL, :SQLSTATE, NULL)
                    ),
                    'context', OBJECT_CONSTRUCT('procedure','SP_LOAD_DATABASE_TO_BRONZE','ppn_id',:v_ppn_id)
                )
            ) INTO :v_log_rows;
        EXCEPTION
            WHEN OTHER THEN NULL;
        END;

        RETURN OBJECT_CONSTRUCT(
            'status', 'ERROR',
            'procedure', 'SP_LOAD_DATABASE_TO_BRONZE',
            'phase', v_phase,
            'message', v_final_msg,
            'last_sql', v_last_sql
        );
END;
