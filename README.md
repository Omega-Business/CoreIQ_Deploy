# CoreIQ Azure Deployment

This repository contains everything you need to deploy a CoreIQ forward container into your Azure environment.

## What You're Deploying

A CoreIQ client container running in your Azure subscription, connected to Azure AI Foundry for local query routing and your organization's Qdrant knowledge base. Complex queries and authentication route back to the CoreIQ backend over TLS.

## Prerequisites

Install these tools before starting:

| Tool | Version | Install |
|------|---------|---------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | 2.50+ | `az --version` |
| [Terraform](https://www.terraform.io/downloads) | 1.0+ | `terraform version` |
| Python | 3.9+ | Required only for Teams bot setup |

Authenticate to Azure before starting:
```bash
az login
az account set --subscription <your-subscription-id>
```

## Deployment Guide

Follow **[client_deploy_checklist.md](./client_deploy_checklist.md)** step by step.

Estimated time: 30–45 minutes.

## Repository Structure

```
├── client_deploy_checklist.md          # Step-by-step deployment guide
├── terraform/
│   └── azure/
│       └── client-deployment/
│           ├── main.tf                 # All Azure resources
│           ├── variables.tf            # Variable definitions
│           ├── outputs.tf              # Post-deploy values
│           └── terraform.tfvars.example  # Configuration template
└── scripts/
    └── package_teams_manifest.py       # Teams manifest bundler (optional)
└── frontend/
    └── teams-app/
        └── manifest/                   # Teams app manifest template + icons
```

## Quick Start

```bash
# 1. Copy the example config
cp terraform/azure/client-deployment/terraform.tfvars.example \
   terraform/azure/client-deployment/terraform.tfvars

# 2. Fill in your values (see checklist Phase 3)
# terraform/azure/client-deployment/terraform.tfvars

# 3. Create your resource group
az group create --name coreiq-{your-client-id} --location eastus

# 4. Deploy
cd terraform/azure/client-deployment
terraform init
terraform apply
```

## Support

Contact the CoreIQ team before starting your deployment — you will need credentials pushed to your Key Vault before the container is fully operational.
