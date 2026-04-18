# 🦞 Azure Claw — One-Click Deploy OpenClaw to Azure VM


[中文文档](README-CN.md)

One-click deployment of [OpenClaw](https://openclaw.ai/) personal AI assistant to an Azure Virtual Machine, supporting both **Ubuntu 24.04 LTS** and **Windows 11** images.

## What is OpenClaw

OpenClaw is a self-hosted AI assistant gateway that connects messaging apps like WhatsApp, Telegram, Discord, Slack, and iMessage to AI coding agents (such as Pi). Run a Gateway process on your own machine and it becomes the bridge between messaging apps and AI assistants.

- **Self-hosted**: Runs on your own hardware, full data control
- **Multi-channel**: One Gateway serves WhatsApp, Telegram, Discord, and more simultaneously
- **Agent-native**: Supports tool calling, session management, memory, and multi-agent routing
- **Open source**: MIT licensed, community-driven

## Prerequisites

Install the following tools on your local machine:

| Tool                | Purpose                    | Install Guide                                                                                                                          |
| ------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **Azure CLI**       | Deploy Azure resources     | [Install Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)                                                           |
| **PowerShell 7+**   | Run deploy/destroy scripts | [Install PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (Windows built-in 5.1 also works) |
| **Azure Bicep CLI** | Compile Bicep templates    | Installed automatically with Azure CLI, or `az bicep install`                                                                          |

You also need:

- An **Azure subscription** ([Create one for free](https://azure.microsoft.com/free/))
- An **AI model provider API Key** (OpenAI / Anthropic / etc.), configured on the VM after deployment

## Quick Start

### Option 1: One-Click Deploy (Azure Portal)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fshuaihuadu%2Fazure-claw%2Fmain%2Finfra%2Fazuredeploy.json)

Click the button and fill in the parameters in the Azure Portal.

> **Note**: The Deploy to Azure button requires the repository to be **public** and an ARM template to be generated:
> ```powershell
> az bicep build --file infra/main.bicep --outfile infra/azuredeploy.json
> git add infra/azuredeploy.json && git commit -m "Generate ARM template" && git push
> ```
> For private repositories, use the script deployment method below.

### Option 2: Script Deployment (Recommended)

```powershell
# Interactive guided deployment (recommended for first use)
# Automatically queries subscriptions, available regions, and VM sizes
.\deploy.ps1

# Custom parameter deployment (skip interactive prompts)
.\deploy.ps1 -Location eastasia -VmSize Standard_B2as_v2 -OsType Ubuntu -AdminUsername azureclaw -AdminPassword "YourP@ssw0rd!"

# Specify resource group name
.\deploy.ps1 -ResourceGroup my-rg -Location eastasia

# Deploy Windows 11 VM
.\deploy.ps1 -OsType Windows

# Enable public HTTPS (Caddy + Let's Encrypt auto-TLS + password auth)
.\deploy.ps1 -EnablePublicHttps
```

After deployment, SSH into the VM and run `openclaw onboard` to interactively configure your AI model provider (OpenAI / Anthropic / Azure OpenAI / etc.) and messaging channels.

> **Tip**: Running `.\deploy.ps1` without parameters enters interactive guided mode, which automatically queries available regions and VM sizes in your Azure subscription to avoid selecting unavailable resources.

Deployment parameters:

| Parameter            | Description                             | Default             |
| -------------------- | --------------------------------------- | ------------------- |
| `-Location`          | Azure region                            | `eastasia`          |
| `-OsType`            | Operating system (`Ubuntu` / `Windows`) | `Ubuntu`            |
| `-VmSize`            | VM size                                 | `Standard_D4s_v5`   |
| `-AdminUsername`     | Admin username                          | `azureclaw`         |
| `-AdminPassword`     | Admin password                          | Auto-generated      |
| `-ResourceGroup`     | Azure resource group name               | `rg-openclaw`       |
| `-EnablePublicHttps` | Public HTTPS (Caddy + Let's Encrypt)    | **Enabled**         |

> **Windows users**: Windows 11 + WSL2 requires at least 8 GB RAM. Use `Standard_B2as_v2` or higher:
> ```powershell
> .\deploy.ps1 -OsType Windows -VmSize Standard_B2as_v2
> ```

> All parameters have default values — just run `.\deploy.ps1` to get started.

### Deployment Artifacts

After a successful deployment, a timestamped directory is created under `logs/` containing three files:

```
logs/20260320143052/
├── deploy.log    # Deployment log (sanitized parameters)
├── .env          # Sensitive info (username, password, IP, etc.)
└── guide.md      # Operations guide (how to connect to server and OpenClaw)
```

## Post-Deployment

Open `logs/<timestamp>/guide.md` for the complete operations guide.

### Ubuntu VM

**1. Connect to the server**:

```bash
ssh <ADMIN_USERNAME>@<VM_PUBLIC_IP>
```

**2. Connect to OpenClaw**:

```bash
# Open Web console in browser
# Without HTTPS:
http://<VM_PUBLIC_IP>:18789
# With HTTPS:
https://<FQDN>  # FQDN is in the .env file

# Gateway login password: deploy.ps1 → GATEWAY_PASSWORD in .env; Portal one-click → the gatewayPassword you typed in the form

# Check service status
sudo systemctl status openclaw

# Run interactive setup (configure API Key, channels, etc.) — do this FIRST
openclaw onboard

# After onboard completes, open the Web UI with the correct password → browser shows "pairing required"
# Then SSH approve:
openclaw devices approve --latest

# View Gateway logs
journalctl -u openclaw -f

# ---- Control Token (only needed for macOS / iOS / Android / CLI remote clients) ----
# View current token (deploy script auto-installs jq; if 'command not found': sudo apt-get install -y jq)
jq -r '.gateway.auth.token // "<not set>"' ~/.openclaw/openclaw.json

# No token yet? Generate one and restart the service:
openclaw doctor --generate-gateway-token
sudo systemctl restart openclaw
```

### Windows 11 VM

> **Note**: Windows deployment completes in two phases. Phase 1 installs WSL2 and the VM reboots automatically. Phase 2 installs Node.js and OpenClaw after reboot.
> Wait approximately 5-10 minutes after deployment before connecting via RDP. Check `C:\openclaw\phase2.log` for progress.

**1. Connect to the server**:

```powershell
mstsc /v:<VM_PUBLIC_IP>
```

**2. Connect to OpenClaw**:

```powershell
# After RDP login, open browser to:
http://localhost:18789
# With HTTPS enabled, also accessible externally:
# https://<FQDN>  # FQDN is in the .env file

# Gateway login password: deploy.ps1 → GATEWAY_PASSWORD in .env; Portal one-click → the gatewayPassword you typed in the form

# Run diagnostics
openclaw doctor

# Run interactive setup — do this FIRST
openclaw onboard --install-daemon

# After onboard completes, open the Web UI with the correct password → browser shows "pairing required"
# Then from PowerShell:
wsl -d Ubuntu -u openclaw -- openclaw devices approve --latest

# ---- Control Token (only needed for macOS / iOS / Android / CLI remote clients) ----
# View current token
wsl -d Ubuntu -u openclaw -- jq -r '.gateway.auth.token // "<not set>"' ~/.openclaw/openclaw.json

# No token yet? Generate one:
wsl -d Ubuntu -u openclaw -- openclaw doctor --generate-gateway-token
wsl -d Ubuntu -u openclaw -- sudo systemctl restart openclaw
```

## Cleanup

```powershell
# Delete all Azure resources (confirmation prompt)
.\destroy.ps1

# Specify resource group name
.\destroy.ps1 -ResourceGroup my-rg

# Skip confirmation and delete immediately
.\destroy.ps1 -Force
```

## Project Structure

```
azure-claw/
├── .github/
│   └── copilot-instructions.md      # Copilot development guidelines
├── docs/                            # Operation guides
│   ├── zh/                          # 中文文档 (Chinese)
│   │   ├── guide-operations.md          # Operations handbook (service, logs, upgrades, etc.)
│   │   ├── guide-slack.md               # Configure Slack channel
│   │   └── guide-teams.md               # Configure Microsoft Teams channel
│   └── en/                          # English documentation
│       ├── guide-operations.md
│       ├── guide-slack.md
│       └── guide-teams.md
├── infra/                           # Bicep infrastructure code
│   ├── main.bicep                   # Main Bicep template
│   ├── azuredeploy.json             # ARM template (generated from Bicep, for one-click deploy)
│   ├── main.parameters.json         # Parameter file
│   └── modules/
│       ├── network.bicep            # VNet / NSG / Public IP
│       ├── vm-ubuntu.bicep          # Ubuntu VM module
│       └── vm-windows.bicep         # Windows VM module
├── scripts/
│   ├── install-openclaw-ubuntu.sh   # Ubuntu install script
│   ├── install-openclaw-windows.ps1 # Windows install script
│   └── shared-functions.ps1         # Shared PowerShell helper functions
├── deploy.ps1                       # Deployment entry script
├── destroy.ps1                      # Resource cleanup script
├── setup-teams.ps1                  # Teams channel semi-automated setup
├── azure.yaml                       # azd project configuration
├── .gitignore
├── LICENSE                          # MIT License
├── logs/                            # Deployment artifacts (git ignored)
│   └── {yyyyMMddHHmmss}/
│       ├── deploy.log               # Deployment log
│       ├── .env                     # Sensitive info
│       └── guide.md                 # Operations guide
└── README.md
```

## Recommended VM Sizes

| Scenario  | Recommended VM Size | vCPU | RAM   | Notes                                      |
| --------- | ------------------- | ---- | ----- | ------------------------------------------ |
| Light use | Standard_B2als_v2   | 2    | 4 GB  | Basic Gateway + 1-2 channels (Ubuntu only) |
| Daily use | Standard_B2as_v2    | 2    | 8 GB  | Multi-channel + Browser tools              |
| **Default (recommended)** | **Standard_D4s_v5** | **4** | **16 GB** | **Default; multi-agent + Browser + sandbox with steady perf** |
| Heavy use | Standard_B4as_v2    | 4    | 16 GB | Multi-agent + Browser + sandbox, cheaper but Burstable-throttled |

## Security

- All deployment modes enable Gateway password authentication by default (`gateway.auth.mode: "password"`), with an auto-generated password saved in the `.env` file
- Use `-EnablePublicHttps` to enable Caddy reverse proxy + Let's Encrypt auto HTTPS certificates for encrypted transport
- In HTTPS mode, Gateway binds to loopback only; only Caddy can access it; NSG opens port 443
- In non-HTTPS mode, NSG opens SSH (22) / RDP (3389) and Gateway (18789) ports; passwords are transmitted in cleartext over HTTP
- **Recommended**: Enable `-EnablePublicHttps` in production, or access Gateway via VPN to avoid cleartext password transmission
- Sensitive information (passwords, Gateway password, etc.) is only saved in `logs/<timestamp>/.env` and is never committed to Git
- Run `openclaw doctor` periodically to check security configuration
- See the OpenClaw [Security Guide](https://docs.openclaw.ai/gateway/security)

## FAQ

### Why does the first connection require pairing?

OpenClaw Gateway uses a device pairing mechanism for security. Each new browser/device must be approved on the server by running `openclaw devices approve --latest`. Pairing is based on a device token stored in the browser — switching browsers, clearing data, or using private mode will require re-pairing.

### Which AI models are supported?

OpenClaw supports multiple model providers including OpenAI (GPT-5.2/Codex), Anthropic (Claude), Google (Gemini), and more. See the [Models documentation](https://docs.openclaw.ai/concepts/models).

### Why does Windows need WSL2?

OpenClaw officially recommends running on WSL2 on Windows. This project's Windows 11 VM scripts automatically configure WSL2 + Ubuntu to run OpenClaw for best compatibility.

### How do I connect messaging channels?

After deployment, use `openclaw onboard` or manually edit `~/.openclaw/openclaw.json` to configure channels. The fastest way to get started is connecting Telegram (just needs a Bot Token). See the [Channels documentation](https://docs.openclaw.ai/channels).

### How do I update OpenClaw?

**Ubuntu:**

```bash
sudo npm install -g openclaw@latest
openclaw doctor
sudo systemctl restart openclaw
```

**Windows (WSL):**

```powershell
wsl -d Ubuntu -- bash -c "sudo npm install -g openclaw@latest"
wsl -d Ubuntu -- bash -c "sudo systemctl restart openclaw"
```

## Configuration Guides

After deployment, refer to these guides to configure AI models and messaging channels:

- [Configure Slack Channel](docs/en/guide-slack.md) — Chat with your AI assistant in Slack
- [Configure Microsoft Teams Channel](docs/en/guide-teams.md) — Chat with your AI assistant in Teams (includes semi-automated setup script `setup-teams.ps1`)
- [Operations Handbook](docs/en/guide-operations.md) — Service management, logs, upgrades, backups, and security audits

## References

- [OpenClaw Website](https://openclaw.ai/)
- [OpenClaw Documentation](https://docs.openclaw.ai/)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [ClawHub Skills Marketplace](https://clawhub.ai/)
- [OpenClaw Docker Deployment](https://docs.openclaw.ai/install/docker)
- [Tailscale Remote Access](https://docs.openclaw.ai/gateway/tailscale)

## License

[MIT](LICENSE)
