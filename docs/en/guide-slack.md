# Guide: Configure Slack as a Messaging Channel

This guide explains how to connect **Slack** to the OpenClaw Gateway, allowing you to chat with your AI assistant directly in Slack. Once configured, you can DM the Bot or @mention it in channels to invoke the AI assistant.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Create a Slack App](#2-create-a-slack-app)
3. [Configure Bot Permissions](#3-configure-bot-permissions)
4. [Enable Event Subscriptions](#4-enable-event-subscriptions)
5. [Install App to Workspace](#5-install-app-to-workspace)
6. [Get Tokens and Secrets](#6-get-tokens-and-secrets)
7. [Configure OpenClaw](#7-configure-openclaw)
8. [Verify Connection](#8-verify-connection)
9. [Advanced Configuration](#9-advanced-configuration)
10. [FAQ](#10-faq)

---

## 1. Prerequisites

- Azure Claw deployment completed (see main [README](../../README.md))
- AI model provider configured (run `openclaw onboard` to set up OpenAI / Anthropic / Azure OpenAI / etc.)
- Slack Workspace admin permission (or ability to request admin approval for App installation)
- VM's port 18789 accessible from the internet (NSG configured)

---

## 2. Create a Slack App

### Option A: Create with App Manifest (Recommended)

Using a Manifest completes App creation, permissions, event subscriptions, and Socket Mode setup in one step — no need to configure each item manually.

1. Go to [Slack API: Your Apps](https://api.slack.com/apps)
2. Click **Create New App**
3. Select **From an app manifest**
4. Select your Slack Workspace → click **Next**
5. Select **JSON** format and paste the following Manifest:

```json
{
    "display_information": {
        "name": "OpenClaw",
        "description": "Slack connector for OpenClaw"
    },
    "features": {
        "app_home": {
            "home_tab_enabled": false,
            "messages_tab_enabled": true,
            "messages_tab_read_only_enabled": false
        },
        "bot_user": {
            "display_name": "OpenClaw",
            "always_online": false
        },
        "slash_commands": [
            {
                "command": "/openclaw",
                "description": "Send a message to OpenClaw",
                "should_escape": false
            }
        ]
    },
    "oauth_config": {
        "scopes": {
            "bot": [
                "chat:write",
                "chat:write.public",
                "channels:history",
                "channels:read",
                "groups:history",
                "im:history",
                "im:read",
                "im:write",
                "mpim:history",
                "users:read",
                "app_mentions:read",
                "reactions:read",
                "reactions:write",
                "pins:read",
                "pins:write",
                "emoji:read",
                "commands",
                "files:read",
                "files:write"
            ]
        },
        "pkce_enabled": false
    },
    "settings": {
        "event_subscriptions": {
            "bot_events": [
                "app_mention",
                "message.channels",
                "message.groups",
                "message.im",
                "message.mpim",
                "reaction_added",
                "reaction_removed",
                "member_joined_channel",
                "member_left_channel",
                "channel_rename",
                "pin_added",
                "pin_removed"
            ]
        },
        "interactivity": {
            "is_enabled": true
        },
        "org_deploy_enabled": false,
        "socket_mode_enabled": true,
        "token_rotation_enabled": false
    }
}
```

6. Click **Next** → review the configuration summary → click **Create**
7. After successful creation, you'll be redirected to the management page

> **When created with a Manifest, steps 3 (Configure Bot Permissions) and 4 (Enable Event Subscriptions) are already complete** — you can skip directly to [section 3.2](#32-generate-app-level-token) to generate the App-Level Token, then continue to [step 5](#5-install-app-to-workspace).

### Option B: Create Manually (From Scratch)

1. Go to [Slack API: Your Apps](https://api.slack.com/apps)
2. Click **Create New App**
3. Select **From scratch**
4. Fill in:
   - **App Name**: `OpenClaw` (or your preferred name)
   - **Workspace**: Select your Slack Workspace
5. Click **Create App**

After creation, you'll be taken to the App management page. Continue with steps 3 and 4 for manual configuration.

---

## 3. Configure Bot Permissions

> **Tip**: If you created the App using **App Manifest** in step 2, permissions and Slash Commands are already configured — skip directly to [3.2 Generate App-Level Token](#32-generate-app-level-token).

### 3.1 Add Bot Token Scopes

1. Left menu → **OAuth & Permissions**
2. Scroll down to **Scopes** → **Bot Token Scopes**
3. Click **Add an OAuth Scope** and add the following permissions:

| Scope               | Description                                 |
| ------------------- | ------------------------------------------- |
| `app_mentions:read` | Read @mention messages                      |
| `chat:write`        | Send messages                               |
| `chat:write.public` | Send messages in public channels not joined |
| `channels:history`  | Read public channel message history         |
| `channels:read`     | Read public channel basic info              |
| `groups:history`    | Read private channel message history        |
| `im:history`        | Read DM message history                     |
| `im:read`           | View DM info                                |
| `im:write`          | Initiate DM conversations                   |
| `mpim:history`      | Read group DM history                       |
| `users:read`        | Read user info                              |
| `reactions:read`    | Read message emoji reactions                |
| `reactions:write`   | Add/remove emoji reactions                  |
| `pins:read`         | Read pinned messages                        |
| `pins:write`        | Pin/unpin messages                          |
| `emoji:read`        | Read custom emoji list                      |
| `commands`          | Register and handle Slash Commands          |
| `files:read`        | Read user-uploaded files (images/documents) |
| `files:write`       | Upload files (AI-returned files)            |

### 3.1b Configure Slash Command (Optional)

1. Left menu → **Slash Commands**
2. Click **Create New Command**
3. Fill in:
   - **Command**: `/openclaw`
   - **Short Description**: `Send a message to OpenClaw`
   - **Escape channels, users, and links**: Unchecked
4. Click **Save**

Once configured, you can type `/openclaw <your question>` anywhere in Slack to ask the AI directly.

### 3.1c Enable Interactivity

1. Left menu → **Interactivity & Shortcuts**
2. Toggle **Interactivity** on
3. Click **Save Changes**

### 3.2 Generate App-Level Token

Socket Mode requires an App-Level Token for WebSocket connections:

1. Left menu → **Basic Information**
2. Scroll down to **App-Level Tokens**
3. Click **Generate Token and Scopes**
4. Token Name: `openclaw-socket`
5. Add Scope: `connections:write`
6. Click **Generate**
7. **Save the generated Token** (starts with `xapp-`)

> **Important**: This Token is only shown once when generated — save it immediately. If lost, you'll need to regenerate it.

---

## 4. Enable Event Subscriptions

> **Tip**: If you created the App using **App Manifest** in step 2, Socket Mode and event subscriptions are already configured — skip directly to [step 5](#5-install-app-to-workspace).

### 4.1 Enable Socket Mode

1. Left menu → **Socket Mode**
2. Toggle **Enable Socket Mode** on (if prompted to generate a Token, see [section 3.2](#32-generate-app-level-token))

### 4.2 Configure Event Subscriptions

1. Left menu → **Event Subscriptions**
2. Toggle **Enable Events** on
3. Under **Subscribe to bot events**, add the following events:

| Event                   | Description                              |
| ----------------------- | ---------------------------------------- |
| `app_mention`           | Triggered when someone @mentions the Bot |
| `message.im`            | DM message received                      |
| `message.channels`      | New message in public channel            |
| `message.groups`        | New message in private channel           |
| `message.mpim`          | New message in group DM                  |
| `reaction_added`        | Emoji reaction added                     |
| `reaction_removed`      | Emoji reaction removed                   |
| `member_joined_channel` | Member joined a channel                  |
| `member_left_channel`   | Member left a channel                    |
| `channel_rename`        | Channel renamed                          |
| `pin_added`             | Message pinned                           |
| `pin_removed`           | Message unpinned                         |

4. Click **Save Changes**

---

## 5. Install App to Workspace

1. Left menu → **Install App**
2. Click **Install to Workspace**
3. Review permissions → click **Allow**
4. After installation, you'll get a **Bot User OAuth Token** (starts with `xoxb-`)
5. **Save this Token**

---

## 6. Get Tokens and Secrets

You need to collect three pieces of information (all found on the Slack App management page):

| Info               | Location                                             | Format                           |
| ------------------ | ---------------------------------------------------- | -------------------------------- |
| **Bot Token**      | OAuth & Permissions → Bot User OAuth Token           | `xoxb-xxxx-xxxx-xxxx`            |
| **App Token**      | Basic Information → App-Level Tokens                 | `xapp-1-xxxx` (Socket Mode only) |
| **Signing Secret** | Basic Information → App Credentials → Signing Secret | 32-character hex string          |

> **Security tip**: These Tokens are sensitive credentials — do not leak or commit them to repositories.

---

## 7. Configure OpenClaw

SSH into the VM (or use WSL on Windows) and configure the Slack channel.

### Option A: Interactive Configuration via `openclaw onboard`

```bash
openclaw onboard
```

In the interactive wizard:
1. Select Add Channel → **Slack**
2. Enter Bot Token (`xoxb-...`)
3. Enter App Token (`xapp-...`) (Socket Mode)
4. Enter Signing Secret
5. Complete configuration

### Option B: Manually Edit Config File

```bash
nano ~/.openclaw/openclaw.json
```

Add the Slack channel to the config file:

```jsonc
{
  "agent": {
    "model": "azure/gpt-4o"
  },
  "providers": {
    "azure": {
      // ... model provider config
    }
  },
  "channels": {
    "slack": {
      "enabled": true,
      "botToken": "xoxb-xxxx-xxxx-xxxx",
      "appToken": "xapp-1-xxxx",           // Required for Socket Mode
      "signingSecret": "your_signing_secret_here",
      "socketMode": true                    // Recommended: use Socket Mode
    }
  }
}
```

**Configuration field descriptions**:

| Field           | Required    | Description                                  |
| --------------- | ----------- | -------------------------------------------- |
| `enabled`       | Yes         | Enable Slack channel                         |
| `botToken`      | Yes         | Bot User OAuth Token (starts with `xoxb-`)   |
| `appToken`      | Socket Mode | App-Level Token (starts with `xapp-`)        |
| `signingSecret` | Yes         | Used to verify request signatures from Slack |
| `socketMode`    | No          | Whether to use Socket Mode (default `false`) |

### Restart Service

```bash
# Ubuntu
sudo systemctl restart openclaw

# Check status
sudo systemctl status openclaw
```

---

## 8. Verify Connection

### 8.1 Check Gateway Logs

```bash
journalctl -u openclaw -f
```

You should see output similar to:

```
OpenClaw Gateway started on 0.0.0.0:18789
Channel connected: Slack (Socket Mode)
Listening for Slack events...
```

### 8.2 Test in Slack

#### Test DM (Direct Message)

1. In the Slack sidebar, find your Bot (under the **Apps** section)
2. Click the Bot name to open a DM conversation
3. Send a message, e.g., "hello"
4. Wait for the AI response

#### Test Channel @Mention

1. Invite the Bot to a channel: type `/invite @OpenClaw` in the channel
2. Send a message: `@OpenClaw what's the weather like today?`
3. The Bot should reply in the channel

### 8.3 Run Diagnostics

```bash
openclaw doctor
```

Ensure the `Slack channel` check shows ✅ Connected.

---

## 9. Advanced Configuration

### 9.1 Restrict Response Channels

If you don't want the Bot to respond in all channels, configure a whitelist:

```jsonc
{
  "channels": {
    "slack": {
      "enabled": true,
      "botToken": "xoxb-xxxx",
      "appToken": "xapp-xxxx",
      "signingSecret": "xxxx",
      "socketMode": true,
      // Only respond in specified channels
      "allowedChannels": ["C01XXXXXXXX", "C02YYYYYYYY"]
    }
  }
}
```

> Channel IDs can be found at the bottom of the channel info panel, or by right-clicking the channel name → Copy Link.

### 9.2 Customize Bot Behavior

```jsonc
{
  "channels": {
    "slack": {
      "enabled": true,
      // ...basic config...

      // No @mention needed in DMs to trigger (default true)
      "respondInDM": true,

      // Whether @mention is required in channels (default true)
      "requireMention": true,

      // Reply in threads instead of directly in the channel
      "useThreads": true
    }
  }
}
```

### 9.3 Multi-Workspace Support

To serve multiple Slack Workspaces, configure multiple Slack channel instances:

```jsonc
{
  "channels": {
    "slack": {
      "enabled": true,
      "botToken": "xoxb-workspace1-token",
      "appToken": "xapp-workspace1-token",
      "signingSecret": "secret1",
      "socketMode": true
    },
    "slack-team2": {
      "type": "slack",
      "enabled": true,
      "botToken": "xoxb-workspace2-token",
      "appToken": "xapp-workspace2-token",
      "signingSecret": "secret2",
      "socketMode": true
    }
  }
}
```

---

## 10. FAQ

### Q: Bot is online but not replying

1. Check that Event Subscriptions are enabled with the correct events
2. Confirm the Bot has been invited to the target channel (`/invite @OpenClaw`)
3. Check Gateway logs for incoming events: `journalctl -u openclaw -f`
4. Run `openclaw doctor` to check Slack connection status

### Q: Getting `invalid_auth` error

- Bot Token has expired or been revoked — go to the Slack App management page to regenerate
- Confirm you're using the **Bot User OAuth Token** (`xoxb-`), not a User Token

### Q: Getting `token_revoked` error

- The App may have been uninstalled from the Workspace — reinstall: **Install App** → **Reinstall to Workspace**

### Q: Socket Mode connection fails

- Confirm the App-Level Token (`xapp-`) is correct and hasn't expired
- Confirm Socket Mode is enabled in Slack App settings
- Check that the VM can access the internet (Socket Mode requires outbound connections to `wss://wss-primary.slack.com`)

### Q: Webhook mode validation fails

- Confirm the VM's port 18789 is reachable from the internet
- Confirm OpenClaw is started and the Slack channel is properly configured before entering the Request URL in Slack
- Confirm URL format is correct: `http://<VM_PUBLIC_IP>:18789/channels/slack/events`

### Q: High message latency

- Check AI model provider response time (`openclaw doctor`)
- Socket Mode typically has slightly higher latency than Webhook, but is more secure
- Confirm VM size is sufficient (at least `Standard_B2s` recommended)

### Q: How to use Slash Commands?

Type `/openclaw your question` in any Slack conversation window to ask the AI directly. Slash Command responses are only visible to the sender (ephemeral), making them suitable for private questions in public channels.

### Q: How to make the Bot respond to Emoji Reactions?

If you created the App with a Manifest, `reaction_added` and `reaction_removed` events are already subscribed. If created manually, add the `reaction_added` event in Event Subscriptions and add the `reactions:read` permission in Bot Token Scopes.

---

## Security Recommendations

1. **Use Socket Mode**: Compared to HTTP Webhook, Socket Mode doesn't require exposing public ports — more secure
2. **Restrict response channels**: Use `allowedChannels` to whitelist channels and prevent the Bot from responding in irrelevant channels
3. **Rotate tokens periodically**: Regularly regenerate Bot Token and App Token
4. **Enable Gateway authentication**: Configure `gateway.auth.mode: "password"` to protect the Web UI
5. **Audit logs**: Periodically check Slack event logs in `journalctl -u openclaw`
