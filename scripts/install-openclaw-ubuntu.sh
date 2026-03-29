#!/bin/bash
set -euo pipefail

# Ensure log directory exists
mkdir -p /var/log/openclaw

# Log all output to file and console
exec > >(tee /var/log/openclaw/install.log) 2>&1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Usage: install-openclaw-ubuntu.sh <admin_username> [enable_public_https] [gateway_password_b64] [fqdn] [foundry_endpoint] [foundry_api_key] [foundry_models]
ADMIN_USER="${1:-azureclaw}"
ENABLE_PUBLIC_HTTPS="${2:-false}"
GATEWAY_PASSWORD_B64="${3:-}"
FQDN="${4:-}"
FOUNDRY_ENDPOINT="${5:-}"
FOUNDRY_API_KEY="${6:-}"
FOUNDRY_MODELS="${7:-}"
ADMIN_HOME="/home/${ADMIN_USER}"

# Decode base64 gateway password
GATEWAY_PASSWORD=""
if [ -n "${GATEWAY_PASSWORD_B64}" ]; then
  GATEWAY_PASSWORD=$(echo "${GATEWAY_PASSWORD_B64}" | base64 -d)
fi

log "=== OpenClaw installer for Ubuntu ==="
log "Admin user: ${ADMIN_USER}"
log "Public HTTPS: ${ENABLE_PUBLIC_HTTPS}"

# 1. Update system packages
log ">>> Updating system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# 2. Install dependencies
log ">>> Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y curl git build-essential

# 3. Install Node.js 24 via NodeSource
log ">>> Installing Node.js 24..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

log "Node.js version: $(node --version)"
log "npm version: $(npm --version)"

# 4. Install OpenClaw globally
log ">>> Installing OpenClaw..."
npm install -g openclaw@latest

# 5. Create OpenClaw config directory and default config
log ">>> Creating OpenClaw configuration..."
mkdir -p "${ADMIN_HOME}/.openclaw"

# Build config with gateway mode; use Python for safe JSON generation (handles special chars in password)
log ">>> Creating OpenClaw configuration..."
mkdir -p "${ADMIN_HOME}/.openclaw"

python3 - "${ADMIN_HOME}/.openclaw/openclaw.json" "${ENABLE_PUBLIC_HTTPS}" "${FQDN}" "${GATEWAY_PASSWORD}" "${FOUNDRY_ENDPOINT}" "${FOUNDRY_API_KEY}" "${FOUNDRY_MODELS}" <<'PYEOF'
import json, sys
config_path = sys.argv[1]
https_enabled = sys.argv[2]
fqdn = sys.argv[3]
gw_password = sys.argv[4]
foundry_endpoint = sys.argv[5]
foundry_api_key = sys.argv[6]
foundry_models_csv = sys.argv[7]

# Known model specs for auto-configuration
KNOWN_MODELS = {
    "gpt-4.1": {"reasoning": False, "input": ["text", "image"], "contextWindow": 1048576, "maxTokens": 32768},
    "gpt-4.1-mini": {"reasoning": False, "input": ["text", "image"], "contextWindow": 1048576, "maxTokens": 32768},
    "gpt-4.1-nano": {"reasoning": False, "input": ["text", "image"], "contextWindow": 1048576, "maxTokens": 32768},
    "gpt-5.1-chat": {"reasoning": True, "input": ["text", "image"], "contextWindow": 1048576, "maxTokens": 32768},
    "gpt-5.4-mini": {"reasoning": True, "input": ["text", "image"], "contextWindow": 1048576, "maxTokens": 32768},
}

def get_model_spec(model_id):
    if model_id in KNOWN_MODELS:
        return KNOWN_MODELS[model_id]
    import re
    reasoning = bool(re.search(r"(?i)(reasoning|think|\.1-chat|gpt-5|deepseek-r)", model_id))
    has_image = bool(re.search(r"(?i)(gpt-[45]|vision|multimodal)", model_id))
    return {"reasoning": reasoning, "input": ["text", "image"] if has_image else ["text"], "contextWindow": 131072, "maxTokens": 16384}

def format_display_name(model_id):
    parts = model_id.split("-")
    result = " ".join(p.capitalize() if p[0:1].islower() else p for p in parts)
    if result.lower().startswith("gpt "):
        result = "GPT " + result[4:]
    return result

# Default model: use Foundry if configured, otherwise Anthropic
default_model = "anthropic/claude-opus-4-6"
if foundry_endpoint and foundry_models_csv:
    first_model = foundry_models_csv.split(",")[0].strip()
    default_model = f"azure-openai/{first_model}"

config = {
    "agents": {"defaults": {"model": {"primary": default_model}}},
    "gateway": {"mode": "local"}
}

if https_enabled == "true" and fqdn:
    config["gateway"]["trustedProxies"] = ["127.0.0.1/32", "::1/128"]
    config["gateway"]["controlUi"] = {"allowedOrigins": [f"https://{fqdn}"]}

if gw_password:
    config["gateway"]["remote"] = {"password": gw_password}

# Configure Foundry models if endpoint is provided
if foundry_endpoint and foundry_api_key and foundry_models_csv:
    models_list = [m.strip() for m in foundry_models_csv.split(",") if m.strip()]
    model_entries = []
    defaults_models = {}
    for mid in models_list:
        spec = get_model_spec(mid)
        model_entries.append({
            "id": mid,
            "name": format_display_name(mid),
            "reasoning": spec["reasoning"],
            "input": spec["input"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": spec["contextWindow"],
            "maxTokens": spec["maxTokens"]
        })
        defaults_models[f"azure-openai/{mid}"] = {}

    config.setdefault("models", {}).setdefault("providers", {})
    config["models"]["providers"]["azure-openai"] = {
        "baseUrl": foundry_endpoint,
        "apiKey": foundry_api_key,
        "api": "openai-completions",
        "headers": {"api-key": foundry_api_key},
        "authHeader": False,
        "models": model_entries
    }
    config["agents"]["defaults"]["models"] = defaults_models

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
PYEOF
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.openclaw"

# 6. Create and enable systemd service
log ">>> Configuring systemd service..."
OPENCLAW_PATH=$(which openclaw)

# Determine bind mode and auth flags
if [ "${ENABLE_PUBLIC_HTTPS}" = "true" ]; then
  # HTTPS mode: bind loopback, Caddy reverse proxies from 443
  BIND_MODE="loopback"
else
  # Direct mode: bind all interfaces for remote access
  BIND_MODE="lan"
fi

# Build ExecStart command (password is read from OPENCLAW_GATEWAY_PASSWORD env var)
EXEC_CMD="${OPENCLAW_PATH} gateway run --port 18789 --bind ${BIND_MODE} --auth password"

cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ADMIN_USER}
ExecStart=${EXEC_CMD}
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=OPENCLAW_GATEWAY_PASSWORD=${GATEWAY_PASSWORD}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw.service
systemctl restart openclaw.service

# 7. Install Caddy reverse proxy (if HTTPS enabled)
if [ "${ENABLE_PUBLIC_HTTPS}" = "true" ]; then
  log ">>> Installing Caddy reverse proxy..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y caddy

  log ">>> Configuring Caddy..."
  cat > /etc/caddy/Caddyfile <<EOF
${FQDN} {
    reverse_proxy 127.0.0.1:18789
}
EOF

  systemctl restart caddy
  systemctl enable caddy
  log ">>> Caddy configured for HTTPS on ${FQDN}"
fi

# 8. Configure firewall
log ">>> Configuring firewall..."
if command -v ufw &> /dev/null; then
  if [ "${ENABLE_PUBLIC_HTTPS}" = "true" ]; then
    ufw allow 443/tcp
    ufw allow 80/tcp
  else
    ufw allow 18789/tcp
  fi
fi

log "=== OpenClaw installation complete ==="
