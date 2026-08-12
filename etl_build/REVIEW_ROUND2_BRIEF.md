# Review round 2 — brief for the reviewer

Thanks for the previous review. I applied most of it. Below is what changed, what I
deliberately did not do (and why), and where I'd like you to focus this time.

Please review the attached procedures **as they now stand** — several have changed materially,
so please don't assume the previous versions.

---

## Important correction to the previous round

Your Salesforce/Openflow section was based on an assumption that does not hold for this project:
**we are not using Openflow.** Salesforce is ingested via the **ADF native connector**
(Bulk API v2, incremental daily) writing Parquet to Blob, exactly like the other file sources.
Openflow was explicitly evaluated and rejected (we did not want a second orchestrator).

So for this project Salesforce is simply another `PARQUET` source. That makes these
recommendations moot: the `OPENFLOW` source subtype, the Openflow freshness/readiness gate,
"Openflow outside PPN orchestration", and the `IsDeleted` handling framed as Openflow-specific.

Two follow-ups I would still value your view on:
1. Is the `PARQUET` / `DATASHARE` split still the right taxonomy given there is no Openflow —
   or is generalizing to `SNOWFLAKE_OBJECT` worthwhile purely for future-proofing?
2. Independently of Openflow: is a configurable `SOURCE_DELETE_COLUMN` (a source-provided
   soft-delete flag) worth adding to SILVER now, or only when a source actually supplies one?

---

## What I implemented from your review

### P0 — gate is now fail-closed against never-invoked tables
Instead of a separate `PPN_TABLE_PLAN` table, I freeze the plan **inside `PPN_PROCESS`**:

- New `ADM.SP_PREPARE_RUN(PPN_ID, P_INCLUDE_DQ)` seeds one **`PENDING`** row per active
  `ETL_TABLES` entry at run start.
- `PENDING` is not in (`SUCCESS`,`SKIP`), so the **existing** gate rule fails automatically —
  no gate logic change was needed.
- Added `PPN_PROCESS.LOAD_ORDER` so the frozen plan is self-sufficient: **ADF now iterates
  `PPN_PROCESS` (ORDER BY LOAD_ORDER), not live `ETL_TABLES`**, so mid-run config edits cannot
  change what the PPN was supposed to process.
- The DQ marker row (`_RUN_`/`_DQ_`) is opt-in via `P_INCLUDE_DQ`, currently FALSE, because
  `SP_RUN_DQ_CHECKS` does not exist yet (seeding it now would fail every run). It flips to TRUE
  when the DQ tool is wired, and the gate then enforces it with no code change.
- `SP_GATE_CHECK` now also reports `entries_pending` and says explicitly when the plan was never
  frozen.

**Question:** is seeding `PPN_PROCESS` with `PENDING` an acceptable substitute for a separate
plan table, or do you see a concrete failure mode that a dedicated plan table would catch?

### P0 — false-success path closed
`SP_RUN_TABLE_LOAD` now sets `PPN_PROCESS = ERROR` **before every** child-error return
(LANDING / CHECK / HIST / SILVER), so the `SP_CHECK_DATA_CHANGE` case you found can no longer
leave the table at landing's `SUCCESS`.

### P0 — state ownership moved to the wrapper
`PPN_PROCESS` is now written **only** by `SP_RUN_TABLE_LOAD`:

```
SP_RUN_TABLE_LOAD   -> owns PPN_PROCESS  (RUNNING -> SKIP | ERROR | SUCCESS/TABLE_COMPLETE)
  SP_LOAD_FILE_TO_BRONZE    -> PPN_LOG only
  SP_LOAD_SHARE_TO_BRONZE   -> PPN_LOG only
  SP_CHECK_DATA_CHANGE      -> PPN_LOG only
  SP_LOAD_BRONZE_TO_HIST    -> PPN_LOG only
  SP_LOAD_BRONZE_TO_SILVER  -> PPN_LOG only
```
All `SP_SET_PROCESS_STATE` calls were removed from the child procedures. The wrapper rolls up
counts from the child return values (`rows_loaded` → `ROWS_EXTRACTED`, `rows_merged` →
`ROWS_INSERTED`, `rows_soft_deleted` → `ROWS_DELETED`). This also fixes the stale `END_TS`
behaviour you noted.

**Known trade-off:** calling a child procedure standalone no longer records table state (it
loads and logs only). We accept this — `SP_RUN_TABLE_LOAD` is the supported entry point.

### P1 — transactions
`SP_LOAD_BRONZE_TO_HIST` (`DELETE` + `INSERT` per PPN) and `SP_LOAD_BRONZE_TO_SILVER`
(`MERGE` + soft-delete sweep) are each wrapped in an explicit
`EXECUTE IMMEDIATE 'BEGIN TRANSACTION' … 'COMMIT'`, with a guarded `ROLLBACK` in the exception
handler (tracked by a `v_txn_open` flag). Structure-sync **DDL runs before** the transaction opens,
per your note.

**Question:** please sanity-check the transaction handling — especially that `EXECUTE IMMEDIATE
'BEGIN TRANSACTION'` (rather than a bare `BEGIN`) is the right way to avoid ambiguity with
Snowflake Scripting block syntax, and that rollback-in-handler is correct here.

### P1 — rerun state semantics
`SP_SET_PROCESS_STATE` now treats `P_STATUS = 'RUNNING'` as a fresh attempt: it clears
`ERROR_MSG`, `END_TS` and the row-count columns and re-stamps `START_TS`. Other statuses keep the
previous COALESCE (non-null overwrites, null preserves).

### P1 — environment portability
Removed all hard-coded `DEV_DB.INFORMATION_SCHEMA` references (they now resolve against the
current database) in `SP_SYNC_TABLE_STRUCTURE`, `SP_CHECK_DATA_CHANGE`,
`SP_LOAD_BRONZE_TO_HIST`, `SP_LOAD_BRONZE_TO_SILVER`.

### P1 — hash construction
`PK_HK` / `ROW_HK` changed from `MD5(COALESCE(TO_VARCHAR(col),'') || '|~|' || …)` to:

```sql
MD5(TO_JSON(ARRAY_CONSTRUCT(col1, col2, …)))
```
NULL now stays distinct from empty string, and the array removes delimiter ambiguity.

**Question:** is JSON-serializing the column array a sound approach here, or would you prefer a
different NULL-safe serialization? Any concern about type-rendering stability across Snowflake
versions (e.g. numeric/timestamp formatting inside `TO_JSON`)?

---

## What I deliberately did NOT do

| Your recommendation | Decision | Reason |
|---|---|---|
| PPN-specific BRONZE work tables | **Not done** | Single daily pipeline, no overlapping runs for the same table. Taking your simpler alternative: prevent concurrent loads of the same table in ADF. Revisit if real concurrency appears. |
| Fail hard on duplicate PKs | **Not done** | A hard fail could break loads on messy-but-acceptable source data. Considering log/warn or a configurable `DEDUPE_ORDER_COLUMN` instead. |
| Exact `MINUS` verification after `HASH_AGG` | **Not done** | Volumes are small (35 GB initial, 8–13 GB/yr); we accept the collision risk consciously. |
| `SNAPSHOT_PPN_ID` lineage for skipped runs | **Not done (yet)** | Agreed it's the tidier semantic; parked as a nice-to-have. |
| `EXECUTE AS OWNER` | **Not done (yet)** | Agreed it's the better security boundary, but it interacts with database/schema context resolution, so we want to decide it deliberately alongside the multi-environment rollout. |
| PPN-scoped Parquet folders | **Planned, not implemented** | Mostly an ADF-side change; we intend to adopt `…/<TABLE>/<PPN_ID>/`. |

We are deliberately keeping the framework lean — this is a small platform (35 GB initial,
8–13 GB/yr growth), and we would rather not carry machinery for scenarios we do not yet run.

---

## Context you may not have had

- **Scale:** ~35 GB initial load, 8–13 GB/yr growth. Daily batch. Not high-concurrency.
- **Layers:** `BRONZE` is the active landing layer. `RAW` exists but is **reserved for a future
  semi-structured/JSON pattern** (land in RAW → transform to BRONZE); it is unused today.
- **BRONZE is rebuilt every run** (`CREATE OR REPLACE` for files, CTAS for shares), so it is
  self-healing for schema drift; only the persistent layers (`BRONZE_HIST`, `SILVER`) need
  `SP_SYNC_TABLE_STRUCTURE`.
- **Still stubbed/pending by design:** `SP_RUN_DQ_CHECKS` (waiting on an external DQ tool) and
  `SP_REFRESH_GOLD` (waiting on the GOLD modelling decision: Dynamic Tables vs dbt).
- **Status:** the full run — `SP_CREATE_PPN` → `SP_VALIDATE_CONFIG` → `SP_PREPARE_RUN` →
  `SP_RUN_TABLE_LOAD` per table → `SP_FINALIZE_RUN` (gate → GOLD stub → close) — executes
  green on DEV.

---

## Current run flow

```
ADF
 ├─ SP_CREATE_PPN(RUN_ID)            -> PPN_ID (RUN_ID stored once on ADM.PPN)
 ├─ SP_VALIDATE_CONFIG(PPN_ID)
 ├─ SP_PREPARE_RUN(PPN_ID)           -> freezes plan: PPN_PROCESS rows = PENDING
 ├─ read plan from PPN_PROCESS ORDER BY LOAD_ORDER
 ├─ per table (ForEach):
 │     (PARQUET only) ADF Copy: source -> Parquet in Blob
 │     SP_RUN_TABLE_LOAD(PPN_ID, SOURCE_ID, TABLE)
 │         landing (file|share) -> check-change -> [identical? SKIP] -> HIST -> SILVER
 ├─ SP_RUN_DQ_CHECKS(PPN_ID)         -- pending (external tool)
 └─ SP_FINALIZE_RUN(PPN_ID)          -> gate -> GOLD (stub) -> close; raises if the run failed
```
Note: only `PPN_ID` is passed between procedures; `RUN_ID` is resolved from `ADM.PPN` by
`SP_LOG_STEP` and stamped on every log row.

---

## What I'd like from this round

1. **Verify the fixes actually close the holes** you identified — particularly the gate
   (frozen plan) and the state-ownership refactor. Did I miss a path where `PPN_PROCESS` can
   still misrepresent reality?
2. **Correctness review of the new/changed code**: `SP_PREPARE_RUN`, `SP_RUN_TABLE_LOAD`,
   `SP_SET_PROCESS_STATE`, the two transactions, and the new hash expressions.
3. **Any remaining correctness or robustness issue** at our stated scale — please distinguish
   "this is a real bug" from "this would matter at larger scale / higher concurrency", so we can
   keep deferring the latter deliberately.
4. Views on the two open questions above (source taxonomy without Openflow; whether to add a
   configurable source-delete column now).

Please be direct about anything you think is wrong or risky — I'd rather hear it now.
