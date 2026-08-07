# antFarm on Snowpark Container Services — planned objects

Not deployable on the trial: `CREATE COMPUTE POOL` fails on trial accounts.
Set up after conversion to the billed account.

Source: [antFarm SPCS documentation](https://in516ht-d-o-o.github.io/antFarm-documentation/docs/Operations/Snowflake_container_services/Snowflake_container_services.html)

## Where it lives

`PLATFORM_DB.ANTFARM` — account-wide and environment-neutral, one instance
serving all environments. Created `WITH MANAGED ACCESS` and owned by SYSADMIN,
consistent with the other PLATFORM_DB schemas.

> Note: the DQ log table writes at runtime into `PLATFORM_DB`, which is
> otherwise read-only to runtime pipelines. A deliberate exception for
> platform tooling — worth stating rather than discovering.

## Objects

| Object | Name | Notes |
|---|---|---|
| Schema | `PLATFORM_DB.ANTFARM` | managed access |
| Warehouse | `ANTFARM_WH` | replaces `COMPUTE_WH` in the service spec; own warehouse for cost attribution |
| Compute pool | `ANTFARM_COMPUTE_POOL` | `CPU_X64_XS`, 1 node. Bills per node-hour while running — suspend when idle |
| Image repository | `PLATFORM_DB.ANTFARM.IMAGE_REPOSITORY` | holds the antfarm + postgres images |
| Stage | `PLATFORM_DB.ANTFARM.SPECS` | `SNOWFLAKE_SSE` |
| Stage | `PLATFORM_DB.ANTFARM.VOLUMES` | `SNOWFLAKE_SSE`, `DIRECTORY = TRUE` |
| Service | `PLATFORM_DB.ANTFARM.ANTFARM` | 2 containers (antfarm, postgres); endpoints 8888 public, 5432 internal; block volume 20Gi |
| Table | `PLATFORM_DB.ANTFARM.DQ_LOG` | DQ results |
| Service user | `SVC_ANTFARM_UPLOADER` | `TYPE = SERVICE`, PAT auth, for `docker login` / image push |
| UDFs / tables | see antFarm docs | separate pages: Snowflake UDFs, antFarm tables |

Account-level grants required by the service role: `CREATE COMPUTE POOL`,
`BIND SERVICE ENDPOINT`.

## Role naming

antFarm's documented names carry a redundant `_ROLE` suffix and do not match
the convention used elsewhere in this account, where no role is suffixed
`_ROLE` and the prefix says where the role belongs. Proposed alignment —
prefix `ANTFARM_` keeps the ownership visible, suffix dropped:

| antFarm doc | Proposed | Purpose |
|---|---|---|
| `ANTFARM_DQ_ROLE` | `ANTFARM_SERVICE_ADMIN` | Owns the compute pool, stages, image repo and service. "DQ" is misleading — this is the service operator |
| `ANTFARM_SUPERUSER_ROLE` | `ANTFARM_SUPERUSER` | Application superuser |
| `ANTFARM_ADMIN_ROLE` | `ANTFARM_ADMIN` | Application administrator |
| `ANTFARM_USER_ROLE` | `ANTFARM_USER` | Application user |
| `ANTFARM_VIEWER_ROLE` | `ANTFARM_VIEWER` | Read-only application access |

Account-level and unprefixed by environment, like `POLICY_ADMIN` and
`TERRAFORM_ADMIN` — the application is account-wide.

> **Confirm renaming with the antFarm team first.** The service spec sets
> `AF_ADMIN_GROUP_ID: ANTFARM_ADMIN_ROLE`, which proves the app resolves at
> least one Snowflake role *by name* from configuration. If other names are
> hard-coded rather than configurable, the defaults must be kept.

## Fit with existing roles

- Application roles are granted to people through Entra groups, same as the
  reporting roles — not granted directly.
- `ANTFARM_SERVICE_ADMIN` is a platform role, held by whoever operates the
  service. Not the same as `{ENV}_DEPLOYER`.
- antFarm reads and writes environment data through its own connection. That
  connection should use an existing environment role — `{ENV}_DATA_LOADER`
  for ingestion, or `{ENV}_TRANSFORMER` if it also transforms — rather than a
  new one. To be confirmed against how the DQ gate is wired.

## Open items

- Confirm the role renaming is safe with the antFarm team.
- Decide the warehouse: dedicated `ANTFARM_WH`, or reuse `PLATFORM_WH`.
- **Private Link + SPCS needs DNS resolution configured** per the Snowflake
  SPCS private-connectivity guide. This is the DNS resolver dependency already
  tracked as an unowned item in the Azure integration scope.
- Confirm which environment role antFarm connects to per environment.
- Secrets in the service spec (encryption keys, Django secret, Redis
  connection) need a home — `AF_SECRET_MANAGER_PROVIDER: local` in the doc
  example is not appropriate for production.
