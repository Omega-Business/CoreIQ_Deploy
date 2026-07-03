# terraform/azure/client-deployment/variables.tf

# [CoreIQ] — Set by CoreIQ team per deployment
variable "client_id" {
  description = "CoreIQ client identifier (e.g. 'acme')"
  type        = string
}
variable "backend_api_key" {
  description = "CoreIQ per-client API key — leave empty to let CoreIQ push it directly via Key Vault"
  type        = string
  sensitive   = true
  default     = ""
}
variable "restart_push_key" {
  description = "Shared secret (not per-client) authenticating the backend's outbound restart call to this container — must match the backend's own RESTART_PUSH_KEY env var"
  type        = string
  sensitive   = true
}

variable "coreiq_sp_object_id" {
  description = "Object ID of CoreIQ's service principal in the client's Azure tenant. Run: az ad sp create --id <coreiq-app-id> && az ad sp show --id <coreiq-app-id> --query id -o tsv"
  type        = string
  default     = ""
}
variable "do_backend_url" {
  description = "CoreIQ DO backend URL — must end in /backend (e.g. https://coreiq.omegabusiness.us/backend)"
  type        = string
}
variable "ghcr_image" {
  description = "GHCR image ref — must point at coreiq-client-stable (built only on GitHub Releases), not coreiq-client (builds on every push to main, for internal iteration/testing only). e.g. ghcr.io/org/coreiq-client-stable:latest"
  type        = string
  default     = "ghcr.io/omega-business/coreiq-client-stable:latest"
}

# [Client] — Provided by the client organization
variable "azure_subscription_id" { type = string }
variable "azure_tenant_id"       { type = string }
variable "resource_group_name"   { type = string }
variable "location" {
  type    = string
  default = "eastus"
}
variable "entra_app_client_id" {
  description = "Azure AD app registration client_id for SSO (optional)"
  type        = string
  default     = ""
}
variable "entra_app_client_secret" {
  description = "Azure AD app registration client_secret for SSO (optional)"
  type        = string
  sensitive   = true
  default     = ""
}
variable "ghcr_token" {
  description = "GitHub PAT or Actions token for GHCR pull"
  type        = string
  sensitive   = true
}
variable "session_secret" {
  description = "Secret key for signing client agent session cookies. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
  default     = ""
}
variable "qdrant_url" {
  description = "Qdrant cloud cluster URL (e.g. https://<id>.us-east4-0.gcp.cloud.qdrant.io)"
  type        = string
}
variable "qdrant_api_key" {
  description = "Qdrant API key (JWT) — leave empty, CoreIQ will push it directly to Key Vault post-deploy"
  type        = string
  sensitive   = true
  default     = ""
}
variable "workload_profile_type" {
  description = "Azure Container App workload profile type — D4 (4 vCPU/8 GB), D8, D16, E4, E8, E16"
  type        = string
  default     = "D4"
}
variable "workload_profile_min_count" {
  description = "Minimum dedicated node count for the workload profile"
  type        = number
  default     = 1
}
variable "workload_profile_max_count" {
  description = "Maximum dedicated node count for the workload profile"
  type        = number
  default     = 3
}
variable "dns_managed_by_do" {
  description = "Set to true once omegabusiness.us DNS is migrated to DigitalOcean. Leave false (default) if domain is still on Wix — DNS record will be skipped and must be added manually."
  type        = bool
  default     = false
}
variable "microsoft_app_id" {
  description = "Azure AD app registration Application (client) ID for the Teams bot"
  type        = string
  default     = ""
}
variable "microsoft_app_password" {
  description = "Azure AD app registration client secret for the Teams bot"
  type        = string
  sensitive   = true
  default     = ""
}
variable "microsoft_app_type" {
  description = "Azure AD app registration type — MultiTenant or SingleTenant"
  type        = string
  default     = "MultiTenant"
}
