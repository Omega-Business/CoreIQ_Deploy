# terraform/azure/client-deployment/outputs.tf
# Comprehensive deployment outputs for CoreIQ Azure client deployment

output "container_app_fqdn" {
  description = "Fully qualified domain name of the deployed Container App"
  value       = local.container_app_stable_fqdn
}

output "container_app_url" {
  description = "HTTPS URL of the deployed Container App for accessing the forward container"
  value       = "https://${local.container_app_stable_fqdn}"
}

output "resource_group_name" {
  description = "Azure resource group name where all resources are deployed"
  value       = data.azurerm_resource_group.rg.name
}

output "key_vault_name" {
  description = "Azure Key Vault name where secrets (API keys) are stored"
  value       = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  description = "Azure Key Vault URI — send this to CoreIQ after terraform apply so they can push your backend API key"
  value       = azurerm_key_vault.kv.vault_uri
}

output "key_vault_id" {
  description = "Azure resource ID of the Key Vault"
  value       = azurerm_key_vault.kv.id
}

output "container_app_name" {
  description = "Name of the deployed Container App"
  value       = azurerm_container_app.app.name
}

output "deployment_summary" {
  description = "Summary of deployed resources and connection details"
  value = {
    client_id              = var.client_id
    region                 = data.azurerm_resource_group.rg.location
    container_url          = "https://${local.container_app_stable_fqdn}"
    key_vault              = azurerm_key_vault.kv.name
    backend_integration    = "BACKEND_URL and BACKEND_API_KEY configured in Container App environment"
  }
}

output "next_steps" {
  description = "Guide for what to do after deployment"
  value = <<-EOT
    Your CoreIQ forward container has been successfully deployed to Azure!

    IMMEDIATE TESTING:
    1. Container health check:
       curl -I https://${local.container_app_stable_fqdn}/healthz

    2. Container API endpoint:
       https://${local.container_app_stable_fqdn}

    CREDENTIALS & SECURITY:
    - BACKEND_API_KEY: Stored in Container App secret "backend-api-key"
    - Access via: az keyvault secret show --vault-name ${azurerm_key_vault.kv.name} --name backend-api-key

    QUERY ROUTING:
    - All queries → CoreIQ backend (${var.do_backend_url})

    MONITORING & LOGS:
    - View container logs:
      az containerapp logs show --resource-group ${data.azurerm_resource_group.rg.name} --name ${azurerm_container_app.app.name}

    AZURE RESOURCES CREATED:
    - Container App: ${azurerm_container_app.app.name}
    - Key Vault: ${azurerm_key_vault.kv.name}
    - Resource Group: ${data.azurerm_resource_group.rg.name}

    See README.md for detailed monitoring, maintenance, and troubleshooting.
  EOT
}

output "backend_url" {
  description = "CoreIQ Digital Ocean backend URL for complex query routing"
  value       = var.do_backend_url
}

output "environment_variables_reference" {
  description = "Reference of environment variables configured in the Container App"
  value = {
    CLIENT_ID                  = var.client_id
    BACKEND_URL                = var.do_backend_url
    ENVIRONMENT                = "production"
    ENTRA_TENANT_ID            = var.azure_tenant_id
    SSO_ENABLED                = var.entra_app_client_id != "" ? "true" : "false"
    BACKEND_API_KEY_SECRET     = "backend-api-key"
  }
}

output "teams_bot_name" {
  description = "Azure Bot Service name — used when referencing the bot in Azure portal"
  value       = nonsensitive(local.bot_enabled ? azurerm_bot_service_azure_bot.teams_bot[0].name : "")
}

output "teams_bot_messaging_endpoint" {
  description = "Bot Framework messaging endpoint — configure this in Azure Bot Service and Teams manifest"
  value       = nonsensitive(local.bot_enabled ? "https://${local.container_app_stable_fqdn}/teams/messages" : "")
}

output "teams_manifest_instructions" {
  description = "Steps to complete Teams bot deployment after terraform apply"
  value = nonsensitive(local.bot_enabled ? (
    "TEAMS BOT DEPLOYMENT (manual steps after terraform apply):\n1. Run the manifest packaging script:\n   python scripts/package_teams_manifest.py \\\n     --app-id ${var.microsoft_app_id} \\\n     --domain ${local.container_app_stable_fqdn}\n2. Upload the generated ZIP to Teams Admin Center:\n   https://admin.teams.microsoft.com -> Teams apps -> Manage apps -> Upload\n3. Assign the app to users or teams as needed.\n"
  ) : "Teams bot not configured (microsoft_app_id and microsoft_app_password not set)")
}

