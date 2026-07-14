# Mirrors "Account Setup/4_security" - SECURITY_DB, network rules, INGRESS_POLICY,
# authentication/password policies (Standards 4.3 / 4.4 / 6.1).
# Activation of account-level policies is gated behind var.activate_* flags
# because of lockout risk - same guard as the commented ALTER ACCOUNT in SQL.

# ---------------------------------------------------------------------------
# SECURITY_DB + schemas
# ---------------------------------------------------------------------------
resource "snowflake_database" "security_db" {
  name    = "SECURITY_DB"
  comment = "Account-wide security objects: network rules and policies (Standards 4.3)"
}

resource "snowflake_schema" "inbound_traffic" {
  database            = snowflake_database.security_db.name
  name                = "INBOUND_TRAFFIC"
  with_managed_access = true
  comment             = "Ingress network rules"
}

resource "snowflake_schema" "outbound_traffic" {
  database            = snowflake_database.security_db.name
  name                = "OUTBOUND_TRAFFIC"
  with_managed_access = true
  comment             = "Egress network rules (external access integrations)"
}

resource "snowflake_schema" "internal_stage" {
  database            = snowflake_database.security_db.name
  name                = "INTERNAL_STAGE"
  with_managed_access = true
  comment             = "Network rules restricting internal stage access"
}

resource "snowflake_schema" "policies" {
  database            = snowflake_database.security_db.name
  name                = "POLICIES"
  with_managed_access = true
  comment             = "Authentication, password, masking and row-access policies"
}

# Ownership to SECURITYADMIN (Standards 4.3). Terraform keeps managing the
# objects because it runs as ACCOUNTADMIN (parent of SECURITYADMIN).
resource "snowflake_grant_ownership" "security_db" {
  account_role_name   = "SECURITYADMIN"
  outbound_privileges = "COPY"
  on {
    object_type = "DATABASE"
    object_name = snowflake_database.security_db.name
  }
  depends_on = [
    snowflake_schema.inbound_traffic,
    snowflake_schema.outbound_traffic,
    snowflake_schema.internal_stage,
    snowflake_schema.policies,
  ]
}

# ---------------------------------------------------------------------------
# Network rules (schema objects in SECURITY_DB.INBOUND_TRAFFIC)
# ---------------------------------------------------------------------------
resource "snowflake_network_rule" "tbaytel_network" {
  name       = "TBAYTEL_NETWORK"
  database   = snowflake_database.security_db.name
  schema     = snowflake_schema.inbound_traffic.name
  type       = "IPV4"
  mode       = "INGRESS"
  value_list = var.tbaytel_ip_ranges
  comment    = "Tbaytel corporate IP ranges"
}

resource "snowflake_network_rule" "in516ht_network" {
  name       = "IN516HT_NETWORK"
  database   = snowflake_database.security_db.name
  schema     = snowflake_schema.inbound_traffic.name
  type       = "IPV4"
  mode       = "INGRESS"
  value_list = var.in516ht_ip_ranges
  comment    = "In516ht IP ranges"
}

resource "snowflake_network_rule" "azure_private_link" {
  count      = length(var.azure_private_link_ids) > 0 ? 1 : 0
  name       = "AZURE_PRIVATE_LINK"
  database   = snowflake_database.security_db.name
  schema     = snowflake_schema.inbound_traffic.name
  type       = "AZURELINKID"
  mode       = "INGRESS"
  value_list = var.azure_private_link_ids
  comment    = "Azure Private Link private endpoints from the Tbaytel VNet"
}

# ---------------------------------------------------------------------------
# INGRESS_POLICY (account-level object referencing the rules above)
# ---------------------------------------------------------------------------
resource "snowflake_network_policy" "ingress" {
  name    = "INGRESS_POLICY"
  comment = "Account ingress policy - rules maintained in SECURITY_DB.INBOUND_TRAFFIC"
  allowed_network_rule_list = concat(
    [
      "\"SECURITY_DB\".\"INBOUND_TRAFFIC\".\"${snowflake_network_rule.tbaytel_network.name}\"",
      "\"SECURITY_DB\".\"INBOUND_TRAFFIC\".\"${snowflake_network_rule.in516ht_network.name}\"",
    ],
    [for r in snowflake_network_rule.azure_private_link : "\"SECURITY_DB\".\"INBOUND_TRAFFIC\".\"${r.name}\""]
  )
}

# !! LOCKOUT RISK !! - verify SELECT CURRENT_IP_ADDRESS() matches an allowed
# rule before setting activate_network_policy = true
resource "snowflake_network_policy_attachment" "account" {
  count               = var.activate_network_policy ? 1 : 0
  network_policy_name = snowflake_network_policy.ingress.name
  set_for_account     = true
}

# ---------------------------------------------------------------------------
# Password + authentication policies (schema objects in SECURITY_DB.POLICIES)
# ---------------------------------------------------------------------------
resource "snowflake_password_policy" "account" {
  name              = "ACCOUNT_PASSWORD_POLICY"
  database          = snowflake_database.security_db.name
  schema            = snowflake_schema.policies.name
  min_length        = 14
  min_upper_case_chars = 1
  min_lower_case_chars = 1
  min_numeric_chars = 1
  min_special_chars = 1
  max_age_days      = 90
  max_retries       = 5
  lockout_time_mins = 30
  history           = 5
  comment           = "Account default password policy"
}

resource "snowflake_authentication_policy" "account" {
  name                       = "ACCOUNT_AUTH_POLICY"
  database                   = snowflake_database.security_db.name
  schema                     = snowflake_schema.policies.name
  authentication_methods     = ["SAML", "KEYPAIR", "PASSWORD"] # tighten to SAML+KEYPAIR after SSO cutover
  mfa_enrollment             = "REQUIRED"
  mfa_authentication_methods = ["PASSWORD"]
  client_types               = ["ALL"]
  comment                    = "Account default authentication policy - SSO for humans, key pair for services"
}

# !! LOCKOUT RISK !! - verify SSO + service key pairs before setting
# activate_auth_policies = true
resource "snowflake_account_password_policy_attachment" "account" {
  count           = var.activate_auth_policies ? 1 : 0
  password_policy = snowflake_password_policy.account.fully_qualified_name
}

resource "snowflake_account_authentication_policy_attachment" "account" {
  count                 = var.activate_auth_policies ? 1 : 0
  authentication_policy = snowflake_authentication_policy.account.fully_qualified_name
}

# masking / row-access policies: define per data domain as they materialise -
# snowflake_masking_policy / snowflake_row_access_policy in SECURITY_DB.POLICIES
