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
    ADF->>SF: CALL SP_PREPARE_RUN(PPN_ID)
    Note over SF: freezes the plan — seeds PPN_PROCESS<br/>with one PENDING row per active table
    ADF->>SF: read frozen plan (PPN_PROCESS, SOURCE_ID <> '_RUN_', ORDER BY LOAD_ORDER)
    SF-->>ADF: table list for THIS PPN

    Note over ADF,SF: PER TABLE (ForEach, by LOAD_ORDER)
    opt SOURCE_TYPE = FILE
        ADF->>SRC: extract table (Copy activity)
        SRC-->>BLOB: write Parquet to Bronze container
    end
    ADF->>SF: CALL SP_RUN_TABLE_LOAD(PPN_ID, SOURCE_ID, TABLE)
    Note over SF: landing (file/share) → check-change →<br/>identical? SKIP : (HIST → SILVER)
    SF-->>ADF: SUCCESS | SKIPPED | ERROR (per table)

    Note over ADF,SF: RUN LEVEL (after all tables)
    ADF->>SF: CALL SP_RUN_DQ_CHECKS(PPN_ID)   %% AntFarm — pending
    SF-->>ADF: max severity + blocking flag
    ADF->>SF: CALL SP_FINALIZE_RUN(PPN_ID)
    Note over SF: gate → PASS: refresh GOLD → close SUCCESS;<br/>FAIL: skip GOLD → close ERROR + re-raise
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
| 3b | ADF → SF | `SP_PREPARE_RUN(PPN_ID)` — **freeze the run plan**: seed one `PENDING` row per active table | `ETL_SOURCES`,`ETL_TABLES` | `PPN_PROCESS` (PENDING), `PPN_LOG` |
| 4 | ADF | Lookup the **frozen plan** for this PPN, `SOURCE_ID <> '_RUN_'` (excludes the run-level DQ marker), order by `LOAD_ORDER` | `PPN_PROCESS` | — |
| — | | **Per table (ForEach):** | | |
| 5a | ADF → SRC/Blob | *(FILE sources only)* Copy activity: extract source → file(s) in Blob | source | Blob |
| 6 | ADF → SF | `SP_RUN_TABLE_LOAD(PPN_ID, SOURCE_ID, TABLE)` — wraps landing (file/share) → check-change → HIST → SILVER; SKIP if identical | config, `BRONZE`, `BRONZE_HIST` | `BRONZE`/`BRONZE_HIST`/`SILVER`, `PPN_PROCESS`, `PPN_LOG` |
| — | | **Run level (after all tables):** | | |
| 7 | ADF → SF | `SP_RUN_DQ_CHECKS(PPN_ID)` — *AntFarm, pending* | `SILVER` | DQ verdict → `PPN_PROCESS`/`PPN_LOG` |
| 8 | ADF → SF | `SP_FINALIZE_RUN(PPN_ID)` — gate → GOLD (if pass) → close; returns SUCCESS or re-raises. `SP_REFRESH_GOLD` currently a **stub** | `PPN_PROCESS`,`SILVER` | `ADM.PPN` final, `GOLD`/`GOLD_{domain}`, `PPN_LOG` |
| 9 | ADF → SF | `SP_CLOSE_PPN(PPN_ID, ERROR)` — **only for early aborts** (validate/loop failures before finalize) | `ADM.PPN` | `ADM.PPN` final, `PPN_LOG` |
| 10 | ADF | On any failure: one alert; failed activity surfaces in monitoring | — | — |

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

- **Skip-if-identical:** step 7 lets a table short-circuit — if this load equals the last
  `BRONZE_HIST` snapshot (count + `HASH_AGG`), HIST + SILVER are skipped and the table is marked
  `SKIP` (still counts as success at the gate).
- **Frozen run plan:** `SP_PREPARE_RUN` seeds every active table as `PENDING` at run start, so the
  gate can see tables that were *never invoked* (they stay `PENDING`, which is not `SUCCESS`/`SKIP`
  → gate FAIL). **Scope of the freeze: table membership + `LOAD_ORDER`** — per-table execution
  config (`SOURCE_TYPE`, `LOAD_TYPE`, `PK_COLUMNS`, stage/pattern, …) is still read live at
  execution time. ADF iterates `PPN_PROCESS`, not live `ETL_TABLES`. Freeze-once: a repeat
  `SP_PREPARE_RUN` call returns the existing plan unchanged and never appends newly-added tables.
- **Only `SP_PREPARE_RUN` inserts `PPN_PROCESS` rows.** `SP_SET_PROCESS_STATE` is update-only and
  raises if no planned row exists — so runtime cannot invent rows for a run that was never
  prepared (which would let the gate pass while never-invoked tables stayed invisible), and an
  unplanned table cannot be processed.
- **Fail-closed gate:** step 8 permits GOLD only if every planned entry is `SUCCESS`/`SKIP` **and**
  DQ passed; anything `ERROR`/`PENDING`/unknown → no GOLD, run closes `ERROR`, one alert.
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

---

## Build status (2026-07-17)

**Built:** `SP_CREATE_PPN`, `SP_VALIDATE_CONFIG`, `SP_PREPARE_RUN`, `SP_RUN_TABLE_LOAD` (wrapper),
`SP_LOAD_FILE_TO_BRONZE`, `SP_LOAD_DATABASE_TO_BRONZE`, `SP_CHECK_DATA_CHANGE`,
`SP_LOAD_BRONZE_TO_HIST`, `SP_LOAD_BRONZE_TO_SILVER`, `SP_SYNC_TABLE_STRUCTURE`,
`SP_GATE_CHECK`, `SP_FINALIZE_RUN`, `SP_REFRESH_GOLD` (**stub**), helpers `SP_LOG_STEP` /
`SP_SET_PROCESS_STATE`, `SP_CLOSE_PPN`. (Loaders + run-control tested on DEV; gate/finalize newly built.)

**Pending:** `SP_RUN_DQ_CHECKS` (waits on the AntFarm DQ tool), real `SP_REFRESH_GOLD`
implementation (Dynamic Tables / dbt), `SP_REPLAY_FROM_HIST` (recovery).
