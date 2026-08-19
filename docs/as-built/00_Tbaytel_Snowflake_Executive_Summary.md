# Tbaytel Snowflake Platform — Executive Summary

**Client:** Tbaytel  **Prepared by:** Blend  **Date:** 19 August 2026
**Version:** 0.1 (Draft for internal review)

---

## What this is

Blend has designed and built the foundation of Tbaytel's Snowflake data platform: the environment structure, the security and access model, and the end-to-end pipeline that moves data from source systems to business-ready reporting. This summary states what is ready, what remains, and the decisions still needed. Three companion documents give the detail — Solution Architecture, Security & RBAC, and the ETL / Data Pipeline.

**Status in one line:** the platform is fully authored and reviewed, and validated against a development database. The client's own Snowflake account is not yet provisioned, so nothing is deployed to a Tbaytel environment — the build is *ready to execute* once the account exists.

---

## What has been built

**A scalable, secure environment structure.** A single Snowflake account (Business Critical edition, Azure Canada Central) hosts three isolated environments — Development, Test and Production — each as its own database in a proven medallion layout (Bronze → Silver → Gold, with per-domain Gold marts). Shared platform administration and security are kept in separate databases with separate ownership, so no single administrative duty implies another. Environments are stood up from repeatable scripts, so each is built identically.

**An enterprise access model tied to Microsoft Entra ID.** People sign in with corporate single sign-on and are placed into roles automatically from their Entra group membership; Snowflake owns what each role can do, Entra owns who is in it. Access follows least privilege, is aligned to Tbaytel's business domains, and separates human users from the service accounts that run the pipeline. A complete data-protection framework — data classification, automatic PII masking driven by column tags, and row-level access — is built and ready, so sensitive data is protected the moment it is tagged.

**A robust, automated data pipeline.** Ingestion is orchestrated by Azure Data Factory and executed by Snowflake procedures. It is configuration-driven — adding a new table is a configuration entry, not new code — and supports both file-based and database/data-share sources. Every load is tracked, logged and re-runnable, and a **quality gate** sits in front of the Gold layer: business-ready data is published only when every table has loaded successfully *and* the data passes automated quality checks. If either fails, the run stops before Gold and raises an alert.

**Cost control and monitoring from day one.** Compute is separated by workload so spend is attributable, warehouses cost nothing when idle, an account-level guard-rail caps credit consumption, and monitoring views report credit usage and access grants.

---

## Where the platform stands

| Area | Status |
|---|---|
| Account, platform and security structure | Prepared and reviewed |
| Role model, SSO/SCIM identity, policies | Prepared and reviewed (activations deferred until verified) |
| Data-protection framework (tags, masking, row access) | Built, ready for use once data is tagged |
| Medallion schemas and warehouses | Prepared and reviewed |
| End-to-end ETL procedures (Bronze → Silver) | Built and tested end-to-end on a development database |
| Quality gate + data-quality integration | Built (running against a stubbed quality service) |
| Gold refresh | Stubbed — pending the Gold data model |
| Client Snowflake account | Not yet provisioned |

---

## Decisions and dependencies still needed

None of these block the review; they are what turns the prepared build into a running production platform.

- **Provision the Tbaytel Snowflake account** (Business Critical, Canada Central) — everything else follows from this.
- **Tbaytel corporate network ranges** — required before the network security policy can be switched on; today it holds a safe placeholder and is intentionally inactive.
- **Private Link endpoint details** — the private-connectivity approach is decided; the specific endpoints are configured on the client account, after which public access is closed off.
- **Data-quality service (antFarm)** — the production service needs the billed account to run; it is currently stubbed so the pipeline and gate work end to end in the meantime.
- **Gold data model** — the Gold refresh step is a placeholder until the target Gold model is defined (to be built with Dynamic Tables or dbt).

---

## Recommended next steps

1. Provision the client account and execute the prepared account and environment scripts (Development first).
2. Obtain the Tbaytel network ranges and Private Link details; activate the network and authentication policies after verifying access.
3. Stand up antFarm on the billed account and connect the quality gate to the real service.
4. Define the Gold data model and implement the Gold refresh.

---

*Prepared by Blend for Tbaytel. Draft for internal review — not for external distribution in this version.*
