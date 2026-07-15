/*
-- create the ADF service user in the DEV environment
USE ROLE USERADMIN;
CREATE USER SVC_DEV_ADF 
LOGIN_NAME = 'SVC_DEV_ADF' 
DISPLAY_NAME = 'Azure Data Factory'
TYPE = 'SERVICE'
COMMENT = 'ADF DEV service user'
DEFAULT_ROLE = DEV_DATA_LOADER
DEFAULT_WAREHOUSE = DEV_DATA_LOADER_WH;

USE ROLE DEV_USERADMIN;
GRANT ROLE DEV_DATA_LOADER TO USER SVC_DEV_ADF;

ALTER USER SVC_DEV_ADF SET RSA_PUBLIC_KEY = 'MII...'; -- Replace with actual RSA public key
*/


/*
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA8HhjM9yn4osGoV5CN1V+
awjybQ7CZvVyhtrHkAnDYMEhE3q7QFn/39TfnAdsC1B2/Yq9Mca5L+0DVPAFn7p4
Hu+djQHK6a6OPTgy1SUipbWYN3GgJjyWznit7HjcOTuO+3Bz8z+YNw5L/PbeOB70
gx8I+xn97AnlbHm6AlcCDiHOnyBJx+Vij2eL7ZIDP9Pzhe4p0mwh7pmvpxC7z5Q6
shSDdsaKoJqES8LD+ACq6WlIqcnvH2RnTT75+3saSBRq4EAdiyILbbSSjdOTdStf
D8iPQFv8HXzJltmj0uJBomIcsniv+xUsbXOSrEoxlmCcg82jkaaF/NFnl66Q9Yhs
bwIDAQAB
-----END PUBLIC KEY-----


-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDweGMz3Kfiiwah
XkI3VX5rCPJtDsJm9XKG2seQCcNgwSETertAWf/f1N+cB2wLUHb9ir0xxrkv7QNU
8AWfunge752NAcrpro49ODLVJSKltZg3caAmPJbOeK3seNw5O477cHPzP5g3Dkv8
9t44HvSDHwj7Gf3sCeVseboCVwIOIc6fIEnH5WKPZ4vtkgM/0/OF7inSbCHuma+n
ELvPlDqyFIN2xoqgmoRLwsP4AKrpaUipye8fZGdNPvn7expIFGrgQB2LIgtttJKN
05N1K18PyI9AW/wdfMmW2aPS4kGiYhyyeK/7FSxtc5KsSjGWYJyDzaORpoX80WeX
rpD1iGxvAgMBAAECggEAAPk7zZXzHWOwCdnhLWrXMYUTwNqdHDWaL8RAUpZM3Yi/
+DLjAduwwYM8dIaYgA3krW9xB1E6prWwRxkXAhKLMfTeZRfAw+QaXKfBl5ioOeuG
S5MrhtFv+t4E4OmMWrRMW+WUp+4gpk2/LlhW21CkxMh3Yizfbk6L8z3QQaTV3qDF
EZK1a6c0I1+ke/VWH+W4yeiwSUHbvtfDFlRsGg84UYb3BwR+a86AJobI+qnWMx2T
x2L6ETT12p59uC1CBbR2CbL4/OCkkFmP/mQMWsGXuiwczdMKgJtW/s7R5wzM43dS
PM6adhRpwqOIcX4G+XO9LAZw21tsTF50raftlTlggQKBgQD+XtptWSsn55fnPe/F
BCBZB54Yy4bIq1FYGDYF8u57DHaTpaC2sQRrYiwY2Mt2gUranq/OqUqy5Ap91AOG
kwkFhc12LSI8+DVgESrLyoJ7c1v5K1S0Ra4Mp7PKR18xveCoW6/NnHSkB1/yjgl2
Frh09jf4YbYFN+R7aIOXM/ePHwKBgQDyAr0vDu3jQ65VT/e196s5FK+3rBAesmQR
W97L6OEz/ckj7zKXLwTFlv9YrdubsF/RdIDs06lnoXmgLFAmEyGDbg5K44BYb5YF
gcO4GLNbedhZCZmeX62sthRw04RoZjuhPYf7cG/Nfo6424wuflNKg6qv4nvFJpwn
QJfFL+qIsQKBgQDkhFo+eijnBIvW1jGdEQPud4V0SQOhKyc8uSNvXLsaGCw+oEEt
XwHVZrCu8bR3ldelZ4IRas0MwQkb2WgBcf5c08OtMwbbNzDcSQ/lXNy0AwLRajgC
a8bc35wJUO0YRriZByV81d2Droxn32poiCjWCoxlu4JGVdwRcecl4y23iQKBgGhJ
V968bzR8yNYIhLUMSeNqD6J1aejgdJCqZyK1cr4lwZRTkhhl8Yd33wcGvFils1Se
AKSNPTXj9nZYQh12Jv3s4gnRaVAynZI37fAZ7MghhGIx6dm+XyfKupo3+5nFXDLK
QhvOws7pl3T/XrP2ScwVWus6DJ3TWnzrr7sQP9+xAoGAA9XBGWi66O0pbi6RfHru
v5tLgwSrHI1/nmoRs9zkz1zXbXS8CngYisEpRvsd3UWMKEVxjzdb1oDvk583kh4i
XfrUT8twKsAKQKWsS8FrplRS01k60DYtKeTL2cKqoy36vyQhLmxPrek7yveLCDNt
5n96WrfYPx7ZkKXFVc5d8Sw=
-----END PRIVATE KEY-----
*/


-- ============================================================
-- ENVIRONMENT CONFIGURATION
-- ============================================================

SET ENV_ABBR = 'DEV_';

SET ENV_SYSADMIN  = $ENV_ABBR || 'SYSADMIN';
SET ENV_USERADMIN = $ENV_ABBR || 'USERADMIN';


-- ============================================================
-- ADF SERVICE USER CONFIGURATION
-- ============================================================

SET SVC_ADF_USER     = 'SVC_' || $ENV_ABBR || 'ADF';
SET ADF_ROLE         = $ENV_ABBR || 'DATA_LOADER';
SET ADF_WAREHOUSE    = $ENV_ABBR || 'DATA_LOADER_WH';


-- ============================================================
-- TERRAFORM SERVICE USER CONFIGURATION
-- ============================================================

SET SVC_TERRAFORM_USER = 'SVC_' || $ENV_ABBR || 'TERRAFORM';
SET TERRAFORM_ROLE      = $ENV_SYSADMIN;


-- ============================================================
-- CREATE SERVICE USERS
-- ============================================================

USE ROLE USERADMIN;


-- ------------------------------------------------------------
-- Azure Data Factory service user
-- ------------------------------------------------------------

CREATE USER IDENTIFIER($SVC_ADF_USER)
    LOGIN_NAME        = $SVC_ADF_USER
    DISPLAY_NAME      = 'Azure Data Factory'
    TYPE              = 'SERVICE'
    COMMENT           = 'ADF service user'
    DEFAULT_ROLE      = $ADF_ROLE
    DEFAULT_WAREHOUSE = $ADF_WAREHOUSE
;


-- ------------------------------------------------------------
-- Terraform service user
-- ------------------------------------------------------------

CREATE USER IDENTIFIER($SVC_TERRAFORM_USER)
    LOGIN_NAME   = $SVC_TERRAFORM_USER
    DISPLAY_NAME = 'Terraform'
    TYPE         = 'SERVICE'
    COMMENT      = 'Terraform deployment service user'
    DEFAULT_ROLE = $TERRAFORM_ROLE
;


-- ============================================================
-- GRANT ENVIRONMENT-SPECIFIC ROLES
-- ============================================================

USE ROLE IDENTIFIER($ENV_USERADMIN);


-- Grant the data-loader role to ADF

GRANT ROLE IDENTIFIER($ADF_ROLE)
    TO USER IDENTIFIER($SVC_ADF_USER);


-- Grant the environment SYSADMIN role to Terraform

GRANT ROLE IDENTIFIER($TERRAFORM_ROLE)
    TO USER IDENTIFIER($SVC_TERRAFORM_USER);


-- ============================================================
-- ASSIGN RSA PUBLIC KEYS
--
-- Generate a separate key pair for each service user.
--
-- Paste only the Base64 public-key content:
--   - without -----BEGIN PUBLIC KEY-----
--   - without -----END PUBLIC KEY-----
--   - without line breaks
-- ============================================================

USE ROLE USERADMIN;


-- ------------------------------------------------------------
-- ADF RSA public key
-- ------------------------------------------------------------

 SET ADF_RSA_PUBLIC_KEY =
     'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA8HhjM9yn4osGoV5CN1V+
awjybQ7CZvVyhtrHkAnDYMEhE3q7QFn/39TfnAdsC1B2/Yq9Mca5L+0DVPAFn7p4
Hu+djQHK6a6OPTgy1SUipbWYN3GgJjyWznit7HjcOTuO+3Bz8z+YNw5L/PbeOB70
gx8I+xn97AnlbHm6AlcCDiHOnyBJx+Vij2eL7ZIDP9Pzhe4p0mwh7pmvpxC7z5Q6
shSDdsaKoJqES8LD+ACq6WlIqcnvH2RnTT75+3saSBRq4EAdiyILbbSSjdOTdStf
D8iPQFv8HXzJltmj0uJBomIcsniv+xUsbXOSrEoxlmCcg82jkaaF/NFnl66Q9Yhs
bwIDAQAB';

 ALTER USER IDENTIFIER($SVC_ADF_USER)
     SET RSA_PUBLIC_KEY = $ADF_RSA_PUBLIC_KEY;


-- ------------------------------------------------------------
-- Terraform RSA public key
-- ------------------------------------------------------------

 SET TERRAFORM_RSA_PUBLIC_KEY =
     'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA8HhjM9yn4osGoV5CN1V+
awjybQ7CZvVyhtrHkAnDYMEhE3q7QFn/39TfnAdsC1B2/Yq9Mca5L+0DVPAFn7p4
Hu+djQHK6a6OPTgy1SUipbWYN3GgJjyWznit7HjcOTuO+3Bz8z+YNw5L/PbeOB70
gx8I+xn97AnlbHm6AlcCDiHOnyBJx+Vij2eL7ZIDP9Pzhe4p0mwh7pmvpxC7z5Q6
shSDdsaKoJqES8LD+ACq6WlIqcnvH2RnTT75+3saSBRq4EAdiyILbbSSjdOTdStf
D8iPQFv8HXzJltmj0uJBomIcsniv+xUsbXOSrEoxlmCcg82jkaaF/NFnl66Q9Yhs
bwIDAQAB';

 ALTER USER IDENTIFIER($SVC_TERRAFORM_USER)
     SET RSA_PUBLIC_KEY = $TERRAFORM_RSA_PUBLIC_KEY;


-- ============================================================
-- VALIDATION
-- ============================================================

DESCRIBE USER IDENTIFIER($SVC_ADF_USER);
SHOW GRANTS TO USER IDENTIFIER($SVC_ADF_USER);

DESCRIBE USER IDENTIFIER($SVC_TERRAFORM_USER);
SHOW GRANTS TO USER IDENTIFIER($SVC_TERRAFORM_USER);