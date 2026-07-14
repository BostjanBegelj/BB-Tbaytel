# Tbaytel Snowflake — Terraform account setup

Terraform (provider `snowflakedb/snowflake` ~> 2.18) equivalent of the SQL
scripts in `Account Setup/`. Each `.tf` file mirrors one SQL folder 1:1:

| Terraform | SQL folder | Contents |
|---|---|---|
| `0_rbac.tf` | `0_RBAC` | {ENV}_SYSADMIN / {ENV}_USERADMIN, PLATFORM_DB + PLATFORM_WH, functional roles + warehouses |
| `1_account_config.tf` | `1_account_config` | TIMEZONE account parameter |
| `2_users.tf` | `2_users` | Service users only (persons come via SCIM) |
| `3_integrations.tf` | `3_integrations` | Git API integration, ADLS storage integration |
| `4_security.tf` | `4_security` | SECURITY_DB, network rules, INGRESS_POLICY, auth/password policies |
| `5_env_databases.tf` | (CREATE_SCHEMA proc) | {ENV}_DB, schemas, RO/RW/FULL access database roles + grants |
| `imports.tf` | — | Import blocks for adopting existing objects |

## Scope boundary

Terraform manages **account-level** objects only. Tables, views, procedures,
stages, file formats — everything *inside* schemas — stays in schemachange/dbt.

## Bootstrap (one-time, SQL)

1. Run `Account Setup/2_users/2_2_create_SVC_TERRAFORM.sql` (key-pair service user).
2. `cp terraform.tfvars.example terraform.tfvars` and fill in (git-ignore `terraform.tfvars` and `*.tfstate`).

## Migration from the SQL scripts

1. `terraform init && terraform plan` — everything shows as "create".
2. Fill `imports.tf` with an `import` block for every object that already
   exists (names are deterministic, so the list can be generated from `SHOW` output).
3. `terraform plan` — existing objects now show as imports (+ attribute diffs);
   fix diffs in code, not in Snowflake.
4. `terraform apply`, iterate until `plan` is a **no-op**.
5. Freeze the SQL scripts (keep as documentation); all changes go through Terraform.

## Lockout guards

`activate_network_policy` and `activate_auth_policies` default to `false`.
Before flipping them: verify `CURRENT_IP_ADDRESS()` matches an allowed network
rule, SSO works for at least one admin, and all service users have RSA keys.
Same guards as the commented `ALTER ACCOUNT` statements in the SQL version.

## Running Terraform without installing it

- Docker: `docker run -v $(pwd):/wf -w /wf hashicorp/terraform:1.9 plan`
- Or a version manager (`tenv` / `tfenv`) in CI.
- `terraform validate` and `plan` are safe (read-only); only `apply` changes Snowflake.

## Notes

- Provider runs as `SVC_TERRAFORM` / ACCOUNTADMIN for simplicity; split into a
  least-privilege deployment role (or provider aliases per built-in role) once stable.
- Several resources are provider **preview features** (network rule/policy
  attachments, auth/password policies, integrations) — enabled in `providers.tf`;
  review on provider upgrades.
- State contains secrets/infrastructure detail — use a remote backend (Azure
  blob) with locking before team/CI use.
