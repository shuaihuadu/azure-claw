#!/bin/bash
set -euo pipefail

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

echo "=== OpenClaw installer for Ubuntu 24.04 LTS ==="
echo "Admin user: ${ADMIN_USER}"
echo "Public HTTPS: ${ENABLE_PUBLIC_HTTPS}"

# 1. Update system packages
echo ">>> Updating system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# 2. Install dependencies
echo ">>> Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y curl git build-essential

# 3. Install Node.js 24 via NodeSource
echo ">>> Installing Node.js 24..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"

# 4. Install OpenClaw globally
echo ">>> Installing OpenClaw..."
npm install -g openclaw@latest

# 5. Create OpenClaw config directory and default config
echo ">>> Creating OpenClaw configuration..."
mkdir -p "${ADMIN_HOME}/.openclaw"

if [ "${ENABLE_PUBLIC_HTTPS}" = "true" ]; then
  # With HTTPS: enable password auth, bind to loopback (Caddy handles external traffic)
  cat > "${ADMIN_HOME}/.openclaw/openclaw.json" <<EOF
{
  "agent": {
    "model": "anthropic/claude-opus-4-6"
  },
  "gateway": {
    "auth": {
      "mode": "password"
    }
  }
}
EOF
else
  cat > "${ADMIN_HOME}/.openclaw/openclaw.json" <<'EOF'
{
  "agent": {
    "model": "anthropic/claude-opus-4-6"
  }
}
EOF
fi
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.openclaw"

# 6. Create and enable systemd service
echo ">>> Configuring systemd service..."
OPENCLAW_PATH=$(which openclaw)

if [ "${ENABLE_PUBLIC_HTTPS}" = "true" ]; then
  # HTTPS mode: bind loopback, Caddy reverse proxies from 443
  GATEWAY_HOST="127.0.0.1"
  EXTRA_ENV="Environment=OPENCLAW_GATEWAY_PASSWORD=${GATEWAY_PASSWORD}"
else
  # Direct mode: bind all interfaces
  GATEWAY_HOST="0.0.0.0"
  EXTRA_ENV=""
fi

cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${ADMIN_USER}
ExecStart=${OPENCLAW_PATH} gateway --port 18789 --host ${GATEWAY_HOST}
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
${EXTRA_ENV}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw.service
systemctl start openclaw.service

# 7. Install Caddy reverse proxy (if HTTPS enabled)
if [ "${ENABLE_PUBLIC_HTTPS}" = "true" ]; then
  echo ">>> Installing Caddy reverse proxy..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y caddy

  echo ">>> Configuring Caddy..."
  cat > /etc/caddy/Caddyfile <<EOF
${FQDN} {
    reverse_proxy 127.0.0.1:18789
}
EOF

  systemctl restart caddy
  systemctl enable caddy
  echo ">>> Caddy configured for HTTPS on ${FQDN}"
fi

# 8. Configure firewall
echo ">>> Configuring firewall..."
if command -v ufw &> /dev/null; then
  if [ "${ENABLE_PUBLIC_HTTPS}" = "true" ]; then
    ufw allow 443/tcp
  else
    ufw allow 18789/tcp
  fi
fi

echo "=== OpenClaw installation complete ==="
