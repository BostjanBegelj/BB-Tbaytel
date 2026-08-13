-- ADM.PPN_PROCESS - authoritative run-time state, one row per run x table.
-- Written ONLY by SP_RUN_TABLE_LOAD (via the SP_SET_PROCESS_STATE helper), which creates the row
-- on first touch and owns its lifecycle: RUNNING -> SUCCESS | SKIP | ERROR.
-- It therefore records WHAT ACTUALLY RAN in a given PPN. The set of tables in a run is decided by
-- the schedule/orchestrator and may legitimately be a SUBSET of ETL_TABLES.
--
-- Consumers:
--   * the PRE-GOLD GATE (SP_GATE_CHECK, called by SP_FINALIZE_RUN): GOLD is refreshed only if
--     every row for the PPN is SUCCESS or SKIP. This is what makes a table failure matter -
--     SP_RUN_TABLE_LOAD does not raise, it just records ERROR here.
--   * per-table status/counts for monitoring and troubleshooting.
--   * rerun decisions (a table left RUNNING or ERROR is the one to re-drive).
--
-- COMPLETENESS CAVEAT: a table the orchestrator never invoked leaves NO row here, so this table
-- alone proves "nothing that ran failed", not "everything ran". The orchestrator therefore passes
-- its dispatched-table COUNT to SP_FINALIZE_RUN, which fails the gate when fewer tables reported.
--
-- RESERVED SOURCE_ID '_RUN_': run-level verdicts rather than tables - e.g. the future DQ result
-- (SOURCE_ID='_RUN_', TABLE_NAME='_DQ_'). Counts towards the gate's failure test but not towards
-- its table counts.
-- Deploy order: create AFTER PPN (FK target).

use role dev_sysadmin;
use database dev_db;
use schema adm;

create or replace table adm.ppn_process (
    ppn_id          number(38,0)     not null comment 'FK -> ADM.PPN.PPN_ID.',
    source_id       varchar          not null comment 'Source identifier (logical FK -> ADM.ETL_SOURCES).',
    table_name      varchar          not null comment 'Table being processed.',
    status          varchar          comment 'RUNNING | SUCCESS | SKIP | ERROR.',
    phase           varchar          comment 'Current/last phase reached.',
    rows_extracted  number(38,0)     comment 'Rows read from source into BRONZE.',
    rows_merged     number(38,0)     comment 'Rows affected by the SILVER MERGE (inserts + updates; not split).',
    rows_deleted    number(38,0)     comment 'Rows soft-deleted in SILVER.',
    watermark_value varchar          comment 'Last incremental high-water mark (stored as text).',
    error_msg       varchar          comment 'Root-cause error message on failure.',
    start_ts        timestamp_ntz(9) comment 'Processing start timestamp.',
    end_ts          timestamp_ntz(9) comment 'Processing end timestamp.',
    constraint pk_adm_ppn_process primary key (ppn_id, source_id, table_name),
    constraint fk_adm_ppn_process_ppn foreign key (ppn_id) references adm.ppn (ppn_id)
) comment = 'Run-time: per-run-per-table state; drives reruns and the GOLD gate (PPN_ prefix).';
