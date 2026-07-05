# CoreIQ Forward Container Deployment Checklist

> **Estimated Time:** 30-45 minutes  
> **Difficulty:** Intermediate (requires Azure and Terraform familiarity)  
> **Support:** Contact CoreIQ team if blocked at any step

---

## Phase 1: Pre-Deployment Prerequisites

### Azure Account Setup

- [ ] **Azure Subscription Active**
  - Confirm you have an active Azure subscription
  - Have `Contributor` or `Owner` role in the target subscription
  - Command to verify: `az account show`

- [ ] **Azure CLI Installed and Authenticated**
  - Version 2.60+: `az --version`
  - If not installed: [Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
  - Authenticate: `az login`
  - Select subscription: `az account set --subscription <subscription-id>`

- [ ] **Terraform Installed**
  - Version 1.3+: `terraform version`
  - If not installed: [Install Terraform](https://www.terraform.io/downloads)

- [ ] **Terraform Script Available**
  - Obtain the CoreIQ Terraform deployment package for Azure from the CoreIQ team
  - Directory: `terraform/azure/client-deployment/` exists and readable

### Client Configuration Decisions

- [ ] **Decide Client ID**
  - Format: lowercase alphanumeric + underscore/hyphen only
  - Examples: `acme`, `demo`, `acme-corp`, `client_123`
  - Used in resource naming: `coreiq-{client_id}`
  - Store this value — you'll use it throughout

- [ ] **Notify CoreIQ Team you are starting a deployment** ⚠️ Do this now
  - Email: [CoreIQ contact]
  - Information to provide:
    - Client ID: `{client_id}` (decided above)
    - Display name for your organization (e.g. "Acme Corp")
    - Initial admin username (e.g. `admin` or a real name)
    - Initial admin email address
    - Azure region you will deploy to
  - CoreIQ will provision your backend resources and send you:
    - **Backend API key** via secure one-time link (pushed to your Key Vault post-deploy)
    - **Admin portal credentials** via secure one-time link (temporary password, change on first login)

- [ ] **Choose Azure Region**
  - Must support Azure Container Apps (Dedicated workload profiles)
  - Recommended regions: `eastus`, `westeurope`, `uksouth`

---

## Phase 2: Credential & Access Preparation

> **Blocked on CoreIQ team?** If you haven't received your `BACKEND_API_KEY` yet, you can
> complete all of Phase 2 and Phase 3 up to the `backend_api_key` line, then pause until
> the key arrives. Don't start `terraform apply` without it.

### Azure Credentials

- [ ] **Retrieve Azure Subscription ID**
  ```bash
  az account show --query id -o tsv
  ```
  - Copy the output (UUID format)
  - Save as: `AZURE_SUBSCRIPTION_ID`

- [ ] **Retrieve Azure Tenant ID**
  ```bash
  az account show --query tenantId -o tsv
  ```
  - Copy the output (UUID format)
  - Save as: `AZURE_TENANT_ID`

- [ ] **Create or Verify Resource Group**
  - The Terraform script looks up an existing resource group — it will not create one for you
  - If using an existing RG: confirm it exists with `az group show --resource-group <name>`
  - If creating a new one:
    ```bash
    az group create --name coreiq-{client_id} --location {your-azure-region}
    ```
  - Recommended name: `coreiq-{client_id}`
  - Save as: `AZURE_RESOURCE_GROUP`

### GitHub Container Registry (GHCR) Token

- [ ] **Create GitHub Personal Access Token**
  - Go to: https://github.com/settings/tokens/new
  - Token name: `CoreIQ GHCR Read` (or similar)
  - Expiration: 90 days (or your preference)
  - Scopes needed: ✅ `read:packages` only
  - ❌ Do NOT check `write:packages` (unnecessary)
  - ❌ Do NOT check `repo` or `admin` (security risk)
  - Click "Generate token"
  - **Copy the token immediately** — you won't see it again
  - Save as: `GHCR_TOKEN` (keep it private)

> **Which image?** `terraform.tfvars`'s `ghcr_image` must point at `coreiq-client-stable` (built only when CoreIQ publishes a GitHub Release), never `coreiq-client` (builds on every push to `main` — internal iteration/testing only, not meant for client deployments).

### CoreIQ Backend URL

- [ ] **Backend URL**
  - Value: `https://coreiq.omegabusiness.us/backend`
  - Save as: `BACKEND_URL` (pre-filled in tfvars — no action needed)

### CoreIQ-Provided Credentials

> Qdrant is not part of this list — the forward-proxy container this module deploys never talks to Qdrant directly (only the shared DO backend does), so no Qdrant URL/API key is provisioned here. Likewise, there is no AI Foundry / Cognitive Services resource in this module — generation is handled entirely by the shared DO backend, not by per-client Azure infrastructure.

- [ ] **restart_push_key**
  - Provided by CoreIQ team (shared secret, not per-client)
  - Must match the backend's own `RESTART_PUSH_KEY` — used only for the backend's outbound restart call to your container

### Teams Bot App Registration (Optional — skip if not using Microsoft Teams)

> **Can be added later.** Leave `microsoft_app_id` and `microsoft_app_password` empty on first deploy — no bot resources are created and nothing breaks. When you're ready to enable Teams, create the app registration below, add the values to tfvars, and re-run `terraform apply`. Terraform will add the bot resources incrementally.

- [ ] **Open Microsoft Entra ID**
  - Azure portal → search "Microsoft Entra ID" in the top bar (this is the new name for Azure Active Directory)
  - Go to **App registrations** → **All applications** tab

- [ ] **Create a new app registration**
  - Click **+ New registration**
  - Name: `CoreIQ Bot` (or similar)
  - Supported account types: choose **Single tenant** (your org only) or **Multitenant** depending on your needs
  - Redirect URI: leave blank
  - Click **Register**

- [ ] **Copy the Application (client) ID**
  - On the app overview page, copy the **Application (client) ID** (UUID format)
  - Save as: `MICROSOFT_APP_ID`

- [ ] **Create a client secret**
  - In the left sidebar: **Certificates & secrets** → **Client secrets** tab
  - Click **+ New client secret**
  - Description: `CoreIQ Terraform` (or similar)
  - Expiry: 24 months recommended
  - Click **Add**
  - **Copy the secret Value immediately** — it is only shown once and cannot be retrieved later
  - Save as: `MICROSOFT_APP_PASSWORD` (keep private — treat like a password)

- [ ] **Note your registration type**
  - Single tenant → set `microsoft_app_type = "SingleTenant"` in tfvars
  - Multitenant → set `microsoft_app_type = "MultiTenant"` in tfvars

---

## Phase 3: Terraform Configuration

### Prepare terraform.tfvars

- [ ] **Copy Example File**
  ```bash
  cd terraform/azure/client-deployment/
  cp terraform.tfvars.example terraform.tfvars
  ```

- [ ] **Open terraform.tfvars in Text Editor**
  - Recommended editors: VS Code, nano, vim, or IDE of choice
  - File location: `terraform/azure/client-deployment/terraform.tfvars`

### Fill REQUIRED Section

Replace placeholders in the REQUIRED section:

- [ ] **client_id** 
  - Value: `{your-client-id}` (from Phase 1)
  - Example: `acme`

- [ ] **azure_subscription_id**
  - Value: UUID from `az account show` (Phase 2)
  - Format: `12345678-1234-1234-1234-123456789abc`

- [ ] **azure_tenant_id**
  - Value: UUID from Azure (Phase 2)
  - Format: `87654321-4321-4321-4321-cba987654321`

- [ ] **location**
  - Value: Azure region chosen in Phase 1
  - Default: `eastus` — leave as-is if following recommendation

- [ ] **resource_group_name**
  - Value: `coreiq-{client_id}` (recommended)
  - Example: `coreiq-acme`
  - Leave as-is if following recommendation

- [ ] **ghcr_token**
  - Value: GitHub Personal Access Token (Phase 2)
  - Format: `ghp_xxxxx...`
  - Keep private — don't commit to Git

- [ ] **session_secret** (Strongly recommended)
  - Generate with: `openssl rand -hex 32`
  - If left empty, a random key is generated on each container restart — users will be logged out on every redeploy
  - Keep private — don't commit to Git

### Fill PROVIDED_BY_COREIQ Section

Values provided by CoreIQ team:

- [ ] **backend_api_key**
  - Leave empty (`""`) — do not fill this in
  - CoreIQ will push the real key to your Key Vault after deployment
  - The container will start with a placeholder and become fully functional once CoreIQ pushes the key (within minutes of you sharing your `key_vault_uri` output)

- [ ] **restart_push_key**
  - Value: From CoreIQ team (Phase 2) — shared secret, not per-client
  - Must match the backend's own `RESTART_PUSH_KEY`

- [ ] **do_backend_url**
  - Value: From CoreIQ team (Phase 2)
  - Format: `https://coreiq.omegabusiness.us/backend`
  - Pre-filled with CoreIQ's production URL

- [ ] **ghcr_image**
  - Leave as default (`ghcr.io/omega-business/coreiq-client-stable:latest`) unless CoreIQ instructs otherwise

### Fill OPTIONAL Section (Optional)

- [ ] **entra_app_client_id** (Optional — skip if not using SSO)
  - Only needed if: You want Azure Entra ID single sign-on
  - If not using: Leave empty or commented out
  - If using: Create Entra app and paste ID here

- [ ] **entra_app_client_secret** (Optional — skip if not using SSO)
  - Only needed if: You want Azure Entra ID single sign-on
  - If not using: Leave empty or commented out
  - If using: Paste Entra app secret here

- [ ] **Teams Bot** (Optional — skip if not integrating with Microsoft Teams)
  - Only needed if: You want a CoreIQ bot available inside Microsoft Teams
  - If not using: Leave `microsoft_app_id` and `microsoft_app_password` empty — bot resources are not created
  - If using: You should have completed the app registration in Phase 2. Fill in:
  - **`microsoft_app_id`** — `MICROSOFT_APP_ID` from Phase 2
  - **`microsoft_app_password`** — `MICROSOFT_APP_PASSWORD` from Phase 2 (keep private)
  - **`microsoft_app_type`** — `"SingleTenant"` or `"MultiTenant"` from Phase 2

- [ ] **Workload Profile** (defaults are fine — no changes required)
  - Variables: `workload_profile_type`, `workload_profile_min_count`, `workload_profile_max_count`
  - Default profile: D4 (4 vCPU / 8 GB RAM), minimum 1 instance
  - Note: The dedicated workload profile runs 24/7 and incurs continuous hourly compute cost regardless of traffic. Adjust `workload_profile_min_count` if cost management is a concern.
  - Default `dns_managed_by_do = false` — leave as-is unless CoreIQ team instructs otherwise

### Validate terraform.tfvars

- [ ] **Review File**
  - Confirm all REQUIRED fields are filled
  - Confirm no secrets are visible in git history:
    ```bash
    git status terraform/azure/client-deployment/terraform.tfvars
    ```
  - Should NOT be staged for commit

---

## Phase 4: Terraform Deployment Execution

### Initialize Terraform

- [ ] **Run Terraform Init**
  ```bash
  cd terraform/azure/client-deployment/
  terraform init
  ```
  - Expected output: Downloads Azure provider plugins
  - Takes: ~30 seconds
  - If error: Check internet connection, Azure CLI authentication

- [ ] **Validate Configuration**
  ```bash
  terraform validate
  ```
  - Expected output: `Success! The configuration is valid.`
  - If error: Check terraform.tfvars for typos (quotes, commas, values)
  - Must run `terraform init` before this step — validate requires providers to be installed

### Review Deployment Plan

- [ ] **Generate Terraform Plan**
  ```bash
  terraform plan -out=tfplan
  ```
  - Review output carefully for:
    - ✅ Correct number of resources (~9-10 resources for a standard deployment without Teams bot; ~12-13 with Teams bot)
    - ✅ Correct resource group name: `coreiq-{client_id}`
    - ✅ Correct location: `{your-region}`
    - ✅ Resources being CREATED (no DESTROY unless re-deploying)
  - Expected resources:
    - [ ] 1x User-assigned managed identity
    - [ ] 1x Key Vault + 2x access policies + 3x secrets (backend key, restart-push key, session secret)
    - [ ] 1x Container App Environment (Dedicated, D4 workload profile)
    - [ ] 1x Container App
    - [ ] 1x `null_resource` registering the container URL with the backend (only if `backend_api_key` is set at apply time — typically left empty per this checklist, so usually not created on first apply)
    - [ ] 1x DigitalOcean DNS record (only if `dns_managed_by_do = true`)
    - [ ] Optionally: 1x Bot Service + 1x Teams channel + 1x KV secret (only if `microsoft_app_id` is set)

- [ ] **Verify No Destruction**
  - Search plan output for `destroy`
  - Should find ZERO lines containing `destroy`
  - If found: Review changes carefully before proceeding

### Apply Configuration

- [ ] **Deploy to Azure**
  ```bash
  terraform apply tfplan
  ```
  - Expected output:
    ```
    Apply complete! Resources: X added, 0 changed, 0 destroyed.
    
    Outputs:
    container_app_url = https://coreiq-{client_id}.azurecontainerapps.io
    key_vault_uri = https://ciq-{client_id}-kv.vault.azure.net/
    ...
    ```
  - Takes: 3-7 minutes (mostly waiting for Container App to provision)
  - Save the outputs — you'll need them for verification

### Push Secrets to Key Vault

> The container will start but requests will fail until CoreIQ pushes these keys. CoreIQ delivers all secrets — you never need to store or handle the values, just run the commands with the values CoreIQ provides.

- [ ] **Send CoreIQ your Key Vault name and URL** (from `terraform output`)
  ```bash
  terraform output key_vault_name
  terraform output key_vault_uri
  ```
  - CoreIQ needs these to know where to push your secrets

- [ ] **CoreIQ will send you one key via secure one-time link:**
  - `coreiq-api-key` — backend API key

- [ ] **Push the key to Key Vault** (paste value from the secure link — do not save it)
  ```bash
  az keyvault secret set \
    --vault-name ciq-{client_id}-kv \
    --name coreiq-api-key \
    --value "<paste key here>"
  ```
  - Expected output: JSON confirming the secret was set
  - The key is now in Key Vault — you do not need to keep a copy

- [ ] **Restart the container to pick up the keys**
  ```bash
  az containerapp revision restart \
    --resource-group coreiq-{client_id} \
    --name coreiq-{client_id} \
    --revision $(az containerapp show \
      --resource-group coreiq-{client_id} \
      --name coreiq-{client_id} \
      --query properties.latestRevisionName -o tsv)
  ```

### Verify Deployment Success

- [ ] **Check Resource Group Created**
  ```bash
  az group show --resource-group coreiq-{client_id}
  ```
  - Should return JSON with group details

- [ ] **Check Container App Status**
  ```bash
  az containerapp show \
    --resource-group coreiq-{client_id} \
    --name coreiq-{client_id}
  ```
  - Look for: `"provisioningState": "Succeeded"`

---

## Phase 5: Post-Deployment Verification

### Health Check

- [ ] **Test Container Health Endpoint**
  ```bash
  curl -I https://coreiq-{client_id}.azurecontainerapps.io/healthz
  ```
  - Expected output: `HTTP/1.1 200 OK`
  - If 404 or timeout: Wait 1-2 minutes (container still starting)

- [ ] **Check Container Logs**
  ```bash
  az containerapp logs show \
    --resource-group coreiq-{client_id} \
    --name coreiq-{client_id} \
    --tail 50
  ```
  - Expected log lines:
    ```
    Starting client agent on :8000
    Starting nginx
    Uvicorn running on http://0.0.0.0:8000
    nginx started
    ```
  - If ERROR: Scroll down to see full error message

### Frontend Access

- [ ] **Load Frontend in Browser**
  - URL: `https://coreiq-{client_id}.azurecontainerapps.io`
  - Expected: Portal UI loads (may show "Connecting..." briefly)
  - Check browser console (F12 → Console) for JavaScript errors

- [ ] **Verify Configuration**
  - Browser console should show:
    ```
    apiUrl: https://coreiq.omegabusiness.us
    clientId: {client_id}
    ssoEnabled: false
    ```

### Test Query (Simple)

- [ ] **Send Test Query to Backend**
  ```bash
  curl -X POST \
    https://coreiq-{client_id}.azurecontainerapps.io/api/chat \
    -H "Content-Type: application/json" \
    -d '{
      "message": "What is CoreIQ?",
      "collection_name": "default",
      "thread_id": "test"
    }'
  ```
  - Expected response:
    ```json
    {
      "answer": "...",
      "citations": [...],
      "tier": "..."
    }
    ```
  - If 400/401/500: Check error message, see Troubleshooting below

---

## Phase 5b: Post-Deployment Hardening

> These steps can only be completed after deployment because they depend on resources that don't exist until `terraform apply` has run.

### Enable Teams Bot (Optional — when ready)

- [ ] **Create Azure AD app registration** (see Phase 2 Teams Bot section for steps)

- [ ] **Update tfvars with app credentials**
  ```hcl
  microsoft_app_id       = "<app-id>"
  microsoft_app_password = "<client-secret>"
  microsoft_app_type     = "MultiTenant"  # or "SingleTenant"
  ```

- [ ] **Re-run terraform apply**
  ```bash
  terraform apply
  ```
  - Terraform adds bot resources incrementally — existing resources are unaffected

- [ ] **Generate the Teams manifest ZIP**
  ```bash
  python scripts/package_teams_manifest.py \
    --app-id <MICROSOFT_APP_ID> \
    --domain <container_app_fqdn>
  ```
  - `container_app_fqdn` comes from `terraform output container_app_fqdn`
  - Produces: `coreiq-teams-{domain}.zip`

- [ ] **Upload the ZIP to Teams Admin Center**
  - Go to: https://admin.teams.microsoft.com → Teams apps → Manage apps → Upload
  - Assign the app to users or teams as needed

---

## Phase 6: Cleanup & Documentation

### Save Important Information

- [ ] **Document Endpoints**
  - Container App URL: `https://coreiq-{client_id}.azurecontainerapps.io`
  - Resource Group: `coreiq-{client_id}`
  - Save in password manager or secure doc

- [ ] **Securely Store Credentials**
  - BACKEND_API_KEY: Stored in Azure Key Vault (not in terraform.tfvars)
  - GHCR_TOKEN: Already provided to Terraform, not needed again
  - Do NOT commit terraform.tfvars to Git

### Clean Up Local Files

- [ ] **Remove tfplan File**
  ```bash
  rm tfplan
  ```

- [ ] **Git Configuration** (if using version control)
  ```bash
  # Ensure terraform.tfvars is ignored
  echo "terraform/azure/client-deployment/terraform.tfvars" >> .gitignore
  git add .gitignore
  git commit -m "chore: ignore terraform.tfvars with credentials"
  ```

- [ ] **Backup terraform.tfvars**
  - Save copy in secure location (not Git)
  - Useful for future Terraform updates or re-deployments

### Document for Team

- [ ] **Share with Team**
  - Container App URL (public)
  - Resource Group name (internal reference)
  - Who to contact for secrets rotation
  - Who manages Terraform state

---

## Phase 7: Troubleshooting

### Container Won't Start

**Symptom:** Container shows "CrashLoopBackOff" or "Waiting"

**Steps:**
- [ ] Check logs: `az containerapp logs show --resource-group coreiq-{client_id} --name coreiq-{client_id}`
- [ ] Common causes:
  - BACKEND_URL not set or invalid → Check terraform.tfvars
  - BACKEND_API_KEY rejected → Verify key with CoreIQ team
- [ ] Force a new revision: `az containerapp update --resource-group coreiq-{client_id} --name coreiq-{client_id} --revision-suffix "v2"`

### 401 Unauthorized to Backend

**Symptom:** Logs show "Invalid or expired API key" when querying

**Steps:**
- [ ] Verify BACKEND_API_KEY in Key Vault:
  ```bash
  az keyvault secret show \
    --vault-name ciq-{client_id}-kv \
    --name coreiq-api-key \
    --query value
  ```
- [ ] Confirm key matches what CoreIQ provided
- [ ] Request new key from CoreIQ if expired
- [ ] Update Key Vault secret:
  ```bash
  az keyvault secret set \
    --vault-name ciq-{client_id}-kv \
    --name coreiq-api-key \
    --value "new-key-here"
  ```

### Frontend Loads but Queries Fail

**Symptom:** Browser shows "Backend unavailable" message

**Steps:**
- [ ] Check BACKEND_URL is correct:
  ```bash
  az containerapp show \
    --resource-group coreiq-{client_id} \
    --name coreiq-{client_id} \
    --query properties.template.containers[0].env
  ```
- [ ] Verify CoreIQ backend is accessible:
  ```bash
  curl -I https://coreiq.omegabusiness.us/health
  ```
- [ ] Check network connectivity: Container may need firewall rules

### Terraform Apply Fails

**Symptom:** `terraform apply` returns error

**Steps:**
- [ ] Verify Azure authentication: `az account show`
- [ ] Re-login if needed: `az login`
- [ ] Check Container Apps Dedicated workload profile quota in region
- [ ] Run `terraform validate` to check syntax
- [ ] Delete `.terraform` and re-run `terraform init`:
  ```bash
  rm -rf .terraform
  terraform init
  terraform plan -out=tfplan
  terraform apply tfplan
  ```

---

## Getting Help

**If you're blocked:**

1. **Check Logs First**
   ```bash
   az containerapp logs show --resource-group coreiq-{client_id} --name coreiq-{client_id} --tail 100
   ```

2. **Contact CoreIQ Support**
   - Provide:
     - Container App name: `coreiq-{client_id}`
     - Error message from logs
     - Steps you've already tried
     - terraform.tfvars values (without secrets)

3. **Useful Commands for Debugging**
   ```bash
   # View all resources in your resource group
   az resource list --resource-group coreiq-{client_id}
   
   # Check container app scale
   az containerapp show --resource-group coreiq-{client_id} --name coreiq-{client_id}
   
   # View Key Vault secrets
   az keyvault secret list --vault-name ciq-{client_id}-kv
   ```

---

## Success Criteria

You're done when:

- ✅ Container App is running (status: `Provisioned`)
- ✅ Health check returns 200: `curl -I https://coreiq-{client_id}.azurecontainerapps.io/healthz`
- ✅ Frontend loads in browser
- ✅ Test query returns answer (not error)
- ✅ Terraform state is secure (not in Git)
- ✅ Team has documented endpoints and procedures

**Estimated total time:** 30-45 minutes (mostly waiting for Azure to provision)

---

## Appendix: Environment Variable Reference

Every environment variable injected into the container and how it gets there.

| Environment Variable | Source | Path |
|----------------------|--------|------|
| `CLIENT_ID` | `var.client_id` | tfvars (REQUIRED) → plain env var |
| `BACKEND_URL` | `var.do_backend_url` | tfvars (PROVIDED_BY_COREIQ) → plain env var |
| `BACKEND_API_KEY` | CoreIQ-pushed | CoreIQ sends key via secure link; client runs `az keyvault secret set` → Key Vault secret `coreiq-api-key` → Container App secret ref |
| `ENVIRONMENT` | hardcoded `"production"` | set in main.tf — no tfvars entry needed |
| `ENTRA_TENANT_ID` | `var.azure_tenant_id` | tfvars (REQUIRED) → plain env var |
| `SSO_ENABLED` | derived | `"true"` if `entra_app_client_id` is set, otherwise `"false"` — no direct tfvars entry |
| `RESTART_PUSH_KEY` | `var.restart_push_key` | tfvars (PROVIDED_BY_COREIQ) → Key Vault secret `restart-push-key` → Container App secret ref |
| `MICROSOFT_APP_ID` | `var.microsoft_app_id` | tfvars (OPTIONAL) → plain env var — omitted if empty |
| `MICROSOFT_APP_PASSWORD` | `var.microsoft_app_password` | tfvars (OPTIONAL) → Key Vault secret `microsoft-app-password` → Container App secret ref — omitted if empty |

**Key Vault secrets** are read by the container via a user-assigned managed identity — the identity is granted `Get` access to the vault before the container app is created. Plain env vars are set directly on the container revision with no secret storage.

---

## Appendix: Omega Deployment Reconciliation (Internal)

> **Internal use only.** This section documents the known drift between the `coreiq-omega` Azure deployment (the original hand-provisioned instance) and the Terraform module. A fresh `terraform apply` against a new resource group will match the module exactly — this drift only affects the omega test environment.

### Drift Summary (as of 2026-05-28)

> **Foundry and Qdrant rows below are historical.** Both were later removed from the Terraform module entirely (Foundry: commit `db5823c`, "Local query-routing tier was already dead in client_agent's actual code path"; Qdrant: this session, since the forward container never talks to Qdrant directly). The "Terraform expects" column for those two rows reflects what the module required on 2026-05-28, not what it requires today — kept here only as a record of the drift analysis performed at that time, not as current guidance.

| Resource | Terraform expects (2026-05-28) | Omega actual | Status |
|---|---|---|---|
| Container App Environment | Dedicated (WorkloadProfiles) with D4 profile | Consumption (`workloadProfiles: null`) | ❌ Requires recreation |
| Managed identity | User-assigned `coreiq-omega-identity` | None (SystemAssigned on Container App) | ❌ Not created |
| KV secret: backend API key | `coreiq-api-key` | `coreiq-api-key` | ✅ Matches |
| KV secret: Foundry key *(historical — removed from module)* | `foundry-api-key` | `foundry-api-key` | ✅ Matched at the time |
| KV secret: Qdrant key *(historical — removed from module)* | `qdrant-api-key` | `qdrant-api` | ❌ Name mismatch at the time |
| KV secret: session secret | `session-secret` | Missing | ❌ Not created |
| KV secret: bot password | `microsoft-app-password` | Missing (set as plain env var) | ❌ Not created |
| Container App secrets | KV references for all secrets except ghcr | Plain inline values (`backend-api-key`, `foundry-api-key`, `ghcr-token`) | ❌ Not KV-backed |
| Bot Service | `coreiq-omega-bot` (auto-named) | `CoreIQ` (manually created) | ⚠️ Different name |
| Foundry model deployment *(historical — removed from module)* | 1x deployment (`var.foundry_model`) | 2x deployments (`Phi-35-mini-instruct`, `gpt-5.4-nano`) | ⚠️ Extra deployment at the time |

### Why the Consumption environment matters

Azure Container Apps on a **Consumption** environment cannot use `key_vault_secret_id` references in secrets — that feature requires a **Dedicated** (WorkloadProfiles) environment. As a result, the omega deployment has inline secret values in Container App config rather than KV references. This is the root cause of most other drift: without KV references, there was no need for a user-assigned managed identity, and secrets couldn't be rotated centrally.

### Reconciliation path for omega

The environment type cannot be changed in-place. Full reconciliation requires:

1. Create a new resource group (e.g., `coreiq-omega-v2`)
2. Run `terraform apply` against the new RG with omega's `terraform.tfvars`
3. Update DNS CNAME in Wix to point to the new Container App FQDN
4. Update the Bot Service messaging endpoint to the new FQDN
5. Decommission `coreiq-omega` resource group after verification

Until then, omega continues to function with inline secrets — it's functional but not managed by Terraform.

### Terraform import commands (if ever needed)

If you want to bring an existing Consumption-environment deployment under Terraform management **without** KV secret references, you would need to temporarily remove the `key_vault_secret_id` blocks and revert to inline `value` secrets. This is not recommended — use a fresh resource group instead.

---

## Phase 8: Updating a Deployed Client to a New Release

Client containers run `coreiq-client-stable`, which only rebuilds when CoreIQ publishes a **GitHub Release** (see `.github/workflows/publish-release-container.yml`). Pushing to `main` alone does **not** reach clients — that only updates `coreiq-client`, the internal dev/test image.

- [ ] **Cut a GitHub Release** once changes are ready to ship — tag it (e.g. `v1.4.0`) and write the release description as client-facing notes (what changed, why it matters). That description is what admins see in the in-app update banner.
- [ ] Publishing the release automatically:
  - Builds and pushes `coreiq-client-stable:latest` + `:{tag}` + `:{commit sha}` to GHCR
  - Notifies the DO backend of the new version (requires the `DO_BACKEND_URL` / `BACKEND_API_KEY` GitHub Actions secrets to be set — see prior turn's summary if these aren't configured yet)
- [ ] **Admins now see an in-app banner** (`Chat` layout, admin-only) the next time they load the portal, showing the release notes
- [ ] **Force the actual redeploy** — publishing the image alone does not make Azure Container Apps re-pull it (floating `:latest` tags are never detected as "changed" by Terraform or Azure). Run:
  ```bash
  python scripts/update_forward_containers.py --client {client_id}
  # or, to update every client_cloud-deployed client at once:
  python scripts/update_forward_containers.py
  ```
- [ ] **Verify the update landed** — check `https://{client-fqdn}/healthz` reports the new `image_sha`, or run `python scripts/check_client_versions.py` to check all clients at once
- [ ] A daily scheduled check (`.github/workflows/check-client-versions.yml`) also runs this comparison automatically and opens a GitHub Issue if any client is still stale after a release

