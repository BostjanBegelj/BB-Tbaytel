# Tbaytel Snowflake — ETL / Data Pipeline

**Client:** Tbaytel  **Prepared by:** Blend  **Document type:** Data Pipeline Design & Build (as-built)
**Version:** 0.1 (Draft for internal review)  **Date:** 19 August 2026
**Status:** Prepared and reviewed. The procedures are authored and tested end-to-end against a development database; the Tbaytel account is not yet provisioned. The Gold refresh is implemented — Gold is materialised as dynamic tables refreshed only by the pipeline (see section 8.3). One component remains stubbed pending the billable account: the real antFarm data-quality service.

---

## 1. Purpose and scope

This document describes the data-loading framework that moves Tbaytel's data from source systems through the medallion layers to the business-facing Gold layer. It covers the orchestration model, the configuration that drives it, the run-control and logging model, each processing stage, the data-quality gate, and error handling. It is standalone and does not assume the architecture or security documents.

The framework is **metadata-driven** ("config over code"): a new table to load is a configuration row, not new code. **Azure Data Factory (ADF) is the single orchestrator**; every in-database step is a Snowflake stored procedure in the environment's `ADM` schema.

---

## 2. Design principles

- **One orchestrator, one call per table.** ADF calls a single wrapper procedure per table; the chain of landing → history → cleanse runs inside Snowflake.
- **Config over code.** Sources and tables are registered in configuration tables; behaviour (load type, keys, watermark, target) is data.
- **Fail-closed quality gate.** Gold is refreshed only if every dispatched table succeeded *and* data quality passes. Anything unclear blocks Gold.
- **Gold is published only by the pipeline.** Gold is materialised as dynamic tables with automatic scheduling disabled, so it changes only when a gated run refreshes it — never on a background clock that could publish half-written or un-gated Silver.
- **State separate from logs.** One authoritative per-table state table drives the gate and reruns; a separate append-only log holds step-level forensics.
- **Idempotent and re-runnable.** Re-running the same batch never duplicates data.
- **The warehouse never fixes source data.** Silver mirrors the source; a duplicate key is a source defect that fails the table, not something the pipeline silently repairs.

---

## 3. The medallion layers

| Layer (schema) | What it holds |
|---|---|
| `BRONZE` | Raw ingested data exactly as loaded from the source extract, per batch, plus lineage columns |
| `BRONZE_HIST` | Append-only history of every Bronze load — the replay and lineage source |
| `SILVER` | Deduplicated, keyed, change-tracked business data (hash keys, soft-delete flags) |
| `GOLD` / `GOLD_{domain}` | Conformed, business-facing dimensions and facts (materialised as dynamic tables, refreshed only by the pipeline — see section 8.3) plus per-domain marts |
| `RAW` | Reserved for a future pattern (semi-structured/JSON landed before Bronze); not used yet |
| `ADM` | Configuration, run state and logging for the framework itself |

The default landing layer is `BRONZE`. `RAW` is reserved and accommodated per-table (a table can target `RAW` and add a `RAW → BRONZE` step later) but is not used in the current design.

---

## 4. Configuration (`ADM`, `ETL_` prefix)

Two configuration tables drive every load.

### 4.1 `ETL_SOURCES` — source-system registry

One row per source system. `SOURCE_TYPE` selects the load pattern:

- **`FILE`** — files landed in a stage, loaded via `SP_LOAD_FILE_TO_BRONZE`. Format-agnostic — the `FILE_FORMAT` decides Parquet / CSV / JSON.
- **`DATABASE`** — read directly from another Snowflake database (an inbound data share or an ordinary database) via `SP_LOAD_DATABASE_TO_BRONZE`.

Key columns: `SOURCE_ID` (PK), `SOURCE_NAME`, `SOURCE_TYPE`, `STAGE_NAME` (FILE), `SOURCE_DB` (DATABASE), `FILE_FORMAT` (FILE), `ACTIVE_FLAG`.

### 4.2 `ETL_TABLES` — per-table load control

One row per table. Adding a table to the pipeline is inserting a row here. Key columns:

| Column | Meaning |
|---|---|
| `SOURCE_ID`, `TABLE_NAME` | PK; `SOURCE_ID` is an FK to `ETL_SOURCES` |
| `LOAD_TYPE` | `FULL` \| `INIT` \| `INCR` \| `PARTITION` \| `WATERMARK` (see section 4.3) |
| `PK_COLUMNS` | Business primary key (required for `INCR` and `WATERMARK`) |
| `SOURCE_OBJECT` | DATABASE: `<schema>.<table>` inside `SOURCE_DB` |
| `FILE_PATTERN` | FILE: regex matching the file(s) for one load |
| `STAGE_SUBPATH` | FILE: override for the stage path; NULL follows the agreed ADF contract `<stage>/{source}/{table}/{ppn_id}/` |
| `WATERMARK_COLUMN` / `_TYPE` / `_OVERLAP` | Watermark extraction control |
| `PARTITION_COLUMN` | PARTITION load: identifies partitions to replace |
| `TARGET_SCHEMA` | Landing layer, default `BRONZE` |
| `LOAD_ORDER` | Ascending execution order within a run |
| `ALLOW_EMPTY` | FULL/INIT only: TRUE permits a zero-row snapshot; FALSE fails the table |
| `ACTIVE_FLAG` | FALSE disables the table |

Sample DEV configuration lives in `SEED/seed_config_dev.sql`; a runnable catalogue of every valid variant (and the combinations validation rejects) is in `SEED/config_examples.sql`.

### 4.3 Load types

| Load type | Extraction | How Silver is applied |
|---|---|---|
| `FULL` / `INIT` | Complete snapshot | MERGE + soft-delete of keys missing from the snapshot |
| `INCR` | A delta produced elsewhere (ADF) | MERGE only — deletes cannot be inferred |
| `PARTITION` | Selected partitions | MERGE + soft-delete scoped to those partitions |
| `WATERMARK` | Delta bounded by a high-water-mark column | MERGE only; for DATABASE sources the loader adds the `WHERE col > bound` itself; for FILE sources it is advisory (ADF extracts, Snowflake still records the max reached) |

Snowflake is the single **watermark registry** for both source patterns — the value reached by each load is stored on `PPN_PROCESS.WATERMARK_VALUE`, so ADF can read back the next lower bound. A `NUMBER` (id) watermark detects inserts only; a modified-timestamp is used to catch updates.

---

## 5. Run-control model (`ADM`, `PPN_` prefix)

A "PPN" is a population/batch — one pipeline run. Two correlation keys tie ADF and Snowflake together:

- **`RUN_ID`** — ADF's pipeline run id, created by ADF, stored once on the run header and stamped on every log row.
- **`PPN_ID`** — the batch id from a Snowflake sequence, returned to ADF and stamped on every data, state and log row.

| Table | Role |
|---|---|
| `PPN` | Run header — one row per run (`RUNNING` → `SUCCESS`/`ERROR`), holds `RUN_ID`, timestamps |
| `PPN_PROCESS` | **Authoritative** per-run-per-table state (`RUNNING` → `SUCCESS`/`SKIP`/`ERROR`), row counts, watermark, error message. Drives the gate and reruns |
| `PPN_LOG` | Append-only step log (forensics) — one row per step, with an `ERROR`-first structured `DETAIL_JSON` |

The separation matters: `PPN_PROCESS` is the single source of truth for state and is written **only** by the table wrapper, so a partially-processed table can never look complete; `PPN_LOG` is written by every procedure and is for diagnosis.

---

## 6. End-to-end flow

```
                                    ┌─────────────── ADF (orchestrator) ───────────────┐
 RUN START   → SP_CREATE_PPN → SP_VALIDATE_CONFIG → read table list (active, by LOAD_ORDER)
 PER TABLE   → SP_RUN_TABLE_LOAD(PPN_ID, SOURCE_ID, TABLE)
                    └─ land (FILE|DATABASE) → check-change → [identical? SKIP] → HIST → SILVER
 RUN END     → SP_FINALIZE_RUN(PPN_ID, expected_count)
                    └─ SP_GATE_CHECK (tables OK? + antFarm DQ) → PASS: SP_REFRESH_GOLD → close SUCCESS
                                                                 FAIL: skip GOLD → close ERROR + raise
```

Ownership split: ADF triggers the run, extracts FILE sources to Blob, iterates the config, calls the procedures in order and handles retry/alert; Snowflake does all in-database work — landing, history, cleanse/merge, DQ, the gate, Gold, run state and logging.

### 6.1 Steps

1. **`SP_CREATE_PPN(RUN_ID)`** — allocates `PPN_ID` + timestamp, writes the run header as `RUNNING`, returns the id to ADF.
2. **`SP_VALIDATE_CONFIG(PPN_ID)`** — pre-flight validation of the active configuration (active tables joined to active sources, checked once as a whole); raises on invalid config.
3. **ADF reads the table list** — active `ETL_TABLES` joined to active `ETL_SOURCES`, ordered by `LOAD_ORDER`. A run may legitimately be a **subset** of all tables (schedules vary). ADF keeps the item count as the completeness proof for step 5.
4. **`SP_RUN_TABLE_LOAD(PPN_ID, SOURCE_ID, TABLE)`** per table — the wrapper (see section 7).
5. **`SP_FINALIZE_RUN(PPN_ID, EXPECTED_COUNT)`** — the gate, Gold and close (see section 8). `EXPECTED_COUNT` is ADF's step-3 item count.
6. **`SP_CLOSE_PPN(PPN_ID, ERROR)`** — used only for early aborts (a validate or loop failure before finalize).

---

## 7. The per-table wrapper (`SP_RUN_TABLE_LOAD`)

ADF makes one call per table; the wrapper chains the in-database stages and returns a single per-table result (`SUCCESS` / `SKIPPED` / `ERROR`):

1. **Land to Bronze** — dispatches by source type to `SP_LOAD_FILE_TO_BRONZE` or `SP_LOAD_DATABASE_TO_BRONZE`.
2. **Empty-snapshot guard** — a FULL/INIT load of zero rows fails the table unless `ALLOW_EMPTY` is set (a silent empty snapshot would soft-delete all of Silver).
3. **Change detection** (`SP_CHECK_DATA_CHANGE`) — compares this Bronze load to the last Bronze history snapshot (row count + hash). If identical, the table is marked `SKIP` and history/Silver are skipped.
4. **Bronze → history** (`SP_LOAD_BRONZE_TO_HIST`) — appends this batch's Bronze rows to `BRONZE_HIST` (idempotent per `PPN_ID`).
5. **Bronze → Silver** (`SP_LOAD_BRONZE_TO_SILVER`) — the cleanse/merge (see section 7.1).

**Failure isolation:** the wrapper does **not** raise on a table failure — the child procedures have already set that table's `PPN_PROCESS` state to `ERROR`, and the wrapper returns an `ERROR` object. One bad table therefore does not abort the run; ADF continues the loop, and the fail-closed gate blocks Gold at the end.

### 7.1 Bronze → Silver detail

Silver is metadata-driven. Business columns are all Bronze columns except the lineage/technical ones. Two hashes are computed per row — a primary-key hash (`PK_HK`, from `PK_COLUMNS`, or all business columns when there is no PK) and a full-row hash (`ROW_HK`) used as a change indicator. The load `MERGE`s on `PK_HK`, updating only when `ROW_HK` differs and un-deleting rows that reappear. FULL/INIT loads additionally soft-delete keys absent from the snapshot; PARTITION scopes the soft-delete to the loaded partitions; INCR/WATERMARK merge only (a bounded delta cannot prove a delete).

**Duplicate-key policy:** before writing, the loader checks for duplicate `PK_HK` values in Bronze. On any duplicate it **fails the table** with the offending key count and a sample — the warehouse does not deduplicate. Duplicates are a source defect, fixed at source and re-extracted, because Silver is meant to mirror the source faithfully.

### 7.2 Schema drift

`SP_SYNC_TABLE_STRUCTURE` reconciles the persistent layers (history, Silver) to the source shape before writing: it adds source columns missing in the target, widens columns where Snowflake permits (longer VARCHAR, higher NUMBER precision at equal scale), and **fails safe** on incompatible changes (different base type, changed scale, changed date/time precision) rather than risk silent data loss. Every structural change is logged. Bronze self-heals because it is rebuilt each run.

### 7.3 Recovery and reprocessing (`SP_REPLAY_FROM_HIST`)

Bronze is transient — each load replaces it, so it only ever holds the current batch. Silver, by contrast, is *stateful*: it is built one batch at a time, accumulating change detection, soft-delete flags and load timestamps. The only durable, replayable record of the full history is therefore `BRONZE_HIST`. `SP_REPLAY_FROM_HIST` is the recovery / reprocessing procedure that rebuilds `SILVER.<table>` from that history.

It reuses the production cleanse logic unchanged: for each stored batch (`PPN_ID`) in ascending order it stages that snapshot back into Bronze and calls `SP_LOAD_BRONZE_TO_SILVER` for it, preserving the original `PPN_ID` so Silver's lineage and each snapshot's log rows stay attached to the batch they belong to. Replaying batch-by-batch in order is essential — collapsing all history into one merge would break full-load delete detection and pick arbitrary row versions. The replay operation opens its own run (`PPN_ID`), so it is auditable end to end (a plan row plus one step row per replayed batch).

It is an **operator-run, out-of-band** procedure — deliberately not part of the ADF nightly flow — for:

- a Silver transformation or hash-formula change: rebuild the whole history under the new rules (a normal run would only re-apply the latest batch, silently losing history and mis-detecting deletes);
- corruption, an accidental drop or a bad manual change discovered outside the Silver Time Travel window: Bronze history is the long-lived truth, and unlike Time Travel it re-derives Silver with the **current** logic rather than restoring the same possibly-defective output;
- a schema change to apply across all history, seeding Silver for a table previously kept only in history, or a point-in-time / environment rebuild.

Two modes: a **full rebuild** (default) drops Silver and replays the whole history; an **in-place replay** of a bounded batch window (`P_FROM_PPN` / `P_TO_PPN`) against an existing Silver, for resume/backfill. A point-in-time rebuild "as of batch N" uses the upper bound alone. Guards keep it safe to run: an empty window leaves Silver untouched (it never drops-then-leaves-empty), and a table without exactly one active configuration row is refused — it reads configuration exactly as the load path does. It is **not atomic across batches** (DDL commits per step and each snapshot applies atomically inside the Silver load), so a mid-replay failure leaves Silver rebuilt through the last good batch and the procedure is simply re-run.

---

## 8. The pre-Gold quality gate

### 8.1 `SP_GATE_CHECK` — one place, two verdicts

The gate answers two questions and refreshes Gold only if both hold: **did every dispatched table load, and does the data pass data quality.** It is fail-closed — anything unclear is a FAIL.

**Table completeness.** The gate reads `PPN_PROCESS` for the batch and FAILs if: no table reported at all; any entry is outside `SUCCESS`/`SKIP` (an `ERROR`, a left-over `RUNNING` from a crashed call, or an unknown/NULL status); or fewer tables reported than ADF dispatched (`P_EXPECTED_COUNT`). The last check is why ADF passes its ForEach item count — because rows are created on first touch, the gate alone can only prove "nothing that ran failed", so ADF supplies the count of what it intended to run. A count suffices, since each dispatched table upserts exactly one row.

**Data quality.** If the table checks pass, the gate invokes antFarm DQ itself (`SP_DQ_EXECUTE`, group `DQ_SILVER`) and judges the result:

| DQ result | Verdict | Gate |
|---|---|---|
| Technical status ≠ SUCCESS | FAIL | Gold blocked |
| No findings | PASS | Gold refreshed |
| Max severity ≥ 100 (blocking) | FAIL | Gold blocked |
| Max severity < 100 | WARN | Gold refreshed, finding reported |
| Findings with unreadable severity | FAIL | unknown never means success |
| Table checks already failed | SKIPPED | Gold already blocked — no antFarm run spent |

The DQ group, the blocking severity (100, matching TBAY-267 "critical = blocking") and the error-row sample size are fixed constants inside the gate, so the ADF contract does not change. DQ is skipped when the table checks already failed — Gold is blocked either way, so there is no reason to spend an antFarm execution and up to an hour of warehouse polling on a run that is already dead.

**Design note:** the gate is intentionally the single invoker *and* judge of DQ (an earlier design had a separate DQ procedure whose verdict the gate re-read from a state row — two places to keep in step). The gate writes nothing itself; `SP_FINALIZE_RUN` logs the object it returns, DQ detail included.

**Cost note:** DQ polling holds a warehouse for the duration, so the ADF activity timeout on finalize must exceed the DQ timeout (default 3600s).

### 8.2 `SP_FINALIZE_RUN` — gate, Gold, close

ADF calls this once after the table loads. It runs the gate; on PASS it refreshes Gold (`SP_REFRESH_GOLD`) and closes the run `SUCCESS`; on FAIL (or a Gold error) it closes the run `ERROR` and re-raises so the ADF activity fails and alerting fires (the run is durably closed `ERROR` first). The whole gate object, DQ detail included, is written to `PPN_LOG`.

### 8.3 The Gold layer and refresh (`SP_REFRESH_GOLD`)

Gold is the single **publish point** of the platform, and it is deliberately **pipeline-only**: it changes only when a gated run reaches this step.

**How Gold is materialised.** The business-facing star schema is built as Snowflake **dynamic tables** over Silver — for example a partner dimension (`DIM_PARTNER`, from `SILVER.PARTNER_ACCOUNT`, with a hash surrogate key and an "unknown" member) and a usage fact (`FCT_WHOLESALE_USAGE`, from `SILVER.WHOLESALE_USAGE`, with foreign keys to the dimension and to the date dimension). Conformed calendar dimensions (`DIM_DATE`, `DIM_TIME`) are plain static reference tables, since a calendar/clock has no changing base query. Object naming follows the repository's Gold convention `DIM_` / `FCT_` (the TBAY-191 object-naming standard).

**Why pipeline-only, not auto-refresh.** Every Gold dynamic table is created with **`SCHEDULER = DISABLE`**, which removes it from Snowflake's automatic (target-lag) refresh. This is deliberate: the loaders write Silver table-by-table and the DQ gate runs *after* Silver, so a time-lagged background refresh could publish a half-written or un-gated Silver state into Gold. With automatic scheduling off, Gold moves only when `SP_REFRESH_GOLD` runs — i.e. only after the gate has passed. (`TARGET_LAG` cannot be set together with `SCHEDULER = DISABLE`, so it is omitted; `INITIALIZE = ON_CREATE` still populates each table once at deploy.)

**What `SP_REFRESH_GOLD` does.** It (1) **enumerates** the Gold dynamic tables from `INFORMATION_SCHEMA.DYNAMIC_TABLES` for the current database and the `GOLD` schema — nothing is hardcoded, and the static `DIM_DATE` / `DIM_TIME` are excluded automatically because they are not dynamic tables; (2) **refreshes** them in one combined `ALTER DYNAMIC TABLE a, b, c REFRESH`, which Snowflake evaluates at a common data timestamp in dependency order (dimension before fact), so list order does not matter; and (3) **verifies** via `INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY` that no Gold table's latest refresh ended `FAILED` / `CANCELLED` / `UPSTREAM_FAILED` (a combined refresh is not all-or-nothing). It keeps the same child-error contract as the loaders — returns `SUCCESS` / `ERROR` (with a message) and does not raise, so a failed refresh makes `SP_FINALIZE_RUN` close the run `ERROR` and re-raise. Adding a new Gold dynamic table needs no change to the procedure, as long as it is created with `SCHEDULER = DISABLE`.

The Gold dynamic tables refresh on the same warehouse the pipeline loads with (`{ENV}_DATA_LOADER_WH`), so Gold-refresh compute is attributed to the load workload.

**Refresh privilege.** Because `SP_REFRESH_GOLD` runs `EXECUTE AS CALLER` and the pipeline calls it as `{ENV}_DATA_LOADER` (ADF's role), that role issues `ALTER DYNAMIC TABLE … REFRESH`, which requires **`OPERATE`** on each Gold dynamic table. This is granted by the access-role framework: `CREATE_SCHEMA` grants `OPERATE` on all present/future dynamic tables to the schema's `_RW_AR` role (and `SELECT` / `MONITOR` to `_RO_AR`), and `{ENV}_DATA_LOADER` holds `FULL_AR` on `GOLD`, which inherits `RW_AR`. (Dynamic tables are a distinct object type, not covered by the schema's `ON ALL/FUTURE TABLES` grants, so they are granted explicitly.) Schemas created before this grant existed are backfilled by `Account Setup/migrations/2026-08-19_dynamic_table_grants_backfill.sql`, run once per environment.

**Domain marts — views over Gold.** The per-domain marts (`GOLD_{domain}`) are exposed as **views over the shared `GOLD` objects**, subset and shaped per domain. A domain reporter reads its mart through Snowflake's **ownership chain**: it has `SELECT` on the view (via the mart's `{schema}_RO_AR`, granted automatically to future views) but no privilege on `GOLD`, and the query succeeds only because the view and the `GOLD` objects share one owner. That owner is **`{ENV}_SYSADMIN`** — it owns the `GOLD` dynamic tables, so the `GOLD_{domain}` **views must also be created as `{ENV}_SYSADMIN`** for the chain to hold. Tag-driven masking still applies through the views (it is evaluated on the querying role, not the view owner). These mart views are not built yet — only the sample star's `GOLD` base objects exist.

---

## 9. Data quality — antFarm

Data quality is provided by **antFarm**, In516ht's DQ tooling, deployed account-wide under `PLATFORM_DB.ANTFARM` (one instance serving all environments) with per-environment DQ procedures in each `{ENV}_DB.ADM`:

- **`SP_DQ_EXECUTE`** — refreshes antFarm metadata, runs a DQ group, polls to completion, and (optionally) returns the result or sends notifications. It separates **technical execution status** from **DQ findings**: a technically successful run can still contain findings, and `status = FAILED` is reserved for genuine technical failures (API failure, missing result, email transport failure).
- **`SP_DQ_RESULT`** — reads the findings for a run from `PLATFORM_DB.ANTFARM.DQ_LOG`, distinguishing a clean run, a run with findings, and an unknown run; caps the error-row sample carried back.
- **`SP_SEND_NOTIFICATION`** — generic email sender over `EMAIL_INTEGRATION` (used by DQ EMAIL mode, no DQ-specific logic).

`SP_DQ_EXECUTE` supports three output modes: execute only, execute + return JSON (used by the gate), and execute + email. Blocking-severity interpretation is left to the caller — the pre-Gold gate applies severity 100 as its threshold; ADF can apply its own for other groups.

**Status:** the real antFarm runs on Snowpark Container Services, which requires the billed account (compute pools are unavailable on trial). Until then a drop-in **stub** (`ANTFARM_DUMMY_SETUP.sql`) reproduces the antFarm procedure signatures and a set of demo DQ groups — including a clean `DQ_SILVER` so a clean ETL run passes the gate, and deliberately failing groups so the technical-failure and unknown-group paths are exercised before production. The stub is removed (`ANTFARM_DUMMY_CLEANUP.sql`) before real antFarm is deployed. The planned SPCS objects, roles and open items (DNS for Private Link, warehouse choice, secrets management) are catalogued in `Account Setup/antfarm/README.md`.

---

## 10. Logging and error handling

- **Error-first logging.** Every step writes a `PPN_LOG` row; on error the flat message is `ERROR [<proc>/<phase>]: <root cause>` and the structured `DETAIL_JSON` puts the `ERROR` block (origin procedure, phase, real error, failing SQL) first, so the cause is visible at a glance rather than buried in a wrapper.
- **State on failure.** A failing child sets `PPN_PROCESS` to `ERROR` and returns an error object; run-control procedures re-raise so the ADF activity fails.
- **Atomic writes.** History (`DELETE`+`INSERT` per batch) and Silver (`MERGE`+soft-delete) each run in one explicit transaction with rollback on failure — Snowflake procedures are not atomic by default. Structure sync/DDL runs before the transaction opens.
- **Idempotency.** Re-running the same `PPN_ID` never duplicates: history is delete-then-insert per batch; Silver is a MERGE keyed by `PK_HK`.
- **Named arguments.** All production procedure calls use named arguments, and custom exception codes are kept within Snowflake's user range.

---

## 11. Procedure inventory

| Procedure | Role |
|---|---|
| `SP_CREATE_PPN` | Allocate batch id, open the run header |
| `SP_VALIDATE_CONFIG` | Pre-flight validation of active configuration |
| `SP_RUN_TABLE_LOAD` | Per-table wrapper: land → check → HIST → SILVER |
| `SP_LOAD_FILE_TO_BRONZE` | Load FILE sources (stage + `COPY`) into Bronze |
| `SP_LOAD_DATABASE_TO_BRONZE` | Load DATABASE sources (share/ordinary DB) into Bronze |
| `SP_CHECK_DATA_CHANGE` | Skip-if-identical detection vs last history snapshot |
| `SP_LOAD_BRONZE_TO_HIST` | Append Bronze batch to history |
| `SP_LOAD_BRONZE_TO_SILVER` | Cleanse/merge into Silver (hash keys, soft-delete) |
| `SP_SYNC_TABLE_STRUCTURE` | Reconcile persistent-layer structure to source (add/widen/fail-safe) |
| `SP_GATE_CHECK` | Pre-Gold gate: table completeness + antFarm DQ |
| `SP_REFRESH_GOLD` | Refresh the Gold dynamic tables in one combined refresh, then verify (pipeline publish point) |
| `SP_FINALIZE_RUN` | Gate → Gold → close, one run-level call |
| `SP_REPLAY_FROM_HIST` | Recovery (out-of-band): rebuild Silver from Bronze history by replaying batches in order — section 7.3 |
| `SP_DQ_EXECUTE` / `SP_DQ_RESULT` / `SP_SEND_NOTIFICATION` | antFarm DQ execution, result read, notification |
| `SP_LOG_STEP` / `SP_SET_PROCESS_STATE` / `SP_CLOSE_PPN` | Helpers: step log, state upsert, run close |

Supporting the framework: the shared Parquet file format (`PLATFORM_DB.FILE_FORMATS.FF_PARQUET`) and the Azure external stage (`{ENV}_DB.ADM.EXT_STAGE_AZURE`, currently an internal stand-in for the Azure Blob external stage until the billable account exists).

---

## 12. Build status and pending work

**Built and tested end-to-end on a development database:** the full create → validate → per-table load → finalize path, including both loaders, change detection, history, Silver merge/soft-delete, structure sync, the DQ-aware gate and finalize, and the standalone DQ procedure set (against the antFarm stub). The Gold layer is implemented as pipeline-refreshed dynamic tables via `SP_REFRESH_GOLD`, with a worked star-schema example (a partner dimension and a wholesale-usage fact over the Silver WHOLESALE path) plus the conformed `DIM_DATE` / `DIM_TIME` calendar dimensions.

**Built, DEV validation pending:** the recovery / reprocessing procedure `SP_REPLAY_FROM_HIST` (section 7.3) is authored and ships with a DEV test script (`TESTS/test_replay_from_hist.sql`); it has not yet been executed against the database.

**Retired:** a separate `SP_RUN_DQ_CHECKS` was never built — DQ moved inside the gate so there is one invoker and one judge.

**Pending:**

- **Real antFarm on SPCS** — needs the billed account; currently stubbed.
- **Production Gold model** — the refresh mechanism is built and demonstrated on a sample star; the full Gold model across the business domains (`GOLD`), and the `GOLD_{domain}` mart views over it (owned by `{ENV}_SYSADMIN`), are still to be built.
- **Azure external stage** — the real Blob external stage over Private Link (currently an internal stand-in).
- **PPN-scoped file folders in production** — the agreed ADF path contract `<stage>/{source}/{table}/{ppn_id}/` must be produced by ADF for input immutability.

---

*Prepared by Blend for Tbaytel. Draft for internal review — not for external distribution in this version.*
