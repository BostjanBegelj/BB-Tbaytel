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
| 06 | `06_integration_git_github.sql` | GitHub API integration + git repository (public / OAuth / PAT) |
| 07 | `07_integration_git_azure_devops.sql` | Azure DevOps API integration + PAT secret + git repository |
| 08 | `08_integration_storage_azure.sql` | Azure Blob storage integration |
| 09 | `09_integration_storage_s3.sql` | AWS S3 storage integration (+ free public-bucket test) |
| 10 | `10_security_db.sql` | `SECURITY_DB` + schemas (`INBOUND_TRAFFIC`, `OUTBOUND_TRAFFIC`, `INTERNAL_STAGE`, `POLICIES`); ownership to SECURITYADMIN |
| 11 | `11_network_rules.sql` | Ingress network rules (Tbaytel, In516ht, Azure Private Link) in `INBOUND_TRAFFIC` |
| 12 | `12_network_policy.sql` | Account `INGRESS_POLICY` referencing the rules + **guarded** activation |
| 13 | `13_auth_password_policies.sql` | Account password + authentication policies in `POLICIES` + **guarded** activation |
| 14 | `14_masking_row_access_templates.sql` | Masking / row-access policy templates (do not run as-is) |

> Security (10–14) is owned by **SECURITYADMIN**, keeping security a distinct
> duty from platform admin (SYSADMIN / `PLATFORM_DB`). All `ALTER ACCOUNT SET`
> activations (network policy, auth/password policy) are **commented out** —
> read the lockout warnings and verify access before enabling them.

Integration notes: only **Git** has a truly free/public test path (a
public repo needs no credentials; your personal repo works via OAuth or
PAT if private). **S3** can be read-tested for free via a credential-less
stage on a public bucket, but the storage *integration* itself needs your
own AWS IAM role. **Azure Blob** and **Azure DevOps** have no public
option — they need your own tenant/org plus credentials.

### 2. environment/ (per environment — set `ENV_ABBR`)

| # | File | Creates |
|---|------|---------|
| 01 | `01_env_admin_roles.sql` | `{ENV}_SYSADMIN`, `{ENV}_USERADMIN`, their account grants, **and platform provisioning access** (usage on `PLATFORM_WH`/`PLATFORM_DB`/`RBAC`/procs) |
| 02 | `02_functional_roles_and_warehouses.sql` | 8 functional roles + one warehouse each |
| 03 | `03_environment_database.sql` | `{ENV}_DB` (via `CREATE_DATABASE`) |
| 04 | `04_environment_schemas.sql` | 9 medallion schemas + retention tiers + RO/FULL role grants |
| 05 | `05_env_service_users.sql` | `SVC_{ENV}_ADF` (role `{ENV}_DATA_LOADER`) and `SVC_{ENV}_POWERBI` (role `{ENV}_REPORTER`) — both key-pair |

### 3. validation/ (run after each deployment)

| # | File | Purpose |
|---|------|---------|
| 00 | `00_validate_state.sql` | Object/role/grant inventory + ownership drift check; also the basis for generating the Terraform `imports.tf` list |

Run it after the account and environment layers and save the output with the
release. Read-only (`SHOW` + `ACCOUNT_USAGE` queries); note `ACCOUNT_USAGE`
grant views can lag by up to ~2 hours.

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
