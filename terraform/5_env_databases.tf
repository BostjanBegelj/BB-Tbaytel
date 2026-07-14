# Environment databases {ENV}_DB with the standard schema set (Standards 4.1)
# and per-schema access roles (Standards 7). This declaratively replaces the
# PLATFORM_DB.RBAC CREATE_SCHEMA / DROP_SCHEMA procedures:
#   {SCHEMA}_RO_AR -> {SCHEMA}_RW_AR -> {SCHEMA}_FULL_AR -> {ENV}_SYSADMIN
# Tables/views/procs INSIDE the schemas stay in schemachange/dbt, not Terraform.

resource "snowflake_database" "env_db" {
  for_each = toset(var.environments)
  name     = "${each.key}_DB"
  comment  = "${each.key} environment database"
}

resource "snowflake_grant_ownership" "env_db" {
  for_each            = toset(var.environments)
  account_role_name   = snowflake_account_role.env_sysadmin[each.key].name
  outbound_privileges = "COPY"
  on {
    object_type = "DATABASE"
    object_name = snowflake_database.env_db[each.key].name
  }
}

resource "snowflake_schema" "env" {
  for_each            = local.env_schemas
  database            = snowflake_database.env_db[each.value.env].name
  name                = each.value.schema
  with_managed_access = true
  is_transient        = each.value.schema == "BRONZE" # BRONZE is transient (Standards 4.5)
}

# ---------------------------------------------------------------------------
# Access roles per schema: RO / RW / FULL database roles
# ---------------------------------------------------------------------------
locals {
  # env_schema x tier, keyed "DEV_BRONZE_RO" etc.
  access_roles = {
    for t in setproduct(keys(local.env_schemas), ["RO", "RW", "FULL"]) :
    "${t[0]}_${t[1]}" => {
      env    = local.env_schemas[t[0]].env
      schema = local.env_schemas[t[0]].schema
      tier   = t[1]
    }
  }
}

resource "snowflake_database_role" "access" {
  for_each = local.access_roles
  database = snowflake_database.env_db[each.value.env].name
  name     = "${each.value.schema}_${each.value.tier}_AR"
  comment  = "${each.value.tier} access role for ${each.value.env}_DB.${each.value.schema}"
}

# hierarchy: RO -> RW -> FULL
resource "snowflake_grant_database_role" "ro_to_rw" {
  for_each                 = local.env_schemas
  database_role_name       = snowflake_database_role.access["${each.key}_RO"].fully_qualified_name
  parent_database_role_name = snowflake_database_role.access["${each.key}_RW"].fully_qualified_name
}

resource "snowflake_grant_database_role" "rw_to_full" {
  for_each                 = local.env_schemas
  database_role_name       = snowflake_database_role.access["${each.key}_RW"].fully_qualified_name
  parent_database_role_name = snowflake_database_role.access["${each.key}_FULL"].fully_qualified_name
}

# FULL -> {ENV}_SYSADMIN
resource "snowflake_grant_database_role" "full_to_env_sysadmin" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_FULL"].fully_qualified_name
  parent_role_name   = snowflake_account_role.env_sysadmin[each.value.env].name
}

# ---------------------------------------------------------------------------
# Privileges (mirrors the CREATE_SCHEMA procedure grants; extend the
# object_type lists to full parity - stages, file formats, streams, etc.)
# ---------------------------------------------------------------------------
resource "snowflake_grant_privileges_to_database_role" "ro_schema_usage" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_RO"].fully_qualified_name
  privileges         = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.env[each.key].fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_database_role" "ro_select_tables" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_RO"].fully_qualified_name
  privileges         = ["SELECT"]
  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.env[each.key].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_database_role" "ro_select_views" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_RO"].fully_qualified_name
  privileges         = ["SELECT"]
  on_schema_object {
    all {
      object_type_plural = "VIEWS"
      in_schema          = snowflake_schema.env[each.key].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_database_role" "ro_select_future_tables" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_RO"].fully_qualified_name
  privileges         = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.env[each.key].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_database_role" "ro_select_future_views" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_RO"].fully_qualified_name
  privileges         = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "VIEWS"
      in_schema          = snowflake_schema.env[each.key].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_database_role" "rw_tables_dml" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_RW"].fully_qualified_name
  privileges         = ["INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES"]
  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.env[each.key].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_database_role" "rw_future_tables_dml" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_RW"].fully_qualified_name
  privileges         = ["INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.env[each.key].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_database_role" "full_schema_all" {
  for_each           = local.env_schemas
  database_role_name = snowflake_database_role.access["${each.key}_FULL"].fully_qualified_name
  all_privileges     = true
  on_schema {
    schema_name = snowflake_schema.env[each.key].fully_qualified_name
  }
}

# NO future-ownership grants - they break tasks, dynamic tables, DMFs etc.
# Objects are created and owned by the functional role (Standards 7).
