-- ADM.PPN - run header (run-time; PPN_ prefix). One row per pipeline run (batch).
-- PPN_ID is allocated by SP_CREATE_PPN and stamped on every row written during the run.
-- Deploy order: create BEFORE PPN_PROCESS and PPN_LOG (their FK target).

use role dev_sysadmin;
use database dev_db;
use schema adm;

create or replace sequence adm.sq_adm_ppn__ppn_id start with 1 increment by 1 order;

create or replace table adm.ppn (
    ppn_id        number(38,0)     not null default adm.sq_adm_ppn__ppn_id.nextval comment 'Population/batch id (sequence).',
    ppn_timestamp timestamp_ntz(9) not null comment 'PPN creation timestamp (batch as-of).',
    run_id        varchar          comment 'ADF pipeline run id (correlation key).',
    status        varchar          comment 'Run status: RUNNING | SUCCESS | ERROR.',
    start_ts      timestamp_ntz(9) comment 'Run start timestamp.',
    end_ts        timestamp_ntz(9) comment 'Run end timestamp.',
    constraint pk_adm_ppn primary key (ppn_id)
) comment = 'Run-time: one header row per pipeline run/batch (PPN_ prefix).';
