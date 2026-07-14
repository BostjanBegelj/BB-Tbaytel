# Mirrors "Account Setup/2_users"
# PERSON users are NOT managed here - they are provisioned by SCIM from Entra ID
# (Standards 6.2). Only service identities (key-pair auth) live in Terraform.
# SVC_TERRAFORM itself is deliberately NOT managed by Terraform (it is the
# identity Terraform runs as - bootstrap it with 2_2_create_SVC_TERRAFORM.sql).

resource "snowflake_service_user" "svc_dev_adf" {
  name              = "SVC_DEV_ADF"
  login_name        = "SVC_DEV_ADF"
  display_name      = "Azure Data Factory"
  comment           = "ADF DEV service user"
  default_role      = snowflake_account_role.functional["DEV_DATA_LOADER"].name
  default_warehouse = snowflake_warehouse.functional["DEV_DATA_LOADER"].name
  rsa_public_key    = "MII..." # TODO replace with actual RSA public key
}

resource "snowflake_grant_account_role" "svc_dev_adf_role" {
  role_name = snowflake_account_role.functional["DEV_DATA_LOADER"].name
  user_name = snowflake_service_user.svc_dev_adf.name
}

# add TEST/PROD ADF service users the same way once those environments go live
