# Bitwarden → Microsoft Sentinel — Azure Function App Connector

This connector pulls data from the [Bitwarden Public API](https://bitwarden.com/help/public-api/) into Microsoft Sentinel using a time-triggered Python Azure Function App. It supports **Bitwarden Cloud US**, **Bitwarden Cloud EU**, and **self-hosted / on-premises Bitwarden servers**.

---

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Data ingested](#data-ingested)
- [Architecture](#architecture)
- [Deployment](#deployment)
  - [Option A – Deploy via ARM template (recommended)](#option-a--deploy-via-arm-template-recommended)
  - [Option B – Deploy manually](#option-b--deploy-manually)
- [Configuration reference](#configuration-reference)
  - [Bitwarden connection](#bitwarden-connection)
  - [Azure Monitor / DCR](#azure-monitor--dcr)
  - [Key Vault secret management](#key-vault-secret-management)
  - [Operational settings](#operational-settings)
- [Self-hosted / on-premises Bitwarden](#self-hosted--on-premises-bitwarden)
- [Bitwarden Cloud EU](#bitwarden-cloud-eu)
- [Verifying data ingestion](#verifying-data-ingestion)
- [Troubleshooting](#troubleshooting)
- [Local development](#local-development)

---

## Overview

The connector runs every **5 minutes** and ingests three data types:

| Table | Description | Polling mode |
|---|---|---|
| `BitwardenEventLogs_CL` | Organisation audit events | 5-minute sliding time window |
| `BitwardenMembers_CL` | Organisation member list | Full snapshot per run |
| `BitwardenGroups_CL` | Organisation group list | Full snapshot per run |

Authentication uses the **OAuth 2.0 client credentials** flow against the Bitwarden identity endpoint. Tokens are cached and automatically refreshed before the 1-hour expiry.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Microsoft Sentinel workspace | Read/write access required |
| Azure subscription | Contributor access to the target resource group |
| Bitwarden plan | Enterprise or Teams plan required for Public API access |
| Bitwarden organisation API key | `client_id` + `client_secret` (see below) |
| Python | 3.11 (runtime provided by Azure Functions) |

### Obtaining a Bitwarden organisation API key

> ⚠️ Use the **organisation** API key, not a personal API key.  
> The `client_id` will be in the format `organization.<UUID>`.

1. Log in to the Bitwarden Admin Console:
   - **Cloud US**: [vault.bitwarden.com](https://vault.bitwarden.com)
   - **Cloud EU**: [vault.bitwarden.eu](https://vault.bitwarden.eu)
   - **Self-hosted**: `https://<your-domain>/`
2. Go to **Settings → Organisation info**.
3. Scroll down to the **API key** section.
4. Click **View API key** (or **Rotate API key** to create a new one).
5. Note the **`client_id`** and **`client_secret`**.

---

## Data ingested

### `BitwardenEventLogs_CL`

| Column | Type | Description |
|---|---|---|
| `TimeGenerated` | datetime | Event timestamp (UTC) |
| `eventType` | int | [Event type code](https://bitwarden.com/help/event-logs/) |
| `itemId` | string | Vault item ID (if applicable) |
| `collectionId` | string | Collection ID (if applicable) |
| `groupId` | string | Group ID (if applicable) |
| `policyId` | string | Policy ID (if applicable) |
| `memberId` | string | Affected member ID |
| `actingUserId` | string | User who performed the action |
| `installationId` | string | Installation ID |
| `device` | int | Device type code |
| `ipAddress` | string | IP address of the acting user |

### `BitwardenMembers_CL`

| Column | Type | Description |
|---|---|---|
| `TimeGenerated` | datetime | Ingestion timestamp (UTC) |
| `memberId` | string | Organisation member ID |
| `userId` | string | Bitwarden user ID |
| `email` | string | Member email address |
| `name` | string | Member display name |

### `BitwardenGroups_CL`

| Column | Type | Description |
|---|---|---|
| `TimeGenerated` | datetime | Ingestion timestamp (UTC) |
| `groupId` | string | Organisation group ID |
| `name` | string | Group name |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Azure Function App  (Linux, Python 3.11, Consumption plan) │
│                                                             │
│  BitwardenTimerTrigger  (cron: 0 */5 * * * *)              │
│  ┌──────────────────┐   ┌──────────────────┐               │
│  │  bitwarden_      │   │  sentinel_        │               │
│  │  client.py       │   │  uploader.py      │               │
│  │                  │   │                   │               │
│  │  OAuth2 token    │──▶│  LogsIngestion    │               │
│  │  (cached 1h)     │   │  Client (DCR)     │               │
│  │  GET /public/    │   │                   │               │
│  │    events        │   │  3 × DCR          │               │
│  │    members       │   │  (Events /        │               │
│  │    groups        │   │   Members /       │               │
│  └──────────────────┘   │   Groups)         │               │
│                         └──────────────────┘               │
└────────────────────────────────┬────────────────────────────┘
                                 │
              ┌──────────────────▼──────────────────┐
              │  Azure Monitor – Logs Ingestion API  │
              │  (Data Collection Endpoint + Rules)  │
              └──────────────────┬──────────────────┘
                                 │
              ┌──────────────────▼──────────────────┐
              │   Microsoft Sentinel / Log Analytics │
              │   BitwardenEventLogs_CL              │
              │   BitwardenMembers_CL                │
              │   BitwardenGroups_CL                 │
              └─────────────────────────────────────┘

Secret management:
  Bitwarden client_secret ──▶ Azure Key Vault ──▶ User-Assigned Managed Identity
```

**Resources created by the ARM template:**

| Resource | Purpose |
|---|---|
| User-Assigned Managed Identity | Grants the Function App access to Key Vault and DCRs |
| Azure Key Vault | Stores the Bitwarden `client_secret` securely |
| Data Collection Endpoint (DCE) | Receives data from the Function App |
| Data Collection Rule – Events | Routes event data to `BitwardenEventLogs_CL` |
| Data Collection Rule – Members | Routes member data to `BitwardenMembers_CL` |
| Data Collection Rule – Groups | Routes group data to `BitwardenGroups_CL` |
| Role assignments (×3) | Grants **Monitoring Metrics Publisher** on each DCR |
| Application Insights | Function App telemetry and logging |
| Storage Account | Required by the Azure Functions runtime |
| App Service Plan | Consumption (serverless) Linux plan |
| Function App | Hosts the timer-triggered Python function |

---

## Deployment

### Option A – Deploy via ARM template (recommended)

Click the button below to deploy all required Azure resources in one step:

[![Deploy To Azure](https://aka.ms/deploytoazurebutton)](https://aka.ms/sentinel-BitwardenFunctionApp-azuredeploy)

#### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `FunctionName` | No | `Bitwarden` | Base name for all resources (max 11 chars, used in globally unique names) |
| `WorkspaceName` | **Yes** | — | Name of your Log Analytics / Sentinel workspace |
| `AppInsightsWorkspaceResourceID` | **Yes** | — | Full Resource ID of the LA workspace for App Insights (copy from **Log Analytics workspace → Properties → Resource ID**) |
| `BitwardenClientId` | **Yes** | — | Bitwarden organisation `client_id` (format: `organization.<UUID>`) |
| `BitwardenClientSecret` | Yes* | — | Bitwarden `client_secret`. Provide this **or** `keyVaultName`, not both |
| `keyVaultName` | Yes* | — | Existing Key Vault name holding the secret. Provide this **or** `BitwardenClientSecret`, not both |
| `keyVaultSecretName` | No | `bitwarden-client-secret` | Secret name within the Key Vault (only used with `keyVaultName`) |
| `BitwardenCloudRegion` | No | `us` | `us` (bitwarden.com) or `eu` (bitwarden.eu). Ignored when self-hosted URLs are set |
| `BitwardenIdentityUrl` | No | *(empty)* | **Self-hosted only**: identity base URL, e.g. `https://bw.example.com/identity` |
| `BitwardenApiUrl` | No | *(empty)* | **Self-hosted only**: API base URL, e.g. `https://bw.example.com/api` |
| `EventLookbackMinutes` | No | `5` | Minutes to look back for events per run (should match timer interval) |

\* Exactly one of `BitwardenClientSecret` or `keyVaultName` must be provided.

---

### Option B – Deploy manually

Follow these steps if you prefer to deploy resources individually or integrate with an existing pipeline.

#### Step 1 – Create resource group (if needed)

```bash
az group create \
  --name rg-bitwarden-sentinel \
  --location westeurope
```

#### Step 2 – Deploy the ARM template

```bash
az deployment group create \
  --resource-group rg-bitwarden-sentinel \
  --template-file azuredeploy_Connector_Bitwarden_AzureFunction.json \
  --parameters \
      WorkspaceName="<your-sentinel-workspace>" \
      AppInsightsWorkspaceResourceID="<full-resource-id>" \
      BitwardenClientId="organization.<uuid>" \
      BitwardenClientSecret="<your-client-secret>"
```

For **Bitwarden Cloud EU**, add `BitwardenCloudRegion=eu`.  
For **self-hosted**, add `BitwardenIdentityUrl` and `BitwardenApiUrl` instead.

#### Step 3 – Package and deploy the function code

```bash
# From the AzureFunctionBitwarden/ directory
cd "Solutions/Bitwarden/Data Connectors/AzureFunctionBitwarden"

# Install dependencies into a local package folder
pip install -r requirements.txt --target .python_packages/lib/site-packages

# Publish to Azure Functions
FUNCTION_APP_NAME=$(az functionapp list \
  --resource-group rg-bitwarden-sentinel \
  --query "[0].name" -o tsv)

func azure functionapp publish "$FUNCTION_APP_NAME" --python
```

> **Note:** The ARM template's `packageUri` parameter points to a pre-built zip. If you modify the Python code, re-build and re-publish using the steps above or update `WEBSITE_RUN_FROM_PACKAGE` to your own zip URL.

---

## Configuration reference

All configuration is managed through **Function App application settings** (environment variables). These are set automatically by the ARM template; change them in the Azure portal under **Function App → Settings → Environment variables** or via the Azure CLI.

### Bitwarden connection

| Environment variable | Required | Default | Description |
|---|---|---|---|
| `BITWARDEN_CLIENT_ID` | **Yes** | — | Organisation `client_id` (format: `organization.<UUID>`) |
| `BITWARDEN_CLIENT_SECRET` | Yes* | — | `client_secret` — used only when Key Vault is not configured |
| `BITWARDEN_CLOUD_REGION` | No | `us` | `us` or `eu`. Ignored when explicit URLs are set |
| `BITWARDEN_IDENTITY_URL` | No | *(derived from region)* | Self-hosted identity base URL, e.g. `https://bw.example.com/identity` |
| `BITWARDEN_API_URL` | No | *(derived from region)* | Self-hosted API base URL, e.g. `https://bw.example.com/api` |

\* Required when Key Vault is not configured.

### Azure Monitor / DCR

These are set automatically by the ARM template and should not need manual changes.

| Environment variable | Description |
|---|---|
| `AZURE_DCE_ENDPOINT` | Data Collection Endpoint URL |
| `AZURE_DCR_EVENTS_IMMUTABLEID` | Immutable ID of the Events DCR |
| `AZURE_DCR_MEMBERS_IMMUTABLEID` | Immutable ID of the Members DCR |
| `AZURE_DCR_GROUPS_IMMUTABLEID` | Immutable ID of the Groups DCR |

### Key Vault secret management

| Environment variable | Description |
|---|---|
| `KEY_VAULT_URI` | Key Vault URI, e.g. `https://kv-bitwarden-xxx.vault.azure.net/` |
| `KEY_VAULT_SECRET_NAME` | Name of the secret in the Key Vault (default: `bitwarden-client-secret`) |
| `AZURE_CLIENT_ID` | Client ID of the User-Assigned Managed Identity |

When `KEY_VAULT_URI` and `KEY_VAULT_SECRET_NAME` are set, the function retrieves the `client_secret` from Key Vault at startup. If Key Vault is unreachable, it falls back to the `BITWARDEN_CLIENT_SECRET` environment variable.

### Operational settings

| Environment variable | Default | Description |
|---|---|---|
| `BITWARDEN_EVENT_LOOKBACK_MINUTES` | `5` | Event query window in minutes. Should be ≥ the timer interval to avoid gaps |
| `LOG_LEVEL` | `INFO` | Python logging level (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |

---

## Self-hosted / on-premises Bitwarden

Self-hosted Bitwarden servers expose the same Public API but at your own domain.

| Endpoint | Self-hosted URL |
|---|---|
| Token (identity) | `https://<your-domain>/identity/connect/token` |
| Events | `https://<your-domain>/api/public/events` |
| Members | `https://<your-domain>/api/public/members` |
| Groups | `https://<your-domain>/api/public/groups` |

Set the following app settings (or ARM template parameters):

```
BITWARDEN_IDENTITY_URL = https://bw.example.com/identity
BITWARDEN_API_URL      = https://bw.example.com/api
```

> Both variables must be set together. Setting only one will cause a `ValueError` at startup.

**Network connectivity:** Ensure the Azure Function App has outbound HTTPS access to your self-hosted Bitwarden server. If the server is behind a firewall or private network, you may need to configure [VNet integration](https://learn.microsoft.com/azure/azure-functions/functions-networking-options) for the Function App.

---

## Bitwarden Cloud EU

For organisations using the European data region (`bitwarden.eu`):

Set the `BitwardenCloudRegion` ARM parameter to `eu`, or update the app setting:

```
BITWARDEN_CLOUD_REGION = eu
```

This maps to:
- Identity: `https://identity.bitwarden.eu`
- API: `https://api.bitwarden.eu`

---

## Verifying data ingestion

After the Function App is deployed, the first execution runs within **5 minutes**. Run these KQL queries in Microsoft Sentinel to verify data is arriving:

```kql
// Check recent event logs
BitwardenEventLogs_CL
| sort by TimeGenerated desc
| take 20
```

```kql
// Check member snapshot
BitwardenMembers_CL
| summarize arg_max(TimeGenerated, *) by memberId
| project TimeGenerated, memberId, email, name
```

```kql
// Check group snapshot
BitwardenGroups_CL
| summarize arg_max(TimeGenerated, *) by groupId
| project TimeGenerated, groupId, name
```

```kql
// Connectivity check — last event received within 30 minutes?
BitwardenEventLogs_CL
| summarize LastReceived = max(TimeGenerated)
| extend IsConnected = LastReceived > ago(30m)
```

---

## Troubleshooting

### No data after 10 minutes

1. Open the Function App in the Azure portal → **Functions → BitwardenTimerTrigger → Monitor**.
2. Check the **Invocations** tab for recent executions and any errors.
3. Review the **Logs** tab or Application Insights for detailed log output.

### `401 Unauthorized` from Bitwarden

- Verify `BITWARDEN_CLIENT_ID` starts with `organization.` (not `user.`).
- Ensure the `client_secret` stored in Key Vault or the app setting is correct and has not been rotated.
- Confirm the Bitwarden organisation has an **Enterprise** or **Teams** plan.

### `ValueError: Both BITWARDEN_IDENTITY_URL and BITWARDEN_API_URL must be set together`

You provided only one of the two self-hosted URL environment variables. Either set both, or remove both and use `BITWARDEN_CLOUD_REGION` instead.

### Key Vault access denied

- Check that the User-Assigned Managed Identity (`AZURE_CLIENT_ID`) has a **Get** and **List** secrets access policy on the Key Vault.
- Verify `KEY_VAULT_URI` ends with `.vault.azure.net/` and the secret name matches `KEY_VAULT_SECRET_NAME`.

### Function App is not triggering

- Verify the Function App is in **Running** state (not stopped).
- Check `AzureWebJobsStorage` is set to a valid storage account connection string.
- For Consumption plan, cold starts may add a few minutes to the first invocation.

### Increasing log verbosity

Set `LOG_LEVEL=DEBUG` in the Function App application settings to get detailed request/response logging.

---

## Local development

### Requirements

- Python 3.11+
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- A `.env` file (see below)

### Setup

```bash
cd "Solutions/Bitwarden/Data Connectors/AzureFunctionBitwarden"

# Create and activate a virtual environment
python -m venv .venv
source .venv/bin/activate        # macOS/Linux
# .venv\Scripts\Activate.ps1    # Windows PowerShell

# Install dependencies
pip install -r requirements.txt
```

### `.env` file

Create `BitwardenTimerTrigger/.env` (never commit this file):

```env
# Bitwarden credentials
BITWARDEN_CLIENT_ID=organization.<your-uuid>
BITWARDEN_CLIENT_SECRET=<your-client-secret>

# Bitwarden endpoints – choose one option:

# Option 1: Bitwarden Cloud US (default – leave these unset or use region)
# BITWARDEN_CLOUD_REGION=us

# Option 2: Bitwarden Cloud EU
# BITWARDEN_CLOUD_REGION=eu

# Option 3: Self-hosted
# BITWARDEN_IDENTITY_URL=https://bw.example.com/identity
# BITWARDEN_API_URL=https://bw.example.com/api

# Azure Monitor / DCR (get from deployed resources)
AZURE_DCE_ENDPOINT=https://<dce-name>.<region>.ingest.monitor.azure.com
AZURE_DCR_EVENTS_IMMUTABLEID=dcr-<id>
AZURE_DCR_MEMBERS_IMMUTABLEID=dcr-<id>
AZURE_DCR_GROUPS_IMMUTABLEID=dcr-<id>

# Azure identity (for local dev use DefaultAzureCredential or set these)
# AZURE_CLIENT_ID=<managed-identity-client-id>
# AZURE_TENANT_ID=<your-tenant-id>
# AZURE_CLIENT_SECRET=<your-sp-secret>   # only for service principal auth

# Optional
LOG_LEVEL=DEBUG
BITWARDEN_EVENT_LOOKBACK_MINUTES=5
```

### Run locally

```bash
func start
```

The timer trigger will not fire automatically on a schedule locally. To invoke it manually:

```bash
# In a second terminal
curl -X POST "http://localhost:7071/admin/functions/BitwardenTimerTrigger" \
  -H "Content-Type: application/json" \
  -d '{}'
```

> **Note:** Local execution writes to the real DCR endpoints. Use a non-production Sentinel workspace for testing.
