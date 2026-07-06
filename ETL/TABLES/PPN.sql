CREATE OR REPLACE SEQUENCE ADM.SQ_ADM_PPN__PPN_ID START WITH 1 INCREMENT BY 1 ORDER;


create or replace TABLE ADM.PPN (
	PPN_ID NUMBER(38,0) NOT NULL DEFAULT ADM.SQ_ADM_PPN__PPN_ID.NEXTVAL COMMENT 'Process/population identifier.',
	PPN_DT TIMESTAMP_NTZ(9) NOT NULL COMMENT 'PPN_ID creation timestamp.',
	constraint PK_ADM_PPN primary key (PPN_ID)
)COMMENT='Table of process/population IDs for particular source applications/sources.'
;