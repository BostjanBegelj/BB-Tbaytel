# ETL test data (synthetic Parquet)

Small synthetic dataset for **technically** exercising the ETL procedures against
`DEV_DB.ADM.EXT_STAGE_AZURE` (the internal stand-in for the Azure Blob stage).
Not real data. Regenerate any time with:

```
python etl_build/_test_data/generate_test_parquet.py
```

The `.parquet` files are git-ignored (binary); only the generator + this README
are tracked.

## Layout (mirrors an Azure Blob container; source system = BSS_ORA)

```
_test_data/BSS_ORA/<TABLE>/load_date=YYYY-MM-DD/<TABLE>_YYYYMMDD.parquet
```

Three load dates: `2026-07-01`, `2026-07-02`, `2026-07-03`.

## Tables

| Table | Grain | Pattern | Type coverage |
|---|---|---|---|
| `CUSTOMER` | 1 row / customer | Full snapshot; **update** (1002 city+email, then 1004 credit), **insert** (1006 on d2), **delete** (1002 gone on d3) | int64, string, **NULL** email, decimal(10,2), bool, 2× timestamp |
| `SERVICE_PLAN` | 1 row / plan | Full snapshot; price change (plan 2 on d2), insert (plan 5 on d3) | int64, string, decimal(8,2), int32 **NULL** (unlimited), bool, date |
| `USAGE_DAILY` | usage events / day | Append (each date = that day's rows) | int64 keys+FKs, date, int32, decimal(12,3) **NULL**, decimal(10,2), bool, timestamp |

Row counts: CUSTOMER 5/6/5, SERVICE_PLAN 4/4/5, USAGE_DAILY 6/6/6.

With `PLATFORM_DB.FILE_FORMATS.FF_PARQUET` (`use_logical_type=true`) these
land in Snowflake as NUMBER / VARCHAR / BOOLEAN / DATE / TIMESTAMP_NTZ, decimals as
NUMBER(p,s). The snapshot changes let you test compare/CDC, history, and IS_DELETED.

## Load steps

`PUT` runs from **SnowSQL / a driver**, not the Snowsight worksheet.

```sql
-- 1) Upload one table+date (repeat per folder). auto_compress=false: Parquet is already compressed.
PUT file://C:/repo/BB-Tbaytel/BB-Tbaytel/etl_build/_test_data/BSS_ORA/CUSTOMER/load_date=2026-07-01/*.parquet
    @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/CUSTOMER/load_date=2026-07-01/
    AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

-- Bulk upload everything at once (recursive keeps the folder structure):
--   PUT file://C:/repo/BB-Tbaytel/BB-Tbaytel/etl_build/_test_data/BSS_ORA/ @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- 2) Inspect
LIST @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/CUSTOMER/;

-- 3) Infer schema (what the load proc uses to build/sync RAW DDL)
SELECT *
FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/CUSTOMER/load_date=2026-07-01/',
    FILE_FORMAT => 'PLATFORM_DB.FILE_FORMATS.FF_PARQUET'));

-- 4) Load one snapshot (match by column name)
COPY INTO DEV_DB.RAW.CUSTOMER
    FROM @DEV_DB.ADM.EXT_STAGE_AZURE/BSS_ORA/CUSTOMER/load_date=2026-07-01/
    FILE_FORMAT = (FORMAT_NAME = 'PLATFORM_DB.FILE_FORMATS.FF_PARQUET')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = ABORT_STATEMENT;
```

To simulate the daily cycle, load `load_date=2026-07-01` first, run the pipeline,
then `2026-07-02`, then `2026-07-03`, checking that updates/inserts/deletes are
detected between runs.
