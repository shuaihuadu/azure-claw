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

---

## 1. Service Status Check

### Ubuntu

```bash
# Check OpenClaw Gateway status
$ sudo systemctl status openclaw

# Output example (normal):
#   Active: active (running) since ...
# Output example (abnormal):
#   Active: failed (Result: exit-code)

# Check OpenClaw health
$ openclaw doctor
```

### Windows (WSL)

```powershell
# Check if WSL is running
> wsl --list --verbose
# STATE should be Running

# Check OpenClaw service status inside WSL
> wsl -d Ubuntu -- sudo systemctl status openclaw

# Check if Windows port proxy is active
> netsh interface portproxy show v4tov4
# Should include 18789 -> WSL IP mapping

# Check OpenClaw health
> wsl -d Ubuntu -- openclaw doctor
```

### Local macOS (LaunchAgent)

```bash
# Check Gateway process
$ ps aux | grep openclaw-gateway

# Check LaunchAgent status
$ launchctl print gui/$(id -u)/ai.openclaw.gateway

# Health check
$ openclaw doctor

# List configured models
$ openclaw models list
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
# Gateway runtime log
$ cat ~/.openclaw/logs/gateway.log

# Gateway error log
$ cat ~/.openclaw/logs/gateway.err.log

# Follow in real-time
$ tail -f ~/.openclaw/logs/gateway.log

# Config health log
$ cat ~/.openclaw/logs/config-health.json
```

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

After modifying the config file, you **must restart the Gateway** for changes to take effect:

```bash
# Ubuntu
$ sudo systemctl restart openclaw

# macOS
$ openclaw gateway restart

# Windows (WSL)
> wsl -d Ubuntu -- sudo systemctl restart openclaw
```

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

---

## 11. Quick Troubleshooting Table

| Issue                                          | Cause                                                    | Solution                                                                                                        |
| ---------------------------------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| **Gateway fails to start**                     | Port in use / config file syntax error                   | `journalctl -u openclaw -n 50` to view error; `python3 -m json.tool ~/.openclaw/openclaw.json` to validate JSON |
| **`openclaw models list` errors**              | Invalid api type or missing models array in config       | Check provider's `api` field is valid (e.g., `openai-responses`); ensure `models` array exists                  |
| **Web UI opens but model calls fail**          | Wrong API Key / endpoint unreachable / model ID mismatch | Test endpoint directly with `curl`; verify API Key; confirm model ID matches deployment name                    |
| **Browser shows 401 Unauthorized**             | Gateway password auth enabled                            | Enter correct Gateway password (see `GATEWAY_PASSWORD` in `.env` file)                                          |
| **Slack/Teams messages no response**           | Channel not enabled / token expired / network issue      | Check channel config in `openclaw.json`; `openclaw doctor` to check channel status                              |
| **WSL service unreachable after restart**      | WSL IP changed, port proxy stale                         | Run `C:\openclaw\refresh-portproxy.ps1`                                                                         |
| **`npm install -g openclaw` permission error** | Ubuntu requires sudo                                     | Use `sudo npm install -g openclaw@latest`                                                                       |
| **HTTPS certificate expired/missing**          | Port 443 not allowed / DNS not resolving                 | Check NSG allows 443+80; `nslookup <FQDN>` to confirm DNS                                                       |
| **Can't SSH/RDP to VM**                        | VM stopped / NSG rules missing / wrong password          | Check VM status in Azure Portal; check NSG inbound rules                                                        |
| **Chat UI shows stale model list**             | Agent cache not refreshed                                | Delete `~/.openclaw/agents/main/agent/models.json` and restart Gateway                                          |

---

## Quick Command Reference

```bash
# ---- Ubuntu one-liner reference ----
sudo systemctl status openclaw          # Status
sudo systemctl restart openclaw         # Restart
journalctl -u openclaw -f               # Real-time logs
openclaw doctor                         # Health check
openclaw models list                    # Model list
sudo npm install -g openclaw@latest     # Upgrade

# ---- macOS one-liner reference ----
openclaw gateway restart                # Restart
openclaw doctor                         # Health check
openclaw models list                    # Model list
tail -f ~/.openclaw/logs/gateway.log    # Real-time logs
npm install -g openclaw@latest          # Upgrade
```
