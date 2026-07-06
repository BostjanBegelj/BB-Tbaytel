# account
Account-level administrative scripts that are typically performed when setting up the Snowflake account.

**WARNING:** the scripts are meant as templates, to be modified as needed according to the project requirements. Do not run any script without reviewing it first and understanding its purpose.

## 0_RBAC
Creates the environment provision database that contains RBAC stored procedures, assuming there is only one Snowflake account for all environments (eg. DEV, UAT, PROD):
- create database
- drop database
- create schema
- drop schema

## 1_account_config
- `alter_parameter_TIMEZONE.sql` - alters the account timezone to the local timezone
- `create_ADMIN_DB.sql` - creates the account-level ADMIN_DB database
- `create_NETWORK_RULES.sql` - creates the network rules, initially including whitelisted IP addresses for the customer and In516ht; the network rules are included in an account-level network policy called INGRESS_POLICY (the policy is usually created in the Snowsight UI)

## 2_users
- `create_person_users.sql` - create person users
- `create_SVC_DEV_MATILLION.sql` - create the Matillion service user in the DEV environment

## 3_integrations
- `create_git_integration_oauth.sql` - creates the Git integration with the Git repo using OAuth with GitHub
- `create_storage_integration_Azure.sql` - creates a storage integration with Azure blob storage
- `create_storage_integration_s3.sql` - creates a storage integration with AWS S3
