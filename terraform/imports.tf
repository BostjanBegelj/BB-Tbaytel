# Import blocks for adopting the EXISTING account (objects created by the SQL
# scripts) into Terraform state without recreating anything. Requires TF >= 1.5.
#
# Workflow:
#   1. terraform plan            -> shows what would be created
#   2. uncomment/extend imports for every object that already exists
#   3. terraform plan            -> imports + diffs only, NO create/destroy of existing objects
#   4. terraform apply
#   5. iterate until plan is a no-op, then freeze the SQL scripts
#
# ID formats: see each resource's docs page ("Import" section). Because naming
# is deterministic ({ENV}_ prefix pattern), the full list can be generated from
# SHOW output.

# --- examples (uncomment per existing object) ---

# import {
#   to = snowflake_database.security_db
#   id = "SECURITY_DB"
# }

# import {
#   to = snowflake_schema.inbound_traffic
#   id = "\"SECURITY_DB\".\"INBOUND_TRAFFIC\""
# }

# import {
#   to = snowflake_network_rule.in516ht_network
#   id = "\"SECURITY_DB\".\"INBOUND_TRAFFIC\".\"IN516HT_NETWORK\""
# }

# import {
#   to = snowflake_network_policy.ingress
#   id = "INGRESS_POLICY"
# }

# import {
#   to = snowflake_account_role.env_sysadmin["DEV"]
#   id = "DEV_SYSADMIN"
# }

# import {
#   to = snowflake_warehouse.functional["DEV_TRANSFORMER"]
#   id = "DEV_TRANSFORMER_WH"
# }

# import {
#   to = snowflake_database.env_db["DEV"]
#   id = "DEV_DB"
# }
