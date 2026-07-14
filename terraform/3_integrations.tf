# Mirrors "Account Setup/3_integrations"
# Preview resources in provider v2 - enabled in providers.tf.
# NOTE: the Azure storage integration consent URL step (DESCRIBE INTEGRATION ->
# open AZURE_CONSENT_URL) remains a one-time manual action after first apply.

resource "snowflake_api_integration" "git" {
  name                 = "DATA_PIPELINE_GIT_INTEGRATION"
  api_provider         = "git_https_api"
  api_allowed_prefixes = var.git_allowed_prefixes
  enabled              = true
}

resource "snowflake_grant_privileges_to_account_role" "git_usage_public" {
  account_role_name = "PUBLIC"
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_api_integration.git.name
  }
}

resource "snowflake_storage_integration" "adls" {
  name                      = "ADLS_BRONZE_INTEGRATION"
  type                      = "EXTERNAL_STAGE"
  storage_provider          = "AZURE"
  azure_tenant_id           = var.azure_tenant_id
  storage_allowed_locations = var.adls_allowed_locations
  enabled                   = true
  comment                   = "Storage integration over the ADLS Bronze container"
}

resource "snowflake_grant_privileges_to_account_role" "adls_usage_data_loader" {
  for_each          = toset(var.environments)
  account_role_name = snowflake_account_role.functional["${each.key}_DATA_LOADER"].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_storage_integration.adls.name
  }
}

# external STAGES over this integration are schema objects -> deploy via
# schemachange/dbt together with the other in-database DDL, not Terraform
