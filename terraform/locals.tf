locals {
  # functional roles (Standards 6.3), one warehouse each (6.4)
  functional_roles = [
    "TRANSFORMER",
    "ANALYST",
    "DATA_LOADER",
    "REPORTER",
    "REPORTER_BILLING",
    "REPORTER_FINANCE",
    "REPORTER_MARKETING",
    "IT_GOVERNANCE",
  ]

  # env x functional role, keyed "DEV_TRANSFORMER" etc.
  env_roles = {
    for pair in setproduct(var.environments, local.functional_roles) :
    "${pair[0]}_${pair[1]}" => { env = pair[0], role = pair[1] }
  }

  # environment database schemas (Standards 4.1)
  env_db_schemas = [
    "RAW",
    "BRONZE",
    "BRONZE_HIST",
    "SILVER",
    "GOLD",
    "GOLD_BILLING",
    "GOLD_FINANCE",
    "GOLD_MARKETING",
    "ADM",
  ]

  # env x schema, keyed "DEV_DB.BRONZE" style: { env, schema }
  env_schemas = {
    for pair in setproduct(var.environments, local.env_db_schemas) :
    "${pair[0]}_${pair[1]}" => { env = pair[0], schema = pair[1] }
  }

  # standard warehouse settings - all start X-Small (Standards 6.4)
  warehouse_defaults = {
    warehouse_size      = "XSMALL"
    warehouse_type      = "STANDARD"
    auto_suspend        = 60
    auto_resume         = true
    initially_suspended = true
  }
}
