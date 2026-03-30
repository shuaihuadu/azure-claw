# Guide: Configure Microsoft Teams as a Messaging Channel

This guide explains how to connect **Microsoft Teams** to the OpenClaw Gateway, allowing you to chat with your AI assistant directly in Teams DMs, group chats, or channels.

> **Complexity note**: Teams integration is more complex than Slack/Telegram, requiring an Azure Bot resource, a Teams App Manifest, and app upload. Allow 30–60 minutes to complete the full setup.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Teams Plugin](#2-install-teams-plugin)
3. [Create Azure Bot](#3-create-azure-bot)
4. [Get Credentials](#4-get-credentials)
5. [Configure Messaging Endpoint](#5-configure-messaging-endpoint)
6. [Enable Teams Channel](#6-enable-teams-channel)
7. [Create Teams App Manifest](#7-create-teams-app-manifest)
8. [Upload Teams App](#8-upload-teams-app)
9. [Configure OpenClaw](#9-configure-openclaw)
10. [Verify Connection](#10-verify-connection)
11. [Advanced Configuration](#11-advanced-configuration)
12. [FAQ](#12-faq)

---

## 1. Prerequisites

- Azure Claw deployment completed (see main [README](../../README.md))
- AI model provider configured (see [Microsoft Foundry configuration guide](guide-microsoft-foundry.md) or use another provider)
- Connected to the VM via SSH (Ubuntu) or RDP (Windows)
- **Must have `-EnablePublicHttps` enabled** (Teams Webhook requires an HTTPS endpoint) or another way to expose an HTTPS endpoint
- Azure AD (Microsoft Entra ID) admin permissions (to create App Registration)
- Teams admin permissions (or ability to request admin approval for App upload)

> **Important**: Teams Bot only supports **HTTPS** endpoints. If you didn't enable `-EnablePublicHttps` during deployment, you'll need to provide HTTPS access via other means. We strongly recommend deploying with `-EnablePublicHttps`.

---

## Semi-Automated Setup (Recommended)

This project provides `setup-teams.ps1`, which automates the following steps:

- Create App Registration + Client Secret
- Create Azure Bot (F0 free tier)
- Configure messaging endpoint + enable Teams channel
- Remotely install Teams plugin on the VM
- Update Caddy reverse proxy / port forwarding configuration
- Inject Teams credentials into OpenClaw config and restart the service
- Generate Teams App package (manifest.json + icons + ZIP)

```powershell
# Auto-detect existing deployment in rg-openclaw
.\setup-teams.ps1

# Specify resource group and Bot name
.\setup-teams.ps1 -ResourceGroup rg-openclaw -BotName my-openclaw-bot
```

After the script completes, you only need one manual step: **upload the generated `openclaw-teams-app.zip` to Teams** (see [section 8](#8-upload-teams-app)).

> Output directory `logs/teams-<timestamp>/` contains:
>
> - `setup-teams.log` — Setup log
> - `.env` — Teams credentials (App ID, Secret, Tenant ID)
> - `openclaw-teams-app.zip` — App package ready to upload to Teams

If you prefer fully manual configuration, continue reading the step-by-step guide below.

---

## 2. Install Teams Plugin

Microsoft Teams is provided as a plugin and is not included in the core OpenClaw installation.

SSH into the VM (or use WSL on Windows):

```bash
openclaw plugins install @openclaw/msteams
```

Verify installation:

```bash
openclaw plugins list
# Should show @openclaw/msteams
```

---

## 3. Create Azure Bot

### Option A: Azure Portal

1. Go to [Create Azure Bot](https://portal.azure.com/#create/Microsoft.AzureBot)
2. Fill in the **Basics** tab:

| Field              | Value                                        |
| ------------------ | -------------------------------------------- |
| **Bot handle**     | `openclaw-msteams` (must be globally unique) |
| **Subscription**   | Select your Azure subscription               |
| **Resource group** | Use `rg-openclaw` or create a new one        |
| **Pricing tier**   | `Free` (sufficient for development/testing)  |
| **Type of App**    | **Single Tenant** (recommended)              |
| **Creation type**  | Create new Microsoft App ID                  |

> **Note**: Since 2025-07-31, newly created Bots no longer support the Multi-Tenant type. Use **Single Tenant**.

3. Click **Review + create** → **Create** (wait 1–2 minutes)

### Option B: Azure CLI

```bash
# Create Azure Bot resource
az bot create \
  --resource-group rg-openclaw \
  --name openclaw-msteams \
  --kind registration \
  --sku F0
```

---

## 4. Get Credentials

You need to collect three credentials:

### 4.1 Get App ID

1. Go to the Azure Bot resource you just created
2. Left menu → **Configuration**
3. Copy the **Microsoft App ID** (format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)

### 4.2 Get App Password (Client Secret)

1. On the Configuration page, click **Manage Password** (redirects to App Registration)
2. Left menu → **Certificates & secrets**
3. Click **+ New client secret**
4. Enter a description (e.g., `openclaw-secret`), select expiration time
5. Click **Add**
6. **Copy the Value column value immediately** — this is the `appPassword`

> **Important**: The Client Secret is only shown once when created. If lost, you'll need to create a new one.

### 4.3 Get Tenant ID

1. On the App Registration page → **Overview**
2. Copy the **Directory (tenant) ID**

### Credentials Summary

| Credential       | Source                                    | Purpose            |
| ---------------- | ----------------------------------------- | ------------------ |
| **App ID**       | Azure Bot → Configuration                 | Bot identity       |
| **App Password** | App Registration → Certificates & secrets | Bot authentication |
| **Tenant ID**    | App Registration → Overview               | Tenant ID          |

---

## 5. Configure Messaging Endpoint

Teams sends messages to your Bot via HTTPS Webhook. You need to set up a publicly accessible HTTPS endpoint.

### Using Azure Claw HTTPS Mode (Recommended)

If you deployed with `-EnablePublicHttps`, Caddy is already providing HTTPS on port 443. You need to add a reverse proxy rule for the Teams Webhook in Caddy.

SSH into the VM and edit the Caddyfile:

```bash
sudo nano /etc/caddy/Caddyfile
```

Modify to:

```
<your-FQDN> {
    # OpenClaw Gateway WebSocket + Web UI
    reverse_proxy /api/messages 127.0.0.1:3978
    reverse_proxy 127.0.0.1:18789
}
```

> Replace `<your-FQDN>` with the `FQDN` value from your `.env` file, e.g., `openclaw-xxxx.eastasia.cloudapp.azure.com`.

Reload Caddy:

```bash
sudo systemctl reload caddy
```

Your messaging endpoint is: `https://<FQDN>/api/messages`

### Set Azure Bot Endpoint

1. Go back to Azure Portal → Azure Bot resource → **Configuration**
2. Set **Messaging endpoint** to:
   ```
   https://<your-FQDN>/api/messages
   ```
3. Click **Apply**

---

## 6. Enable Teams Channel

1. In the Azure Bot resource, left menu → **Channels**
2. Click **Microsoft Teams**
3. Click **Configure** → **Save**
4. Accept the Terms of Service

---

## 7. Create Teams App Manifest

A Teams App requires a Manifest package (ZIP file) containing `manifest.json` and two icon files.

### 7.1 Create Icon Files

Prepare two PNG icons:
- `color.png` — 192×192 pixels, color icon
- `outline.png` — 32×32 pixels, outline icon (white lines + transparent background)

> **Quick method**: You can use any 192×192 and 32×32 PNG images as placeholders.

### 7.2 Create manifest.json

Create `manifest.json`, replacing `<APP_ID>` with your Microsoft App ID:

```json
{
    "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.23/MicrosoftTeams.schema.json",
    "manifestVersion": "1.23",
    "version": "1.0.0",
    "id": "<APP_ID>",
    "name": {
        "short": "OpenClaw"
    },
    "developer": {
        "name": "Azure Claw",
        "websiteUrl": "https://openclaw.ai",
        "privacyUrl": "https://openclaw.ai/privacy",
        "termsOfUseUrl": "https://openclaw.ai/terms"
    },
    "description": {
        "short": "OpenClaw AI Assistant",
        "full": "Chat with OpenClaw AI assistant through Microsoft Teams"
    },
    "icons": {
        "outline": "outline.png",
        "color": "color.png"
    },
    "accentColor": "#5B6DEF",
    "bots": [
        {
            "botId": "<APP_ID>",
            "scopes": [
                "personal",
                "team",
                "groupChat"
            ],
            "isNotificationOnly": false,
            "supportsCalling": false,
            "supportsVideo": false,
            "supportsFiles": true
        }
    ],
    "webApplicationInfo": {
        "id": "<APP_ID>"
    },
    "authorization": {
        "permissions": {
            "resourceSpecific": [
                {
                    "name": "ChannelMessage.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "ChannelMessage.Send.Group",
                    "type": "Application"
                },
                {
                    "name": "Member.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "Owner.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "ChannelSettings.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "TeamMember.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "TeamSettings.Read.Group",
                    "type": "Application"
                },
                {
                    "name": "ChatMessage.Read.Chat",
                    "type": "Application"
                }
            ]
        }
    }
}
```

### 7.3 Package as ZIP

Place the three files in the same directory and package as ZIP:

```bash
zip openclaw-teams-app.zip manifest.json color.png outline.png
```

> **Alternative**: You can also use the [Teams Developer Portal](https://dev.teams.microsoft.com/apps) to create the App online, skipping manual JSON Manifest editing:
> 1. Click **+ New app** → fill in basic info
> 2. **App features** → **Bot** → select "Enter a bot ID manually" → paste App ID
> 3. Check Scopes: Personal, Team, Group Chat
> 4. **Distribute** → **Download app package** to download the ZIP

---

## 8. Upload Teams App

### Option A: Upload via Teams Client (Sideload)

1. Open the Teams client
2. Left sidebar → **Apps** → **Manage your apps**
3. Click **Upload an app** → **Upload a custom app**
4. Select the `openclaw-teams-app.zip` you just created
5. Confirm installation

> **If upload fails**: Try selecting "Upload an app to your org's app catalog" instead of "Upload a custom app" — this can often bypass Sideload restrictions.

### Option B: Upload via Teams Admin Center

1. Go to [Teams Admin Center](https://admin.teams.microsoft.com/)
2. **Teams apps** → **Manage apps**
3. Click **Upload new app** → select the ZIP file
4. After installation, search for "OpenClaw" in Teams and add it

### Install to a Team

After installing the App, you also need to add the Bot to specific teams/channels:

1. Go to the target team
2. Click team name → **Manage team** → **Apps**
3. Search and add "OpenClaw"

---

## 9. Configure OpenClaw

SSH into the VM (or use WSL on Windows) and configure the Teams channel.

### Option A: Interactive Configuration via `openclaw onboard`

```bash
openclaw onboard
```

In the interactive wizard:
1. Select Add Channel → **Microsoft Teams**
2. Enter App ID
3. Enter App Password (Client Secret)
4. Enter Tenant ID
5. Confirm Webhook port and path
6. Complete configuration

### Option B: Manually Edit Config File

```bash
nano ~/.openclaw/openclaw.json
```

Add Teams channel configuration:

```jsonc
{
  "agent": {
    "model": "azure/gpt-4o"  // or another model
  },
  "channels": {
    "msteams": {
      "enabled": true,
      "appId": "<APP_ID>",
      "appPassword": "<APP_PASSWORD>",
      "tenantId": "<TENANT_ID>",
      "webhook": {
        "port": 3978,
        "path": "/api/messages"
      }
    }
  }
}
```

You can also use environment variables instead of putting sensitive info in the config file:

```bash
export MSTEAMS_APP_ID="<APP_ID>"
export MSTEAMS_APP_PASSWORD="<APP_PASSWORD>"
export MSTEAMS_TENANT_ID="<TENANT_ID>"
```

### Configuration Field Descriptions

| Field          | Required | Description                             |
| -------------- | -------- | --------------------------------------- |
| `enabled`      | Yes      | Enable Teams channel                    |
| `appId`        | Yes      | Azure Bot's Microsoft App ID            |
| `appPassword`  | Yes      | App Registration's Client Secret        |
| `tenantId`     | Yes      | Azure AD tenant ID                      |
| `webhook.port` | No       | Webhook listening port (default `3978`) |
| `webhook.path` | No       | Webhook path (default `/api/messages`)  |

### Restart Service

```bash
# Ubuntu
sudo systemctl restart openclaw

# Check status
sudo systemctl status openclaw
```

---

## 10. Verify Connection

### 10.1 Check Gateway Logs

```bash
journalctl -u openclaw -f
```

You should see output similar to:

```
OpenClaw Gateway started on 127.0.0.1:18789
Channel connected: Microsoft Teams (webhook on :3978)
Listening for Teams events...
```

### 10.2 Test via Azure Web Chat

Before uploading the Teams App, you can first verify the Webhook with Azure's built-in Web Chat:

1. Azure Portal → Azure Bot resource → **Test in Web Chat**
2. Send a message
3. Confirm you receive an AI response

> This step confirms that your Webhook endpoint is properly connected, ruling out Teams App issues.

### 10.3 Test in Teams

#### Test DM (Direct Message)

1. In the Teams sidebar, find OpenClaw under **Apps**
2. Click to open → send a DM message
3. Wait for the AI response

#### Test Channel @Mention

1. Ensure the Bot has been added to the target team
2. Send `@OpenClaw hello` in a channel
3. The Bot should reply in the channel

> **Note**: By default, @mention is required to trigger a Bot response in channels. This can be changed with `requireMention: false`.

### 10.4 Run Diagnostics

```bash
openclaw doctor
```

Ensure the `Microsoft Teams channel` check shows ✅ Connected.

---

## 11. Advanced Configuration

### 11.1 Access Control

#### DM Access Policy

The default DM policy is `pairing` (pairing mode) — messages from unknown senders are ignored until approved by an admin.

```jsonc
{
  "channels": {
    "msteams": {
      // pairing: requires pairing approval (default)
      // allowlist: only allow listed users
      // open: allow everyone
      // disabled: disable DMs
      "dmPolicy": "pairing",
      // Use AAD Object ID (recommended — more stable than usernames)
      "allowFrom": ["<aad-object-id-1>", "<aad-object-id-2>"]
    }
  }
}
```

#### Group/Channel Access Policy

The default group policy is `allowlist` (whitelist mode) — the Bot won't respond in unauthorized groups/channels.

```jsonc
{
  "channels": {
    "msteams": {
      // allowlist: only allow listed groups (default)
      // open: allow any group (still requires @mention)
      // disabled: disable group responses
      "groupPolicy": "allowlist",
      "groupAllowFrom": ["user@org.com"],
      // Fine-grained control by team/channel
      "teams": {
        "<team-id>": {
          "channels": {
            "<channel-id>": {
              "requireMention": true
            }
          }
        }
      }
    }
  }
}
```

### 11.2 Reply Style

Teams channels have two UI styles — choose based on your channel's actual setting:

| Style                    | Description                              | `replyStyle` Value |
| ------------------------ | ---------------------------------------- | ------------------ |
| **Posts** (classic)      | Messages shown as cards + thread replies | `thread` (default) |
| **Threads** (Slack-like) | Messages displayed linearly              | `top-level`        |

```jsonc
{
  "channels": {
    "msteams": {
      "replyStyle": "thread",
      "teams": {
        "<team-id>": {
          "channels": {
            "<channel-id>": {
              "replyStyle": "top-level"
            }
          }
        }
      }
    }
  }
}
```

### 11.3 Enable Graph API (Channel File/Image Support)

By default, image/file attachments in channels cannot be read by the Bot (only HTML placeholders). To enable support, add Microsoft Graph permissions:

1. In Entra ID → App Registration, add **Microsoft Graph Application permissions**:
   - `ChannelMessage.Read.All` (read channel message attachments + history)
   - `Chat.Read.All` (read group chats)
2. Click **Grant admin consent** (admin permissions required)
3. Update the Teams App Manifest version, repackage and re-upload

#### Send Files in Groups/Channels

Sending files in groups/channels requires additional SharePoint configuration:

1. Add Graph API permissions:
   - `Sites.ReadWrite.All` (Application) — upload files to SharePoint
   - `Chat.Read.All` (Application) — optional, enables per-user sharing links
2. Get the SharePoint Site ID:

```bash
# Via Graph Explorer or curl
curl -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/sites/<hostname>:/<site-path>"
```

3. Configure OpenClaw:

```jsonc
{
  "channels": {
    "msteams": {
      "sharePointSiteId": "<site-id>"
    }
  }
}
```

### 11.4 Message History

```jsonc
{
  "channels": {
    "msteams": {
      // Channel/group message history limit (default 50, set to 0 to disable)
      "historyLimit": 50,
      // DM history limit
      "dmHistoryLimit": 50
    }
  }
}
```

---

## 12. FAQ

### Q: Web Chat test shows `401 Unauthorized`

This is normal — it means your endpoint is reachable but didn't pass Azure JWT authentication. Use Azure Portal's **Test in Web Chat** feature to test, not direct browser access.

### Q: Messages in Teams get no reply

1. Confirm Gateway is started and listening on port 3978: `journalctl -u openclaw -f`
2. Confirm the Azure Bot's Messaging Endpoint is configured correctly
3. In channels, @mention is required by default — check that you correctly used `@OpenClaw`
4. Run `openclaw doctor` to check Teams connection status

### Q: Images don't display in channels

- This is a Teams limitation: images/files are stored in SharePoint/OneDrive, which the Bot can't access by default
- You need to add Microsoft Graph permissions to the App Registration and get admin consent (see [11.3 Enable Graph API](#113-enable-graph-api-channel-fileimage-support))

### Q: Manifest upload error "Icon file cannot be empty"

- Icon files referenced in the Manifest ZIP are 0 bytes or missing
- Ensure `color.png` (192×192) and `outline.png` (32×32) are valid PNG files

### Q: Manifest upload error "webApplicationInfo.Id already in use"

- The App is already installed in another team/chat. Uninstall the old version first, or wait 5–10 minutes for changes to propagate
- You can also upload via [Teams Admin Center](https://admin.teams.microsoft.com/)

### Q: Bot doesn't work in private channels

- This is a known Teams limitation. Bot support for private channels is limited
- Alternative: Use standard channels for Bot interaction, or use DMs directly

### Q: Message replies are delayed or duplicated

- Teams sends messages via HTTP Webhook. If the AI model responds slowly, it may cause:
  - Gateway timeout
  - Teams retrying messages (producing duplicate replies)
- OpenClaw quickly returns a response and sends AI replies asynchronously, but extremely slow model responses may still cause issues
- Consider using a faster model (e.g., `gpt-4o-mini`)

### Q: How to get Team ID and Channel ID?

**Team ID** and **Channel ID** need to be extracted from Teams URLs (note: not the `groupId` parameter):

```
Team URL:
https://teams.microsoft.com/l/team/19%3ABk4j...%40thread.tacv2/conversations?groupId=...
                                    └────────────────────────────┘
                                    Team ID (URL-decoded)

Channel URL:
https://teams.microsoft.com/l/channel/19%3A15bc...%40thread.tacv2/ChannelName?groupId=...
                                      └─────────────────────────┘
                                      Channel ID (URL-decoded)
```

> **Note**: The `groupId` query parameter in the URL is NOT the Team ID — don't use it.

### Q: How to update an installed App?

1. Modify settings in `manifest.json`
2. Increment the `version` field (e.g., `1.0.0` → `1.1.0`)
3. Repackage the ZIP and upload
4. Reinstall the App in each team for new permissions to take effect
5. Fully quit and restart Teams (not just closing the window) to clear cache

---

## Security Recommendations

1. **Use HTTPS**: Teams Webhook requires an HTTPS endpoint — ensure `-EnablePublicHttps` is enabled during deployment
2. **Protect credentials**: `appPassword` is sensitive — don't commit to repositories or share with others
3. **Use AAD Object ID**: Use stable AAD Object IDs in `allowFrom` instead of usernames (usernames can change)
4. **Restrict group access**: Keep the default `groupPolicy: "allowlist"` and only allow authorized groups to use the Bot
5. **Rotate keys periodically**: Regularly regenerate Client Secrets in App Registration
6. **Audit logs**: Periodically check Teams event logs in `journalctl -u openclaw`

---

## References

- [OpenClaw Microsoft Teams Documentation](https://docs.openclaw.ai/channels/msteams)
- [Create Azure Bot](https://learn.microsoft.com/azure/bot-service/bot-service-quickstart-registration) — Azure Bot setup guide
- [Teams Developer Portal](https://dev.teams.microsoft.com/apps) — Create/manage Teams Apps
- [Teams App Manifest Schema](https://learn.microsoft.com/microsoftteams/platform/resources/schema/manifest-schema)
- [RSC Permission Reference](https://learn.microsoft.com/microsoftteams/platform/graph-api/rsc/resource-specific-consent)
- [Teams Bot File Handling](https://learn.microsoft.com/microsoftteams/platform/bots/how-to/bots-filesv4)
- [Proactive Messaging](https://learn.microsoft.com/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages)
