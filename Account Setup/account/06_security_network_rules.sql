-- ============================================================
-- SECURITY_DB network rules (INBOUND_TRAFFIC)
-- RUN ONCE PER ACCOUNT.  (Snowflake Standards v0.6, sections 4.3 / 4.4)
-- Ingress network rules (schema objects) in SECURITY_DB.INBOUND_TRAFFIC,
-- NOT PLATFORM_DB. Referenced by the account INGRESS_POLICY
-- (07_security_network_policy).
-- ============================================================
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

-- Microsoft Entra ID service ranges - so SCIM provisioning (Doc 06) can
-- reach the SCIM endpoint once a network policy is enforced. These are
-- Microsoft-published ranges that change over time - keep them current
-- (or use the private SCIM endpoint pattern instead).
CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.ENTRAID_SCIM
  TYPE = IPV4
  MODE = INGRESS
  VALUE_LIST = ('20.190.128.0/18', '40.126.0.0/18');

ALTER NETWORK RULE SECURITY_DB.INBOUND_TRAFFIC.ENTRAID_SCIM SET
  VALUE_LIST = ('20.190.128.0/18', '40.126.0.0/18') -- TODO keep in sync with Microsoft's published Entra ID ranges
  COMMENT = 'Microsoft Entra ID ranges for SCIM provisioning reachability';
