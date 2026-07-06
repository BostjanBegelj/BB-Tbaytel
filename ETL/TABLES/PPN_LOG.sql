CREATE OR REPLACE SEQUENCE ADM.SQ_ADM_PPN_LOG__PPN_LOG_ID START WITH 1 INCREMENT BY 1 ORDER;

create or replace TABLE ADM.PPN_LOG (
	PPN_LOG_ID NUMBER(38,0) NOT NULL DEFAULT ADM.SQ_ADM_PPN_LOG__PPN_LOG_ID.NEXTVAL COMMENT 'Process/population log identifier.',
	PPN_ID NUMBER(38,0) NOT NULL COMMENT 'Process/population identifier.',
	SOURCE_ID VARCHAR(16777216) NOT NULL COMMENT 'Source (table, API, file,...) identifier.',
	PPN_PHASE VARCHAR(16777216) NOT NULL COMMENT 'Framework process phase',
	LOG_START TIMESTAMP_NTZ(9) NOT NULL COMMENT 'Log start timestamp.',
	LOG_END TIMESTAMP_NTZ(9) NOT NULL COMMENT 'Log end timestamp.',
    DURATION_MSEC NUMBER(38,0) NOT NULL COMMENT 'Process duration in MSEC',
	LOG_STATUS VARCHAR(16777216) NOT NULL COMMENT 'Framework phase log status.',
	SOURCE_OBJECT VARCHAR(16777216) COMMENT 'Source object name.',
	TARGET_OBJECT VARCHAR(16777216) COMMENT 'Target object name.',
	ROW_COUNT NUMBER(38,0) COMMENT 'Count of processed rows within one step (INSERT, DELETE, SELECT, UPDATE...).',
	RUN_ID VARCHAR(16777216) COMMENT 'Unique run identifier for NIFI execution call',
	LOG_MESSAGE VARCHAR(16777216) COMMENT 'Log message',
	LOG_MESSAGE_DETAIL VARCHAR(16777216) COMMENT 'Detailed log message containing additional information that can be in json format.',
	constraint PK_ADM_PPN_LOG primary key (PPN_LOG_ID)
)COMMENT='Process log table containing detailed log per each load of a specific table/api/file.'
;