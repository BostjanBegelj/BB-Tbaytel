# Tbaytel ETL — Process Lineage (ADF ⇄ Snowflake)

How a run flows end to end: who does what, in what order, and where ADF hands off to
Snowflake stored procedures. **ADF is the single orchestrator**; all in-database work is
Snowflake procedures. Two correlation keys tie it together:

- **RUN_ID** — ADF's pipeline run id. Created by ADF, passed once to `SP_CREATE_PPN`, stored on
  `ADM.PPN`, and stamped on every `ADM.PPN_LOG` row (via lookup) → one join key between ADF
  monitoring and the Snowflake logs.
- **PPN_ID** — the population/batch id from a Snowflake sequence. Returned by `SP_CREATE_PPN`,
  carried by ADF for the whole run, stamped on every data row and every state/log row.

Ownership split:
- **ADF**: trigger, extract source→Blob (Parquet sources only), iterate config, call the
  procedures in order, branch on results, retry/alert.
- **Snowflake**: everything in-database — landing, history, cleanse/merge, DQ, gate, GOLD,
  run state (`PPN_PROCESS`) and logging (`PPN_LOG`).

---

## Sequence

```mermaid
sequenceDiagram
    autonumber
    participant ADF as ADF (orchestrator)
    participant SRC as Source systems
    participant BLOB as ADLS / Blob
    participant SF as Snowflake

    Note over ADF: RUN START (once per run)
    ADF->>ADF: generate RUN_ID
    ADF->>SF: CALL SP_CREATE_PPN(RUN_ID)
    SF-->>ADF: PPN_ID + PPN_TIMESTAMP  (ADM.PPN = RUNNING)
    ADF->>SF: CALL SP_VALIDATE_CONFIG(PPN_ID)
    SF-->>ADF: OK / raises on invalid config
    ADF->>SF: read table list (ETL_TABLES + ETL_SOURCES, both ACTIVE, ORDER BY LOAD_ORDER)
    SF-->>ADF: table list for THIS PPN (may be a subset — schedules vary)
    Note over ADF: ADF owns the list and its COUNT<br/>(passed to finalize as the completeness proof)

    Note over ADF,SF: PER TABLE (ForEach, by LOAD_ORDER)
    opt SOURCE_TYPE = FILE
        ADF->>SRC: extract table (Copy activity)
        SRC-->>BLOB: write Parquet to Bronze container
    end
    ADF->>SF: CALL SP_RUN_TABLE_LOAD(PPN_ID, SOURCE_ID, TABLE)
    Note over SF: landing (file/share) → check-change →<br/>identical? SKIP : (HIST → SILVER)
    SF-->>ADF: SUCCESS | SKIPPED | ERROR (per table)

    Note over ADF,SF: RUN LEVEL (after all tables)
    ADF->>SF: CALL SP_FINALIZE_RUN(PPN_ID, COUNT(tables dispatched))
    Note over SF: gate = tables OK? + antFarm DQ (DQ_SILVER, blocking sev 100)<br/>PASS: refresh GOLD → close SUCCESS;<br/>FAIL: skip GOLD → close ERROR + re-raise
    SF->>SF: SP_GATE_CHECK → SP_DQ_EXECUTE → antFarm
    alt run OK
        SF-->>ADF: SUCCESS  (ADM.PPN = SUCCESS)
    else run failed
        SF-->>ADF: raises → ADF activity fails + alert  (ADM.PPN = ERROR)
    end
    Note over ADF,SF: early abort (validate/loop error) → ADF calls SP_CLOSE_PPN(ERROR) directly
```

---

## Steps in order

| # | Actor | Action / Procedure | Reads | Writes |
|---|---|---|---|---|
| 1 | ADF | Trigger pipeline; generate `RUN_ID` | — | — |
| 2 | ADF → SF | `SP_CREATE_PPN(RUN_ID)` → returns `PPN_ID`, `PPN_TIMESTAMP` | — | `ADM.PPN` (RUNNING), `PPN_LOG` |
| 3 | ADF → SF | `SP_VALIDATE_CONFIG(PPN_ID)` (pre-flight active config) | `ETL_SOURCES`,`ETL_TABLES` | `PPN_LOG` (raises on invalid) |
| 4 | ADF | Lookup the table list for this run: active `ETL_TABLES` joined to active `ETL_SOURCES`, ordered by `LOAD_ORDER` (a run may legitimately be a **subset** — schedules vary). **ADF keeps the item count** for step 8 | `ETL_SOURCES`,`ETL_TABLES` | — |
| — | | **Per table (ForEach):** | | |
| 5a | ADF → SRC/Blob | *(FILE sources only)* Copy activity: extract source → file(s) in Blob | source | Blob |
| 6 | ADF → SF | `SP_RUN_TABLE_LOAD(PPN_ID, SOURCE_ID, TABLE)` — wraps landing (file/share) → check-change → HIST → SILVER; SKIP if identical | config, `BRONZE`, `BRONZE_HIST` | `BRONZE`/`BRONZE_HIST`/`SILVER`, `PPN_PROCESS`, `PPN_LOG` |
| — | | **Run level (after all tables):** | | |
| 7 | ADF → SF | `SP_FINALIZE_RUN(PPN_ID, EXPECTED_COUNT)` — gate → GOLD (if pass) → close; returns SUCCESS or re-raises. The gate runs antFarm DQ itself (`SP_GATE_CHECK` → `SP_DQ_EXECUTE`, group `DQ_SILVER`, blocking severity 100 — both fixed in the procedure), so there is **no separate DQ activity**. `EXPECTED_COUNT` = the step-4 item count (`@length(...)`), the only completeness proof Snowflake can have. `SP_REFRESH_GOLD` refreshes the GOLD dynamic tables (pipeline-only — see the GOLD-refresh note under Cross-cutting behavior) | `PPN_PROCESS`,`SILVER`,`PLATFORM_DB.ANTFARM.DQ_LOG` | `ADM.PPN` final, `GOLD`/`GOLD_{domain}`, `PPN_LOG` |
| 8 | ADF → SF | `SP_CLOSE_PPN(PPN_ID, ERROR)` — **only for early aborts** (validate/loop failures before finalize) | `ADM.PPN` | `ADM.PPN` final, `PPN_LOG` |
| 9 | ADF | On any failure: one alert; failed activity surfaces in monitoring | — | — |

---

## Orchestration model — WRAPPED (chosen)

ADF makes **one call per table**: `SP_RUN_TABLE_LOAD(PPN_ID, SOURCE_ID, TABLE)`, which chains
landing → check-change → HIST → SILVER inside Snowflake and returns a single per-table result
(`SUCCESS` / `SKIPPED` / `ERROR`). Fewer ADF↔SF round-trips and the skip/branch logic lives in the
proc. ADF still owns the run-level steps (create/validate/config read, DQ, finalize, close) and the
Parquet extract to Blob (5a).

**Failure isolation:** `SP_RUN_TABLE_LOAD` does **not** raise on a table-load failure — it returns
an `ERROR` object and the child procs have already set that table's `PPN_PROCESS` state to `ERROR`.
So one bad table doesn't abort the run; ADF continues the ForEach, and the fail-closed
`SP_GATE_CHECK` blocks GOLD at the end because a table is `ERROR`. (ADF can also inspect the returned
status per table for its own alerting.)

---

## Cross-cutting behavior

- **Skip-if-identical:** step 6 lets a table short-circuit — if this load equals the last
  `BRONZE_HIST` snapshot (count + `HASH_AGG`), HIST + SILVER are skipped and the table is marked
  `SKIP` (still counts as success at the gate).
- **No frozen run plan.** There is no pre-seeding step: a run may process a varying subset of
  `ETL_TABLES`, so a frozen plan would either be wrong (freezing "all active tables" when tonight's
  schedule is a subset) or duplicate the schedule that already lives in ADF. `PPN_PROCESS` rows are
  created on **first touch** by `SP_RUN_TABLE_LOAD` (claim `RUNNING`) — a table that was never
  invoked simply leaves no row.
- **Fail-closed gate:** step 7 permits GOLD only if the gate passes. `SP_GATE_CHECK` FAILs when
  no table reported, when any entry is outside `SUCCESS`/`SKIP` (`ERROR`, a left-over `RUNNING`
  from a crashed call, unknown/NULL), or when fewer tables reported than ADF dispatched. Any FAIL →
  no GOLD, run closes `ERROR`, one alert.
- **DQ is part of the gate, not a separate step.** `SP_GATE_CHECK` calls `ADM.SP_DQ_EXECUTE`
  (`DQ_SILVER`, `JSON`) and judges the result: a technical DQ failure, a finding at severity ≥ 100,
  or findings whose severity cannot be read all FAIL the gate; findings below 100 PASS with
  `dq_verdict = 'WARN'` and GOLD is still refreshed. When the table checks have already failed, DQ
  is not run at all (`dq_verdict = 'SKIPPED'`) — GOLD is blocked either way and an antFarm
  execution holds a warehouse for the whole poll. The gate is therefore no longer a pure read; the
  full DQ object comes back inside the gate result and `SP_FINALIZE_RUN` writes it to `PPN_LOG`.
  The ADF activity timeout on finalize must exceed `SP_DQ_EXECUTE`'s `P_TIMEOUT_S` (3600s).
- **GOLD refresh (pipeline-only):** GOLD is materialised as **dynamic tables** created with
  `SCHEDULER = DISABLE` (no background / target-lag refresh), so GOLD changes only when a gated run
  calls `SP_REFRESH_GOLD` — never on a clock that could publish un-gated SILVER. `SP_REFRESH_GOLD`
  enumerates the GOLD dynamic tables from `INFORMATION_SCHEMA.DYNAMIC_TABLES` (nothing hardcoded),
  refreshes them in ONE combined `ALTER DYNAMIC TABLE a, b, c REFRESH` (common data timestamp,
  dependency order), then VERIFIES via `DYNAMIC_TABLE_REFRESH_HISTORY` that none ended
  `FAILED`/`CANCELLED`/`UPSTREAM_FAILED` (a combined refresh is not all-or-nothing). Same child-error
  contract as the loaders — returns `SUCCESS`/`ERROR`, does not raise. It runs as the caller
  (`{ENV}_DATA_LOADER`), which holds `OPERATE` on the dynamic tables via `FULL_AR → RW_AR`
  (`CREATE_SCHEMA` grants `OPERATE` on all/future dynamic tables to `RW_AR`). The `GOLD_{domain}`
  marts are **views over GOLD** owned by `{ENV}_SYSADMIN` (same owner as the GOLD dynamic tables), so
  a domain reporter reads its mart through the ownership chain with no privilege on GOLD. Static
  `DIM_DATE`/`DIM_TIME` are plain tables and are not refreshed.
- **Who proves completeness:** because rows are created on first touch, the gate alone proves only
  *"nothing that ran failed"*. Snowflake cannot know the intended list — ADF owns it. So ADF passes
  its ForEach item count into `SP_FINALIZE_RUN`, and the gate FAILs on `reported < expected`. A
  count suffices: each dispatched table upserts exactly one row (PK `PPN_ID`+`SOURCE_ID`+
  `TABLE_NAME`), so a shortfall can only mean a dispatch never reached Snowflake. The wider case —
  ADF dying mid-loop — is already covered by ADF's own control flow: the finalize activity is never
  reached, so GOLD is never refreshed.
- **State vs log:** `PPN_PROCESS` = authoritative per-run×table state (drives the gate and reruns),
  written **only by `SP_RUN_TABLE_LOAD`** (RUNNING → SKIP/ERROR/SUCCESS, counts rolled up), so a
  partially-processed table can never look complete. `PPN_LOG` = append-only step forensics
  (ERROR block first), written by every procedure.
- **Atomic writes:** HIST (`DELETE`+`INSERT` per PPN) and SILVER (`MERGE`+soft-delete) each run in
  one explicit transaction with rollback on failure — Snowflake procedures are not atomic by
  default. Structure sync/DDL runs *before* the transaction opens.
- **Error propagation:** loaders return an error object *and* set `ERROR` state; run-control procs
  re-raise so the ADF activity fails and alerting fires.
- **Idempotency:** re-running the same `PPN_ID` never duplicates — HIST delete-then-insert per PPN,
  SILVER MERGE keyed by `PK_HK`.
- **Recovery / reprocessing (out of band):** `SP_REPLAY_FROM_HIST` rebuilds `SILVER.<table>` from
  `BRONZE_HIST` by replaying every stored PPN snapshot in ascending order through
  `SP_LOAD_BRONZE_TO_SILVER` — the same cleanse logic the nightly run uses, so no transform code is
  duplicated. It is an **operator-run maintenance** entry point, NOT part of the ADF flow: use it
  after a SILVER transform/hash change (drop + full rebuild — a normal run would only re-apply the
  latest PPN), after corruption/loss found outside the Time Travel window (HIST is the long-lived
  truth, and unlike Time Travel it re-derives SILVER with the *current* logic), or for a
  point-in-time / bounded in-place resume. Order matters — collapsing all history into one MERGE
  would break FULL delete-detection — so snapshots are replayed one PPN at a time, each applied
  atomically; the replay is not atomic across PPNs and is safely re-runnable. See the ETL as-built
  doc §7.3 and `TESTS/test_replay_from_hist.sql`.

---

## Build status (2026-08-19)

**Built:** `SP_CREATE_PPN`, `SP_VALIDATE_CONFIG`, `SP_RUN_TABLE_LOAD` (wrapper),
`SP_LOAD_FILE_TO_BRONZE`, `SP_LOAD_DATABASE_TO_BRONZE`, `SP_CHECK_DATA_CHANGE`,
`SP_LOAD_BRONZE_TO_HIST`, `SP_LOAD_BRONZE_TO_SILVER`, `SP_SYNC_TABLE_STRUCTURE`,
`SP_GATE_CHECK` (now DQ-aware), `SP_FINALIZE_RUN`, `SP_REFRESH_GOLD` (real — refreshes the GOLD
dynamic tables), the standalone DQ
set `SP_DQ_EXECUTE` / `SP_DQ_RESULT` / `SP_SEND_NOTIFICATION`, helpers `SP_LOG_STEP` /
`SP_SET_PROCESS_STATE`, `SP_CLOSE_PPN`, and the recovery procedure `SP_REPLAY_FROM_HIST`
(authored 2026-08-20; DEV validation pending — ships with `TESTS/test_replay_from_hist.sql`).
(Loaders + run-control tested on DEV; gate/finalize and the
DQ set newly built. antFarm itself is still stubbed under `PLATFORM_DB.ANTFARM` — see
`Account Setup/antfarm/`.) GOLD dynamic tables (`DIM_PARTNER`, `FCT_WHOLESALE_USAGE`) + static
`DIM_DATE`/`DIM_TIME` built under `etl_build/GOLD/`; `CREATE_SCHEMA` now grants `OPERATE` on dynamic
tables to `RW_AR` so `{ENV}_DATA_LOADER` can refresh (backfill migration for pre-existing schemas
under `Account Setup/migrations/`), verified on DEV.

**Pending:** real antFarm on SPCS (needs the billed account); the **production GOLD model** across
the business domains and the `GOLD_{domain}` mart views over it (the refresh mechanism is built and
demonstrated on the sample WHOLESALE star); DEV validation of `SP_REPLAY_FROM_HIST` (built, not yet
executed against the database).

**Retired:** `SP_RUN_DQ_CHECKS` was never built — DQ moved inside `SP_GATE_CHECK` instead, so
there is one invoker and one judge rather than a separate procedure whose verdict the gate re-read
from a `PPN_PROCESS` row.
