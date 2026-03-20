param(
    [switch]$EnablePublicHttps,
    [string]$GatewayPasswordB64 = '',
    [string]$Fqdn = ''
)

$ErrorActionPreference = 'Stop'

# Decode base64 gateway password
$GatewayPassword = ''
if ($GatewayPasswordB64) {
    $GatewayPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($GatewayPasswordB64))
}

# OpenClaw installer for Windows 11 (via WSL2)
# Phase 1: Enable WSL2, optionally install Caddy, register post-reboot setup task, reboot
# Phase 2: After reboot, the scheduled task installs Node.js + OpenClaw in WSL

Write-Host "=== OpenClaw installer for Windows 11 (Phase 1) ==="
Write-Host "Public HTTPS: $EnablePublicHttps"

# 1. Install WSL2 with Ubuntu (handles feature enablement automatically on Win11)
Write-Host ">>> Installing WSL2 with Ubuntu..."
wsl --install --distribution Ubuntu --no-launch

# 2. Configure Windows Firewall
Write-Host ">>> Configuring Windows Firewall..."
New-NetFirewallRule -DisplayName "OpenClaw Gateway" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 18789 `
    -Action Allow `
    -Profile Any `
    -ErrorAction SilentlyContinue

if ($EnablePublicHttps) {
    New-NetFirewallRule -DisplayName "HTTPS (Caddy)" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 443 `
        -Action Allow `
        -Profile Any `
        -ErrorAction SilentlyContinue

    # Download Caddy binary
    Write-Host ">>> Downloading Caddy..."
    $caddyDir = "C:\caddy"
    New-Item -ItemType Directory -Path $caddyDir -Force | Out-Null
    Invoke-WebRequest -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile "$caddyDir\caddy.exe" -UseBasicParsing

    # Write Caddyfile
    Write-Host ">>> Writing Caddyfile..."
    Set-Content -Path "$caddyDir\Caddyfile" -Value @"
$Fqdn {
    reverse_proxy 127.0.0.1:18789
}
"@ -Encoding UTF8
}

# 3. Write config for Phase 2 to read
Write-Host ">>> Writing Phase 2 config..."
$configContent = @"
EnablePublicHttps=$($EnablePublicHttps.ToString())
GatewayPassword=$GatewayPassword
Fqdn=$Fqdn
"@
Set-Content -Path "C:\openclaw-config.txt" -Value $configContent -Encoding UTF8

# 4. Create post-reboot setup script (Phase 2)
Write-Host ">>> Creating post-reboot setup script..."

$phase2Script = @'
$ErrorActionPreference = 'Stop'
$logFile = "C:\openclaw-setup.log"

function Log { param($msg) Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" }

Log "=== OpenClaw post-reboot setup (Phase 2) started ==="

# Read config from Phase 1
$config = @{}
Get-Content "C:\openclaw-config.txt" | ForEach-Object {
    $parts = $_ -split '=', 2
    if ($parts.Count -eq 2) { $config[$parts[0]] = $parts[1] }
}
$enableHttps = $config['EnablePublicHttps'] -eq 'True'
$gwPassword = $config['GatewayPassword']
$fqdn = $config['Fqdn']
Log "Config: EnablePublicHttps=$enableHttps, Fqdn=$fqdn"

# Wait for WSL to be ready
$maxRetries = 30
for ($i = 0; $i -lt $maxRetries; $i++) {
    $status = wsl --status 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    Log "Waiting for WSL... attempt $($i + 1)/$maxRetries"
    Start-Sleep -Seconds 10
}

# Initialize Ubuntu distro
Log "Initializing Ubuntu distro..."
wsl -d Ubuntu -- bash -c "echo 'Ubuntu ready'"
Log "Ubuntu distro initialized"

# Install Node.js 24
Log "Installing Node.js 24..."
wsl -d Ubuntu -- bash -c "curl -fsSL https://deb.nodesource.com/setup_24.x | sudo bash - && sudo apt-get install -y nodejs"
Log "Node.js installed: $(wsl -d Ubuntu -- node --version)"

# Install OpenClaw
Log "Installing OpenClaw..."
wsl -d Ubuntu -- bash -c "sudo npm install -g openclaw@latest"
Log "OpenClaw installed"

# Create config
Log "Creating OpenClaw configuration..."
if ($enableHttps) {
    wsl -d Ubuntu -- bash -c "mkdir -p ~/.openclaw && cat > ~/.openclaw/openclaw.json << 'HEREDOC'
{
  ""agent"": {
    ""model"": ""anthropic/claude-opus-4-6""
  },
  ""gateway"": {
    ""auth"": {
      ""mode"": ""password""
    }
  }
}
HEREDOC"
} else {
    wsl -d Ubuntu -- bash -c "mkdir -p ~/.openclaw && cat > ~/.openclaw/openclaw.json << 'HEREDOC'
{
  ""agent"": {
    ""model"": ""anthropic/claude-opus-4-6""
  }
}
HEREDOC"
}

# Create systemd service in WSL
Log "Configuring systemd service..."
$gatewayHost = if ($enableHttps) { "127.0.0.1" } else { "0.0.0.0" }
$envLine = if ($enableHttps -and $gwPassword) { "Environment=OPENCLAW_GATEWAY_PASSWORD=$gwPassword" } else { "" }
$unit = @"
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/openclaw gateway --port 18789 --host $gatewayHost
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
$envLine

[Install]
WantedBy=multi-user.target
"@
$unit | wsl -d Ubuntu -- bash -c "sudo tee /etc/systemd/system/openclaw.service > /dev/null"
wsl -d Ubuntu -- bash -c "sudo systemctl daemon-reload && sudo systemctl enable openclaw.service && sudo systemctl start openclaw.service"
Log "OpenClaw service started"

# Configure port proxy from host to WSL
$wslIp = wsl -d Ubuntu -- bash -c "hostname -I" | ForEach-Object { $_.Trim().Split(' ')[0] }
if ($wslIp) {
    $listenAddr = if ($enableHttps) { "127.0.0.1" } else { "0.0.0.0" }
    netsh interface portproxy add v4tov4 listenport=18789 listenaddress=$listenAddr connectport=18789 connectaddress=$wslIp
    Log "Port proxy: ${listenAddr}:18789 -> WSL(${wslIp}):18789"
}

# Start Caddy if HTTPS is enabled
if ($enableHttps -and (Test-Path "C:\caddy\caddy.exe")) {
    Log "Starting Caddy reverse proxy..."
    $caddyAction = New-ScheduledTaskAction -Execute "C:\caddy\caddy.exe" -Argument "run --config C:\caddy\Caddyfile"
    $caddyTrigger = New-ScheduledTaskTrigger -AtStartup
    $caddyPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "CaddyServer" -Action $caddyAction -Trigger $caddyTrigger -Principal $caddyPrincipal -Force
    Start-ScheduledTask -TaskName "CaddyServer"
    Log "Caddy started for HTTPS on $fqdn"
}

# Clean up
Remove-Item "C:\openclaw-config.txt" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "OpenClawSetup" -Confirm:$false -ErrorAction SilentlyContinue
Log "=== OpenClaw setup complete ==="
'@

$phase2Path = "C:\openclaw-post-reboot.ps1"
Set-Content -Path $phase2Path -Value $phase2Script -Encoding UTF8

# 5. Register scheduled task to run Phase 2 after reboot
Write-Host ">>> Registering post-reboot setup task..."
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File $phase2Path"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "OpenClawSetup" `
    -Action $action -Trigger $trigger -Principal $principal -Force

# 6. Schedule reboot to complete WSL2 installation
Write-Host ">>> Phase 1 complete. The VM will reboot in 30 seconds to finalize WSL2."
Write-Host ">>> After reboot, Node.js and OpenClaw will be installed automatically."
Write-Host ">>> Check C:\openclaw-setup.log for Phase 2 progress."
shutdown /r /t 30 /c "Rebooting to complete WSL2 and OpenClaw installation..."
