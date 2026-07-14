# Mirrors "Account Setup/1_account_config"
# (network rules moved to 4_security.tf, per Standards 4.3)

resource "snowflake_account_parameter" "timezone" {
  key   = "TIMEZONE"
  value = var.timezone
}
