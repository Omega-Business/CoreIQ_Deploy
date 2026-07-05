# terraform/azure/client-deployment/main.tf
terraform {
  required_version = ">= 1.3"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.48" }
    digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

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

  # Stable ingress FQDN — strips the revision suffix (--xxxxxxx) so the bot
  # messaging endpoint doesn't break when a new revision is deployed.
  container_app_stable_fqdn = replace(
    azurerm_container_app.app.latest_revision_fqdn,
    "/--[^.]+\\./",
    "."
  )
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
  value        = var.backend_api_key
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]

  # var.backend_api_key only seeds the initial value. Once a client is
  # migrated to per-client keys (services/api_key_service.py), the real
  # value is rotated out-of-band via services/secret_store_client.py's
  # Key Vault push — Terraform must not fight that rotation on every
  # subsequent apply by resetting it back to the tfvars bootstrap value.
  lifecycle {
    ignore_changes = [value]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Key Vault secrets — sourced by container app via managed identity
# ─────────────────────────────────────────────────────────────────────────────
#
# Note: no Qdrant secret here. client_agent (the forward-proxy container this
# module deploys) never talks to Qdrant directly — only the shared DO backend
# does — so a Qdrant URL/API key has no reason to live in this container's
# Key Vault at all.

resource "azurerm_key_vault_secret" "session_secret" {
  name         = "session-secret"
  value        = var.session_secret
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]
}

# Shared value both the backend and every client_agent hold in plaintext,
# used only for the backend's outbound POST {container_url}/internal/restart
# call — not tenant-bound, must match the backend's own RESTART_PUSH_KEY env var.
resource "azurerm_key_vault_secret" "restart_push_key" {
  name         = "restart-push-key"
  value        = var.restart_push_key
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
    name                = "session-secret"
    key_vault_secret_id = azurerm_key_vault_secret.session_secret.versionless_id
    identity            = azurerm_user_assigned_identity.ca_identity.id
  }
  secret {
    name                = "restart-push-key"
    key_vault_secret_id = azurerm_key_vault_secret.restart_push_key.versionless_id
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
        name        = "SESSION_SECRET"
        secret_name = "session-secret"
      }
      env {
        name        = "RESTART_PUSH_KEY"
        secret_name = "restart-push-key"
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
# Register this container's URL with the backend — authenticates with this
# client's own issued API key (backend_api_key), validated per-client on the
# backend (services/api_key_service.py), so a client can only register its
# own container_url. Only runs when the key is known at apply time (CoreIQ's
# own deployments, where the key is issued before running terraform). For
# client-managed deployments where the key is pushed post-deploy via Key
# Vault (see client_deploy_checklist.md), this step is skipped and the
# CoreIQ team registers container_url manually once the key lands.
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "register_container_url" {
  count = var.backend_api_key != "" ? 1 : 0

  triggers = {
    container_url = "https://${local.container_app_stable_fqdn}"
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sf -X POST "${var.do_backend_url}/internal/clients/${var.client_id}/container-url" \
        -H "Authorization: Bearer ${var.backend_api_key}" \
        -H "Content-Type: application/json" \
        -d '{"url": "https://${local.container_app_stable_fqdn}"}'
    EOT
  }

  depends_on = [azurerm_container_app.app]
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
  endpoint            = "https://${local.container_app_stable_fqdn}/teams/messages"

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

