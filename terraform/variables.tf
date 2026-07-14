variable "snowflake_organization" {
  description = "Snowflake organization name"
  type        = string
}

variable "snowflake_account" {
  description = "Snowflake account name (within the organization)"
  type        = string
}

variable "private_key_path" {
  description = "Path to the SVC_TERRAFORM RSA private key"
  type        = string
  sensitive   = true
}

variable "environments" {
  description = "Environment prefixes - the single variable across the whole setup (Standards 3)"
  type        = list(string)
  default     = ["DEV", "TEST", "PROD"]
}

variable "timezone" {
  description = "Account timezone"
  type        = string
  default     = "America/Toronto"
}

variable "tbaytel_ip_ranges" {
  description = "Tbaytel corporate ingress IP ranges (CIDR)"
  type        = list(string)
  default     = ["0.0.0.0/0"] # TODO replace with actual ranges
}

variable "in516ht_ip_ranges" {
  description = "In516ht ingress IP ranges (CIDR)"
  type        = list(string)
  default     = ["89.212.52.137/32"]
}

variable "azure_private_link_ids" {
  description = "Azure Private Link private endpoint LinkIdentifiers (SYSTEM$GET_PRIVATELINK_AUTHORIZED_ENDPOINTS)"
  type        = list(string)
  default     = [] # TODO populate before enabling the AZURE_PRIVATE_LINK rule in INGRESS_POLICY
}

variable "azure_tenant_id" {
  description = "Azure tenant ID for the storage integration"
  type        = string
  default     = "" # TODO
}

variable "adls_allowed_locations" {
  description = "Allowed ADLS locations for the storage integration (Bronze container)"
  type        = list(string)
  default     = ["azure://<storage_account>.blob.core.windows.net/<container>/"] # TODO
}

variable "git_allowed_prefixes" {
  description = "Allowed Git URL prefixes for the API integration"
  type        = list(string)
  default     = ["https://github.com/BostjanBegelj/BB-Tbaytel.git"]
}

variable "activate_network_policy" {
  description = "Set INGRESS_POLICY on the account. LOCKOUT RISK - enable only after verifying your own IP/endpoint is allowed."
  type        = bool
  default     = false
}

variable "activate_auth_policies" {
  description = "Set account authentication/password policies. LOCKOUT RISK - enable only after SSO and service key pairs are verified."
  type        = bool
  default     = false
}
