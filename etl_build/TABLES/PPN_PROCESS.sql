-- ADM.PPN_PROCESS - authoritative run-time state, one row per run x table.
-- Drives reruns and the GOLD gate (SP_GATE_CHECK reads it). Upserted by SP_SET_PROCESS_STATE.
-- Rows are created on first touch by the table load itself (via SP_SET_PROCESS_STATE), so this
-- table records WHAT ACTUALLY RAN in a given PPN. The set of tables in a run is decided by the
-- schedule/orchestrator and may legitimately be a SUBSET of ETL_TABLES.
-- NOTE: consequently a table the orchestrator never invoked leaves no row here at all - a
-- completeness/gate check cannot be based on this table alone (see the GOLD gate decision).
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
