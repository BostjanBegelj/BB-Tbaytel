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

-- Blend delivery-team network
CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.BLEND_NETWORK
  TYPE = IPV4
  MODE = INGRESS
  VALUE_LIST = ('89.212.52.137/32');

ALTER NETWORK RULE SECURITY_DB.INBOUND_TRAFFIC.BLEND_NETWORK SET
  VALUE_LIST = ('89.212.52.137/32')
  COMMENT = 'Blend delivery-team IP ranges';

-- Azure Private Link private endpoint(s) - client/BI/ADF traffic arrives over
-- the Microsoft backbone from the Tbaytel VNet (Standards 3 / 4.3)
CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.AZURE_PRIVATE_LINK
  TYPE = AZURELINKID
  MODE = INGRESS
  VALUE_LIST = ('/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/privateEndpoints/<pe-name>');

ALTER NETWORK RULE SECURITY_DB.INBOUND_TRAFFIC.AZURE_PRIVATE_LINK SET
  VALUE_LIST = ('/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/privateEndpoints/<pe-name>') -- TODO replace with actual LinkIdentifier(s); see SYSTEM$GET_PRIVATELINK_AUTHORIZED_ENDPOINTS()
  COMMENT = 'Azure Private Link private endpoints from the Tbaytel VNet';

-- Microsoft Entra ID ranges for SCIM provisioning.
--
-- NOT CREATED HERE, and deliberately NOT part of INGRESS_POLICY.
--
-- There is no private path for Entra SCIM. Snowflake documents that the
-- integration must use the PUBLIC account endpoint - not the
-- .privatelink URL - even when Private Link is in use, so SCIM traffic
-- always arrives from Microsoft's public ranges.
--
-- Snowflake further states that ALL Azure public-cloud IP ranges are
-- currently required for an Entra SCIM network policy, not a couple of
-- /18s. Putting that into the account-wide ingress policy would admit
-- the whole Azure public cloud to every interface of the account.
--
-- The supported pattern is a SEPARATE network policy attached to the
-- SCIM security integration, which overrides the account policy for
-- that integration only. It is created in
-- 17_identity_scim_provisioning.sql, next to the integration it serves.
