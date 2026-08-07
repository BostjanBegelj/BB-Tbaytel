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
--
-- !! 0.0.0.0/0 IS A PLACEHOLDER AND ALLOWS EVERY IPv4 ADDRESS !!
-- Allowed lists are a union, so this value makes the whole policy a no-op
-- for IPv4 - it swallows the narrow BLEND_NETWORK entry and admits anyone.
-- Harmless only while INGRESS_POLICY is inactive (see 07). Activating the
-- policy with this value in place gives NO protection while making the
-- account look governed, which is worse than not activating it.
-- DO NOT ACTIVATE until the real Tbaytel ranges are in.
CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.TBAYTEL_NETWORK
  TYPE = IPV4
  MODE = INGRESS
  VALUE_LIST = ('0.0.0.0/0');

ALTER NETWORK RULE SECURITY_DB.INBOUND_TRAFFIC.TBAYTEL_NETWORK SET
  VALUE_LIST = ('0.0.0.0/0') -- TODO replace with actual Tbaytel IP ranges
  COMMENT = 'PLACEHOLDER 0.0.0.0/0 - allows everything. Replace with Tbaytel corporate ranges before activating INGRESS_POLICY.';

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

-- Blocking public access - needed once Private Link is live.
--
-- An AZURELINKID rule in the ALLOWED list does NOT block public traffic:
-- private-endpoint rules have no effect on requests arriving over the
-- public internet. Allowing the LinkID alone leaves the public endpoint
-- open to whatever the IPv4 rules permit.
--
-- To force traffic through Private Link, this rule goes in the policy's
-- BLOCKED list (see 07). Do not enable until Private Link is verified
-- working - it blocks everything else, including this session.
-- CREATE NETWORK RULE IF NOT EXISTS SECURITY_DB.INBOUND_TRAFFIC.BLOCK_PUBLIC_ACCESS
--   TYPE = IPV4
--   MODE = INGRESS
--   VALUE_LIST = ('0.0.0.0/0');
-- ALTER NETWORK RULE SECURITY_DB.INBOUND_TRAFFIC.BLOCK_PUBLIC_ACCESS SET
--   VALUE_LIST = ('0.0.0.0/0')
--   COMMENT = 'Blocked list only - forces traffic through Private Link';


-- ADF, Power BI and CI/CD are NOT given their own rules.
-- Their public source ranges are Microsoft service tags: very large and
-- changed weekly, so allowlisting them would admit most of Azure and
-- still break when the list moves. They reach Snowflake either over
-- Private Link (Managed VNet endpoint / VNet data gateway / self-hosted
-- runner) or from the corporate network - both already covered above.
-- If a public path is ever unavoidable, scope a network policy to that
-- SERVICE USER rather than widening this account policy: precedence is
-- security integration > user > account.


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
