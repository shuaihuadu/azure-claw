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

# Ensure openclaw directory exists
$openclawDir = "C:\openclaw"
New-Item -ItemType Directory -Path $openclawDir -Force | Out-Null

# Phase 1 logging
$logFile = "$openclawDir\phase1.log"
function Log { param($msg) $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"; Add-Content $logFile $line; Write-Host $line }

# OpenClaw installer for Windows 11 (via WSL2)
# Phase 1: Enable WSL2, optionally install Caddy, register post-reboot setup task, reboot
# Phase 2: After reboot, the scheduled task installs Node.js + OpenClaw in WSL

Log "=== OpenClaw installer for Windows 11 (Phase 1) ==="
Log "Public HTTPS: $EnablePublicHttps"

# 1. Install WSL2 with Ubuntu (handles feature enablement automatically on Win11)
# Idempotent: wsl --install is safe to re-run; --no-launch prevents interactive prompt
Log ">>> Installing WSL2 with Ubuntu..."
wsl --install --distribution Ubuntu --no-launch

# 2. Configure Windows Firewall (idempotent: remove then re-add to avoid duplicate rules)
Log ">>> Configuring Windows Firewall..."
Remove-NetFirewallRule -DisplayName "OpenClaw Gateway" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "OpenClaw Gateway" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 18789 `
    -Action Allow `
    -Profile Any

if ($EnablePublicHttps) {
    Remove-NetFirewallRule -DisplayName "HTTPS (Caddy)" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "HTTPS (Caddy)" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 443 `
        -Action Allow `
        -Profile Any

    # Download Caddy binary
    Log ">>> Downloading Caddy..."
    $caddyDir = "C:\caddy"
    New-Item -ItemType Directory -Path $caddyDir -Force | Out-Null
    Invoke-WebRequest -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile "$caddyDir\caddy.exe" -UseBasicParsing

    # Write Caddyfile
    Log ">>> Writing Caddyfile..."
    Set-Content -Path "$caddyDir\Caddyfile" -Value @"
$Fqdn {
    reverse_proxy 127.0.0.1:18789
}
"@ -Encoding UTF8
}

# 3. Write config for Phase 2 to read
Log ">>> Writing Phase 2 config..."
$configContent = @"
EnablePublicHttps=$($EnablePublicHttps.ToString())
GatewayPassword=$GatewayPassword
Fqdn=$Fqdn
"@
Set-Content -Path "$openclawDir\config.txt" -Value $configContent -Encoding UTF8

# 4. Create post-reboot setup script (Phase 2)
Log ">>> Creating post-reboot setup script..."

$phase2Script = @'
$ErrorActionPreference = 'Stop'
$logFile = "C:\openclaw\phase2.log"

function Log { param($msg) Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" }

# Idempotency: skip if Phase 2 already completed successfully
if (Test-Path "C:\openclaw\phase2.done") {
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Phase 2 already completed. Skipping."
    Unregister-ScheduledTask -TaskName "OpenClawSetup" -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}

Log "=== OpenClaw post-reboot setup (Phase 2) started ==="

# Read config from Phase 1
$config = @{}
Get-Content "C:\openclaw\config.txt" | ForEach-Object {
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

# Initialize Ubuntu distro with a default user (avoids root-only default)
Log "Initializing Ubuntu distro..."
$wslUser = "openclaw"
wsl -d Ubuntu -- bash -c "id -u $wslUser 2>/dev/null || (useradd -m -s /bin/bash $wslUser && echo '${wslUser} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$wslUser)"
# Set as default user for this distro
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
Get-ChildItem $regPath -ErrorAction SilentlyContinue | ForEach-Object {
    $distroName = (Get-ItemProperty $_.PSPath).DistributionName
    if ($distroName -eq "Ubuntu") {
        $uid = wsl -d Ubuntu -- bash -c "id -u $wslUser"
        Set-ItemProperty -Path $_.PSPath -Name DefaultUid -Value ([int]$uid)
    }
}
wsl -d Ubuntu -u $wslUser -- bash -c "echo 'Ubuntu ready as $wslUser'"
Log "Ubuntu distro initialized with user: $wslUser"

# Install Node.js 24 (idempotent: NodeSource setup + apt install is safe to re-run)
Log "Installing Node.js 24..."
wsl -d Ubuntu -u $wslUser -- bash -c "curl -fsSL https://deb.nodesource.com/setup_24.x | sudo bash - && sudo apt-get install -y nodejs"
Log "Node.js installed: $(wsl -d Ubuntu -u $wslUser -- node --version)"

# Install OpenClaw (idempotent: npm install -g overwrites existing)
Log "Installing OpenClaw..."
wsl -d Ubuntu -u $wslUser -- bash -c "sudo npm install -g openclaw@latest"
Log "OpenClaw installed"

# Create config (idempotent: always overwrite with correct config)
Log "Creating OpenClaw configuration..."
if ($enableHttps -and $fqdn) {
    $configJson = @"
{
  ""agents"": {
    ""defaults"": {
      ""model"": {
        ""primary"": ""anthropic/claude-opus-4-6""
      }
    }
  },
  ""gateway"": {
    ""mode"": ""local"",
    ""trustedProxies"": [""127.0.0.1/32"", ""::1/128""],
    ""controlUi"": {
      ""allowedOrigins"": [""https://$fqdn""]
    }
  }
}
"@
} else {
    $configJson = @"
{
  ""agents"": {
    ""defaults"": {
      ""model"": {
        ""primary"": ""anthropic/claude-opus-4-6""
      }
    }
  },
  ""gateway"": {
    ""mode"": ""local""
  }
}
"@
}
wsl -d Ubuntu -u $wslUser -- bash -c "mkdir -p ~/.openclaw && cat > ~/.openclaw/openclaw.json << 'HEREDOC'
$configJson
HEREDOC"

# Create systemd service in WSL
Log "Configuring systemd service..."
$bindMode = if ($enableHttps) { "loopback" } else { "lan" }
$execCmd = "/usr/local/bin/openclaw gateway run --port 18789 --bind $bindMode --auth password"
if ($gwPassword) { $execCmd += " --password `$OPENCLAW_GATEWAY_PASSWORD" }
$envLine = if ($gwPassword) { "Environment=OPENCLAW_GATEWAY_PASSWORD=$gwPassword" } else { "" }
$unit = @"
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$wslUser
ExecStart=$execCmd
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
$envLine

[Install]
WantedBy=multi-user.target
"@
$unit | wsl -d Ubuntu -u root -- bash -c "tee /etc/systemd/system/openclaw.service > /dev/null"
wsl -d Ubuntu -u root -- bash -c "systemctl daemon-reload && systemctl enable openclaw.service && systemctl start openclaw.service"
Log "OpenClaw service started"

# Create a port-proxy refresh script (handles WSL IP changes across reboots)
Log "Creating port proxy refresh script..."
$listenAddr = if ($enableHttps) { "127.0.0.1" } else { "0.0.0.0" }
$portProxyScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
# Wait for WSL to be ready
for (`$i = 0; `$i -lt 20; `$i++) {
    `$status = wsl --status 2>&1
    if (`$LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 5
}
# Ensure Ubuntu distro is running
wsl -d Ubuntu -u $wslUser -- bash -c "echo ready" 2>&1 | Out-Null
# Get current WSL IP and refresh port proxy
`$wslIp = wsl -d Ubuntu -u $wslUser -- bash -c "hostname -I" | ForEach-Object { `$_.Trim().Split(' ')[0] }
if (`$wslIp) {
    netsh interface portproxy delete v4tov4 listenport=18789 listenaddress=$listenAddr 2>&1 | Out-Null
    netsh interface portproxy add v4tov4 listenport=18789 listenaddress=$listenAddr connectport=18789 connectaddress=`$wslIp
}
"@
Set-Content -Path "C:\openclaw\refresh-portproxy.ps1" -Value $portProxyScript -Encoding UTF8

# Run port proxy now
$wslIp = wsl -d Ubuntu -u $wslUser -- bash -c "hostname -I" | ForEach-Object { $_.Trim().Split(' ')[0] }
if ($wslIp) {
    netsh interface portproxy delete v4tov4 listenport=18789 listenaddress=$listenAddr 2>&1 | Out-Null
    netsh interface portproxy add v4tov4 listenport=18789 listenaddress=$listenAddr connectport=18789 connectaddress=$wslIp
    Log "Port proxy: ${listenAddr}:18789 -> WSL(${wslIp}):18789"
}

# Register scheduled task to refresh port proxy on every startup (WSL IP may change)
$ppAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\openclaw\refresh-portproxy.ps1"
$ppTrigger = New-ScheduledTaskTrigger -AtStartup
$ppPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "OpenClawPortProxy" -Action $ppAction -Trigger $ppTrigger -Principal $ppPrincipal -Force
Log "Port proxy refresh task registered for startup"

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

# Mark Phase 2 as complete (idempotency sentinel)
Set-Content -Path "C:\openclaw\phase2.done" -Value "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" -Encoding UTF8

# Clean up
Remove-Item "C:\openclaw\config.txt" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "OpenClawSetup" -Confirm:$false -ErrorAction SilentlyContinue
Log "=== OpenClaw setup complete ==="
'@

$phase2Path = "$openclawDir\post-reboot.ps1"
Set-Content -Path $phase2Path -Value $phase2Script -Encoding UTF8

# 5. Register scheduled task to run Phase 2 after reboot
Log ">>> Registering post-reboot setup task..."
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File $phase2Path"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "OpenClawSetup" `
    -Action $action -Trigger $trigger -Principal $principal -Force

# 6. Schedule reboot to complete WSL2 installation
Log ">>> Phase 1 complete. The VM will reboot in 30 seconds to finalize WSL2."
Log ">>> After reboot, Node.js and OpenClaw will be installed automatically."
Log ">>> Check C:\openclaw\phase2.log for Phase 2 progress."
shutdown /r /t 30 /c "Rebooting to complete WSL2 and OpenClaw installation..."
