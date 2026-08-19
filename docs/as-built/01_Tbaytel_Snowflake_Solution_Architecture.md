# Tbaytel Snowflake — Solution Architecture

**Client:** Tbaytel  **Prepared by:** Blend  **Document type:** Solution Architecture (as-built)
**Version:** 0.1 (Draft for internal review)  **Date:** 19 August 2026
**Status:** Prepared and reviewed. The scripts described here are authored and dry-run validated; the Tbaytel Snowflake account is not yet provisioned, so nothing is deployed to a client environment yet. Language throughout is deliberately "prepared / ready to execute", not "live".

---

## 1. Purpose and scope

This document describes the Snowflake data platform designed and built for Tbaytel: the account topology, the database and schema layout, the role-based access model, virtual warehouses, data retention, integrations, and the end-to-end ingestion architecture. It is a standalone reference — it does not assume the reader has the earlier High-Level Design — and reflects the platform as it currently stands in the delivery repository.

Two companion documents cover specific areas in more depth: the *Security & RBAC* document (identity, policies, masking, network) and the *ETL / Data Pipeline* document (the bronze-to-gold procedures). Where those overlap with this document, this one gives the architectural summary and the companion gives the detail.

The build is organised into three layers, each with a clear lifecycle:

| Layer | Runs | Produces |
|---|---|---|
| **Account** | Once per Snowflake account | Account parameters, the shared platform database, the security database, integrations, identity federation |
| **Environment** | Once per environment (DEV, TEST, PROD) | The environment's admin and functional roles, warehouses, data database and schemas, service users |
| **Validation** | After each deployment | Object/grant inventory, edition capability probe, access-isolation tests |

---

## 2. Guiding principles

The design follows a small set of principles that explain most of the decisions below:

- **Separation of duties by database.** Platform administration, security/policy administration, and environment data each live in their own database with their own owning role, so no single duty implies another.
- **Environment isolation in one account.** DEV, TEST and PROD are separate databases inside a single Snowflake account, prefixed `DEV_` / `TEST_` / `PROD_`. Cross-environment access is designed to be impossible and is tested for.
- **Config over code.** Ingestion is metadata-driven — adding a table is a configuration row, not new code.
- **Least privilege, granted through roles.** Every schema is created with managed access and read-only / read-write / full database roles; functional roles receive only what they need.
- **Cost attributed per workload.** Each functional role has its own virtual warehouse, so credit consumption is attributable and cappable.
- **Recoverability drives retention.** Time Travel retention is set by how hard a layer is to rebuild, not by how important it feels.
- **Prepared, not activated.** Anything with a lockout or blast-radius risk (network policy, authentication policy activation) is scripted but left commented, to be enabled deliberately after verification.

---

## 3. Account topology

A **single Snowflake account** hosts all three environments, on **Business Critical** edition, in **Azure, Canada Central**. Business Critical is the edition floor for this engagement: it provides Tri-Secret Secure, Private Link, and the governance features (tags, masking policies, row-access policies) the design relies on. Environment separation is achieved with a **database per environment** rather than an account per environment, which keeps shared platform and security objects in one place while still isolating data.

```
Snowflake account (Business Critical, Azure Canada Central)
│
├── PLATFORM_DB      shared, environment-neutral platform administration
├── SECURITY_DB      account-wide security objects (owned by SECURITYADMIN)
│
├── DEV_DB           DEV environment data (medallion)
├── TEST_DB          TEST environment data (medallion)
├── PROD_DB          PROD environment data (medallion)
│
└── SNOWFLAKE        (system) ACCOUNT_USAGE, etc.
```

Account-level objects that are not database objects — warehouses, roles, resource monitors, network policies, security integrations — are created in the account layer and are shared across environments unless explicitly environment-prefixed.

---

## 4. Databases and schemas

### 4.1 PLATFORM_DB — shared platform administration

`PLATFORM_DB` is unprefixed (it exists once) and holds account-wide, **non-security** administrative content. It is read-only to the runtime pipelines, so a DEV run can never alter shared state. It is owned by `SYSADMIN`. Its schemas are all created *with managed access*, so grants are centralised through access roles.

| Schema | Purpose | Populated |
|---|---|---|
| `RBAC` | Provisioning procedures (`CREATE_DATABASE`, `DROP_DATABASE`, `CREATE_SCHEMA`, `DROP_SCHEMA`) | Yes |
| `DEPLOYMENT` | CI/CD: git repositories, change history, release log | Yes (git repos) |
| `MONITORING` | FinOps and access views over `SNOWFLAKE.ACCOUNT_USAGE` | Yes (3 views) |
| `FILE_FORMATS` | Shared, environment-independent file formats (e.g. Parquet) | Yes |
| `UTIL` | Shared helper functions (UDFs/UDTFs) | Container only |
| `REFERENCE` | Environment-neutral static reference/lookup data | Container only |
| `SHARED_WORKSPACE` | SQL scratch/collaboration area for admins and engineers | Container only |
| `ANTFARM` | Data-quality tooling (antFarm), account-wide, one instance for all environments | Planned (see section 8) |

`UTIL`, `REFERENCE` and `SHARED_WORKSPACE` are deliberately created as empty containers: the schema and its access roles are the contract, and objects appear only when there is something real to put in them.

`PLATFORM_WH` (X-Small) is the provisioning/deployment warehouse used to run the RBAC procedures and stand up environments.

### 4.2 SECURITY_DB — security and policy objects

`SECURITY_DB` is unprefixed and owned by `SECURITYADMIN`, so security administration is a distinct duty from platform administration. It organises objects by concern:

| Schema | Contents |
|---|---|
| `INBOUND_TRAFFIC` | Ingress network rules (Tbaytel corporate ranges, Blend, Azure Private Link) |
| `OUTBOUND_TRAFFIC` | Egress network rules for external access integrations |
| `INTERNAL_STAGE` | Network rules restricting internal stage access |
| `POLICIES` | Authentication, password, masking and row-access policies, governance tags |

The full security model is described in the *Security & RBAC* companion document.

### 4.3 {ENV}_DB — environment data (medallion)

Each environment database (`DEV_DB`, `TEST_DB`, `PROD_DB`) holds the environment's data in a medallion layout, plus an administration schema for run control. There are **19 schemas** per environment:

| Schema | Layer | Role in the pipeline |
|---|---|---|
| `ADM` | Administration | ETL configuration, run state and logging (see the ETL companion) |
| `RAW` | Landing (reserved) | Reserved for future semi-structured/JSON sources landed before Bronze; not used yet |
| `BRONZE` | Landing | Raw ingested data as loaded from the source extract, per batch |
| `BRONZE_HIST` | History | Append-only history of every Bronze load — the replay/lineage source |
| `SILVER` | Cleansed/conformed | Deduplicated, keyed, change-tracked business data |
| `GOLD` | Business-facing (shared) | Conformed dimensions and shared facts |
| `GOLD_{domain}` × 13 | Business-facing (domain marts) | One reporting mart per Tier-2 business domain |

The 13 domain marts follow the client's Data Domain Map (see section 5). Splitting Gold into a shared `GOLD` schema plus per-domain marts is what lets access be granted per domain without row-level filtering in Phase 1.

### 4.4 Object naming

- Environment data objects are prefixed by environment (`DEV_`, `TEST_`, `PROD_`).
- Shared/account objects are unprefixed (`PLATFORM_DB`, `SECURITY_DB`).
- Access roles created per schema follow `{DB}.{SCHEMA}_RO_AR` / `_RW_AR` / `_FULL_AR` (database roles).
- Functional roles are `{ENV}_{FUNCTION}`; their warehouses are `{ENV}_{FUNCTION}_WH`.
- Service users are `SVC_{ENV}_{SYSTEM}`.

---

## 5. Data domain model

The Gold domain marts implement the client's Data Domain Map — five Tier-1 domains and thirteen Tier-2 sub-domains:

| Tier-1 domain | Tier-2 domains (mart schemas) |
|---|---|
| Sales, Marketing & Comms | Marketing & Comms, Sales |
| Finance | Accounting, FP&A, Procurement |
| Operations & OPE | Customer Care, Field Operations |
| Human Resources | Payroll/People & Talent, Health & Safety, Occupational Health |
| Networks & Technology | IT & Security, Network Operations, Engineering |

Each Tier-2 domain maps to a `GOLD_{domain}` schema and a matching domain-reporter role. This is an ownership/stewardship map; it does not imply that all 13 marts carry data from day one. In Phase 1 only a subset of sources is ingested, so several marts will initially be empty schemas that exist so the access model and Entra mapping are complete.

---

## 6. Roles and warehouses (architecture view)

The access model is summarised here; the *Security & RBAC* document has the full hierarchy and grant detail.

**Admin roles per environment:** `{ENV}_SYSADMIN` (owns the environment database, runs the provisioning procedures) and `{ENV}_USERADMIN` (owns the functional roles), slotted under the built-in `SYSADMIN` / `USERADMIN`.

**Functional roles per environment (20):**

| Group | Roles |
|---|---|
| Human (4) | `TRANSFORMER`, `ANALYST`, `REPORTER`, `IT_GOVERNANCE` |
| Domain reporters (13) | one `REPORTER_{domain}` per Tier-2 domain |
| Service (3) | `DATA_LOADER` (ADF ingestion), `DEPLOYER` (CI/CD), `POWERBI` (Power BI service account) |

Human roles receive access through Microsoft Entra groups (see the Security companion). Service roles are used by key-pair `SVC_` users.

**Virtual warehouses:** each of the 20 functional roles has its own warehouse (`{ENV}_{ROLE}_WH`) so cost is attributable per workload. All are **X-Small**, `AUTO_SUSPEND = 60s`, `AUTO_RESUME = TRUE`, and created **initially suspended** — they cost nothing until first used and can be resized per workload later. `PLATFORM_WH` (X-Small) serves provisioning and deployment at the account level.

Sizing note: 20 warehouses per environment is a deliberate starting point for cost attribution, not a performance requirement. Consolidating the 13 domain reporters onto a shared reporting warehouse is a recommended optimisation once real query patterns are known (see section 12).

---

## 7. Data retention (Time Travel)

Retention is set per schema by how hard the content is to rebuild, since Time Travel is billed on churn × days and buys accident recovery, not history. Business Critical allows up to 90 days if policy later requires more.

| Schema(s) | Retention (days) | Rationale |
|---|---|---|
| `RAW`, `BRONZE` | 1 | Re-loadable from the source extract |
| `SILVER`, `GOLD`, all `GOLD_{domain}` | 7 | Rebuildable from the layer above; high churn on every load |
| `BRONZE_HIST`, `ADM` | 30 | Not rebuildable — the replay source and the run-state/audit log; losing either breaks rerun and lineage |

---

## 8. Provisioning and the access-role pattern

Environments are stood up through stored procedures in `PLATFORM_DB.RBAC` rather than hand-written DDL, so every environment is built identically:

- `CREATE_DATABASE` / `DROP_DATABASE` — create/remove an environment database (drop is guarded: it refuses if user schemas remain).
- `CREATE_SCHEMA` / `DROP_SCHEMA` — create a managed-access schema together with its three database access roles (`_RO_AR`, `_RW_AR`, `_FULL_AR`), wiring the standard hierarchy (RO ⊂ RW ⊂ FULL) and granting present-and-future object privileges to each.

The procedures run `EXECUTE AS CALLER`, so `{ENV}_SYSADMIN` owns the objects it creates. Functional roles are then granted the appropriate access role per schema (for example `TRANSFORMER` gets `FULL` on the medallion schemas, `ANALYST` gets `RO` on SILVER/GOLD). This access-role indirection means object grants are managed once, centrally, and future objects are covered automatically.

---

## 9. Integrations

The account layer prepares the integrations Tbaytel's platform needs. Each is scripted; credentials and endpoint-specific values are filled in at deployment.

| Integration | Purpose | Notes |
|---|---|---|
| **GitHub / Azure DevOps (git)** | Source control for CI/CD; git repositories under `PLATFORM_DB.DEPLOYMENT` | Deployment role reads the repos |
| **Azure Blob storage** | External stage for file-based ingestion (landing container) | Over Private Link on the billable account |
| **AWS S3 storage** | Optional storage integration | Prepared; free read-test path via public bucket |
| **Entra ID SSO (SAML2)** | Human sign-in | Gated until Private Link URLs are final |
| **Entra ID SCIM** | User/group provisioning | Separate network policy on the integration |
| **Email notification** | Outbound platform/DQ alerts (`EMAIL_INTEGRATION`) | Snowflake email restrictions apply (verified in-account recipients) |

Identity (SSO, SCIM) and the security model behind them are covered in the Security companion.

---

## 10. Ingestion and data-flow architecture

Ingestion is orchestrated by **Azure Data Factory (ADF)**; all in-database work is Snowflake stored procedures. Two source patterns are supported:

- **FILE** — the source system's data is extracted to Parquet (or other format) in the Azure Blob landing container, then loaded into Bronze via `COPY` through an external stage.
- **DATABASE** — data is read directly from another Snowflake database (an inbound data share or an ordinary database), with no staging.

The flow through the medallion layers is:

```
Source → (ADF extract to Blob, FILE only) → BRONZE → BRONZE_HIST → SILVER → [DQ gate] → GOLD / GOLD_{domain}
```

ADF creates a run, validates configuration, then calls one Snowflake procedure per table that chains landing → change-detection → history → Silver. After all tables, a single finalize call runs the pre-Gold quality gate and, if it passes, refreshes Gold. Run state and step-level logs are written to the `ADM` schema throughout. The full procedure inventory and behaviour are in the *ETL / Data Pipeline* companion; data quality runs through **antFarm** (deployed under `PLATFORM_DB.ANTFARM`), invoked inside the gate.

Gold is materialised as Snowflake **dynamic tables** with automatic scheduling disabled, so it is refreshed **only by the pipeline** (the finalize step) after the gate passes — never on a background clock that could publish un-gated Silver. Conformed calendar dimensions are static reference tables.

The per-domain marts (`GOLD_{domain}`) are exposed as **views over the shared `GOLD` objects**. Both the `GOLD` dynamic tables and the mart views are owned by `{ENV}_SYSADMIN`, so Snowflake's **ownership chain** lets a domain reporter read its mart with only `SELECT` on the view and no privilege on `GOLD`. Because the pipeline refreshes the dynamic tables as `{ENV}_DATA_LOADER`, that role holds `OPERATE` on them through its `FULL` access role — `CREATE_SCHEMA` grants `OPERATE` on dynamic tables to the read-write access role (see the Security & RBAC companion).

---

## 11. Deployment, CI/CD and infrastructure-as-code

Two administration models coexist by design:

- **Interim / manual provisioning** through `{ENV}_SYSADMIN` / `{ENV}_USERADMIN` and the RBAC procedures — used now to stand up environments.
- **CI/CD deployment** through `{ENV}_DEPLOYER` (used by `SVC_{ENV}_DEPLOY`), which runs schema/object deployment (schemachange or dbt) with `FULL` on the environment schemas and read access to the git repositories in `PLATFORM_DB.DEPLOYMENT`. It is deliberately separate from `TRANSFORMER` (interactive engineering) and from account-level infrastructure.
- **Terraform (future)** through a dedicated `TERRAFORM_ADMIN` role and `SVC_TERRAFORM` service user, which will eventually own account-level objects. The SQL scripts become the documented baseline at that point; the validation layer already produces the object/grant inventory that seeds the Terraform import list.

---

## 12. Cost management and monitoring

- **Account guard-rail:** a resource monitor (`RM_ACCOUNT_GUARD`) is assigned at account level. Trial settings use a lifetime credit cap; at handover this switches to a monthly quota agreed with FinOps, and to notify-only at the account level (an account-wide suspend in production would stop reporting, loads and CI/CD at once).
- **Per-workload warehouses:** every role has its own warehouse, so credits are attributable and can be capped individually where a hard stop is wanted.
- **Monitoring views** in `PLATFORM_DB.MONITORING`: `V_WAREHOUSE_CREDITS` (credits by warehouse), `V_CREDITS_BY_SERVICE` (daily credits by service type, including serverless — which no resource monitor caps), and `V_GRANTS_TO_ROLES` (live grant inventory, also used by validation and the Terraform import list).
- **Recommended next steps:** consolidate the 13 domain-reporter warehouses onto a shared reporting warehouse; set the production monthly quota with FinOps; schedule the governance coverage controls (see the Security companion) as tasks.

---

## 13. Validation

Every deployment is checked by the validation layer:

- **Edition capability probe** — run first on any new account; proves empirically that Time Travel beyond one day, tags, masking policies, row-access policies and tag-based policy attachment all work (i.e. the account really is Business Critical). Every statement fails on Standard edition.
- **State inventory** — objects, roles, grants and ownership drift; also the basis for the Terraform import list.
- **Access-isolation tests** — negative tests that must fail (e.g. a DEV role touching PROD), positive controls, and evidence capture. These need more than one environment to be meaningful and are run immediately after a deployment.

---

## 14. Current status and open items

**Prepared and reviewed:** account layer (parameters, `PLATFORM_DB`, `SECURITY_DB`, RBAC procedures, monitoring, integrations, identity), environment layer (admin + functional roles, warehouses, database, 19 schemas, service users), validation layer, and the full bronze-to-gold ETL procedure set. All are authored and dry-run validated in the delivery repository.

**Not yet done / pending decisions:**

- The Tbaytel Snowflake account is not yet provisioned — nothing is deployed to a client environment.
- **Network policy IP ranges** — Tbaytel corporate ranges not yet supplied; the ingress policy carries a placeholder and must not be activated until the real ranges are in.
- **Private Link** — decided; endpoint identifiers to be filled in on the billable account, after which public access is blocked.
- **antFarm on Snowpark Container Services** — requires the billed account (compute pools are unavailable on trial); currently stubbed.
- **Production Gold model** — the Gold refresh mechanism is built (dynamic tables, pipeline-only refresh) and demonstrated on a sample star; the full Gold model across the business domains, and the `GOLD_{domain}` mart views over it, are still to be built.

---

*Prepared by Blend for Tbaytel. Draft for internal review — not for external distribution in this version.*
