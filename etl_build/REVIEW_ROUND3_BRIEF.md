# Review round 3 (final) — brief for the reviewer

Round 2's four findings were all correct and are now fixed. This is intended as a **final
sign-off pass**, so I'd like a narrower question answered than before:

> Is there anything left that would make you say "do not run this in production"?

Please review the attached procedures as they now stand. Note that
`SP_SET_PROCESS_STATE`'s signature changed, so all callers changed with it.

---

## What I changed since round 2

### 1. `SP_SET_PROCESS_STATE` is now UPDATE-only  *(your P0)*
The `MERGE … WHEN NOT MATCHED THEN INSERT` is gone. It now performs a plain `UPDATE`, captures
`SQLROWCOUNT` immediately, and raises (`-20230`) if it is not exactly 1:

> "PPN_PROCESS row does not exist: the run was not prepared (SP_PREPARE_RUN) or this table is not
> part of the frozen plan."

Invariant now documented in the table DDL and the procedure header:
**`SP_PREPARE_RUN` is the only procedure that inserts into `PPN_PROCESS`; everything at runtime
only updates.** This also blocks `SP_RUN_TABLE_LOAD` from claiming a table that isn't in the plan.

### 2. `SP_PREPARE_RUN` is freeze-once, idempotent and atomic  *(your P1)*
- If the PPN already has plan rows → returns the existing plan **unchanged**
  (`action: ALREADY_PREPARED`, with the entry count). It no longer errors on a second call —
  that was the `v_planned = 0 → RAISE` bug you found, and my "idempotent" comment was simply wrong.
- First-time seeding (tables + optional `_RUN_/_DQ_` marker) now runs inside a single
  `BEGIN TRANSACTION … COMMIT`, with `ROLLBACK` in the handler, so a failure cannot leave a
  half-frozen plan. The "no active tables" check raises **inside** the transaction, so nothing is
  committed in that case.
- A retried call never appends tables added to the config after the freeze.

### 3. `SP_CHECK_DATA_CHANGE`: schema comparison before hashing  *(your P1)*
It now compares the **business column sets** of BRONZE and BRONZE_HIST first (order-independent,
same technical-column exclusions). If they differ it returns `action: SCHEMA_CHANGED`,
`is_identical = FALSE`, and **does not attempt the hash** — which is what previously failed against
the not-yet-synced HIST table. HIST then runs `SP_SYNC_TABLE_STRUCTURE` and loads normally.

### 4. Same-PPN rerun guard — implemented slightly differently from your suggestion
You proposed: if current-PPN HIST exists, compare against it; identical → safe retry SKIP.

I went stricter: **if `BRONZE_HIST` already contains rows for the current PPN, never skip**
(`action: RETRY_FORCE`).

Reasoning: consider attempt 1 that wrote HIST and then failed in SILVER. On retry, current-PPN HIST
would match BRONZE, your rule would SKIP, and SILVER would stay stale permanently while the table
is marked SKIP. Since HIST (delete+insert per PPN) and SILVER (MERGE) are both idempotent, the only
cost of always reprocessing a rerun is one redundant pass.

**Please tell me if you disagree** — specifically whether you see a case where forcing reprocessing
on a rerun is worse than the stale-SILVER risk I'm avoiding.

Resulting decision order in `SP_CHECK_DATA_CHANGE`:

```
RETRY_FORCE      (current PPN already in HIST)
  else NO_PREVIOUS   (no history table / no earlier PPN)
  else SCHEMA_CHANGED(BRONZE vs HIST column sets differ)
  else IDENTICAL | DIFFERENT   (COUNT + HASH_AGG)
```

### 5. P2 items you raised
- **Transaction syntax:** now plain `BEGIN TRANSACTION;` / `COMMIT;` / `ROLLBACK;` instead of
  `EXECUTE IMMEDIATE`, in HIST, SILVER and PREPARE. The `v_txn_open` flag is now set **after**
  `BEGIN TRANSACTION` succeeds, and cleared inside the rollback block.
- **MERGE metric semantics:** `PPN_PROCESS.ROWS_INSERTED` renamed to **`ROWS_MERGED`**
  ("rows affected by the SILVER MERGE — inserts + updates, not split"), and the never-populated
  `ROWS_UPDATED` column was dropped. `SP_SET_PROCESS_STATE`'s parameter list changed accordingly.
- **SKIP path metrics:** the SKIP branch now preserves `ROWS_EXTRACTED` from the landing step,
  since landing genuinely happened.
- **Hash comment:** corrected — SQL NULL renders as `undefined` inside the array, not JSON null;
  the point that matters is that it stays distinct from `''`. Added a warning not to reuse this
  expression for `OBJECT`/`VARIANT` values without canonicalisation (relevant to the future RAW
  semi-structured pattern).
- **Freeze scope wording:** now stated explicitly everywhere as *table membership + `LOAD_ORDER`
  are frozen for the PPN; per-table execution configuration remains live.*
- **`USE DATABASE DEV_DB` in the scripts:** intentional. These are deployment scripts and the
  header is the environment selector (the account-setup layer is env-parameterised the same way).
  All *runtime* references now resolve via `CURRENT_DATABASE()` / unqualified `INFORMATION_SCHEMA`.
  Tell me if you still consider that a risk.

### 6. Your other answers — accepted, no code written
- **Source taxonomy:** keeping `PARQUET` / `DATASHARE`. Salesforce stays `PARQUET`.
- **`SOURCE_DELETE_COLUMN`:** not added speculatively. But I've raised your Salesforce point as a
  real requirements question internally (an INCR feed cannot infer deletion from absence, so if
  Salesforce deletes must reach SILVER we need ADF `includeDeletedObjects` + a source delete flag).
  If the business confirms it, we'll add it then.
- Still deferred deliberately: shared-BRONZE concurrency, exact `MINUS` after `HASH_AGG`,
  hard-fail on duplicate business keys.

### 7. Your two visible risks
- **PPN-scoped Parquet folders** (`…/<TABLE>/<PPN_ID>/`): accepted as pre-production, agreed it is
  about input immutability and not just concurrency. It's an ADF-side change plus a config change,
  planned next.
- **Empty FULL/INIT extraction:** good catch, and currently unguarded. A zero-row full snapshot
  would soft-delete everything in SILVER. Before DQ exists I'm inclined to add a minimal guard —
  see the question below.

---

## Questions for this round

1. **Empty-snapshot guard — where does it belong?** Options I see:
   (a) config flag on `ETL_TABLES` (e.g. `ALLOW_EMPTY` / `MIN_ROWS`) checked in the landing step;
   (b) a guard inside `SP_LOAD_BRONZE_TO_SILVER` that refuses a FULL/INIT load whose snapshot is
   empty while SILVER holds rows; (c) leave it entirely to the future DQ framework.
   Which would you choose given DQ is not yet available, and would you fail the table or just
   warn?
2. **The rerun guard** (§4) — do you accept the stricter RETRY_FORCE rule, or do you still prefer
   your conditional-skip version?
3. **Deployment/runtime split** — is the remaining `USE DATABASE DEV_DB` in deployment headers
   acceptable to you, or would you parameterise those too before promotion?
4. **Regression tests for the hash.** You suggested covering NULL/'', NUMBER scales, FLOAT, DATE,
   TIMESTAMP_NTZ/TZ, BOOLEAN. Do you consider that a release blocker, or a follow-up task?
5. **Anything remaining that is genuinely a bug** (as opposed to scale/concurrency hardening we
   have consciously deferred)? If the answer is "nothing blocking", please say so plainly — that
   is the outcome I'm trying to establish with this round.

---

## Current state, for context

Run flow (only `PPN_ID` is passed between procedures; `RUN_ID` lives on `ADM.PPN` and is stamped
onto every log row by `SP_LOG_STEP`):

```
SP_CREATE_PPN(RUN_ID) -> SP_VALIDATE_CONFIG -> SP_PREPARE_RUN   (plan frozen: PENDING rows)
   per table (ADF ForEach over the frozen plan, ORDER BY LOAD_ORDER):
       (PARQUET only) ADF Copy: source -> Parquet in Blob
       SP_RUN_TABLE_LOAD -> landing -> check-change -> [skip?] -> HIST -> SILVER
   SP_RUN_DQ_CHECKS        (pending - external tool)
   SP_FINALIZE_RUN         -> gate -> GOLD (stub) -> close; raises if the run failed
```

- `PPN_PROCESS` = frozen plan + authoritative state, written only by `SP_PREPARE_RUN` (insert) and
  `SP_RUN_TABLE_LOAD` (update, via `SP_SET_PROCESS_STATE`).
- `PPN_LOG` = append-only step forensics; error messages are
  `ERROR [<PROC>/<phase>]: <root cause>` with an `ERROR`-first `DETAIL_JSON`.
- Scale: ~35 GB initial, 8–13 GB/yr, daily batch, single pipeline.
- Still stubbed by design: `SP_RUN_DQ_CHECKS`, `SP_REFRESH_GOLD`.

Please be blunt about anything you would still block on.
