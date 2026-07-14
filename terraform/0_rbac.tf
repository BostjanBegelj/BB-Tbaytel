# Mirrors "Account Setup/0_RBAC" - provisioning roles, PLATFORM_DB, functional
# roles and their warehouses.
# NOTE: the RBAC stored procedures (CREATE_SCHEMA etc.) in PLATFORM_DB.RBAC are
# replaced by declarative resources here (see 5_env_databases.tf). If the procs
# are still wanted for ad-hoc use, deploy them via schemachange, not Terraform.

# ---------------------------------------------------------------------------
# Environment provisioning roles: {ENV}_SYSADMIN, {ENV}_USERADMIN (Standards 6.2)
# ---------------------------------------------------------------------------
resource "snowflake_account_role" "env_sysadmin" {
  for_each = toset(var.environments)
  name     = "${each.key}_SYSADMIN"
  comment  = "Owns databases, schemas and warehouses in ${each.key}"
}

resource "snowflake_grant_account_role" "env_sysadmin_to_sysadmin" {
  for_each         = toset(var.environments)
  role_name        = snowflake_account_role.env_sysadmin[each.key].name
  parent_role_name = "SYSADMIN"
}

resource "snowflake_grant_privileges_to_account_role" "env_sysadmin_account" {
  for_each          = toset(var.environments)
  account_role_name = snowflake_account_role.env_sysadmin[each.key].name
  privileges        = ["CREATE DATABASE", "CREATE WAREHOUSE"]
  on_account        = true
}

resource "snowflake_account_role" "env_useradmin" {
  for_each = toset(var.environments)
  name     = "${each.key}_USERADMIN"
  comment  = "Creates functional roles and manages role grants in ${each.key}"
}

resource "snowflake_grant_account_role" "env_useradmin_to_useradmin" {
  for_each         = toset(var.environments)
  role_name        = snowflake_account_role.env_useradmin[each.key].name
  parent_role_name = "USERADMIN"
}

resource "snowflake_grant_privileges_to_account_role" "env_useradmin_account" {
  for_each          = toset(var.environments)
  account_role_name = snowflake_account_role.env_useradmin[each.key].name
  privileges        = ["CREATE ROLE"]
  on_account        = true
}

# ---------------------------------------------------------------------------
# PLATFORM_DB (unprefixed, account-wide - Standards 4.2) + PLATFORM_WH
# ---------------------------------------------------------------------------
resource "snowflake_database" "platform_db" {
  name    = "PLATFORM_DB"
  comment = "Account-wide platform administration content (Standards 4.2)"
}

resource "snowflake_schema" "platform_rbac" {
  database            = snowflake_database.platform_db.name
  name                = "RBAC"
  with_managed_access = true
  comment             = "RBAC provisioning content (procedures deployed via schemachange, if kept)"
}

resource "snowflake_schema" "platform_shared_workspace" {
  database            = snowflake_database.platform_db.name
  name                = "SHARED_WORKSPACE"
  with_managed_access = true
}

resource "snowflake_warehouse" "platform_wh" {
  name                = "PLATFORM_WH"
  comment             = "Provisioning and deployment warehouse"
  warehouse_size      = local.warehouse_defaults.warehouse_size
  warehouse_type      = local.warehouse_defaults.warehouse_type
  auto_suspend        = local.warehouse_defaults.auto_suspend
  auto_resume         = local.warehouse_defaults.auto_resume
  initially_suspended = local.warehouse_defaults.initially_suspended
}

# ---------------------------------------------------------------------------
# Functional roles + one warehouse per role (Standards 6.3 / 6.4)
# ---------------------------------------------------------------------------
resource "snowflake_account_role" "functional" {
  for_each = local.env_roles
  name     = each.key
  comment  = "${each.value.role} functional role in ${each.value.env}"
}

resource "snowflake_grant_account_role" "functional_to_env_sysadmin" {
  for_each         = local.env_roles
  role_name        = snowflake_account_role.functional[each.key].name
  parent_role_name = snowflake_account_role.env_sysadmin[each.value.env].name
}

resource "snowflake_warehouse" "functional" {
  for_each            = local.env_roles
  name                = "${each.key}_WH"
  comment             = "Dedicated warehouse for ${each.key} (per-workload cost attribution)"
  warehouse_size      = local.warehouse_defaults.warehouse_size
  warehouse_type      = local.warehouse_defaults.warehouse_type
  auto_suspend        = local.warehouse_defaults.auto_suspend
  auto_resume         = local.warehouse_defaults.auto_resume
  initially_suspended = local.warehouse_defaults.initially_suspended
}

resource "snowflake_grant_privileges_to_account_role" "functional_wh_usage" {
  for_each          = local.env_roles
  account_role_name = snowflake_account_role.functional[each.key].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.functional[each.key].name
  }
}
