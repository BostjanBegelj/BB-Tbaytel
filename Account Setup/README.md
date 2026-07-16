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
| 01 | `01_account_parameters.sql` | Account params (`TIMEZONE`, `STATEMENT_TIMEOUT_IN_SECONDS`, `ABORT_DETACHED_QUERY`, `PERIODIC_DATA_REKEYING`) + guard-rail resource monitor `RM_ACCOUNT_GUARD` |
| 02 | `02_platform_database.sql` | `PLATFORM_WH` + `PLATFORM_DB` + schemas (`RBAC`, `DEPLOYMENT`, `MONITORING`, `UTIL`, `REFERENCE`, `SHARED_WORKSPACE`) |
| 03 | `03_platform_rbac_procedures.sql` | Provisioning procs in `RBAC` (`CREATE_DATABASE`, `DROP_DATABASE`, `CREATE_SCHEMA`, `DROP_SCHEMA`) |
| 04 | `04_platform_objects.sql` | Dummy scaffold objects + sample rows per PLATFORM_DB schema (incl. `ENV_CONFIG`, `ENTRA_GROUP_ROLE_MAP`) |
| 05 | `05_security_database.sql` | `SECURITY_DB` + schemas (`INBOUND_TRAFFIC`, `OUTBOUND_TRAFFIC`, `INTERNAL_STAGE`, `POLICIES`); ownership to SECURITYADMIN |
| 06 | `06_security_network_rules.sql` | Ingress network rules (Tbaytel, In516ht, Azure Private Link, Entra-ID SCIM) in `INBOUND_TRAFFIC` |
| 07 | `07_security_network_policy.sql` | Account `INGRESS_POLICY` referencing the rules + **guarded** activation |
| 08 | `08_security_auth_password_policies.sql` | Account password + authentication policies (+ SSO-users policy) in `POLICIES` + **guarded** activation |
| 09 | `09_security_masking_row_access_templates.sql` | Masking / row-access policy templates (do not run as-is) |
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
> objects → `SECURITY_DB`, per-environment data → `{ENV}_DB`). The objects in
> `04` are dummy placeholders illustrating the intended content of each schema.

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

### 3. validation/ (run after each deployment)

| # | File | Purpose |
|---|------|---------|
| 01 | `01_validate_state.sql` | Object/role/grant inventory + ownership drift check; also the basis for generating the Terraform `imports.tf` list |

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
