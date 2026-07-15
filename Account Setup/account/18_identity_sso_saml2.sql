-- ============================================================
-- IDENTITY - SSO (SAML2) with Microsoft Entra ID
-- RUN ONCE PER ACCOUNT - but ONLY AFTER Azure Private Link (Docs 03/04),
-- configured against the FINAL privatelink URLs.  (Azure Doc 05)
--
-- Ordering matters (Doc 00): creating SSO before the privatelink URLs
-- are final forces the SYSTEM$MIGRATE_SAML_IDP_REGISTRATION rework.
-- Values come from the Entra Enterprise Application. The statement is
-- left GATED (commented) until those values and the URLs are known.
-- ============================================================
USE ROLE ACCOUNTADMIN;

-- CREATE SECURITY INTEGRATION IF NOT EXISTS ENTRAID_SSO
--   TYPE = SAML2
--   ENABLED = TRUE
--   SAML2_ISSUER  = '<Microsoft Entra Identifier>'    -- e.g. https://sts.windows.net/<tenant-id>/
--   SAML2_SSO_URL = '<Login URL>'                      -- e.g. https://login.microsoftonline.com/<tenant-id>/saml2
--   SAML2_PROVIDER = 'CUSTOM'
--   SAML2_X509_CERT = '<single-line certificate body>'
--   SAML2_SP_INITIATED_LOGIN_PAGE_LABEL = 'EntraID SSO'
--   SAML2_ENABLE_SP_INITIATED = TRUE
--   SAML2_SNOWFLAKE_ISSUER_URL = 'https://<account>.snowflakecomputing.com'
--   SAML2_SNOWFLAKE_ACS_URL    = 'https://<account>.snowflakecomputing.com/fed/login';

-- DESC SECURITY INTEGRATION ENTRAID_SSO;   -- sanity check after creation

-- Certificate rotation (Entra signing cert default ~3 years):
-- ALTER SECURITY INTEGRATION ENTRAID_SSO SET SAML2_X509_CERT = '<new single-line cert>';
