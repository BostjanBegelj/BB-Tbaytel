-- ADM.PPN_LOG - append-only step log (run-time; PPN_ prefix). One row per step, written by SP_LOG_STEP.
-- Detail forensics; PPN_PROCESS (not this) is authoritative for state.
-- Deploy order: create AFTER PPN (FK target).

use role dev_sysadmin;
use database dev_db;
use schema adm;

create or replace sequence adm.sq_adm_ppn_log__log_id start with 1 increment by 1 order;

create or replace table adm.ppn_log (
    log_id        number(38,0)     not null default adm.sq_adm_ppn_log__log_id.nextval comment 'Log row id (sequence).',
    ppn_id        number(38,0)     not null comment 'FK -> ADM.PPN.PPN_ID.',
    run_id        varchar          comment 'ADF pipeline run id (correlation).',
    source_id     varchar          comment 'Source identifier.',
    table_name    varchar          comment 'Table being processed (if applicable).',
    phase         varchar          not null comment 'Framework phase (e.g. LOAD_FILE_TO_BRONZE, DQ).',
    status        varchar          not null comment 'START | SUCCESS | SKIP | ERROR | END.',
    start_ts      timestamp_ntz(9) comment 'Step start timestamp.',
    end_ts        timestamp_ntz(9) comment 'Step end timestamp.',
    duration_msec number(38,0)     comment 'Step duration in milliseconds.',
    source_object varchar          comment 'Source object/name.',
    target_object varchar          comment 'Target object/name.',
    row_count     number(38,0)     comment 'Rows processed in this step.',
    message       varchar          comment 'Human-readable log message.',
    detail_json   varchar          comment 'Structured detail (JSON string; ERROR block first per logging standard).',
    constraint pk_adm_ppn_log primary key (log_id),
    constraint fk_adm_ppn_log_ppn foreign key (ppn_id) references adm.ppn (ppn_id)
) comment = 'Run-time: append-only per-step log for forensics (PPN_ prefix).';
