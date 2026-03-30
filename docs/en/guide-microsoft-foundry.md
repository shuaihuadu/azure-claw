# Guide: Configure Azure OpenAI / Microsoft Foundry as AI Model Provider

This guide explains how to connect the OpenClaw Gateway to **Azure OpenAI Service** or **Microsoft Foundry**, using Azure-hosted models like GPT-4.1 and GPT-5.4-mini to power your AI assistant.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Create Azure OpenAI Resource](#2-create-azure-openai-resource)
3. [Deploy a Model](#3-deploy-a-model)
4. [Get Connection Information](#4-get-connection-information)
5. [Configure OpenClaw](#5-configure-openclaw)
6. [Verify Connection](#6-verify-connection)
7. [Using Microsoft Foundry (Optional)](#7-using-microsoft-foundry-optional)
8. [Entra ID Passwordless Authentication (Recommended for Production)](#8-entra-id-passwordless-authentication-recommended-for-production)
9. [FAQ](#9-faq)

---

## 1. Prerequisites

- Azure Claw deployment completed (see main [README](../../README.md))
- Azure subscription with Azure OpenAI Service access enabled
  > If not yet enabled, submit a request at the [Azure OpenAI access page](https://aka.ms/oai/access)
- Connected to the VM via SSH (Ubuntu) or RDP (Windows)

---

## 2. Create Azure OpenAI Resource

### Option A: Azure Portal

1. Sign in to [Azure Portal](https://portal.azure.com/)
2. Search **Azure OpenAI** → click **Create**
3. Fill in the details:
   - **Subscription**: Select your Azure subscription
   - **Resource group**: Use `rg-openclaw` or create a new one
   - **Region**: Choose a region that supports the desired model (e.g., `East US`, `Sweden Central`)
   - **Name**: e.g., `openclaw-aoai`
   - **Pricing tier**: `Standard S0`
4. Click **Review + create** → **Create**

### Option B: Azure CLI

Run on your local machine or on the VM:

```bash
# Create Azure OpenAI resource
az cognitiveservices account create \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --kind OpenAI \
  --sku S0 \
  --location eastus
```

> **Region tip**: Different regions support different models. For GPT-4o, consider `eastus`, `eastus2`, `swedencentral`, or `westus3`. See the full region-model matrix at [Azure OpenAI model availability](https://learn.microsoft.com/azure/ai-services/openai/concepts/models#model-summary-table-and-region-availability).

---

## 3. Deploy a Model

Deploy a model in your Azure OpenAI resource for OpenClaw to use.

### Option A: Azure Portal

1. Go to your Azure OpenAI resource
2. Left menu → **Model deployments** → **Manage Deployments** (redirects to Microsoft Foundry)
3. Click **+ Create new deployment**
4. Fill in the details:
   - **Model**: Select `gpt-4.1` (recommended) or `gpt-5.4-mini` (lightweight, fast)
   - **Deployment name**: e.g., `gpt-4.1` (recommended to match the model name for easier configuration)
   - **Deployment type**: `Standard`
   - **TPM quota**: Set based on your needs (30K–80K is enough for personal use)
5. Click **Create**

### Option B: Azure CLI

```bash
# Deploy gpt-4.1 model
az cognitiveservices account deployment create \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --deployment-name gpt-4.1 \
  --model-name gpt-4.1 \
  --model-version "2025-04-14" \
  --model-format OpenAI \
  --sku-capacity 30 \
  --sku-name Standard
```

> **Recommended models**:
>
> | Model | Characteristics | Best For |
> | --- | --- | --- |
> | `gpt-4.1` | High-quality reasoning, strong coding | Daily coding assistant |
> | `gpt-5.4-mini` | Fast response, low cost | Lightweight Q&A, frequent calls |

---

## 4. Get Connection Information

You need two pieces of information to configure OpenClaw:

### Get Endpoint and API Key

#### Option A: Azure Portal

1. Go to your Azure OpenAI resource
2. Left menu → **Keys and Endpoint**
3. Note the following:
   - **Endpoint**: e.g., `https://openclaw-aoai.openai.azure.com/`
   - **Key 1**: e.g., `abc123...` (either Key 1 or Key 2 works)

#### Option B: Azure CLI

```bash
# Get Endpoint
az cognitiveservices account show \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --query properties.endpoint \
  --output tsv

# Get API Key
az cognitiveservices account keys list \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --query key1 \
  --output tsv
```

---

## 5. Configure OpenClaw

> **Recommended**: If you deployed using `deploy.ps1`, the script will automatically prompt you to configure AI models after deployment, supporting three modes (select existing resource / create new resource / manual input) — no need to manually edit config files. You can also use `scripts/setup-foundry-model.ps1` to add models after deployment.

### Option A: Automatic Configuration via deploy.ps1 (Recommended)

After deployment, interactive mode will prompt whether to configure AI models, offering three methods:

1. **Select existing Azure AI resource** — Automatically retrieves endpoint, API key, and deployed model list
2. **Create new Foundry resource** — Automatically creates a resource and deploys models
3. **Manual input** — Provide endpoint, API key, and model names

The script will write the configuration to `~/.openclaw/openclaw.json` on the VM via `az vm run-command` and restart the service.

### Option B: Interactive Configuration via `openclaw onboard`

SSH into the VM (or use WSL on Windows):

```bash
openclaw onboard
```

In the interactive wizard, select Azure OpenAI and follow the prompts to enter the endpoint and API key.

### Option C: Manually Edit Config File

```bash
nano ~/.openclaw/openclaw.json
```

Write the following content:

```jsonc
{
  "agents": {
    "defaults": {
      "model": {
        // Use the deployment name directly, no "azure/" prefix needed
        "primary": "gpt-4.1"
      }
    }
  },
  "models": {
    "providers": {
      "azure-openai": {
        // Endpoint + /openai/v1 suffix
        "baseUrl": "https://openclaw-aoai.openai.azure.com/openai/v1",
        "apiKey": "<your Azure OpenAI API Key>",
        "api": "openai-completions",
        "headers": {
          "authHeader": "api-key"
        },
        // List all available deployment names
        "models": ["gpt-4.1"]
      }
    }
  }
}
```

**Configuration fields**:

| Field                                              | Description                     | Example                                  |
| -------------------------------------------------- | ------------------------------- | ---------------------------------------- |
| `agents.defaults.model.primary`                    | Default model (deployment name) | `gpt-4.1`                                |
| `models.providers.azure-openai.baseUrl`            | Endpoint + `/openai/v1`         | `https://xxx.openai.azure.com/openai/v1` |
| `models.providers.azure-openai.apiKey`             | Azure OpenAI API Key            | `CtQcuGGH...`                            |
| `models.providers.azure-openai.api`                | API type                        | `openai-completions`                     |
| `models.providers.azure-openai.headers.authHeader` | Auth header name                | `api-key`                                |
| `models.providers.azure-openai.models`             | Available model list            | `["gpt-4.1", "gpt-5.4-mini"]`            |

> **Endpoint format note**: Azure OpenAI has two endpoint formats — be careful to distinguish them:
>
> | Format | Example | Purpose |
> | --- | --- | --- |
> | **OpenAI endpoint** (domain) | `https://xxx.openai.azure.com/` | SDK or direct model calls |
> | **Project endpoint** (with `/api/projects/`) | `https://xxx.services.ai.azure.com/api/projects/...` | Foundry Agent management (not used by OpenClaw) |
>
> OpenClaw uses the **OpenAI endpoint** with the `/openai/v1` suffix. If the endpoint shown in the Microsoft Foundry portal already has the `/openai/v1` suffix, use it as-is.

### Restart Service

```bash
# Ubuntu
sudo systemctl restart openclaw

# Check status
sudo systemctl status openclaw
```

---

## 6. Verify Connection

### Check Gateway Logs

```bash
# View real-time logs
journalctl -u openclaw -f
```

You should see output similar to:

```
OpenClaw Gateway started on 0.0.0.0:18789
Model provider: Azure OpenAI (gpt-4o)
Ready to accept connections
```

### Send a Test Message

1. Open `http://<VM_PUBLIC_IP>:18789` in your browser
2. Send a message in the WebChat
3. Confirm you receive an AI response

### Run Diagnostics

```bash
openclaw doctor
```

Ensure all checks pass, especially `Model connectivity`.

---

## 7. Using Microsoft Foundry (Optional)

If you manage models through **Microsoft Foundry** ([ai.azure.com](https://ai.azure.com/)), you can use the Foundry endpoints directly.

### 7.1 Two Types of Endpoints

Sign in to ai.azure.com → your project → **Overview** page. You'll see two endpoints:

```
Project endpoint
  https://<resource>.services.ai.azure.com/api/projects/<project>
  → Used for Microsoft Foundry Agent management (AIProjectClient), NOT used by OpenClaw

Azure OpenAI endpoint
  https://<resource>.openai.azure.com/
  → Used for direct model calls, used by OpenClaw
```

| Endpoint         | Format                                                      | Used by OpenClaw? |
| ---------------- | ----------------------------------------------------------- | ----------------- |
| Project endpoint | `https://<resource>.services.ai.azure.com/api/projects/...` | **No**            |
| OpenAI endpoint  | `https://<resource>.openai.azure.com/`                      | **Yes**           |

> OpenClaw is an OpenAI-compatible API client that only needs the OpenAI endpoint + API Key + deployment name. The project endpoint is for Azure SDK (`AIProjectClient`) to manage Microsoft Foundry Agents — it's unrelated to OpenClaw.

### 7.2 Get Connection Info from Microsoft Foundry Portal

1. Sign in to [ai.azure.com](https://ai.azure.com/) → select your project
2. **Overview** page → copy the **Azure OpenAI endpoint** (not the project endpoint)
3. Copy the **API key**
4. **Models + endpoints** page → check deployed model names (i.e., deployment names)

### 7.3 Configure OpenClaw

```jsonc
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "gpt-4.1"
      }
    }
  },
  "models": {
    "providers": {
      "azure-openai": {
        "baseUrl": "https://<resource>.openai.azure.com/openai/v1",
        "apiKey": "<API Key copied from Microsoft Foundry portal>",
        "api": "openai-completions",
        "headers": {
          "authHeader": "api-key"
        },
        "models": ["gpt-4.1"]
      }
    }
  }
}
```

> **Note**: The OpenAI endpoint shown in the Microsoft Foundry portal may already include the `/openai/v1` suffix — use it as-is. If only the domain is shown (e.g., `https://xxx.openai.azure.com/`), append `/openai/v1`.

---

## 8. Entra ID Passwordless Authentication (Recommended for Production)

For production environments, using **Microsoft Entra ID** (formerly Azure AD) passwordless authentication is recommended over API Keys. By configuring **Managed Identity** on the VM, you don't need to store API Keys in config files.

### 8.1 Enable VM Managed Identity

```bash
# Enable System-Assigned Managed Identity for the VM
az vm identity assign \
  --name openclaw-vm \
  --resource-group rg-openclaw
```

### 8.2 Assign RBAC Role

The Managed Identity needs the correct role to call models:

| Operation                              | Minimum Role                            | Description                          |
| -------------------------------------- | --------------------------------------- | ------------------------------------ |
| Call models (Chat/Completions)         | `Cognitive Services OpenAI User`        | Most common, sufficient for OpenClaw |
| Create/manage Microsoft Foundry Agents | `Cognitive Services OpenAI Contributor` | Only if managing Agents              |
| Read Microsoft Foundry project config  | `Azure AI Developer`                    | Only if using project endpoint       |

> **Best practice**: Always follow the principle of least privilege. OpenClaw only calls models, so `Cognitive Services OpenAI User` is sufficient.

```bash
# Get the VM's Managed Identity Principal ID
VM_PRINCIPAL_ID=$(az vm show \
  --name openclaw-vm \
  --resource-group rg-openclaw \
  --query identity.principalId \
  --output tsv)

# Get the Azure OpenAI resource ID
AOAI_RESOURCE_ID=$(az cognitiveservices account show \
  --name openclaw-aoai \
  --resource-group rg-openclaw \
  --query id \
  --output tsv)

# Assign role
az role assignment create \
  --assignee "$VM_PRINCIPAL_ID" \
  --role "Cognitive Services OpenAI User" \
  --scope "$AOAI_RESOURCE_ID"
```

### 8.3 Configure OpenClaw with Entra ID

```jsonc
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "gpt-4.1"
      }
    }
  },
  "models": {
    "providers": {
      "azure-openai": {
        "baseUrl": "https://openclaw-aoai.openai.azure.com/openai/v1",
        "api": "openai-completions",
        "headers": {
          "authHeader": "api-key"
        },
        "useAzureAD": true,
        // No apiKey needed — the VM's Managed Identity automatically obtains tokens
        "models": ["gpt-4.1"]
      }
    }
  }
}
```

### 8.4 API Key vs Entra ID Comparison

| Method                      | Configuration Complexity | Security                 | Best For                    |
| --------------------------- | ------------------------ | ------------------------ | --------------------------- |
| API Key                     | Simple (copy & paste)    | Moderate (keys can leak) | Personal use, quick testing |
| Entra ID + Managed Identity | Additional RBAC setup    | High (no stored secrets) | Production environments     |

---

## 9. FAQ

### Q: Getting `401 Unauthorized` error

- Check that the API Key was copied correctly (no extra spaces)
- Confirm the Key hasn't expired or been rotated
- If using Entra ID auth, confirm the VM has been assigned the `Cognitive Services OpenAI User` role
- In multi-tenant scenarios, confirm `az login --tenant <correct-tenant-ID>` logs into the tenant where the resource resides

### Q: Getting `404 Resource Not Found` error

- Check that model names in the `models` array match the **deployment names** in Azure
- Confirm that `baseUrl` uses the **OpenAI endpoint** (`xxx.openai.azure.com`) with the `/openai/v1` suffix, not the project endpoint (`xxx.services.ai.azure.com/api/projects/...`)

### Q: Getting `429 Rate Limit` error

- Current TPM quota is insufficient — increase the deployment's TPM quota in the Azure Portal
- Or wait for the rate limit window to expire

### Q: How to switch models?

After deploying a new model in Azure OpenAI, update `agents.defaults.model.primary` in the config file and add the new model name to the `models` array. For example, to switch to GPT-5.4-mini:

```jsonc
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "gpt-5.4-mini"
      }
    }
  },
  "models": {
    "providers": {
      "azure-openai": {
        "baseUrl": "https://openclaw-aoai.openai.azure.com/openai/v1",
        // ...rest of config unchanged
        "models": ["gpt-4.1", "gpt-5.4-mini"]
      }
    }
  }
}
```

### Q: How much does Azure OpenAI cost?

Azure OpenAI charges per token usage, with different prices for different models. Light personal use typically costs $5–$30 per month. See [Azure OpenAI pricing](https://azure.microsoft.com/pricing/details/cognitive-services/openai-service/).

### Q: Microsoft Foundry portal shows OpenAI endpoint with `/openai/v1` — how to fill it in?

The OpenAI endpoint shown on the Microsoft Foundry portal Overview page may look like `https://xxx.openai.azure.com/openai/v1`. This is exactly the format OpenClaw needs — use it directly:

```
Portal shows: https://xxx.openai.azure.com/openai/v1
OpenClaw baseUrl: https://xxx.openai.azure.com/openai/v1   ← use directly
```

If the portal only shows the domain (e.g., `https://xxx.openai.azure.com/`), append `/openai/v1`.

### Q: Multi-tenant Entra ID auth reports `Token tenant does not match`

This means the `az login` or Managed Identity tenant doesn't match the Azure OpenAI resource's tenant. Solution:

```bash
# Switch to the correct tenant
az login --tenant <tenant-ID-of-the-resource>
```

---

## References

- [Azure OpenAI documentation](https://learn.microsoft.com/azure/ai-services/openai/)
- [Azure OpenAI REST API reference](https://learn.microsoft.com/azure/ai-services/openai/reference)
- [Microsoft Foundry](https://ai.azure.com/)
- [Azure OpenAI model availability](https://learn.microsoft.com/azure/ai-services/openai/concepts/models)
- [OpenClaw Models documentation](https://docs.openclaw.ai/concepts/models)
