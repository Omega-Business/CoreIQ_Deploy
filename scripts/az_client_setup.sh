#!/usr/bin/env bash
# az_client_setup.sh
#
# Collects all Azure values needed for a CoreIQ Terraform deployment,
# checks AI Foundry quota before proceeding, creates the Teams bot Entra
# app registration (optional), and writes a ready-to-use terraform.tfvars.
#
# Usage:
#   ./scripts/az_client_setup.sh [options]
#
# Required flags (or answered interactively):
#   --client-id           SLUG    CoreIQ client identifier (e.g. "acme")
#   --ghcr-token          TOKEN   GitHub PAT with read:packages scope
#   --backend-api-key     KEY     CoreIQ backend API key (ciq_<client>_...)
#   --qdrant-url          URL     Qdrant cluster URL (provided by CoreIQ)
#   --qdrant-api-key      KEY     Qdrant JWT API key (provided by CoreIQ)
#
# Optional flags:
#   --location            REGION  Azure region (default: eastus)
#   --foundry-model       NAME    AI Foundry model (default: gpt-5.4-nano)
#   --foundry-model-ver   VER     Model version (default: 2026-03-17)
#   --foundry-model-fmt   FMT     Model format: OpenAI or Microsoft (default: OpenAI)
#   --no-teams                    Skip Teams bot app registration
#   --skip-model-deployment       Write skip_model_deployment=true (deploy infra now, model later)
#   --output              PATH    Where to write tfvars
#   --yes                         Non-interactive: skip confirmations

set -euo pipefail

# ─── colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()     { echo -e "${RED}[error]${NC} $*"; }
die()     { err "$*" >&2; exit 1; }

# ─── defaults ────────────────────────────────────────────────────────────────
CLIENT_ID=""
LOCATION="eastus"
GHCR_TOKEN=""
BACKEND_API_KEY=""
QDRANT_URL=""
QDRANT_API_KEY=""
FOUNDRY_MODEL="gpt-5.4-nano"
FOUNDRY_MODEL_VERSION="2026-03-17"
FOUNDRY_MODEL_FORMAT="OpenAI"
SKIP_MODEL_DEPLOYMENT=false
CREATE_TEAMS_BOT=true
YES=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_FILE="${REPO_ROOT}/terraform/azure/client-deployment/terraform.tfvars"

# Regions to scan when the chosen region has no quota
CANDIDATE_REGIONS=(
  "eastus" "eastus2" "westus" "westus3"
  "northcentralus" "southcentralus"
  "westeurope" "uksouth" "francecentral" "swedencentral"
  "australiaeast" "japaneast"
)

# ─── arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-id)          CLIENT_ID="$2";             shift 2 ;;
    --location)           LOCATION="$2";              shift 2 ;;
    --ghcr-token)         GHCR_TOKEN="$2";            shift 2 ;;
    --backend-api-key)    BACKEND_API_KEY="$2";       shift 2 ;;
    --qdrant-url)         QDRANT_URL="$2";            shift 2 ;;
    --qdrant-api-key)     QDRANT_API_KEY="$2";        shift 2 ;;
    --foundry-model)      FOUNDRY_MODEL="$2";         shift 2 ;;
    --foundry-model-ver)  FOUNDRY_MODEL_VERSION="$2"; shift 2 ;;
    --foundry-model-fmt)      FOUNDRY_MODEL_FORMAT="$2";    shift 2 ;;
    --skip-model-deployment)  SKIP_MODEL_DEPLOYMENT=true;  shift ;;
    --no-teams)               CREATE_TEAMS_BOT=false;      shift ;;
    --output)             OUTPUT_FILE="$2";           shift 2 ;;
    --yes|-y)             YES=true;                   shift ;;
    -h|--help)
      sed -n '1,30p' "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
    *) die "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

# ─── prereq checks ───────────────────────────────────────────────────────────
for cmd in az jq openssl; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done

# ─── interactive prompts ─────────────────────────────────────────────────────
prompt_required() {
  local var_name="$1" prompt_text="$2" current_val="$3" is_secret="${4:-false}"
  if [[ -n "$current_val" ]]; then echo -n "$current_val"; return; fi
  local val=""
  while [[ -z "$val" ]]; do
    if [[ "$is_secret" == "true" ]]; then
      read -rsp "  ${prompt_text}: " val; echo
    else
      read -rp  "  ${prompt_text}: " val
    fi
    [[ -z "$val" ]] && warn "${var_name} is required."
  done
  echo -n "$val"
}

prompt_optional() {
  local prompt_text="$1" default="$2"
  local val
  read -rp "  ${prompt_text} [${default}]: " val
  echo -n "${val:-$default}"
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║    CoreIQ Azure Client Setup — Terraform Prep        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─── collect inputs ──────────────────────────────────────────────────────────
info "Collecting required values..."
echo ""

CLIENT_ID=$(prompt_required      "client_id"       "Client ID (e.g. acme)"                  "$CLIENT_ID")
LOCATION=$(prompt_optional                         "Azure region"                            "$LOCATION")
GHCR_TOKEN=$(prompt_required     "ghcr_token"      "GitHub PAT (read:packages scope)"       "$GHCR_TOKEN" true)
BACKEND_API_KEY=$(prompt_required "backend_api_key" "CoreIQ backend API key (ciq_...)"      "$BACKEND_API_KEY" true)
QDRANT_URL=$(prompt_required     "qdrant_url"      "Qdrant cluster URL"                     "$QDRANT_URL")
QDRANT_API_KEY=$(prompt_required "qdrant_api_key"  "Qdrant API key"                         "$QDRANT_API_KEY" true)

if [[ ! "$CLIENT_ID" =~ ^[a-z0-9_-]+$ ]]; then
  die "client_id '${CLIENT_ID}' is invalid — use lowercase letters, numbers, hyphens, and underscores only."
fi

RESOURCE_GROUP="coreiq-${CLIENT_ID}"
BOT_APP_NAME="CoreIQ Bot - ${CLIENT_ID}"

echo ""

# ─── azure auth check ────────────────────────────────────────────────────────
info "Verifying Azure CLI authentication..."
az account show &>/dev/null || die "Not authenticated with Azure CLI. Run: az login"

ACCOUNT_JSON=$(az account show -o json)
SUBSCRIPTION_ID=$(echo "$ACCOUNT_JSON" | jq -r '.id')
TENANT_ID=$(echo "$ACCOUNT_JSON" | jq -r '.tenantId')
ACCOUNT_NAME=$(echo "$ACCOUNT_JSON" | jq -r '.name')

success "Authenticated — subscription: ${ACCOUNT_NAME} (${SUBSCRIPTION_ID})"
echo ""

# ─── foundry quota helpers ───────────────────────────────────────────────────

# Returns "LIMIT:CURRENT" | "NOT_FOUND" | "ERROR"
query_quota() {
  local region="$1" model="$2" model_format="$3"
  local usage_json
  usage_json=$(az cognitiveservices usage list --location "$region" -o json 2>/dev/null) || {
    echo "ERROR"; return
  }

  # Try exact key (e.g. OpenAI.Standard.gpt-4o-mini), then fall back to name contains model
  local limit current
  local quota_key="${model_format}.Standard.${model}"
  limit=$(echo "$usage_json" | jq -r --arg k "$quota_key" \
    '.[] | select(.name.value == $k) | .limit // empty' | head -1)
  current=$(echo "$usage_json" | jq -r --arg k "$quota_key" \
    '.[] | select(.name.value == $k) | .currentValue // empty' | head -1)

  # Fuzzy fallback — match on model name substring
  if [[ -z "$limit" ]]; then
    limit=$(echo "$usage_json" | jq -r --arg m "${model,,}" \
      '[.[] | select(.name.value | ascii_downcase | contains($m))] | .[0].limit // empty' | head -1)
    current=$(echo "$usage_json" | jq -r --arg m "${model,,}" \
      '[.[] | select(.name.value | ascii_downcase | contains($m))] | .[0].currentValue // empty' | head -1)
  fi

  [[ -z "$limit" ]] && { echo "NOT_FOUND"; return; }
  echo "${limit%.*}:${current%.*}"   # strip decimals — Azure returns e.g. 2000.0
}

# Prints up to 3 regions with available quota (skipping $3)
suggest_regions() {
  local model="$1" model_format="$2" skip_region="$3"
  info "Scanning other regions for available '${model}' quota (this takes ~20 s)..."
  local found=0
  for region in "${CANDIDATE_REGIONS[@]}"; do
    [[ "$region" == "$skip_region" ]] && continue
    local result
    result=$(query_quota "$region" "$model" "$model_format")
    [[ "$result" == "ERROR" || "$result" == "NOT_FOUND" ]] && continue
    local limit current avail
    limit=$(echo  "$result" | cut -d: -f1)
    current=$(echo "$result" | cut -d: -f2)
    avail=$(( limit - current ))
    (( avail > 0 )) || continue
    printf "    %-20s %d TPM available  (quota: %d, used: %d)\n" \
      "$region" "$avail" "$limit" "$current"
    (( ++found >= 3 )) && break
  done
  (( found == 0 )) && warn "No other regions found with available quota."
}

# ─── foundry quota check ─────────────────────────────────────────────────────
info "Checking AI Foundry quota for '${FOUNDRY_MODEL}' in '${LOCATION}'..."

QUOTA_RESULT=$(query_quota "$LOCATION" "$FOUNDRY_MODEL" "$FOUNDRY_MODEL_FORMAT")
QUOTA_OK=true

# Presents options when quota is zero/exhausted. Sets SKIP_MODEL_DEPLOYMENT=true
# if the user chooses to deploy infra now and add the model later.
handle_quota_failure() {
  local reason="$1"   # "zero" | "exhausted" | "not_found"
  echo ""
  case "$reason" in
    zero)
      err "No quota allocated for '${FOUNDRY_MODEL}' in '${LOCATION}' (limit: 0 TPM)."
      err "terraform apply will fail with QuotaExceeded at the model deployment step."
      ;;
    exhausted)
      err "Quota for '${FOUNDRY_MODEL}' in '${LOCATION}' is fully consumed (${QUOTA_CURRENT} / ${QUOTA_LIMIT} TPM)."
      err "terraform apply may fail at the model deployment step."
      ;;
    not_found)
      err "Model '${FOUNDRY_MODEL}' not found in region '${LOCATION}'."
      err "This region may not support Azure AI Foundry or this model."
      ;;
  esac
  echo ""
  suggest_regions "$FOUNDRY_MODEL" "$FOUNDRY_MODEL_FORMAT" "$LOCATION"
  echo ""

  if [[ "$YES" == "true" || "$SKIP_MODEL_DEPLOYMENT" == "true" ]]; then
    warn "Continuing with skip_model_deployment = true."
    warn "Re-run terraform apply with skip_model_deployment = false once quota is granted."
    SKIP_MODEL_DEPLOYMENT=true
    return
  fi

  echo "  Options:"
  echo "    1) Request quota now, then re-run this script"
  echo "       https://aka.ms/oai/quotaincrease"
  echo "    2) Use a different region  (re-run with --location <region>)"
  echo "    3) Deploy all other infrastructure now; add the model once quota arrives"
  echo "       (sets skip_model_deployment = true in tfvars)"
  echo "    4) Abort"
  echo ""
  read -rp "  Choice [1-4]: " choice
  case "$choice" in
    1) die "Aborted — request quota at https://aka.ms/oai/quotaincrease then re-run." ;;
    2) die "Aborted — re-run with --location <region> once you know which region has quota." ;;
    3) warn "Continuing with skip_model_deployment = true."
       warn "After quota is granted: set skip_model_deployment = false in tfvars and re-run terraform apply."
       SKIP_MODEL_DEPLOYMENT=true ;;
    4) die "Aborted." ;;
    *) die "Invalid choice — aborted." ;;
  esac
}

case "$QUOTA_RESULT" in
  ERROR)
    warn "Quota API unavailable — could not verify. Proceeding with caution."
    warn "If terraform apply fails with QuotaExceeded, visit:"
    warn "  Azure portal → Azure OpenAI → Quotas → ${LOCATION} → Request increase"
    QUOTA_OK=true
    ;;
  NOT_FOUND)
    QUOTA_OK=false
    handle_quota_failure "not_found"
    ;;
  *)
    QUOTA_LIMIT=$(echo  "$QUOTA_RESULT" | cut -d: -f1)
    QUOTA_CURRENT=$(echo "$QUOTA_RESULT" | cut -d: -f2)
    QUOTA_AVAIL=$(( QUOTA_LIMIT - QUOTA_CURRENT ))

    if (( QUOTA_LIMIT == 0 )); then
      QUOTA_OK=false
      handle_quota_failure "zero"
    elif (( QUOTA_AVAIL <= 0 )); then
      QUOTA_OK=false
      handle_quota_failure "exhausted"
    else
      QUOTA_OK=true
      success "Foundry quota OK — ${QUOTA_AVAIL} TPM available in '${LOCATION}' (${QUOTA_CURRENT} / ${QUOTA_LIMIT} used)."
    fi
    ;;
esac
echo ""

# ─── resource group ──────────────────────────────────────────────────────────
info "Checking resource group '${RESOURCE_GROUP}'..."
if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  success "Resource group exists."
else
  warn "Resource group '${RESOURCE_GROUP}' does not exist."
  if [[ "$YES" == "true" ]]; then
    CREATE_RG=true
  else
    read -rp "  Create it now in region '${LOCATION}'? [Y/n] " yn
    [[ "${yn,,}" == "n" ]] && CREATE_RG=false || CREATE_RG=true
  fi

  if [[ "${CREATE_RG:-true}" == "true" ]]; then
    info "Creating resource group '${RESOURCE_GROUP}' in '${LOCATION}'..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
    success "Resource group created."
  else
    warn "Resource group not created — you must create it before running terraform apply."
  fi
fi
echo ""

# ─── teams bot app registration ──────────────────────────────────────────────
MICROSOFT_APP_ID=""
MICROSOFT_APP_PASSWORD=""
MICROSOFT_APP_TYPE="SingleTenant"

if [[ "$CREATE_TEAMS_BOT" == "true" && "$YES" == "false" ]]; then
  read -rp "  Create Teams bot app registration? [Y/n] " yn
  [[ "${yn,,}" == "n" ]] && CREATE_TEAMS_BOT=false
fi

if [[ "$CREATE_TEAMS_BOT" == "true" ]]; then
  info "Setting up Entra app registration: '${BOT_APP_NAME}'..."

  EXISTING_APP=$(az ad app list --display-name "$BOT_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

  if [[ -n "$EXISTING_APP" && "$EXISTING_APP" != "None" ]]; then
    warn "App '${BOT_APP_NAME}' already exists (${EXISTING_APP}) — reusing it."
    MICROSOFT_APP_ID="$EXISTING_APP"
  else
    APP_JSON=$(az ad app create \
      --display-name "$BOT_APP_NAME" \
      --sign-in-audience "AzureADMyOrg" \
      -o json)
    MICROSOFT_APP_ID=$(echo "$APP_JSON" | jq -r '.appId')
    success "App registered — ID: ${MICROSOFT_APP_ID}"
  fi

  info "Creating client secret (expires 24 months)..."
  SECRET_JSON=$(az ad app credential reset \
    --id "$MICROSOFT_APP_ID" \
    --append \
    --display-name "CoreIQ Terraform" \
    --years 2 \
    -o json)
  MICROSOFT_APP_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
  success "Client secret created."

  MICROSOFT_APP_TYPE="SingleTenant"
  success "App type: ${MICROSOFT_APP_TYPE}"
  echo ""
fi

# ─── generate session secret ─────────────────────────────────────────────────
info "Generating session secret..."
SESSION_SECRET=$(openssl rand -hex 32)
success "Session secret generated."
echo ""

# ─── write terraform.tfvars ──────────────────────────────────────────────────
info "Writing terraform.tfvars to: ${OUTPUT_FILE}"

if [[ -f "$OUTPUT_FILE" ]]; then
  BACKUP="${OUTPUT_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  warn "Existing tfvars found — backing up to: ${BACKUP}"
  cp "$OUTPUT_FILE" "$BACKUP"
fi

if [[ "$CREATE_TEAMS_BOT" == "true" && -n "$MICROSOFT_APP_ID" ]]; then
  TEAMS_BLOCK="microsoft_app_id       = \"${MICROSOFT_APP_ID}\"
microsoft_app_password = \"${MICROSOFT_APP_PASSWORD}\"
microsoft_app_type     = \"${MICROSOFT_APP_TYPE}\""
else
  TEAMS_BLOCK='microsoft_app_id       = ""
microsoft_app_password = ""
microsoft_app_type     = "MultiTenant"'
fi

cat > "$OUTPUT_FILE" <<TFVARS
# ============================================================================
# CoreIQ Azure Client Deployment Configuration
# Generated by az_client_setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Client: ${CLIENT_ID}
# ============================================================================
# WARNING: This file contains secrets. DO NOT commit to git.
# ============================================================================

# ============================================================================
# SECTION 1: REQUIRED — Azure & Client Values
# ============================================================================

client_id             = "${CLIENT_ID}"
azure_subscription_id = "${SUBSCRIPTION_ID}"
azure_tenant_id       = "${TENANT_ID}"
location              = "${LOCATION}"
resource_group_name   = "${RESOURCE_GROUP}"
ghcr_token            = "${GHCR_TOKEN}"
session_secret        = "${SESSION_SECRET}"

# ============================================================================
# SECTION 2: PROVIDED_BY_COREIQ — Do Not Change
# ============================================================================

backend_api_key = "${BACKEND_API_KEY}"
do_backend_url  = "https://coreiq.omegabusiness.us/backend"
ghcr_image      = "ghcr.io/omega-business/coreiq-client-stable:latest"

qdrant_url     = "${QDRANT_URL}"
qdrant_api_key = "${QDRANT_API_KEY}"

# ============================================================================
# SECTION 3: OPTIONAL — Defaults suitable for most deployments
# ============================================================================

foundry_sku           = "S0"
foundry_model         = "${FOUNDRY_MODEL}"
foundry_model_version = "${FOUNDRY_MODEL_VERSION}"
foundry_model_format  = "${FOUNDRY_MODEL_FORMAT}"
skip_model_deployment = ${SKIP_MODEL_DEPLOYMENT}

workload_profile_type      = "D4"
workload_profile_min_count = 1
workload_profile_max_count = 3

dns_managed_by_do = false

entra_app_client_id     = ""
entra_app_client_secret = ""

${TEAMS_BLOCK}
TFVARS

chmod 600 "$OUTPUT_FILE"
success "terraform.tfvars written (permissions: 600)."
echo ""

# ─── summary ─────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                     Setup Complete                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Client ID         : ${CLIENT_ID}"
echo "  Subscription      : ${SUBSCRIPTION_ID}"
echo "  Tenant            : ${TENANT_ID}"
echo "  Resource Group    : ${RESOURCE_GROUP}"
echo "  Region            : ${LOCATION}"
echo "  Foundry Model     : ${FOUNDRY_MODEL} (${FOUNDRY_MODEL_FORMAT})"
if [[ "$QUOTA_OK" == "true" ]]; then
echo "  Foundry Quota     : ${QUOTA_AVAIL:-?} TPM available"
elif [[ "$SKIP_MODEL_DEPLOYMENT" == "true" ]]; then
echo -e "  Foundry Quota     : ${YELLOW}pending — model deployment skipped${NC}"
else
echo -e "  Foundry Quota     : ${YELLOW}unverified — review before applying${NC}"
fi
echo "  Skip Model Deploy : ${SKIP_MODEL_DEPLOYMENT}"
if [[ "$CREATE_TEAMS_BOT" == "true" && -n "$MICROSOFT_APP_ID" ]]; then
echo "  Teams Bot App ID  : ${MICROSOFT_APP_ID}"
echo "  Teams Bot Type    : ${MICROSOFT_APP_TYPE}"
fi
echo ""
echo "  tfvars written to : ${OUTPUT_FILE}"
echo ""
echo "  Next steps:"
echo "    cd terraform/azure/client-deployment/"
echo "    terraform init"
echo "    terraform validate"
echo "    terraform plan -out=tfplan"
echo "    terraform apply tfplan"
if [[ "$SKIP_MODEL_DEPLOYMENT" == "true" ]]; then
echo ""
echo -e "  ${YELLOW}Model deployment skipped. Once quota is approved:${NC}"
echo "    1. Edit terraform.tfvars — set skip_model_deployment = false"
echo "    2. terraform plan -out=tfplan && terraform apply tfplan"
fi
echo ""
echo -e "  ${YELLOW}Keep terraform.tfvars secure — it contains secrets.${NC}"
echo -e "  ${YELLOW}Ensure it is listed in .gitignore before committing.${NC}"
echo ""
