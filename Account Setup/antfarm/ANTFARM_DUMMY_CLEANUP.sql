-- =====================================================================
-- REMOVE TEMPORARY ANTFARM STUB OBJECTS
-- =====================================================================
--
-- Run BEFORE deploying real Antfarm.
--
-- IMPORTANT:
--   Do not run this after the real PLATFORM_DB.ANTFARM objects have
--   replaced the dummy objects.
--
-- The PLATFORM_DB.ANTFARM schema itself is intentionally retained.
-- =====================================================================


DROP FUNCTION IF EXISTS PLATFORM_DB.ANTFARM.API_DQ_GET_LOG(
    VARCHAR,
    VARCHAR,
    VARCHAR
);

DROP FUNCTION IF EXISTS PLATFORM_DB.ANTFARM.API_RUN_DQ(
    VARCHAR
);


DROP PROCEDURE IF EXISTS PLATFORM_DB.ANTFARM.LOAD_API_PROJECT_META_DATA(
    VARCHAR
);

DROP PROCEDURE IF EXISTS PLATFORM_DB.ANTFARM.LOAD_API_DQ_META_DATA(
    VARCHAR
);

DROP PROCEDURE IF EXISTS PLATFORM_DB.ANTFARM.LOAD_API_INGESTION_META_DATA(
    VARCHAR
);


DROP TABLE IF EXISTS PLATFORM_DB.ANTFARM.DQ_LOG;
DROP TABLE IF EXISTS PLATFORM_DB.ANTFARM.DQ_RULES;


-- PLATFORM_DB.ANTFARM schema is kept.
