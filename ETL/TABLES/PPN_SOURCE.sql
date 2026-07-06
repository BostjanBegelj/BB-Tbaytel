create or replace TABLE ADM.PPN_SOURCE (
	SOURCE_ID VARCHAR(16777216) NOT NULL COMMENT 'Source (table, API, file,...) identifier.',
	SOURCE_NAME VARCHAR(16777216) NOT NULL COMMENT 'Source application identifier.',
	constraint PK_ADM_PPN_SOURCE primary key (SOURCE_ID)
)COMMENT='Table containing list of used Sources'
;