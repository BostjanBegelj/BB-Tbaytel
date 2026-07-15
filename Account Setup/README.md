# Tbaytel Snowflake — Account Setup

SQL scripts to stand up the Snowflake account and its environments.
Organized by **lifecycle**, not by object type:

- **`account/`** — run **once per Snowflake account**. Account-level
  objects that are not environment-specific and are never prefixed
  with `DEV_/TEST_/QA_/PROD_`.
- **`environment/`** — run **once per environment**. Set `ENV_ABBR`
  at the top of each file (`DEV_`, `TEST_`, `QA_`, `PROD_`) and run
  the whole file. To add an environment, re-run this folder with a
  different `ENV_ABBR`.

> Scripts are templates. Review before running. Run each file as a
> role that can assume `ACCOUNTADMIN`/`SECURITYADMIN`/`SYSADMIN`
> (the files switch roles with `USE ROLE` as needed).

## Run order

### 1. account/ (once per account)

| # | File | Creates |
|---|------|---------|
| 01 | `01_account_parameters.sql` | Account `TIMEZONE` |
| 02 | `02_platform_db_and_procs.sql` | `PLATFORM_WH`, `PLATFORM_DB`, `RBAC` schema, provisioning procs (`CREATE_DATABASE`, `DROP_DATABASE`, `CREATE_SCHEMA`, `DROP_SCHEMA`) |
| 03 | `03_terraform_admin_role.sql` | `TERRAFORM_ADMIN` account role + global grants |
| 04 | `04_svc_terraform_user.sql` | `SVC_TERRAFORM` service user (key-pair) |
| 05 | `05_human_access.sql` | Reference: people come via SSO/SCIM; optional break-glass admin |

**Also part of the account layer** (currently still in their existing
folders — to be moved/renumbered into `account/` in a follow-up):
`4_security/` (SECURITY_DB, network rules, network policy, auth/password/
masking policies) and `3_integrations/` (Git, storage). These run after
`02_platform_db_and_procs.sql`.

### 2. environment/ (per environment — set `ENV_ABBR`)

| # | File | Creates |
|---|------|---------|
| 01 | `01_env_admin_roles.sql` | `{ENV}_SYSADMIN`, `{ENV}_USERADMIN`, their account grants, **and platform provisioning access** (usage on `PLATFORM_WH`/`PLATFORM_DB`/`RBAC`/procs) |
| 02 | `02_functional_roles_and_warehouses.sql` | 8 functional roles + one warehouse each |
| 03 | `03_environment_database.sql` | `{ENV}_DB` (via `CREATE_DATABASE`) |
| 04 | `04_environment_schemas.sql` | 9 medallion schemas + retention tiers + RO/FULL role grants |
| 05 | `05_env_service_users.sql` | `SVC_{ENV}_ADF` (role `{ENV}_DATA_LOADER`) and `SVC_{ENV}_POWERBI` (role `{ENV}_REPORTER`) — both key-pair |

## Key design points

- **Two admin models coexist:** the `{ENV}_SYSADMIN/{ENV}_USERADMIN`
  roles (manual/interim provisioning) and `TERRAFORM_ADMIN` (future
  CI/CD). Terraform will eventually own account-level objects; the SQL
  scripts become documentation at that point.
- **Human users are not created in SQL** — Entra SSO + SCIM provision
  people and map Entra groups to functional roles. Only `SVC_` users
  are created in SQL (key-pair auth).
- **Retention tiers** are set per schema in `04` — adjust to policy.

## Reporter model (by design)

- **`{ENV}_REPORTER`** — used by the **Power BI service user**
  (`SVC_{ENV}_POWERBI`). It has RO on `GOLD` and **all** `GOLD_*`
  domain schemas, so the shared Power BI service account can read
  across every domain. This broad access is intentional.
- **`{ENV}_REPORTER_BILLING` / `_FINANCE` / `_MARKETING`** — used by
  **actual people** connecting via Power BI DirectQuery with SSO,
  assigned through Entra group mapping. As currently granted in
  `04_environment_schemas.sql`, each has RO on **its own** domain
  schema (`GOLD_BILLING` etc.) only. These roles are granted to
  `{ENV}_SYSADMIN` for management; they are not service users.

No role hierarchy links the domain reporters to the general
`REPORTER` — they are parallel, and access is set directly per schema.

> Note: domain reporters do **not** currently get RO on the shared
> `GOLD` schema. If DirectQuery models need conformed dimensions from
> `GOLD`, add a `GOLD` RO grant to each domain reporter in `04`.
