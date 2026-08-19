# GOLD layer simulation

Simulates the **GOLD** end of the medallion pipeline on top of the existing
`share_sim_db` → BRONZE → SILVER flow. It adds a small star schema plus the two
conformed calendar dimensions, and wires the pipeline's GOLD refresh step.

## What's here

| File | Object | Type | Notes |
|------|--------|------|-------|
| `SHARE_SIM_DB_DEMO_DATA.sql` | `share_sim_db.wholesale.*` | data reload | Enriches the share source: 6 partners, 72 usage rows over 2 weeks. Idempotent. |
| `DIM_DATE.sql` | `GOLD.DIM_DATE` | table | Date dimension with **Canadian (Ontario statutory + federal) holidays computed in SQL**. |
| `DIM_TIME.sql` | `GOLD.DIM_TIME` | table | Time-of-day dimension (per-second), conformed. |
| `DIM_PARTNER.sql` | `GOLD.DIM_PARTNER` | **dynamic table** | Dimension from `SILVER.PARTNER_ACCOUNT`; `PARTNER_HK` surrogate + unknown member. |
| `FCT_WHOLESALE_USAGE.sql` | `GOLD.FCT_WHOLESALE_USAGE` | **dynamic table** | Fact from `SILVER.WHOLESALE_USAGE`; FKs to `DIM_PARTNER` and `DIM_DATE`. |
| `SP_REFRESH_GOLD.sql` | `ADM.SP_REFRESH_GOLD` | procedure | **Replaces the stub** — refreshes the two GOLD dynamic tables in the pipeline. Deploy into `etl_build/PROCEDURES/`. |
| `VERIFY_GOLD.sql` | — | checks | Row counts, star joins, holiday spot-check, DT health/refresh. |

The two objects you asked for are the **dynamic tables** `DIM_PARTNER` (dimension)
and `FCT_WHOLESALE_USAGE` (fact). `DIM_DATE` / `DIM_TIME` are regular tables because
a calendar / clock is static reference data — a Dynamic Table needs a changing base
query to be worthwhile.

Naming follows the repo's Gold convention `DIM_` / `FCT_` (per the TBAY-191
`Tbaytel_Object_Naming_Conventions` doc).

## Deploy order

```
-- one-time prerequisites (already in your repo):
--   etl_build/SHARED_SIM/SHARE_SIM_DB.sql        (creates the share tables + grants)
--   etl_build/SEED/seed_config_dev.sql            (registers WHOLESALE in config)

1. SHARE_SIM_DB_DEMO_DATA.sql        -- richer demo data into the share source
2. run the pipeline for WHOLESALE    -- lands BRONZE -> SILVER, e.g.:
     CALL ADM.SP_CREATE_PPN('gold-demo');
     SET PPN = (SELECT $1:ppn_id::NUMBER FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
     CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'WHOLESALE', 'PARTNER_ACCOUNT');
     CALL ADM.SP_RUN_TABLE_LOAD($PPN, 'WHOLESALE', 'WHOLESALE_USAGE');
3. DIM_DATE.sql                      -- conformed calendar
4. DIM_TIME.sql                      -- conformed clock
5. DIM_PARTNER.sql                   -- dimension DT (build before the fact)
6. FCT_WHOLESALE_USAGE.sql           -- fact DT (references DIM_PARTNER)
7. SP_REFRESH_GOLD.sql               -- redeploy the real refresh proc
8. VERIFY_GOLD.sql                   -- sanity checks
```

`DIM_PARTNER` must exist before `FCT_WHOLESALE_USAGE` (the fact reads it).

## Refresh model

- `DIM_PARTNER` → `TARGET_LAG = DOWNSTREAM`: refreshes only as needed by the fact.
- `FCT_WHOLESALE_USAGE` → `TARGET_LAG = '1 hour'`: Snowflake keeps it within an hour
  of SILVER and drives the dimension refresh in dependency order.
- **Pipeline-driven:** `ADM.SP_REFRESH_GOLD(ppn_id)` (called by `SP_FINALIZE_RUN`
  after the gate PASSes) now issues `ALTER DYNAMIC TABLE ... REFRESH` on
  `DIM_PARTNER` then `FCT_WHOLESALE_USAGE` — so a run refreshes GOLD on demand,
  independent of the lag clock. `DIM_DATE` / `DIM_TIME` are static — not refreshed.

## SP_REFRESH_GOLD wiring

Replaces the old no-op stub at `etl_build/PROCEDURES/SP_REFRESH_GOLD.sql`.
Same contract `SP_FINALIZE_RUN` already expects: returns `status = 'SUCCESS' | 'ERROR'`
(+ `message` on failure) and does **not** raise — a failed refresh makes
`SP_FINALIZE_RUN` close the run `ERROR` and re-raise, exactly like the loaders.
To add another GOLD dynamic table, copy a refresh block (dimensions before facts).

## Warehouse

Dynamic tables refresh on **`DEV_DATA_LOADER_WH`** — the same warehouse the ETL
pipeline loads with, so GOLD refresh compute is attributed to the load workload.
The owning role (`DEV_SYSADMIN` here) needs `USAGE` on it:

```sql
use role securityadmin;
grant usage on warehouse dev_data_loader_wh to role dev_sysadmin;
```

## Holidays in DIM_DATE

Ontario statutory + federal, **computed in SQL** (no CSV): fixed dates,
nth-weekday-of-month (Family Day, Labour Day, Thanksgiving, Victoria Day) and
Good Friday via the Easter computus. Verified against known dates 2000–2100.
The Croatian `DIM_DATE_STU.csv` is not used here.
