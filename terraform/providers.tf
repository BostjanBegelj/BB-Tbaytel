# Snowflake provider - snowflakedb/snowflake v2.x (v2.18+ as of 2026-07)
# Connects as the SVC_TERRAFORM service user (key pair) created by
# "Account Setup/2_users/2_2_create_SVC_TERRAFORM.sql".

terraform {
  required_version = ">= 1.5" # import blocks require 1.5+

  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.18"
    }
  }

  # TODO remote state before team use (Azure blob backend suggested):
  # backend "azurerm" { ... }
}

provider "snowflake" {
  organization_name = var.snowflake_organization
  account_name      = var.snowflake_account
  user              = "SVC_TERRAFORM"
  role              = "ACCOUNTADMIN" # TODO split to least-privilege TERRAFORM_ADMIN once stable
  authenticator     = "SNOWFLAKE_JWT"
  private_key       = file(var.private_key_path)

  # resources still in preview in provider v2 must be enabled explicitly
  preview_features_enabled = [
    "snowflake_network_rule_resource",
    "snowflake_network_policy_attachment_resource",
    "snowflake_password_policy_resource",
    "snowflake_authentication_policy_resource",
    "snowflake_account_password_policy_attachment_resource",
    "snowflake_account_authentication_policy_attachment_resource",
    "snowflake_api_integration_resource",
    "snowflake_storage_integration_resource",
  ]
}
