# Standalone Antfarm DQ Solution — Final Reviewed Version

## Architecture

The DQ procedures are deployed in each environment database:

```text
DEV_DB.ADM
TEST_DB.ADM
PROD_DB.ADM
```

Antfarm is centralized in:

```text
PLATFORM_DB.ANTFARM
```

Final procedures:

```text
ADM.SP_DQ_EXECUTE
ADM.SP_DQ_RESULT
ADM.SP_SEND_NOTIFICATION
```

The account-level email integration is:

```text
EMAIL_INTEGRATION
```

Session context: `ADM.*` references are schema-qualified only, the same
convention as the rest of the ETL framework. The caller supplies the
environment database — ADF connects as `{ENV}_DATA_LOADER` against the
environment DB, so `ADM.SP_DQ_RESULT` and `ADM.SP_SEND_NOTIFICATION`
resolve in the right place without hard-coding a database name.

Dependency flow:

```text
ADM.SP_DQ_EXECUTE
    |
    +-- PLATFORM_DB.ANTFARM.LOAD_API_INGESTION_META_DATA
    +-- PLATFORM_DB.ANTFARM.LOAD_API_DQ_META_DATA
    +-- PLATFORM_DB.ANTFARM.LOAD_API_PROJECT_META_DATA
    +-- PLATFORM_DB.ANTFARM.API_RUN_DQ
    +-- PLATFORM_DB.ANTFARM.API_DQ_GET_LOG
    |
    +-- optional ADM.SP_DQ_RESULT
              |
              +-- JSON
              |
              +-- EMAIL -> ADM.SP_SEND_NOTIFICATION
                              |
                              -> EMAIL_INTEGRATION
```

## Core principle

Technical execution status and DQ findings are separate.

A technically successful run can contain bad data:

```json
{
  "status": "SUCCESS",
  "dq_result": {
    "status": "SUCCESS",
    "has_issues": true,
    "max_severity_level": 100
  }
}
```

`status = FAILED` is reserved for technical failures such as:

- Antfarm API failure;
- metadata refresh failure;
- missing/invalid Antfarm response;
- missing result after Antfarm reported success;
- actual EMAIL transport failure.

DQ findings themselves do not cause technical failure.

---

## SP_DQ_EXECUTE

Signature:

```sql
ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME  VARCHAR,
    P_CALLER_ID      VARCHAR DEFAULT 'antfarm_admin',
    P_PROJECT_NAME   VARCHAR DEFAULT 'DWH',
    P_TIMEOUT_S      NUMBER  DEFAULT 3600,
    P_SLEEP_S        NUMBER  DEFAULT 60,
    P_OUTPUT_TYPE    VARCHAR DEFAULT NULL,
    P_MAX_ERROR_ROWS NUMBER  DEFAULT 20
)
```

`P_MAX_ERROR_ROWS` is passed straight through to `SP_DQ_RESULT`, so the
single-call ADF pattern can control its own payload size.

`P_OUTPUT_TYPE`:

```text
NULL   -> execute only
JSON   -> execute + return DQ result
EMAIL  -> execute + process result + send configured notifications
```

Example:

```sql
CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_STG_PAS',
    P_OUTPUT_TYPE   => 'JSON'
);
```

### Metadata refresh

The real Antfarm procedures return `VARCHAR` and catch their own exceptions:

```text
All SQL statements executed successfully.
```

or:

```text
Error executing SQL: ...
```

`SP_DQ_EXECUTE` captures and validates every refresh response before calling `API_RUN_DQ`.

### Timeout

Default:

```text
3600 seconds
```

The DQ timeout starts immediately before `API_RUN_DQ`, so metadata-refresh time is not included.

### Polling

Known active states:

```text
STARTED
RUNNING
```

Successful terminal state:

```text
SUCCESS
```

HTTP 200 without `task_status` fails immediately instead of being treated as `RUNNING`.

### Result failure propagation

If Antfarm reports `SUCCESS` but `SP_DQ_RESULT` returns `FAILED`, the top-level procedure also returns:

```text
status = FAILED
phase  = GET_RESULT
```

This prevents ADF from missing a failed result read or failed requested email delivery.

---

## SP_DQ_RESULT

Signature:

```sql
ADM.SP_DQ_RESULT(
    P_RUN_ID         VARCHAR,
    P_OUTPUT_TYPE    VARCHAR DEFAULT 'JSON',
    P_MAX_ERROR_ROWS NUMBER  DEFAULT 20
)
```

Source:

```sql
FROM PLATFORM_DB.ANTFARM.DQ_LOG
WHERE RUN_ID = ?
```

`DQ_RULES` is intentionally not joined. `DQ_LOG` is treated as the historical execution snapshot.

The procedure reads all checks, including `NUM_OF_ERRORS = 0`, so it distinguishes:

```text
valid clean run
valid run with DQ issues
unknown/missing RUN_ID
```

Clean run example:

```json
{
  "status": "SUCCESS",
  "has_issues": false,
  "failed_checks": 0,
  "total_errors": 0,
  "results": []
}
```

Run with findings:

```json
{
  "status": "SUCCESS",
  "has_issues": true,
  "failed_checks": 2,
  "total_errors": 3,
  "max_severity_level": 100
}
```

### ERROR_ROWS output cap

The default is:

```text
P_MAX_ERROR_ROWS = 20
```

Allowed range:

```text
1 .. 1000
```

Each failed check reports:

```text
error_rows
error_rows_available
error_rows_truncated
```

This prevents unnecessarily large JSON/ADF activity outputs.

---

## EMAIL mode

If there are no DQ findings:

```text
email_status = NOT_REQUIRED
emails_sent  = 0
```

If findings exist but no active Antfarm recipient is configured:

```text
email_status   = SKIPPED
emails_sent    = 0
emails_skipped = 1
message        = "... no active Antfarm email recipient configured"
```

`emails_skipped` is reported for every mixed run too, so a run that
delivered some groups and silently dropped others cannot present itself
as a clean `SUCCESS`. A missing recipient is a configuration gap, not a
transport failure, so it does not fail the run.

If an actual send fails:

```text
email_status = FAILED
status       = FAILED
```

If some sends succeed and others fail:

```text
email_status = PARTIAL
status       = FAILED
```

This is a technical failure of the requested EMAIL operation.

---

## SP_SEND_NOTIFICATION

Signature:

```sql
ADM.SP_SEND_NOTIFICATION(
    P_SUBJECT       VARCHAR,
    P_HTML_BODY     VARCHAR,
    P_RECIPIENTS_TO VARCHAR,
    P_RECIPIENTS_CC VARCHAR DEFAULT '',
    P_INTEGRATION   VARCHAR DEFAULT 'EMAIL_INTEGRATION'
)
```

The procedure:

- accepts comma- or semicolon-separated TO/CC strings;
- limits the subject to 256 characters;
- uses `SNOWFLAKE.NOTIFICATION.TEXT_HTML`;
- uses `SNOWFLAKE.NOTIFICATION.EMAIL_INTEGRATION_CONFIG`;
- calls `SYSTEM$SEND_SNOWFLAKE_NOTIFICATION`;
- returns `SUCCESS` or `FAILED`.

It remains generic and contains no DQ-specific logic.

---

## Snowflake EMAIL constraint

Snowflake email is not an unrestricted SMTP relay.

Recipients must be:

1. email addresses of Snowflake users in the same account;
2. verified;
3. included in `EMAIL_INTEGRATION.ALLOWED_RECIPIENTS` when that property is configured.

`ALLOWED_RECIPIENTS` supports a maximum of 50 addresses.

This means Antfarm values in:

```text
DQ_LOG_MAIL_TO
DQ_LOG_MAIL_CC
```

must satisfy the Snowflake email restrictions.

Account setup is in:

```text
20_integration_notification_email.sql
```

The procedure is `EXECUTE AS CALLER`, therefore the role executing DQ EMAIL mode needs `USAGE ON INTEGRATION EMAIL_INTEGRATION`:

```sql
GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE {ENV}_DATA_LOADER;
GRANT USAGE ON INTEGRATION EMAIL_INTEGRATION TO ROLE {ENV}_SYSADMIN;
```

`{ENV}_DATA_LOADER` is the ADF service role and the normal caller.
`{ENV}_SYSADMIN` owns the `ADM` procedures and needs it to test and to
send manually.

---

## Real Antfarm signatures confirmed

The supplied Antfarm files confirm:

```sql
API_RUN_DQ(VARCHAR)
RETURNS VARCHAR
```

```sql
API_DQ_GET_LOG(VARCHAR, VARCHAR, VARCHAR)
RETURNS VARCHAR
```

```sql
LOAD_API_INGESTION_META_DATA(VARCHAR)
RETURNS VARCHAR
```

```sql
LOAD_API_DQ_META_DATA(VARCHAR)
RETURNS VARCHAR
```

```sql
LOAD_API_PROJECT_META_DATA(VARCHAR)
RETURNS VARCHAR
```

`API_DQ_GET_MAX_SEVERITY` is not required. Maximum failed-check severity is derived directly from `DQ_LOG`.

---

## Temporary Antfarm demo

Before real Antfarm exists, deploy:

```text
ANTFARM_DUMMY_SETUP.sql
```

The stub creates drop-in objects under:

```text
PLATFORM_DB.ANTFARM
```

Demo scenarios:

| DQ group | Technical status | Expected result |
|---|---|---|
| `DQ_DEMO_OK` | SUCCESS | 2 checks, 0 errors |
| `DQ_DEMO_ISSUES` | SUCCESS | 3 checks, 2 failed, 3 errors |
| `DQ_DEMO_RESULT_MISSING` | SUCCESS | result missing -> top-level FAILED / GET_RESULT |
| `DQ_DEMO_TECH_FAIL` | FAILED | result procedure not called |
| `DQ_SILVER` | SUCCESS | 2 checks, 0 errors - the real gate group, clean so a clean ETL run passes |
| any unknown group | FAILED | `API_RUN_DQ` http_code 400, phase `RUN_DQ` |

Plus one demo caller:

| Caller | Effect |
|---|---|
| `P_CALLER_ID = 'demo_meta_fail'` | metadata refresh returns `Error executing SQL: ...` -> FAILED / `REFRESH_METADATA`, `API_RUN_DQ` never reached |

The metadata-failure and unknown-group paths are covered deliberately:
the real `LOAD_API_*` procedures report failure only in their return
text, so without a stub that reproduces that, the validation in
`SP_DQ_EXECUTE` would never be exercised before production.

Run:

```text
ANTFARM_DUMMY_DEMO.sql
```

Before real Antfarm is deployed:

```text
ANTFARM_DUMMY_CLEANUP.sql
```

must be run.

Do not run dummy cleanup after the real Antfarm objects have replaced the stubs.

---

## Deployment order

Account level:

```text
1. 20_integration_notification_email.sql
```

Environment database:

```text
1. SP_SEND_NOTIFICATION.sql
2. SP_DQ_RESULT.sql
3. SP_DQ_EXECUTE.sql
```

Temporary demo:

```text
1. ANTFARM_DUMMY_SETUP.sql
2. environment procedures
3. ANTFARM_DUMMY_DEMO.sql
```

Before real Antfarm:

```text
ANTFARM_DUMMY_CLEANUP.sql
```

---

## Use inside the pre-GOLD gate

`ADM.SP_GATE_CHECK` (the ETL framework's pre-GOLD gate) calls `SP_DQ_EXECUTE`
directly, so DQ is part of the gate rather than a separate orchestrator step:

```sql
CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME  => 'DQ_SILVER',
    P_OUTPUT_TYPE    => 'JSON',
    P_MAX_ERROR_ROWS => 5
);
```

The group name (`DQ_SILVER`), the blocking severity (`100`) and the error-row
sample (`5`) are fixed constants inside `SP_GATE_CHECK`, not parameters — one
gate, one group, and the ADF contract for `SP_FINALIZE_RUN` stays unchanged.

How the gate reads the result:

| Result | `dq_verdict` | Gate |
|---|---|---|
| `status` <> SUCCESS | `FAIL` | FAIL — DQ could not prove the data is OK |
| `has_issues` = false | `PASS` | PASS |
| `max_severity_level` >= 100 | `FAIL` | FAIL — GOLD blocked |
| `max_severity_level` < 100 | `WARN` | PASS — reported, GOLD still refreshed |
| findings with unreadable severity | `FAIL` | FAIL — unknown never means success |
| table checks already failed | `SKIPPED` | FAIL (on the tables) — no antFarm run spent |

`P_MAX_ERROR_ROWS => 5` matters here: `SP_FINALIZE_RUN` writes the whole gate
object, DQ result included, into `ADM.PPN_LOG`. The full error set stays in
`PLATFORM_DB.ANTFARM.DQ_LOG`.

Because the gate polls antFarm inside the finalize call, the ADF activity
timeout on `SP_FINALIZE_RUN` must exceed `P_TIMEOUT_S` (3600s default), and the
gate holds a warehouse for the duration.

EMAIL mode is not used by the gate. The gate's job is to block GOLD; DQ
notification is a separate concern and stays on the `EMAIL` path.

---

## ADF interpretation

Recommended call:

```sql
CALL ADM.SP_DQ_EXECUTE(
    P_DQ_GROUP_NAME => 'DQ_STG_PAS',
    P_OUTPUT_TYPE   => 'JSON'
);
```

ADF logic:

```text
top-level status != SUCCESS
    -> technical failure

top-level status = SUCCESS
    -> inspect dq_result.has_issues

has_issues = false
    -> DQ clean

has_issues = true
    -> inspect max_severity_level
```

The blocking severity threshold is intentionally controlled by the external process rather than hard-coded in these procedures.
