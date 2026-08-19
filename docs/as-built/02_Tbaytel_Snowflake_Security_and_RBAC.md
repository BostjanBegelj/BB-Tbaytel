# Tbaytel Snowflake — Security & RBAC

**Client:** Tbaytel  **Prepared by:** Blend  **Document type:** Security & Access Model (as-built)
**Version:** 0.1 (Draft for internal review)  **Date:** 19 August 2026
**Status:** Prepared and reviewed. Objects are authored and dry-run validated; the Tbaytel account is not yet provisioned. All account-level activations that carry a lockout risk (network policy, authentication policy) are scripted but left inactive, to be enabled deliberately after verification.

---

## 1. Purpose and scope

This document describes the security and access-control model of the Tbaytel Snowflake platform: the role hierarchy, how people and services authenticate, how identities are provisioned from Microsoft Entra ID, network controls, and the data-protection framework (classification tags, masking, row access). It is standalone — it repeats the context needed to read it without the architecture document.

The design goal is an enterprise-grade, least-privilege model where **Snowflake owns roles and privileges, Microsoft Entra owns membership**, security administration is a duty distinct from platform administration, and every control that could lock users out is enabled only after it has been verified safe.

---

## 2. Security design principles

- **Separation of duties.** Security objects live in their own database (`SECURITY_DB`) owned by `SECURITYADMIN`; platform objects live in `PLATFORM_DB` owned by `SYSADMIN`; environment data lives in `{ENV}_DB` owned by `{ENV}_SYSADMIN`. A policy administrator role (`POLICY_ADMIN`) sits beneath `SECURITYADMIN` for day-to-day policy work.
- **Least privilege through access roles.** Every schema is created *with managed access* and gets three database access roles — read-only, read-write, full. Functional roles receive only the access role they need.
- **Two-tier identity.** Entra groups are synced into Snowflake as roles that hold no privileges; each is granted the matching Snowflake functional role. Entra manages who is in a group; Snowflake manages what a role can do.
- **Strong authentication.** Humans use Entra SSO (SAML2); service accounts use key-pair; passwords survive only as a break-glass path under a strict policy.
- **Fail-safe activation.** Network and authentication policies are scripted but not activated until the deployer has verified their own access is preserved.
- **Tag-driven data protection.** Masking follows a tag on a column — a steward tags a column and the mask applies automatically, with no table DDL change.

---

## 3. Role model

### 3.1 The two tiers

Snowflake is the system of record for roles and privileges. Microsoft Entra ID is the system of record for *membership*. The two are joined by a simple, once-only wiring:

1. SCIM provisions each Entra group into Snowflake as a **synced role** that holds no privileges.
2. Each synced role is **granted the matching functional role** (one grant per group, once).

The result: a person added to an Entra group inherits the synced role, which inherits the functional role, which carries the actual privileges. Membership changes happen entirely in Entra; access definitions stay in Snowflake (and in git/Terraform). The functional roles are never created or owned by SCIM — importantly, `{ENV}_SYSADMIN` must exist before Entra is wired up, because it owns the environment database and runs the provisioning procedures.

This was a deliberate choice over letting SCIM create and own the functional roles, which would have made `{ENV}_SYSADMIN` depend on Entra and could not stand up an environment without a tenant.

### 3.2 Account-level roles

| Role | Purpose |
|---|---|
| `SECURITYADMIN` (built-in) | Owns `SECURITY_DB`; holds `MANAGE GRANTS`; administers the security model |
| `POLICY_ADMIN` | Creates and manages tags, masking, row-access, password and authentication policies in `SECURITY_DB.POLICIES`; granted to `SECURITYADMIN` |
| `PII_READER` | The masking-exemption role — the only role that sees unmasked PII (see section 7). Deliberately *not* in the admin hierarchy, so administering the exemption does not imply being exempt |
| `AAD_PROVISIONER` | The role SCIM runs as; can create users and roles; used only by the SCIM integration |
| `TERRAFORM_ADMIN` | Future IaC ownership of account-level objects (with `SVC_TERRAFORM`) |
| `ANTFARM_*` (planned) | Data-quality service and application roles (see the ETL/DQ companion); account-wide |

### 3.3 Environment admin roles

Per environment, slotted under the built-in hierarchy:

- `{ENV}_SYSADMIN` — owns `{ENV}_DB`, creates databases and warehouses, runs the RBAC provisioning procedures. Granted to built-in `SYSADMIN`.
- `{ENV}_USERADMIN` — creates and owns the environment's functional roles. Granted to built-in `USERADMIN`.

### 3.4 Environment functional roles (20 per environment)

**Human roles (4)** — each reached through an Entra group:

| Role | Access |
|---|---|
| `{ENV}_TRANSFORMER` | Data engineering / transformation — `FULL` on the medallion schemas (ADM, RAW, BRONZE, BRONZE_HIST, SILVER, GOLD, all marts) |
| `{ENV}_ANALYST` | Interactive analysis — `RO` on ADM, SILVER, GOLD and all marts |
| `{ENV}_REPORTER` | Reporting on the shared `GOLD` schema only |
| `{ENV}_IT_GOVERNANCE` | Governance/monitoring — `RO` across the medallion layers |

**Domain reporters (13)** — one `{ENV}_REPORTER_{domain}` per Tier-2 domain, each with `RO` on its own `GOLD_{domain}` mart and nothing else. Reached through Entra groups.

**Service roles (3)** — used by key-pair `SVC_` users, no Entra group:

| Role | Used by | Access |
|---|---|---|
| `{ENV}_DATA_LOADER` | `SVC_{ENV}_ADF` (ingestion) | `FULL` on the medallion schemas |
| `{ENV}_DEPLOYER` | `SVC_{ENV}_DEPLOY` (CI/CD) | `FULL` on the environment schemas + read on the git repos |
| `{ENV}_POWERBI` | `SVC_{ENV}_POWERBI` (reporting service) | `RO` on `GOLD` and every `GOLD_{domain}` mart |

### 3.5 The reporter model (three distinct things)

A common point of confusion, resolved by design:

- `{ENV}_POWERBI` is the **Power BI service account** role, with broad read across `GOLD` and every domain mart so one service account can refresh all reports. This breadth is intentional.
- `{ENV}_REPORTER` is a **human** role, read on the shared `GOLD` schema only.
- `{ENV}_REPORTER_{domain}` are **human** roles, one per domain mart.

Access is **additive**: a person can hold `{ENV}_REPORTER` plus one or more domain-reporter roles at once. This requires `DEFAULT_SECONDARY_ROLES = 'ALL'` on the user (see section 5.3). There is no hierarchy linking domain reporters to `{ENV}_REPORTER` — they are parallel, and access is granted per schema. Domain reporters do not get access to the shared `GOLD` schema; conformed dimensions reach a mart as **views over `GOLD`** relying on Snowflake's ownership chain, so the reporter needs `SELECT` on the view but no privilege on `GOLD` (the Gold table and the view must be created by the same role — `{ENV}_DEPLOYER`).

### 3.6 The access-role pattern

Each schema is created with three database roles that carry the actual object privileges:

- `{DB}.{SCHEMA}_RO_AR` — read (SELECT/USAGE, present and future objects)
- `{DB}.{SCHEMA}_RW_AR` — read + write (inherits RO)
- `{DB}.{SCHEMA}_FULL_AR` — full (inherits RW; granted to `{ENV}_SYSADMIN`)

Functional roles are granted the access role, never the object directly. Object grants are therefore defined once per schema and cover future objects automatically. Ownership is not granted on future objects (that breaks some object types); objects are created by a functional role instead.

---

## 4. Identity providers and provisioning

Microsoft Entra ID is the identity provider. Three authentication paths are used:

- **SAML SSO** — for humans.
- **SCIM** — for provisioning users and groups.
- **Key-pair** — for service accounts.

### 4.1 SSO (SAML2)

An `ENTRAID_SSO` SAML2 security integration federates human sign-in to Entra. It is scripted but **gated** (left commented) until Azure Private Link is live and the `.privatelink` URLs are final — creating it against non-final URLs forces a SAML IdP re-registration rework later. MFA for SSO users is enforced by Entra Conditional Access, so Snowflake-side MFA on external authentication is left off to avoid double prompts.

### 4.2 SCIM provisioning

An `AAD_PROVISIONING` SCIM integration (running as `AAD_PROVISIONER`) provisions users and group roles from Entra. The integration and role are Azure-independent and prepared ahead; only the provisioning **token** is generated at runtime (valid ~6 months — it must be regenerated before expiry or provisioning silently stops).

SCIM has no private path: it must point at the **public** account endpoint even when Private Link is in use, and Snowflake currently requires *all* Azure public-cloud ranges to be allowed for it. Those ranges do not belong in the account-wide ingress policy, so SCIM gets its **own network policy attached to the integration**, which overrides the account policy for that integration only. Azure publishes the ranges as a weekly JSON download, so this needs a refresh process rather than a one-off paste.

### 4.3 Entra group → role grants

The synced roles are connected to the functional roles once, after SCIM has provisioned the groups and every environment is built. The grant list covers **59 Entra groups**: 19 human functional roles × 3 environments (57) plus the two account-wide roles `POLICY_ADMIN` and `PII_READER`. The grants are generated from the catalogue (`SHOW ROLES`) rather than typed, because the synced role name matches the Entra group name verbatim and may be a quoted, case-sensitive identifier. Only human roles get an Entra group; service roles are used by `SVC_` users and are excluded. Entra group naming is owned on the Azure side.

### 4.4 Service users

Per environment, three key-pair service users are created (`TYPE = SERVICE`, no password): `SVC_{ENV}_ADF` (role `{ENV}_DATA_LOADER`), `SVC_{ENV}_POWERBI` (role `{ENV}_POWERBI`), and `SVC_{ENV}_DEPLOY` (role `{ENV}_DEPLOYER`). Public keys are registered at deployment; **private keys are never stored in scripts or source control** — they live in the appropriate secret store (Azure Key Vault for ADF, the gateway/service credential store for Power BI, the CI/CD secret store for deployment).

---

## 5. Authentication and password policy

### 5.1 Password policy

`ACCOUNT_PASSWORD_POLICY` (in `SECURITY_DB.POLICIES`) sets the account default wherever password authentication is still allowed: minimum length 14, at least one upper/lower/numeric/special character, 90-day maximum age, 5 retries, 30-minute lockout, and a password history of 5.

### 5.2 Authentication policy

`ACCOUNT_AUTH_POLICY` defines the allowed methods. During cutover it includes `('SAML', 'KEYPAIR', 'PASSWORD')` so current admins are not locked out before SSO is verified end-to-end; after cutover it tightens to `('SAML', 'KEYPAIR')`, with the break-glass user given its own user-level policy allowing password + MFA. A separate `SSO_USERS_AUTH_POLICY` exists for SSO users (MFA enforced by Entra, not by Snowflake).

Both the authentication and password account defaults are **left inactive** in the scripts — they are activated only after SSO works for at least one admin and all service users have keys registered, to avoid a lockout.

### 5.3 Default secondary roles

Users must be provisioned with `DEFAULT_SECONDARY_ROLES = 'ALL'` or only one role is active per session, which breaks the additive reporting model and Power BI DirectQuery (which cannot switch roles mid-session). This is set as the SCIM attribute `defaultSecondaryRoles = 'ALL'` on the **Entra side**, not with `ALTER USER` (which is unreliable for SCIM-managed users — a full sync can reset it). It is verified on the first provisioned user with `DESC USER`.

---

## 6. Network security

Network controls are organised in `SECURITY_DB` and applied through an account ingress policy.

### 6.1 Ingress network rules (`SECURITY_DB.INBOUND_TRAFFIC`)

| Rule | Type | Contents |
|---|---|---|
| `TBAYTEL_NETWORK` | IPv4 | Tbaytel corporate ranges — **currently a `0.0.0.0/0` placeholder** |
| `BLEND_NETWORK` | IPv4 | Blend delivery-team ranges |
| `AZURE_PRIVATE_LINK` | AzureLinkID | Private endpoint(s) from the Tbaytel VNet — placeholder identifiers |
| `BLOCK_PUBLIC_ACCESS` (prepared) | IPv4 | For the *blocked* list, to force traffic through Private Link once it is live |

### 6.2 Account ingress policy

`INGRESS_POLICY` references the Tbaytel and Blend rules. It is **not activated**: activating it while `TBAYTEL_NETWORK` still holds `0.0.0.0/0` would give no protection while making the account look governed — worse than not activating. It must be enabled only after the real Tbaytel ranges are supplied and the deployer confirms their own IP is allowed. When Private Link is verified, public access is forced off by adding `BLOCK_PUBLIC_ACCESS` to the *blocked* list (an AzureLinkID rule in the allowed list alone does not block public traffic).

ADF, Power BI and CI/CD are not given their own ingress rules — their public source ranges are large, weekly-changing Microsoft service tags. They reach Snowflake over Private Link or from the corporate network, both already covered. If a public path is ever unavoidable, a policy is scoped to that specific service user rather than widening the account policy.

### 6.3 Private Link

Private Link is decided for this engagement. Client, BI and ADF traffic arrives over the Microsoft backbone from the Tbaytel VNet. Endpoint identifiers are filled in on the billable account, after which the block-public rule is enabled.

---

## 7. Data protection: classification, masking, row access

The governance framework is **built and deployable now, before the Gold model exists**, because nothing in it references a specific column — masking is driven by tags. Running it on an empty account is safe: no column is tagged, so nothing is masked until a steward tags something.

### 7.1 Governance tags

Two tags in `SECURITY_DB.POLICIES`:

- `DATA_CLASSIFICATION` (`PUBLIC` / `INTERNAL` / `CONFIDENTIAL` / `RESTRICTED`) — an inventory dimension applied at table or column level. It drives no enforcement on its own.
- `PII_TYPE` (`NAME`, `EMAIL`, `PHONE`, `ADDRESS`, `DOB`, `GOVERNMENT_ID`, `PAYMENT_CARD`, `ACCOUNT_NUMBER`, `IP_ADDRESS`, `GEOLOCATION`) — **column-level only**, and what actually drives masking.

### 7.2 Tag-driven masking

Five masking policies (one per physical data type: STRING, NUMBER, FLOAT, DATE, TIMESTAMP_NTZ) are bound once to the `PII_TYPE` tag. From then on, any column tagged with a `PII_TYPE` value is masked automatically without touching the table DDL. The policies branch on the tag value to keep partial forms useful for support and reconciliation — email domain preserved, last four digits of phone/account/card, dates truncated to year — while hiding the identifying value. Only the `PII_READER` role sees unmasked values; everyone else, including `ACCOUNTADMIN`, sees the masked value.

Two rules matter because breaking either fails **silently**, and both are enforced by the design plus periodic controls:

1. `PII_TYPE` is a column-level tag only — setting it on a table would mass-mask every string column.
2. A tag-bound policy only attaches where the column type matches a policy signature — a tagged column of an unsupported type stays readable. A coverage query finds exactly this case and is run after every Gold release.

`PII_READER` is granted structurally only to the pipeline **service** roles (`DATA_LOADER`, `DEPLOYER`) — because masking applies on read, a transform reading masked Silver would write masked Gold. `{ENV}_TRANSFORMER` (a human role) is deliberately excluded, so data engineers are not silently given unmasked PII; all human access to unmasked PII, including for engineers, is granted through the Entra group mapped to `PII_READER` as an explicit, reviewable assignment.

### 7.3 Row access

A row-access policy (`RAP_DOMAIN`) and a mapping table (`ROW_ACCESS_MAP`) are provided but **not attached to any table yet**. Phase 1 separates reporting domains by schema and role, so row-level filtering is not required. The mechanism exists for the day a shared table must serve several domains from one set of rows; adding a domain is then a row in the mapping table, not a policy change. Column masking and row visibility are independent controls — `PII_READER` is deliberately not a row-access bypass.

### 7.4 Ongoing controls

Periodic controls (queries provided, to be scheduled as tasks once Gold exists) detect the dangerous silent states: tagged columns whose data type has no matching policy signature; columns classified `RESTRICTED` but carrying no `PII_TYPE`; `PII_TYPE` set at table level; and current `PII_READER` membership for review.

---

## 8. Email notification security constraint

Outbound platform and DQ email uses an account-level `EMAIL_INTEGRATION`. Snowflake email is not an open SMTP relay: recipients must be the **verified email address of a Snowflake user in this account**, and, where `ALLOWED_RECIPIENTS` is set (max 50 addresses), be on that list. Business distribution lists therefore do not work directly — fan-out is routed in Exchange, not Snowflake. The DQ procedures that send mail run `EXECUTE AS CALLER`, so the executing role (`{ENV}_DATA_LOADER` for ADF, `{ENV}_SYSADMIN` for manual/test) needs `USAGE` on the integration.

---

## 9. Validation and evidence

The access model is verified after deployment by the validation layer: an object/role/grant inventory with ownership-drift detection, and negative access-isolation tests — statements that **must fail** (for example a DEV role reaching PROD), positive controls, and captured evidence. These require more than one environment to be meaningful and are run immediately after a deployment, before `ACCOUNT_USAGE` catches up.

---

## 10. Current status and open items

**Prepared and reviewed:** the full role hierarchy (admin, functional, access, account-level), SCIM and SSO integrations, password/authentication policies, network rules and ingress policy, and the tag/masking/row-access framework. All authored and dry-run validated; nothing activated.

**Open / pending:**

- **Tbaytel corporate IP ranges** — not yet supplied; ingress policy cannot be activated until they replace the placeholder.
- **SSO values and Private Link URLs** — SSO integration stays gated until these are final.
- **SCIM token and Entra group names** — generated/confirmed at provisioning; group naming owned Azure-side.
- **Network/auth policy activation** — deliberately deferred until access is verified.
- **Occupational Health** (special-category health data) — role and schema exist but no access is granted and no data is loaded until Tbaytel's privacy function signs off.
- **`PII_READER` and tag-application grants** — applied per environment after its roles exist.

---

*Prepared by Blend for Tbaytel. Draft for internal review — not for external distribution in this version.*
