# Tbaytel Snowflake — Account Setup

SQL scripts to stand up the Snowflake account and its environments.
Organized by **lifecycle**, not by object type:

- **`account/`** — run **once per Snowflake account**. Account-level
  objects that are not environment-specific and are never prefixed
  with `DEV_/TEST_/PROD_`.
- **`environment/`** — run **once per environment**. Set `ENV_ABBR`
  at the top of each file (`DEV_`, `TEST_`, `PROD_`) and run
  the whole file. To add an environment, re-run this folder with a
  different `ENV_ABBR`.

> Standards v0.7 §4 defines **three** environments — DEV, TEST, PROD —
> in one account. Use those three prefixes only. Anything called UAT in
> a ticket is TEST here.

> Scripts are templates. Review before running. Run each file as a
> role that can assume `ACCOUNTADMIN`/`SECURITYADMIN`/`SYSADMIN`
> (the files switch roles with `USE ROLE` as needed).

## Run order

### 1. account/ (once per account)

| # | File | Creates |
|---|------|---------|
| 01 | `01_account_parameters.sql` | Account params (`TIMEZONE`, `STATEMENT_TIMEOUT_IN_SECONDS`, `ABORT_DETACHED_QUERY`, `PERIODIC_DATA_REKEYING`) + guard-rail resource monitor `RM_ACCOUNT_GUARD` |
| 02 | `02_platform_database.sql` | `PLATFORM_WH` + `PLATFORM_DB` + schemas (`RBAC`, `DEPLOYMENT`, `MONITORING`, `UTIL`, `REFERENCE`, `FILE_FORMATS`, `SHARED_WORKSPACE`) |
| 03 | `03_platform_rbac_procedures.sql` | Provisioning procs in `RBAC` (`CREATE_DATABASE`, `DROP_DATABASE`, `CREATE_SCHEMA`, `DROP_SCHEMA`) |
| 04 | `04_platform_objects.sql` | `MONITORING` views over `ACCOUNT_USAGE`: `V_WAREHOUSE_CREDITS`, `V_CREDITS_BY_SERVICE` (incl. serverless), `V_GRANTS_TO_ROLES` |
| 05 | `05_security_database.sql` | `SECURITY_DB` + schemas (`INBOUND_TRAFFIC`, `OUTBOUND_TRAFFIC`, `INTERNAL_STAGE`, `POLICIES`); ownership to SECURITYADMIN |
| 06 | `06_security_network_rules.sql` | Ingress network rules (Tbaytel, Blend, Azure Private Link) in `INBOUND_TRAFFIC`. Entra SCIM is **not** here — it needs all Azure public ranges and gets its own policy on the integration in `17` |
| 07 | `07_security_network_policy.sql` | Account `INGRESS_POLICY` referencing the rules + **guarded** activation |
| 08 | `08_security_auth_password_policies.sql` | Account password + authentication policies (+ SSO-users policy) in `POLICIES` + **guarded** activation |
| 09 | `09_security_tags_masking_row_access.sql` | Governance tags (`DATA_CLASSIFICATION`, `PII_TYPE`), tag-driven masking policies, `PII_READER` exemption role, `RAP_DOMAIN` row-access policy + mapping table. **Deployable as-is** — nothing is masked until a column is tagged |
| 10 | `10_terraform_admin_role.sql` | `TERRAFORM_ADMIN` account role + global grants |
| 11 | `11_terraform_service_user.sql` | `SVC_TERRAFORM` service user (key-pair) |
| 12 | `12_human_access.sql` | Reference: people come via SSO/SCIM; optional break-glass admin |
| 13 | `13_integration_git_github.sql` | GitHub API integration + git repository (public / OAuth / PAT) |
| 14 | `14_integration_git_azure_devops.sql` | Azure DevOps API integration + PAT secret + git repository |
| 15 | `15_integration_storage_azure_blob.sql` | Azure Blob storage integration |
| 16 | `16_integration_storage_s3.sql` | AWS S3 storage integration (+ free public-bucket test) |
| 17 | `17_identity_scim_provisioning.sql` | Entra SCIM: `AAD_PROVISIONER` role + `AAD_PROVISIONING` integration (token generated at runtime) |
| 18 | `18_identity_sso_saml2.sql` | Entra SSO (SAML2) `ENTRAID_SSO` — **gated** template; run only after Private Link URLs are final |

Groups: **platform** (02–04) · **security** (05–09) · **terraform + human access** (10–12) · **integrations** (13–16) · **identity federation / Azure** (17–18).

> Azure-integration prep (from the integration guides/runbooks): `01` params + monitor, the Entra SCIM network rule in `06` (also added to `INGRESS_POLICY` in `07`), the SSO-users policy in `08`, `ENTRA_GROUP_ROLE_MAP` in `04`, and `17`/`18`. SSO (`18`) stays gated until the Private Link URLs are final — configuring it earlier forces the SAML IdP re-registration rework.

> Security (05–09) is owned by **SECURITYADMIN**, keeping security a distinct
> duty from platform admin (SYSADMIN / `PLATFORM_DB`). All `ALTER ACCOUNT SET`
> activations (network policy, auth/password policy) are **commented out** —
> read the lockout warnings and verify access before enabling them.

> `PLATFORM_DB` holds account-wide **non-security** admin content only (security
> objects → `SECURITY_DB`, per-environment data → `{ENV}_DB`). Only schemas with
> real content are populated — `RBAC` (procedures, from `03`) and `MONITORING`
> (views, from `04`). `UTIL`, `REFERENCE` and `SHARED_WORKSPACE` exist as empty
> containers by design; the schema and its access roles are the contract, and
> objects appear when there is something real to put in them.

> `PLATFORM_DB.SHARED_WORKSPACE` is a SQL scratch/collaboration schema. It is
> **not** the Snowsight **Workspaces** feature, which holds per-user *files*
> rather than database objects — a confusion that surfaced on TBAY-372. The
> name matches Standards v0.7; the distinction is documented in `02` and `04`.

Integration notes: only **Git** has a truly free/public test path (a
public repo needs no credentials; your personal repo works via OAuth or
PAT if private). **S3** can be read-tested for free via a credential-less
stage on a public bucket, but the storage *integration* itself needs your
own AWS IAM role. **Azure Blob** and **Azure DevOps** have no public
option — they need your own tenant/org plus credentials.

### 2. environment/ (per environment — set `ENV_ABBR`)

| # | File | Creates |
|---|------|---------|
| 01 | `01_environment_admin_roles.sql` | `{ENV}_SYSADMIN`, `{ENV}_USERADMIN`, their account grants, **and platform provisioning access** (usage on `PLATFORM_WH`/`PLATFORM_DB`/`RBAC`/procs) |
| 02 | `02_environment_functional_roles_and_warehouses.sql` | 9 functional roles incl. `DEPLOYER` (CI/CD) + one warehouse each; `DEPLOYER` also gets read on the git repos in `PLATFORM_DB.DEPLOYMENT` |
| 03 | `03_environment_database.sql` | `{ENV}_DB` (via `CREATE_DATABASE`) |
| 04 | `04_environment_schemas.sql` | 9 medallion schemas + retention tiers + RO/FULL role grants |
| 05 | `05_environment_service_users.sql` | `SVC_{ENV}_ADF` (`{ENV}_DATA_LOADER`), `SVC_{ENV}_POWERBI` (`{ENV}_REPORTER`), `SVC_{ENV}_DEPLOY` (`{ENV}_DEPLOYER`) — all key-pair |

### 3. validation/ (`00` first, the rest after each deployment)

| # | File | Purpose |
|---|------|---------|
| 00 | `00_edition_capability_probe.sql` | **Run first on any new account.** Proves empirically that Time Travel > 1 day, tags, masking policies, row access policies and tag-based policy attachment all work — i.e. that the account is Enterprise or higher. Every statement fails on Standard. Creates and drops a throwaway database. `SHOW ORGANIZATION ACCOUNTS` returns no rows on a trial, so it cannot be used to read the edition. |
| 01 | `01_validate_state.sql` | Object/role/grant inventory + ownership drift check; also the basis for generating the Terraform `imports.tf` list |
| 02 | `02_validate_access_isolation.sql` | Negative access tests: cross-environment grant scan, statements that **must fail** per role, positive controls, evidence capture |

`01` answers *was everything created?*; `02` answers *is it actually isolated?*
An inventory can look perfect while one stray grant lets DEV write PROD. `02`
needs more than one environment to be meaningful, and its Part 2/3 are
real-time — use them straight after a deployment, before `ACCOUNT_USAGE`
catches up. Together they cover TBAY-372 AC4–AC8 and the test evidence in AC10.

Run them after the account and environment layers and save the output with the
release. `01` is read-only (`SHOW` + `ACCOUNT_USAGE` queries); note `ACCOUNT_USAGE`
grant views can lag by up to ~2 hours. `02` is read-only in Part 1 but creates
and drops a throwaway table in Parts 2–3, so it is not safe to run blind — read
it first.

## Key design points

- **Two admin models coexist:** the `{ENV}_SYSADMIN/{ENV}_USERADMIN`
  roles (manual/interim provisioning) and `TERRAFORM_ADMIN` (future
  CI/CD). Terraform will eventually own account-level objects; the SQL
  scripts become documentation at that point.
- **Human users are not created in SQL** — Entra SSO + SCIM provision
  people and map Entra groups to functional roles. Only `SVC_` users
  are created in SQL (key-pair auth).
- **Retention tiers** are set per schema in `04` — adjust to policy.
- **Deployment role:** `{ENV}_DEPLOYER` (used by `SVC_{ENV}_DEPLOY`) runs CI/CD (schemachange/dbt) — FULL on the env schemas + read on the git repos in `PLATFORM_DB.DEPLOYMENT`, with its own warehouse. Kept separate from `TRANSFORMER` (interactive engineering) and `TERRAFORM_ADMIN` (account-level infra).

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
