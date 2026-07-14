-- Network rules (Snowflake Standards v0.6, sections 4.3 / 4.4)
-- Network rules are schema objects and live in SECURITY_DB.INBOUND_TRAFFIC.
-- SUPERSEDES: 1_account_config/1_1_create_NETWORK_RULES.sql (PLATFORM_DB / ADMIN_DB location).
-- The rules are referenced by the account-level INGRESS_POLICY (see 4_2).
--
-- Pattern: CREATE IF NOT EXISTS + ALTER SET (non-destructive, rerunnable).
-- NOT CREATE OR REPLACE - a rule referenced by an active network policy cannot
-- be dropped/replaced, so OR REPLACE fails once INGRESS_POLICY is attached.
-- ALTER SET also matches how Terraform reconciles the object after import.

USE ROLE SECURITYADMIN;

-- Tbaytel corporate ranges
CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.TBAYTEL_NETWORK
  TYPE = IPV4
  MODE = INGRESS
  VALUE_LIST = ('0.0.0.0/0');

ALTER NETWORK RULE SECURITY_DB.INBOUND_TRAFFIC.TBAYTEL_NETWORK SET
  VALUE_LIST = ('0.0.0.0/0') -- TODO replace with actual Tbaytel IP ranges
  COMMENT = 'Tbaytel corporate IP ranges';

-- In516ht network
CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.IN516HT_NETWORK
  TYPE = IPV4
  MODE = INGRESS
  VALUE_LIST = ('89.212.52.137/32');

ALTER NETWORK RULE SECURITY_DB.INBOUND_TRAFFIC.IN516HT_NETWORK SET
  VALUE_LIST = ('89.212.52.137/32')
  COMMENT = 'In516ht IP ranges';

-- Azure Private Link private endpoint(s) - client/BI/ADF traffic arrives over
-- the Microsoft backbone from the Tbaytel VNet (Standards 3 / 4.3)
CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.AZURE_PRIVATE_LINK
  TYPE = AZURELINKID
  MODE = INGRESS
  VALUE_LIST = ('/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/privateEndpoints/<pe-name>');

ALTER NETWORK RULE SECURITY_DB.INBOUND_TRAFFIC.AZURE_PRIVATE_LINK SET
  VALUE_LIST = ('/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/privateEndpoints/<pe-name>') -- TODO replace with actual LinkIdentifier(s); see SYSTEM$GET_PRIVATELINK_AUTHORIZED_ENDPOINTS()
  COMMENT = 'Azure Private Link private endpoints from the Tbaytel VNet';
