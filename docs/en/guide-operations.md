# OpenClaw Operations Handbook

This document covers day-to-day operations for OpenClaw on Azure VMs, including service management, log troubleshooting, configuration changes, upgrades, and common issue resolution.

> **Convention**: Commands prefixed with `$` are run on Ubuntu (SSH), and commands prefixed with `>` are run on Windows (PowerShell / RDP).

---

## Table of Contents

1. [Service Status Check](#1-service-status-check)
2. [Restart Service](#2-restart-service)
3. [View Logs](#3-view-logs)
4. [Configuration Management](#4-configuration-management)
5. [Upgrade OpenClaw](#5-upgrade-openclaw)
6. [Port & Network Troubleshooting](#6-port--network-troubleshooting)
7. [Caddy (HTTPS) Troubleshooting](#7-caddy-https-troubleshooting)
8. [Disk & Resource Monitoring](#8-disk--resource-monitoring)
9. [Backup & Restore](#9-backup--restore)
10. [Security Audit](#10-security-audit)
11. [Quick Troubleshooting Table](#11-quick-troubleshooting-table)
12. [Device Pairing Management](#12-device-pairing-management)

---

## 1. Service Status Check

### OpenClaw CLI (recommended, cross-platform)

OpenClaw ships a cross-platform operator command set that does not rely on systemd:

```bash
# Quick local overview (gateway reachability, models, channels, recent activity)
$ openclaw status
$ openclaw status --all       # full local diagnosis (safe to paste)
$ openclaw status --deep      # asks the gateway for a live health probe

# Gateway control
$ openclaw gateway status     # gateway process status
$ openclaw gateway status --deep  # also scans system services (launchd/systemd/schtasks)
$ openclaw gateway restart    # restart
$ openclaw gateway stop       # stop
$ openclaw gateway install    # install as a supervised service
$ openclaw gateway probe      # probe gateway reachability

# Dedicated health command
$ openclaw health             # gateway snapshot (WS, low overhead)
$ openclaw health --verbose   # force live probe
$ openclaw health --json      # machine-readable

# Repair and migrations (config, state dir, services)
$ openclaw doctor             # read-only diagnosis + interactive fixes
$ openclaw doctor --fix       # auto-apply config/state migrations
$ openclaw doctor --repair    # silent repair (apply all recommended fixes)
$ openclaw doctor --deep      # also scan for extra gateway installs

# Logs
$ openclaw logs --follow      # equivalent to tail -f

# Channel health
$ openclaw channels status --probe  # live per-account channel probe via gateway
```

### Ubuntu systemd layer

```bash
# OpenClaw Gateway systemd status
$ sudo systemctl status openclaw

# Output example (healthy):
#   Active: active (running) since ...
# Output example (unhealthy):
#   Active: failed (Result: exit-code)
```

### Windows (WSL)

```powershell
# Check if WSL is running
> wsl --list --verbose
# STATE should be Running

# Run the cross-platform CLI inside WSL
> wsl -d Ubuntu -u openclaw -- openclaw status
> wsl -d Ubuntu -u openclaw -- openclaw health

# Check Windows port proxy
> netsh interface portproxy show v4tov4
# Should include 18789 -> WSL IP mapping
```

### Local macOS (LaunchAgent)

```bash
# The cross-platform CLI above already covers this. Extra launchd layer:
$ launchctl print gui/$(id -u)/ai.openclaw.gateway
```

---

## 2. Restart Service

### Ubuntu

```bash
# Restart OpenClaw Gateway
$ sudo systemctl restart openclaw

# Stop only
$ sudo systemctl stop openclaw

# Start only
$ sudo systemctl start openclaw

# Reload systemd config (required after modifying .service file)
$ sudo systemctl daemon-reload
$ sudo systemctl restart openclaw
```

### Windows (WSL)

```powershell
# Restart OpenClaw inside WSL
> wsl -d Ubuntu -- sudo systemctl restart openclaw

# If WSL itself is stuck, restart entire WSL
> wsl --shutdown
> wsl -d Ubuntu -- sudo systemctl start openclaw

# After WSL restart, refresh port proxy (IP changes)
# Script located at C:\openclaw\refresh-portproxy.ps1 (created during deployment)
> powershell -File C:\openclaw\refresh-portproxy.ps1
```

### Local macOS

```bash
# Restart Gateway using built-in command
$ openclaw gateway restart

# Manual method
$ launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway
```

---

## 3. View Logs

### Ubuntu

```bash
# Follow Gateway logs in real-time (Ctrl+C to exit)
$ journalctl -u openclaw -f

# View last 100 log lines
$ journalctl -u openclaw -n 100

# View logs from the last hour
$ journalctl -u openclaw --since "1 hour ago"

# View installation log
$ cat /var/log/openclaw/install.log

# View Caddy logs (when HTTPS is enabled)
$ journalctl -u caddy -f
```

### Windows (WSL)

```powershell
# View logs inside WSL
> wsl -d Ubuntu -- journalctl -u openclaw -f

# View installation logs
> type C:\openclaw\phase1.log
> type C:\openclaw\phase2.log

# View Caddy logs (when HTTPS is enabled)
> type C:\caddy\caddy.log
```

### Local macOS

```bash
# OpenClaw writes logs to /tmp/openclaw/ by default (rotated daily)
$ ls /tmp/openclaw/

# Follow today's log in real time
$ tail -f /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log

# Or use the built-in cross-platform CLI
$ openclaw logs --follow

# LaunchAgent stdout/stderr paths (if redirected):
$ cat ~/Library/Logs/openclaw/gateway.log 2>/dev/null || echo 'check launchctl print for actual paths'
```

> Log path can be customised via `logging.file` in `openclaw.json`.

---

## 4. Configuration Management

### Config File Location

| Environment      | Path                                                 |
| ---------------- | ---------------------------------------------------- |
| Ubuntu VM        | `/home/<admin>/.openclaw/openclaw.json`              |
| Windows VM (WSL) | Inside WSL: `/home/openclaw/.openclaw/openclaw.json` |
| Local macOS      | `~/.openclaw/openclaw.json`                          |

### View Current Configuration

```bash
# View full config (note: contains API Key — don't output in insecure environments)
$ cat ~/.openclaw/openclaw.json

# View model config only
$ openclaw models list

# Diagnose config issues
$ openclaw doctor
```

### Apply Config Changes

The Gateway watches `~/.openclaw/openclaw.json` by default (`gateway.reload.mode="hybrid"`) and hot-applies most changes automatically — **no manual restart needed for the majority of fields**.

Hot reload semantics:

| Change type                                                                                        | Needs restart? |
| -------------------------------------------------------------------------------------------------- | -------------- |
| Channels (`channels.*`, WhatsApp/Slack/Teams, etc.)                                                | No             |
| Agent / models / routing (`agents`, `models`, `routing`)                                           | No             |
| Sessions / messages / tools / media (`session`, `messages`, `tools`, `browser`, `skills`, `audio`) | No             |
| Automation (`hooks`, `cron`, `agent.heartbeat`)                                                    | No             |
| Gateway server (`gateway.port`, `gateway.bind`, `gateway.auth`, `gateway.tailscale`, TLS)          | **Yes**        |
| Infrastructure (`discovery`, `canvasHost`, `plugins`)                                              | **Yes**        |

In `hybrid` mode the Gateway auto-restarts for restart-required fields. For normal fields the change is virtually instant. Confirm a reload in the logs:

```bash
$ journalctl -u openclaw -f | grep -i reload
```

If you do need to restart manually (e.g. after changing port or auth mode):

```bash
# Cross-platform (recommended)
$ openclaw gateway restart

# Or via systemd
$ sudo systemctl restart openclaw

# Windows (WSL)
> wsl -d Ubuntu -u openclaw -- openclaw gateway restart
```

> [Rare case] Editing the `.service` unit file (not `openclaw.json`) still requires `sudo systemctl daemon-reload && sudo systemctl restart openclaw`.

### Common Config Change Examples

**Switch default model:**

Edit `agents.defaults.model.primary` in `openclaw.json`:

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "azure-openai/gpt-4.1"
      }
    }
  }
}
```

**Add model aliases:**

```json
{
  "agents": {
    "defaults": {
      "models": {
        "azure-openai/gpt-4.1": { "alias": "gpt4" },
        "azure-openai/gpt-5.4-mini": { "alias": "mini" }
      }
    }
  }
}
```

**Change Gateway bind address:**

```json
{
  "gateway": {
    "port": 18789,
    "bind": "loopback"
  }
}
```

`bind` options: `"loopback"` (localhost only), `"0.0.0.0"` (all interfaces).

---

## 5. Upgrade OpenClaw

### Ubuntu

```bash
# 1. Upgrade
$ sudo npm install -g openclaw@latest

# 2. Verify
$ openclaw --version
$ openclaw doctor

# 3. Restart service
$ sudo systemctl restart openclaw

# 4. Check running status
$ sudo systemctl status openclaw
```

### Windows (WSL)

```powershell
# 1. Upgrade inside WSL
> wsl -d Ubuntu -- bash -c "sudo npm install -g openclaw@latest"

# 2. Verify
> wsl -d Ubuntu -- openclaw --version

# 3. Restart service
> wsl -d Ubuntu -- sudo systemctl restart openclaw
```

### Local macOS

```bash
$ npm install -g openclaw@latest
$ openclaw --version
$ openclaw doctor
$ openclaw gateway restart
```

> **Note**: After upgrading, run `openclaw doctor` to check. Major version upgrades may require running `openclaw onboard` to update the configuration.

---

## 6. Port & Network Troubleshooting

### Check Port Listening

```bash
# Ubuntu / macOS — Check if port 18789 is listening
$ ss -tlnp | grep 18789
# or
$ lsof -i :18789
```

```powershell
# Windows — Check port usage
> netstat -ano | findstr 18789
```

### Test Connectivity

```bash
# Test if VM's Gateway is reachable from local machine
$ curl -s -o /dev/null -w "%{http_code}" http://<VM_PUBLIC_IP>:18789
# Returns 200 or 401 means port is accessible

# Test HTTPS (when Caddy is enabled)
$ curl -s -o /dev/null -w "%{http_code}" https://<FQDN>
```

### NSG Rule Check

```bash
# View inbound rules for the VM's NSG
$ az network nsg rule list --nsg-name openclaw-nsg --resource-group rg-openclaw -o table
```

### Common Network Issues

| Symptom                   | Possible Cause                                  | Troubleshooting                          |
| ------------------------- | ----------------------------------------------- | ---------------------------------------- |
| Browser can't reach 18789 | NSG not allowing / Gateway not bound to 0.0.0.0 | Check NSG rules + `ss -tlnp`             |
| HTTPS certificate error   | Caddy didn't obtain cert / DNS not resolving    | `journalctl -u caddy` to check cert logs |
| WSL port unreachable      | Port proxy stale (WSL IP changed)               | Run `refresh-portproxy.ps1`              |
| Connection timeout        | VM not started / NSG denying all                | Check VM status and NSG in Azure Portal  |

---

## 7. Caddy (HTTPS) Troubleshooting

Only applicable when deployed with `-EnablePublicHttps`.

### Ubuntu

```bash
# Check Caddy status
$ sudo systemctl status caddy

# View Caddy configuration
$ cat /etc/caddy/Caddyfile

# Restart Caddy
$ sudo systemctl restart caddy

# Check certificate status
$ sudo caddy list-certificates

# Test reverse proxy to Gateway
$ curl -s http://127.0.0.1:18789
```

### Windows

```powershell
# Caddy installation directory
> dir C:\caddy\

# View Caddyfile
> type C:\caddy\Caddyfile

# Start Caddy manually (for troubleshooting)
> C:\caddy\caddy.exe run --config C:\caddy\Caddyfile
```

### Let's Encrypt Certificate Acquisition Failure

Common causes:
1. DNS not yet pointing to VM's public IP — confirm `nslookup <FQDN>` returns the correct IP
2. Port 443 blocked by firewall — confirm NSG allows 443 and 80
3. Invalid domain format — the domain in the Caddyfile must be a fully qualified domain name (FQDN)

---

## 8. Disk & Resource Monitoring

### Ubuntu

```bash
# Disk usage
$ df -h

# OpenClaw directory usage
$ du -sh ~/.openclaw/

# Clean OpenClaw session history (free space)
$ du -sh ~/.openclaw/agents/main/sessions/
$ rm -f ~/.openclaw/agents/main/sessions/*.jsonl

# Memory and CPU
$ free -h
$ top -b -n 1 | head -20
```

### Windows

```powershell
# Disk usage
> Get-PSDrive C | Select-Object Used, Free

# OpenClaw directory usage
> wsl -d Ubuntu -- du -sh /home/openclaw/.openclaw/

# WSL memory usage
> wsl -d Ubuntu -- free -h
```

---

## 9. Backup & Restore

### Backup

Key data directories:

| Directory                   | Content                        | Importance |
| --------------------------- | ------------------------------ | ---------- |
| `~/.openclaw/openclaw.json` | Main config file               | ★★★        |
| `~/.openclaw/credentials/`  | Channel auth credentials       | ★★★        |
| `~/.openclaw/agents/`       | Agent config + session history | ★★         |
| `~/.openclaw/workspace/`    | Working directory              | ★          |

```bash
# Ubuntu — Backup locally
$ tar czf openclaw-backup-$(date +%Y%m%d).tar.gz \
    ~/.openclaw/openclaw.json \
    ~/.openclaw/credentials/ \
    ~/.openclaw/agents/main/agent/

# Download to local machine (run from local)
$ scp <user>@<VM_IP>:~/openclaw-backup-*.tar.gz ./
```

### Restore

```bash
# Upload backup to VM
$ scp openclaw-backup-20260327.tar.gz <user>@<VM_IP>:~/

# Restore on VM
$ cd ~ && tar xzf openclaw-backup-20260327.tar.gz
$ sudo systemctl restart openclaw
```

---

## 10. Security Audit

Perform these checks periodically to ensure Gateway security:

```bash
# 1. Run OpenClaw built-in diagnostics
$ openclaw doctor

# 2. Check Gateway auth mode (should be password or token)
$ grep -A3 '"auth"' ~/.openclaw/openclaw.json

# 3. Check Gateway bind address
#    - With HTTPS (Caddy): should be loopback (127.0.0.1)
#    - Without HTTPS: bound to 0.0.0.0 but must have password auth enabled
$ grep '"bind"' ~/.openclaw/openclaw.json

# 4. Check NSG rules for unnecessary exposed ports
$ az network nsg rule list --nsg-name openclaw-nsg --resource-group rg-openclaw -o table

# 5. Check system updates (Ubuntu)
$ sudo apt list --upgradable

# 6. Check npm global packages for known vulnerabilities
$ npm audit -g
```

### Security Best Practices Checklist

- [ ] Gateway authentication enabled (`gateway.auth.mode` is `password` or `token`)
- [ ] HTTPS enabled in production (`-EnablePublicHttps`)
- [ ] NSG only opens necessary ports (HTTPS: 443, non-HTTPS: 22/3389 + 18789)
- [ ] OS and Node.js are up to date
- [ ] API Keys are not hardcoded in scripts or code
- [ ] `.env` files in `logs/` directory are not committed to Git

### Gateway Control Token (`gateway.auth.token`)

The control token is the shared secret used by remote clients (macOS app, `openclaw` CLI over SSH tunnel, iOS/Android nodes) to authenticate against the Gateway WebSocket. This project defaults to `password` mode paired with Caddy HTTPS. If you need to switch to `token` mode (for example to pair the macOS "Remote over SSH" app or iOS/Android nodes), use one of the methods below to obtain the token.

#### 1. Use the token OpenClaw auto-generates

```bash
# Option A: onboard writes one by default — just read it
$ jq -r '.gateway.auth.token' ~/.openclaw/openclaw.json

# Option B: use the doctor subcommand to (re)generate one
$ openclaw doctor --generate-gateway-token
```

The generated token is written to `gateway.auth.token` in `~/.openclaw/openclaw.json`. Restart the service so the new config takes effect:

```bash
$ sudo systemctl restart openclaw
```

#### 2. Set a custom token manually

```bash
# Generate a random 32-byte token
$ TOKEN=$(openssl rand -base64 32)
$ echo "$TOKEN"

# Apply to config
$ openclaw config set gateway.auth.mode token
$ openclaw config set gateway.auth.token "$TOKEN"
$ sudo systemctl restart openclaw
```

#### 3. How clients consume the token

- **Environment variable**: `export OPENCLAW_GATEWAY_TOKEN="<token>"`
- **CLI flag**: `openclaw gateway status --url ws://127.0.0.1:18789 --token <token>`
- **Client config**: write `gateway.remote.token` in the client's local `~/.openclaw/openclaw.json`
  ```bash
  openclaw config set gateway.remote.token "<token>"
  ```

#### 4. Rotate the token

Rotate immediately if you suspect the token has leaked:

```bash
$ openclaw doctor --generate-gateway-token   # generate new token
$ sudo systemctl restart openclaw             # apply
# Then update `gateway.remote.token` on every client (macOS app / CLI / nodes)
```

> ⚠️ Never commit the token to Git. It is an operator credential: anyone holding it can call `/v1/chat/completions`, `/tools/invoke`, and every other Gateway HTTP surface.

---

## 11. Quick Troubleshooting Table

| Issue                                          | Cause                                                    | Solution                                                                                                        |
| ---------------------------------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| **Gateway fails to start**                     | Port in use / config file syntax error                   | `journalctl -u openclaw -n 50` to view error; `python3 -m json.tool ~/.openclaw/openclaw.json` to validate JSON |
| **`openclaw models list` errors**              | Invalid api type or missing models array in config       | Check provider's `api` field is valid (e.g., `openai-responses`); ensure `models` array exists                  |
| **Web UI opens but model calls fail**          | Wrong API Key / endpoint unreachable / model ID mismatch | Test endpoint directly with `curl`; verify API Key; confirm model ID matches deployment name                    |
| **Browser shows 401 Unauthorized**             | Gateway password auth enabled                            | Enter correct Gateway password (`deploy.ps1`: `GATEWAY_PASSWORD` in `.env`; Portal one-click: whatever you typed as `gatewayPassword`; lost both: see [§10 Credential Lookup](#credential-lookup-login-password--control-token))                                          |
| **Browser shows `origin not allowed`** | Accessing Control UI from a non-loopback origin not in `gateway.controlUi.allowedOrigins` | See [11.1 Control UI “origin not allowed”](#111-control-ui-origin-not-allowed) below |
| **Slack/Teams messages no response**           | Channel not enabled / token expired / network issue      | Check channel config in `openclaw.json`; `openclaw doctor` to check channel status                              |
| **WSL service unreachable after restart**      | WSL IP changed, port proxy stale                         | Run `C:\openclaw\refresh-portproxy.ps1`                                                                         |
| **`npm install -g openclaw` permission error** | Ubuntu requires sudo                                     | Use `sudo npm install -g openclaw@latest`                                                                       |
| **HTTPS certificate expired/missing**          | Port 443 not allowed / DNS not resolving                 | Check NSG allows 443+80; `nslookup <FQDN>` to confirm DNS                                                       |
| **Can't SSH/RDP to VM**                        | VM stopped / NSG rules missing / wrong password          | Check VM status in Azure Portal; check NSG inbound rules                                                        |
| **Chat UI shows stale model list**             | Agent cache not refreshed                                | Delete `~/.openclaw/agents/main/agent/models.json` and restart Gateway                                          |

---

### 11.1 Control UI “origin not allowed”

**Symptom**: opening the Control UI in a browser shows

```
origin not allowed (open the Control UI from the gateway host or allow it in gateway.controlUi.allowedOrigins)
```

**Why**: by default the Gateway only trusts loopback origins (`http://127.0.0.1:18789`, `http://localhost:18789`). The moment you load the UI from a public IP, an Azure FQDN, the Caddy HTTPS hostname, or any reverse proxy, the Control UI rejects the origin as a security guard.

**Recommended fixes (most secure first)**:

#### Option A: SSH tunnel (most secure, best for daily use)

From your laptop:

```bash
ssh -N -L 18789:127.0.0.1:18789 <ADMIN_USERNAME>@<VM_PUBLIC_IP>
```

Then open <http://127.0.0.1:18789/>. From the Gateway's perspective the request is loopback — no allowlist edit required.

#### Option B: Allow your browser origin (Caddy HTTPS / public-access deployments)

SSH into the VM and run:

```bash
# Single origin
openclaw config set gateway.controlUi.allowedOrigins '["https://openclaw-xxxx.japaneast.cloudapp.azure.com"]'

# Multiple origins
openclaw config set gateway.controlUi.allowedOrigins \
  '["https://openclaw-xxxx.japaneast.cloudapp.azure.com", "https://chat.example.com"]'
```

Or edit `~/.openclaw/openclaw.json` directly:

```jsonc
{
  "gateway": {
    "controlUi": {
      "enabled": true,
      // List every origin (scheme + host + port) you'll load the UI from in a browser.
      "allowedOrigins": [
        "https://openclaw-xxxx.japaneast.cloudapp.azure.com",
        "http://20.48.19.109:18789"
      ]
    }
  }
}
```

Gateway hot-reload picks it up (`gateway.reload.mode` defaults to `hybrid`). If it doesn't, restart manually:

```bash
openclaw gateway restart
# or
sudo systemctl restart openclaw
```

Verify:

```bash
openclaw config get gateway.controlUi.allowedOrigins
```

#### Three common pitfalls

1. **Origins must match exactly**: `scheme://host[:port]`, no trailing slash. `https://example.com` is not the same as `https://example.com/`. `https://example.com` and `https://example.com:443` are equivalent, but prefer the bare form.
2. **HTTP and HTTPS are different origins**: if Caddy is doing TLS, allow only `https://...` — don't also add `http://...:18789` unless you actually need both reachable.
3. **Don't reach for `dangerouslyAllowHostHeaderOriginFallback`**: it lets the Control UI trust whatever appears in the Host header, which can be spoofed behind a misconfigured proxy. Only use it if you fully control the proxy/ingress chain.

#### Caddy HTTPS shortcut

If you deployed with `deploy.ps1 -EnablePublicHttps` the FQDN is in your `.env` file:

```bash
FQDN=<your FQDN from .env>
openclaw config set gateway.controlUi.allowedOrigins "[\"https://$FQDN\"]"
openclaw gateway restart
```

---

## 12. Device Pairing Management

OpenClaw Gateway requires a per-browser/per-client **device pairing** approval. Even after entering the password, the browser must be approved on the server side before it can access the Control UI.

### 12.1 First-time pairing flow

> **Order matters**: the gateway only produces a pairing request after the browser's password check passes. If the password/token is wrong the browser gets a flat 401, the server never sees a pairing request, and `openclaw devices list --pending` stays empty — there is nothing for `approve` to act on.

1. SSH into the VM and run `openclaw onboard` to configure your model API key (required after the first deploy)
2. Open the Control UI in your browser (`https://<FQDN>` or `http://<IP>:18789`), enter `GATEWAY_PASSWORD`, click connect
3. Browser shows `pairing required` / "waiting for server approval" (this confirms the password check passed)
4. SSH into the VM (Windows: `wsl -d Ubuntu -u openclaw -- ...`) and run:

```bash
openclaw devices approve --latest
```

5. Browser auto-connects.

### 12.2 Common commands

```bash
openclaw devices list                    # list all paired devices
openclaw devices list --pending          # only pending requests
openclaw devices approve --latest        # approve the latest request
openclaw devices approve <id>            # approve a specific request
openclaw devices remove <id>             # revoke one device
openclaw devices remove --all            # wipe all (every client must re-pair)
```

### 12.3 When you need to re-pair

Pairing is bound to a device token stored in browser local storage. The following situations lose the token and require a fresh approval:

- Switching browsers or devices
- Private / incognito windows
- Manually clearing site data, cookies, or LocalStorage
- Browser reinstall or different OS user profile
- Server-side `openclaw devices remove`

### 12.4 Troubleshooting

- **Browser stuck at "pairing required"**: server hasn't approved, or the gateway didn't push the event. Refresh the browser.
- **`openclaw devices list --pending` is empty**: the request never reached the gateway. Check that origin isn't being blocked (§11.1) and the password is correct.
- **Don't try to reuse a device record across people**: device tokens are private credentials. Sharing one means anyone with it can act as that device.

---

## Quick Command Reference

```bash
# ---- Cross-platform OpenClaw CLI (recommended) ----
openclaw status                         # Local overview
openclaw status --deep                  # Live gateway probe
openclaw health --json                  # Structured health snapshot
openclaw gateway restart                # Restart gateway
openclaw gateway status                 # Gateway status
openclaw doctor                         # Diagnose
openclaw doctor --repair                # Silent repair
openclaw logs --follow                  # Follow logs
openclaw channels status --probe        # Channel probe
openclaw models list                    # List models
npm install -g openclaw@latest          # Upgrade (Ubuntu needs sudo)

# ---- Ubuntu systemd layer ----
sudo systemctl status openclaw          # Status
sudo systemctl restart openclaw         # Restart
journalctl -u openclaw -f               # Follow logs
```
