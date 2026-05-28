# terraform/azure/client-deployment/main.tf
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.48" }
    azapi   = { source = "azure/azapi", version = "~> 1.0" }
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" }
  }
}

provider "azapi" {}

# DigitalOcean provider — configured when DNS is moved from Wix
# Until then, set via environment: export DIGITALOCEAN_TOKEN="your-token"
provider "digitalocean" {}


provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

locals {
  safe_client_id = lower(replace(var.client_id, "_", "-"))
  kv_name        = "ciq-${substr(local.safe_client_id, 0, min(length(local.safe_client_id), 14))}-kv"
  bot_enabled    = var.microsoft_app_id != "" && var.microsoft_app_password != ""
}

# Key Vault — stores BACKEND_API_KEY and Entra creds
resource "azurerm_key_vault" "kv" {
  name                       = local.kv_name
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = var.azure_tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
}

resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = ["Get", "Set", "List", "Delete", "Purge", "Recover"]
}

resource "azurerm_key_vault_secret" "api_key" {
  name         = "coreiq-api-key"
  value        = var.backend_api_key != "" ? var.backend_api_key : "bootstrap-pending"
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]

  # CoreIQ pushes the real key post-deploy via the coreiq_push access policy.
  # Ignore value drift so future terraform applies don't overwrite it.
  lifecycle {
    ignore_changes = [value]
  }
}

# CoreIQ push access — grants CoreIQ's multi-tenant SP permission to set/get
# the backend API key for zero-touch key delivery and rotation.
resource "azurerm_key_vault_access_policy" "coreiq_push" {
  count        = var.coreiq_sp_object_id != "" ? 1 : 0
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = var.azure_tenant_id
  object_id    = var.coreiq_sp_object_id

  secret_permissions = ["Get", "Set"]
}

# ─────────────────────────────────────────────────────────────────────────────
# Azure AI Foundry — local query routing model (OpenAI GPT or Microsoft Phi)
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_cognitive_account" "ai_foundry" {
  name                = "coreiq-${local.safe_client_id}-foundry"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  kind                = "OpenAI"
  sku_name            = var.foundry_sku

  tags = {
    Project   = "CoreIQ"
    Component = "AI-Foundry"
    Client    = var.client_id
  }
}

resource "azapi_resource" "foundry_model_deployment" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2023-05-01"
  name      = var.foundry_model
  parent_id = azurerm_cognitive_account.ai_foundry.id

  body = jsonencode({
    properties = {
      model = {
        format  = var.foundry_model_format
        name    = var.foundry_model
        version = var.foundry_model_version
      }
    }
    sku = {
      name     = "Standard"
      capacity = 10
    }
  })

  depends_on = [azurerm_cognitive_account.ai_foundry]
}

# Store Foundry API key in Key Vault
resource "azurerm_key_vault_secret" "foundry_api_key" {
  name         = "foundry-api-key"
  value        = azurerm_cognitive_account.ai_foundry.primary_access_key
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]
}

# ─────────────────────────────────────────────────────────────────────────────
# Key Vault secrets — sourced by container app via managed identity
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_key_vault_secret" "qdrant_api_key" {
  name         = "qdrant-api-key"
  value        = var.qdrant_api_key != "" ? var.qdrant_api_key : "bootstrap-pending"
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]

  # CoreIQ pushes the real scoped key post-deploy once client collections exist.
  # ignore_changes prevents terraform apply from overwriting it.
  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "session_secret" {
  name         = "session-secret"
  value        = var.session_secret
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]
}

resource "azurerm_key_vault_secret" "microsoft_app_password" {
  count        = local.bot_enabled ? 1 : 0
  name         = "microsoft-app-password"
  value        = var.microsoft_app_password
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]
}

# ─────────────────────────────────────────────────────────────────────────────
# Managed identity — created before the container app so KV access policy
# can be granted before the app attempts to read secrets
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "ca_identity" {
  name                = "coreiq-${local.safe_client_id}-identity"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_key_vault_access_policy" "ca_identity" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = var.azure_tenant_id
  object_id          = azurerm_user_assigned_identity.ca_identity.principal_id
  secret_permissions = ["Get"]
}

# ─────────────────────────────────────────────────────────────────────────────
# Container App environment — Workload Profiles (required for KV references)
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_container_app_environment" "env" {
  name                = "coreiq-${local.safe_client_id}-env"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  workload_profile {
    name                  = "Dedicated"
    workload_profile_type = var.workload_profile_type
    minimum_count         = var.workload_profile_min_count
    maximum_count         = var.workload_profile_max_count
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Container App — client frontend + agent
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_container_app" "app" {
  name                         = "coreiq-${local.safe_client_id}"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = data.azurerm_resource_group.rg.name
  revision_mode                = "Single"
  workload_profile_name        = "Dedicated"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ca_identity.id]
  }

  registry {
    server               = "ghcr.io"
    username             = "x-access-token"
    password_secret_name = "ghcr-token"
  }

  # ghcr-token must remain a plain Container App secret — registry auth
  # does not support Key Vault references
  secret {
    name  = "ghcr-token"
    value = var.ghcr_token
  }
  secret {
    name                = "backend-api-key"
    key_vault_secret_id = azurerm_key_vault_secret.api_key.versionless_id
    identity            = azurerm_user_assigned_identity.ca_identity.id
  }
  secret {
    name                = "foundry-api-key"
    key_vault_secret_id = azurerm_key_vault_secret.foundry_api_key.versionless_id
    identity            = azurerm_user_assigned_identity.ca_identity.id
  }
  secret {
    name                = "qdrant-api-key"
    key_vault_secret_id = azurerm_key_vault_secret.qdrant_api_key.versionless_id
    identity            = azurerm_user_assigned_identity.ca_identity.id
  }
  secret {
    name                = "session-secret"
    key_vault_secret_id = azurerm_key_vault_secret.session_secret.versionless_id
    identity            = azurerm_user_assigned_identity.ca_identity.id
  }
  dynamic "secret" {
    for_each = local.bot_enabled ? [1] : []
    content {
      name                = "microsoft-app-password"
      key_vault_secret_id = azurerm_key_vault_secret.microsoft_app_password[0].versionless_id
      identity            = azurerm_user_assigned_identity.ca_identity.id
    }
  }

  template {
    container {
      name   = "coreiq-client"
      image  = var.ghcr_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "CLIENT_ID"
        value = var.client_id
      }
      env {
        name  = "BACKEND_URL"
        value = var.do_backend_url
      }
      env {
        name        = "BACKEND_API_KEY"
        secret_name = "backend-api-key"
      }
      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
      env {
        name  = "ENTRA_TENANT_ID"
        value = var.azure_tenant_id
      }
      env {
        name  = "SSO_ENABLED"
        value = var.entra_app_client_id != "" ? "true" : "false"
      }
      env {
        name  = "FOUNDRY_ENDPOINT"
        value = azurerm_cognitive_account.ai_foundry.endpoint
      }
      env {
        name  = "FOUNDRY_MODEL"
        value = var.foundry_model
      }
      env {
        name        = "FOUNDRY_API_KEY"
        secret_name = "foundry-api-key"
      }
      env {
        name  = "QDRANT_URL"
        value = var.qdrant_url
      }
      env {
        name        = "QDRANT_API_KEY"
        secret_name = "qdrant-api-key"
      }
      env {
        name        = "SESSION_SECRET"
        secret_name = "session-secret"
      }
      dynamic "env" {
        for_each = local.bot_enabled ? [1] : []
        content {
          name  = "MICROSOFT_APP_ID"
          value = var.microsoft_app_id
        }
      }
      dynamic "env" {
        for_each = local.bot_enabled ? [1] : []
        content {
          name        = "MICROSOFT_APP_PASSWORD"
          secret_name = "microsoft-app-password"
        }
      }
    }
    min_replicas = 1
    max_replicas = 3
  }

  ingress {
    external_enabled = true
    target_port      = 80
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  depends_on = [azurerm_key_vault_access_policy.ca_identity]
}

# ─────────────────────────────────────────────────────────────────────────────
# DNS — DigitalOcean (when domain moves from Wix)
# ─────────────────────────────────────────────────────────────────────────────
# This resource is configured when DNS is migrated to DigitalOcean.
# Until then: manually add CNAME in Wix:
#   {client_id}.coreiq.omegabusiness.us → {container_app_fqdn}

resource "digitalocean_record" "client_cname" {
  count  = var.dns_managed_by_do ? 1 : 0
  domain = "omegabusiness.us"
  type   = "CNAME"
  name   = "${var.client_id}.coreiq"
  value  = azurerm_container_app.app.latest_revision_fqdn
  ttl    = 3600
}

# ─────────────────────────────────────────────────────────────────────────────
# Azure Bot Service — Teams channel integration
# Created only when microsoft_app_id is provided
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_bot_service_azure_bot" "teams_bot" {
  count               = local.bot_enabled ? 1 : 0
  name                = "coreiq-${local.safe_client_id}-bot"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = "global"
  microsoft_app_id        = var.microsoft_app_id
  microsoft_app_type      = var.microsoft_app_type
  microsoft_app_tenant_id = var.azure_tenant_id
  sku                     = "S1"
  endpoint            = "https://${azurerm_container_app.app.latest_revision_fqdn}/teams/messages"

  tags = {
    Project   = "CoreIQ"
    Component = "Teams-Bot"
    Client    = var.client_id
  }
}

resource "azurerm_bot_channel_ms_teams" "teams" {
  count               = local.bot_enabled ? 1 : 0
  bot_name            = azurerm_bot_service_azure_bot.teams_bot[0].name
  location            = azurerm_bot_service_azure_bot.teams_bot[0].location
  resource_group_name = data.azurerm_resource_group.rg.name
}

