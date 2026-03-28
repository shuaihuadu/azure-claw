#!/bin/bash
set -euo pipefail

# Ensure log directory exists
mkdir -p /var/log/openclaw

# Log all output to file and console
exec > >(tee /var/log/openclaw/install.log) 2>&1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Usage: install-openclaw-ubuntu.sh <admin_username> [enable_public_https] [gateway_password_b64] [fqdn]
ADMIN_USER="${1:-azureclaw}"
ENABLE_PUBLIC_HTTPS="${2:-false}"
GATEWAY_PASSWORD_B64="${3:-}"
FQDN="${4:-}"
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

# Build config with gateway mode; add allowedOrigins when using HTTPS reverse proxy
log ">>> Creating OpenClaw configuration..."
mkdir -p "${ADMIN_HOME}/.openclaw"

if [ "${ENABLE_PUBLIC_HTTPS}" = "true" ] && [ -n "${FQDN}" ]; then
cat > "${ADMIN_HOME}/.openclaw/openclaw.json" <<EOF
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-opus-4-6"
      }
    }
  },
  "gateway": {
    "mode": "local",
    "controlUi": {
      "allowedOrigins": ["https://${FQDN}"]
    }
  }
}
EOF
else
cat > "${ADMIN_HOME}/.openclaw/openclaw.json" <<EOF
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-opus-4-6"
      }
    }
  },
  "gateway": {
    "mode": "local"
  }
}
EOF
fi
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

# Build ExecStart command with auth flags
EXEC_CMD="${OPENCLAW_PATH} gateway run --port 18789 --bind ${BIND_MODE} --auth password"
if [ -n "${GATEWAY_PASSWORD}" ]; then
  EXEC_CMD="${EXEC_CMD} --password \${OPENCLAW_GATEWAY_PASSWORD}"
fi

cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ADMIN_USER}
ExecStart=${EXEC_CMD}
Restart=on-failure
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
