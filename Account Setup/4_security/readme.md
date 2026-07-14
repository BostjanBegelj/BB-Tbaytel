# 4_security — SECURITY_DB (account-wide security database)

Implements Snowflake Standards v0.6 section 4.3: an unprefixed, account-wide
`SECURITY_DB` owned by **SECURITYADMIN**, keeping security administration a
distinct duty from platform administration (`PLATFORM_DB` / SYSADMIN).

| Script | Creates |
|---|---|
| `4_0_create_SECURITY_DB.sql` | Database + schemas `INBOUND_TRAFFIC`, `OUTBOUND_TRAFFIC`, `INTERNAL_STAGE`, `POLICIES`; ownership transfer to SECURITYADMIN; optional `POLICY_ADMIN` block |
| `4_1_create_network_rules.sql` | Ingress network rules (Tbaytel, In516ht, Azure Private Link) in `INBOUND_TRAFFIC` |
| `4_2_create_network_policy.sql` | Account-level `INGRESS_POLICY` referencing the rules + guarded activation |
| `4_3_create_auth_password_policies.sql` | Account password + authentication policies in `POLICIES` + guarded activation |
| `4_4_create_masking_row_access_templates.sql` | Masking / row-access policy templates (do not run as-is) |

**Supersedes** `1_account_config/1_1_create_NETWORK_RULES.sql` (which placed
network rules in PLATFORM_DB/ADMIN_DB). Do not run that script on new accounts.

Run order: 4_0 → 4_1 → 4_2 → 4_3. Activation statements (`ALTER ACCOUNT SET ...`)
are commented out — read the lockout warnings before enabling them.

The Terraform equivalent of this folder is `/terraform/4_security.tf`.
