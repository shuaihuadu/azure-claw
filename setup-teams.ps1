<#
.SYNOPSIS
    Semi-automated setup for Microsoft Teams channel on an existing OpenClaw deployment.
    Creates Azure Bot, App Registration, configures VM, and generates Teams App package.

.DESCRIPTION
    This script automates most of the Teams integration process:
    1. Creates App Registration + Client Secret
    2. Creates Azure Bot (F0 free tier)
    3. Configures messaging endpoint
    4. Enables Teams channel on the Bot
    5. Remotely installs @openclaw/msteams plugin on the VM
    6. Updates Caddy config (HTTPS mode) or opens port 3978 (non-HTTPS)
    7. Injects Teams credentials into OpenClaw config
    8. Restarts OpenClaw service
    9. Generates Teams App manifest package (ZIP)

    After running, you only need to manually upload the ZIP to Teams.

.PARAMETER ResourceGroup
    Resource group name. Default: rg-openclaw

.PARAMETER BotName
    Azure Bot display name. Default: openclaw-msteams

.EXAMPLE
    .\setup-teams.ps1
    # Auto-detect deployment from rg-openclaw

.EXAMPLE
    .\setup-teams.ps1 -ResourceGroup rg-openclaw -BotName my-openclaw-bot
#>

param(
    [string]$ResourceGroup = 'rg-openclaw',
    [string]$BotName = 'openclaw-msteams'
)

$ErrorActionPreference = 'Stop'
$StartTime = Get-Date

# ============================================================
# Logging
# ============================================================
$timestamp = $StartTime.ToString('yyyyMMddHHmmss')
$logDir = Join-Path $PSScriptRoot 'logs' "teams-$timestamp"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$transcriptPath = Join-Path $logDir 'setup-teams.log'
Start-Transcript -Path $transcriptPath -Append | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts] [$Level] $Message"
}

# ============================================================
# Step 0: Check Azure CLI login
# ============================================================
Write-Host ""
Write-Host "=========================================="
Write-Host "  OpenClaw Teams Channel Setup"
Write-Host "=========================================="
Write-Host ""

Write-Log 'Checking Azure CLI login status...' 'STEP'
az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Log 'Not logged in. Running az login...' 'INFO'
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure CLI login failed."
    }
}
$accountInfo = az account show --output json | ConvertFrom-Json
Write-Log "Logged in as: $($accountInfo.user.name) (Subscription: $($accountInfo.name))" 'INFO'
$tenantId = $accountInfo.tenantId

# ============================================================
# Step 1: Detect existing deployment
# ============================================================
Write-Log "Detecting existing deployment in '$ResourceGroup'..." 'STEP'

$rgExists = az group exists --name $ResourceGroup 2>&1
if ($rgExists -ne 'true') {
    Write-Error "Resource group '$ResourceGroup' does not exist. Please run deploy.ps1 first."
}

# Get VM info
$vms = az vm list --resource-group $ResourceGroup --output json | ConvertFrom-Json
if ($vms.Count -eq 0) {
    Write-Error "No VM found in resource group '$ResourceGroup'. Please run deploy.ps1 first."
}
$vm = $vms[0]
$vmName = $vm.name
$vmOsType = if ($vm.storageProfile.osDisk.osType -eq 'Linux') { 'Ubuntu' } else { 'Windows' }
Write-Log "Found VM: $vmName (OS: $vmOsType)" 'INFO'

# Get public IP and FQDN
$publicIps = az network public-ip list --resource-group $ResourceGroup --output json | ConvertFrom-Json
if ($publicIps.Count -eq 0) {
    Write-Error "No public IP found. The VM must have a public IP."
}
$publicIp = $publicIps[0]
$vmIpAddress = $publicIp.ipAddress
$vmFqdn = $publicIp.dnsSettings.fqdn
Write-Log "Public IP: $vmIpAddress" 'INFO'
Write-Log "FQDN: $vmFqdn" 'INFO'

# Detect HTTPS mode by checking NSG rules for port 443
$nsgs = az network nsg list --resource-group $ResourceGroup --output json | ConvertFrom-Json
$enablePublicHttps = $false
foreach ($nsg in $nsgs) {
    foreach ($rule in $nsg.securityRules) {
        if ($rule.destinationPortRange -eq '443' -and $rule.access -eq 'Allow') {
            $enablePublicHttps = $true
            break
        }
    }
}
Write-Log "HTTPS mode: $enablePublicHttps" 'INFO'

if (-not $enablePublicHttps) {
    Write-Host ""
    Write-Host "  WARNING: Teams Bot requires HTTPS. Your deployment does not have -EnablePublicHttps." -ForegroundColor Yellow
    Write-Host "  The script will open port 3978 directly, but you will need to configure HTTPS" -ForegroundColor Yellow
    Write-Host "  separately (e.g., via ngrok or Tailscale Funnel) for Teams to reach the endpoint." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Recommended: Re-deploy with -EnablePublicHttps for fully automated HTTPS setup." -ForegroundColor Yellow
    Write-Host ""
    $proceed = Read-Host "Continue anyway? (y/N) [N]"
    if ($proceed -ne 'y' -and $proceed -ne 'Y') {
        Write-Host "[INFO] Cancelled. Re-deploy with: .\deploy.ps1 -EnablePublicHttps"
        Stop-Transcript | Out-Null
        exit 0
    }
}

# Build messaging endpoint URL
if ($enablePublicHttps) {
    $messagingEndpoint = "https://${vmFqdn}/api/messages"
}
else {
    $messagingEndpoint = "https://${vmFqdn}:3978/api/messages"
}
Write-Log "Messaging endpoint: $messagingEndpoint" 'INFO'

# ============================================================
# Step 2: Summary and confirm
# ============================================================
Write-Host ""
Write-Host "=========================================="
Write-Host "  Setup Summary"
Write-Host "=========================================="
Write-Host "  Resource Group : $ResourceGroup"
Write-Host "  VM Name        : $vmName ($vmOsType)"
Write-Host "  Public IP      : $vmIpAddress"
Write-Host "  FQDN           : $vmFqdn"
Write-Host "  HTTPS Mode     : $enablePublicHttps"
Write-Host "  Bot Name       : $BotName"
Write-Host "  Tenant ID      : $tenantId"
Write-Host "  Endpoint       : $messagingEndpoint"
Write-Host "=========================================="
Write-Host ""
$confirm = Read-Host "Proceed? (Y/n) [Y]"
if ($confirm -eq 'n' -or $confirm -eq 'N') {
    Write-Host "[INFO] Cancelled."
    Stop-Transcript | Out-Null
    exit 0
}

# ============================================================
# Step 3: Create App Registration
# ============================================================
Write-Log 'Creating App Registration...' 'STEP'

# Pause transcript to prevent secrets from leaking
Stop-Transcript | Out-Null

$appDisplayName = $BotName
$appResult = az ad app create `
    --display-name $appDisplayName `
    --sign-in-audience "AzureADMyOrg" `
    --output json | ConvertFrom-Json

$appId = $appResult.appId
$appObjectId = $appResult.id

# Resume transcript
Start-Transcript -Path $transcriptPath -Append | Out-Null
Write-Log "App Registration created. App ID: $appId" 'INFO'

# Create Client Secret (pause transcript again for secret value)
Write-Log 'Creating Client Secret...' 'STEP'
Stop-Transcript | Out-Null

$secretResult = az ad app credential reset `
    --id $appObjectId `
    --display-name "openclaw-teams-secret" `
    --years 2 `
    --output json | ConvertFrom-Json

$appPassword = $secretResult.password

Start-Transcript -Path $transcriptPath -Append | Out-Null
Write-Log 'Client Secret created.' 'INFO'

# ============================================================
# Step 4: Create Azure Bot
# ============================================================
Write-Log 'Creating Azure Bot resource...' 'STEP'

# Create the Bot using REST API since az bot create may not support all options
az bot create `
    --resource-group $ResourceGroup `
    --name $BotName `
    --kind registration `
    --sku F0 `
    --appid $appId `
    --app-type SingleTenant `
    --tenant-id $tenantId `
    --endpoint $messagingEndpoint `
    --output none 2>&1

if ($LASTEXITCODE -ne 0) {
    # Bot may already exist — try update instead
    Write-Log 'Bot may already exist. Updating endpoint...' 'WARN'
    az bot update `
        --resource-group $ResourceGroup `
        --name $BotName `
        --endpoint $messagingEndpoint `
        --output none
}

Write-Log "Azure Bot '$BotName' ready." 'INFO'

# ============================================================
# Step 5: Enable Teams channel
# ============================================================
Write-Log 'Enabling Microsoft Teams channel on Bot...' 'STEP'

az bot msteams create `
    --resource-group $ResourceGroup `
    --name $BotName `
    --output none 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Log 'Teams channel may already be enabled. Continuing...' 'WARN'
}

Write-Log 'Teams channel enabled.' 'INFO'

# ============================================================
# Step 6: Configure VM (remote commands)
# ============================================================
Write-Log 'Configuring VM remotely...' 'STEP'

if ($vmOsType -eq 'Ubuntu') {
    # --- Ubuntu: single az vm run-command ---
    Write-Log 'Installing Teams plugin and updating config on Ubuntu VM...' 'STEP'

    # Build the remote bash script
    $remoteScript = @"
#!/bin/bash
set -euo pipefail

ADMIN_USER=`$(ls /home/ | head -1)
ADMIN_HOME="/home/`${ADMIN_USER}"
OPENCLAW_CONFIG="`${ADMIN_HOME}/.openclaw/openclaw.json"

echo ">>> Installing @openclaw/msteams plugin..."
sudo -u `${ADMIN_USER} openclaw plugins install @openclaw/msteams || npm install -g @openclaw/msteams

echo ">>> Updating OpenClaw config with Teams channel..."
# Use node to safely merge JSON config (avoid jq dependency)
node -e "
const fs = require('fs');
const cfgPath = '`${OPENCLAW_CONFIG}';
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
if (!cfg.channels) cfg.channels = {};
cfg.channels.msteams = {
  enabled: true,
  appId: '${appId}',
  appPassword: '${appPassword}',
  tenantId: '${tenantId}',
  webhook: { port: 3978, path: '/api/messages' }
};
fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
console.log('Config updated:', JSON.stringify(cfg.channels.msteams.appId));
"

chown -R `${ADMIN_USER}:`${ADMIN_USER} "`${ADMIN_HOME}/.openclaw"
"@

    # Add Caddy update if HTTPS mode
    if ($enablePublicHttps) {
        $remoteScript += @"

echo ">>> Updating Caddy config for Teams webhook..."
CADDY_FILE="/etc/caddy/Caddyfile"
if [ -f "`${CADDY_FILE}" ]; then
    # Check if /api/messages route already exists
    if ! grep -q "/api/messages" "`${CADDY_FILE}"; then
        # Insert Teams reverse_proxy rule before the Gateway reverse_proxy line
        sed -i '/reverse_proxy 127.0.0.1:18789/i\    reverse_proxy /api/messages 127.0.0.1:3978' "`${CADDY_FILE}"
        echo "Caddy config updated with Teams webhook route."
    else
        echo "Teams webhook route already in Caddy config."
    fi
    systemctl reload caddy
    echo "Caddy reloaded."
fi
"@
    }

    $remoteScript += @"

echo ">>> Restarting OpenClaw service..."
systemctl restart openclaw
echo ">>> Done. Teams channel configured on Ubuntu VM."
"@

    # Execute on VM
    az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $vmName `
        --command-id RunShellScript `
        --scripts $remoteScript `
        --output json | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Log 'VM remote command failed. You may need to configure manually.' 'ERROR'
        Write-Host "  See docs/guide-teams.md sections 2, 5, 9 for manual steps." -ForegroundColor Yellow
    }
    else {
        Write-Log 'Ubuntu VM configured successfully.' 'INFO'
    }
}
else {
    # --- Windows: az vm run-command via PowerShell ---
    Write-Log 'Installing Teams plugin and updating config on Windows VM...' 'STEP'

    $remoteScript = @"
`$ErrorActionPreference = 'Stop'
`$wslUser = 'openclaw'
`$openclawConfig = "/home/`${wslUser}/.openclaw/openclaw.json"

Write-Host ">>> Installing @openclaw/msteams plugin..."
wsl -d Ubuntu -u `$wslUser -- bash -c "openclaw plugins install @openclaw/msteams || sudo npm install -g @openclaw/msteams"

Write-Host ">>> Updating OpenClaw config with Teams channel..."
`$nodeScript = @'
const fs = require("fs");
const cfgPath = "/home/WSLUSER/.openclaw/openclaw.json";
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
if (!cfg.channels) cfg.channels = {};
cfg.channels.msteams = {
  enabled: true,
  appId: "APPID_PLACEHOLDER",
  appPassword: "APPPW_PLACEHOLDER",
  tenantId: "TENANT_PLACEHOLDER",
  webhook: { port: 3978, path: "/api/messages" }
};
fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
console.log("Config updated:", cfg.channels.msteams.appId);
'@
`$nodeScript = `$nodeScript -replace 'WSLUSER', `$wslUser
`$nodeScript = `$nodeScript -replace 'APPID_PLACEHOLDER', '${appId}'
`$nodeScript = `$nodeScript -replace 'APPPW_PLACEHOLDER', '${appPassword}'
`$nodeScript = `$nodeScript -replace 'TENANT_PLACEHOLDER', '${tenantId}'
`$nodeScript | wsl -d Ubuntu -u `$wslUser -- bash -c "cat | node -e \"`$(cat)\""

Write-Host ">>> Restarting OpenClaw service in WSL..."
wsl -d Ubuntu -u root -- bash -c "systemctl restart openclaw"

# Port proxy for Teams webhook port 3978 (WSL → Windows host)
Write-Host ">>> Setting up port proxy for Teams webhook (3978)..."
`$wslIp = wsl -d Ubuntu -u `$wslUser -- bash -c "hostname -I" | ForEach-Object { `$_.Trim().Split(' ')[0] }
if (`$wslIp) {
    netsh interface portproxy delete v4tov4 listenport=3978 listenaddress=127.0.0.1 2>&1 | Out-Null
    netsh interface portproxy add v4tov4 listenport=3978 listenaddress=127.0.0.1 connectport=3978 connectaddress=`$wslIp
    Write-Host "Port proxy: 127.0.0.1:3978 -> WSL(`${wslIp}):3978"
}
"@

    # Add Caddy update if HTTPS mode on Windows
    if ($enablePublicHttps) {
        $remoteScript += @"

Write-Host ">>> Updating Caddy config for Teams webhook..."
`$caddyFile = "C:\caddy\Caddyfile"
if (Test-Path `$caddyFile) {
    `$content = Get-Content `$caddyFile -Raw
    if (`$content -notmatch '/api/messages') {
        `$content = `$content -replace '(reverse_proxy 127\.0\.0\.1:18789)', "reverse_proxy /api/messages 127.0.0.1:3978`n    `$1"
        Set-Content -Path `$caddyFile -Value `$content -Encoding UTF8
        Write-Host "Caddy config updated."
    } else {
        Write-Host "Teams route already in Caddy config."
    }
    # Restart Caddy task
    Stop-ScheduledTask -TaskName "CaddyServer" -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName "CaddyServer"
    Write-Host "Caddy restarted."
}
"@
    }

    $remoteScript += @"

# Update port proxy refresh script to include port 3978
Write-Host ">>> Updating port proxy refresh script..."
`$ppScript = Get-Content "C:\openclaw\refresh-portproxy.ps1" -Raw -ErrorAction SilentlyContinue
if (`$ppScript -and `$ppScript -notmatch 'listenport=3978') {
    `$ppScript += @'

# Teams webhook port proxy
netsh interface portproxy delete v4tov4 listenport=3978 listenaddress=127.0.0.1 2>&1 | Out-Null
if (`$wslIp) {
    netsh interface portproxy add v4tov4 listenport=3978 listenaddress=127.0.0.1 connectport=3978 connectaddress=`$wslIp
}
'@
    Set-Content -Path "C:\openclaw\refresh-portproxy.ps1" -Value `$ppScript -Encoding UTF8
    Write-Host "Port proxy refresh script updated."
}

Write-Host ">>> Done. Teams channel configured on Windows VM."
"@

    az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $vmName `
        --command-id RunPowerShellScript `
        --scripts $remoteScript `
        --output json | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Log 'VM remote command failed. You may need to configure manually.' 'ERROR'
        Write-Host "  See docs/guide-teams.md sections 2, 5, 9 for manual steps." -ForegroundColor Yellow
    }
    else {
        Write-Log 'Windows VM configured successfully.' 'INFO'
    }
}

# ============================================================
# Step 7: Generate Teams App package
# ============================================================
Write-Log 'Generating Teams App manifest package...' 'STEP'

$appPackageDir = Join-Path $logDir 'teams-app'
New-Item -ItemType Directory -Path $appPackageDir -Force | Out-Null

# Generate manifest.json
$manifest = @{
    '$schema'          = 'https://developer.microsoft.com/en-us/json-schemas/teams/v1.23/MicrosoftTeams.schema.json'
    manifestVersion    = '1.23'
    version            = '1.0.0'
    id                 = $appId
    name               = @{ short = 'OpenClaw' }
    developer          = @{
        name          = 'Azure Claw'
        websiteUrl    = 'https://openclaw.ai'
        privacyUrl    = 'https://openclaw.ai/privacy'
        termsOfUseUrl = 'https://openclaw.ai/terms'
    }
    description        = @{
        short = 'OpenClaw AI Assistant'
        full  = 'Chat with your OpenClaw AI assistant directly in Microsoft Teams.'
    }
    icons              = @{
        outline = 'outline.png'
        color   = 'color.png'
    }
    accentColor        = '#5B6DEF'
    bots               = @(
        @{
            botId              = $appId
            scopes             = @('personal', 'team', 'groupChat')
            isNotificationOnly = $false
            supportsCalling    = $false
            supportsVideo      = $false
            supportsFiles      = $true
        }
    )
    webApplicationInfo = @{ id = $appId }
    authorization      = @{
        permissions = @{
            resourceSpecific = @(
                @{ name = 'ChannelMessage.Read.Group'; type = 'Application' }
                @{ name = 'ChannelMessage.Send.Group'; type = 'Application' }
                @{ name = 'Member.Read.Group'; type = 'Application' }
                @{ name = 'Owner.Read.Group'; type = 'Application' }
                @{ name = 'ChannelSettings.Read.Group'; type = 'Application' }
                @{ name = 'TeamMember.Read.Group'; type = 'Application' }
                @{ name = 'TeamSettings.Read.Group'; type = 'Application' }
                @{ name = 'ChatMessage.Read.Chat'; type = 'Application' }
            )
        }
    }
}

$manifestJson = $manifest | ConvertTo-Json -Depth 10
Set-Content -Path (Join-Path $appPackageDir 'manifest.json') -Value $manifestJson -Encoding UTF8
Write-Log 'manifest.json generated.' 'INFO'

# Generate placeholder icons (minimal valid PNG files)
# These are the smallest valid PNG files - a single pixel
# color.png: 192x192 blue pixel PNG (minimal valid PNG header)
# outline.png: 32x32 white pixel PNG (minimal valid PNG header)

function New-MinimalPng {
    param([string]$Path, [int]$Width, [int]$Height, [byte]$R, [byte]$G, [byte]$B)

    # Build a minimal valid PNG with a single-color image
    $ms = New-Object System.IO.MemoryStream

    # PNG signature
    $signature = [byte[]]@(137, 80, 78, 71, 13, 10, 26, 10)
    $ms.Write($signature, 0, 8)

    # Helper: write a PNG chunk
    function Write-PngChunk {
        param([System.IO.MemoryStream]$Stream, [string]$Type, [byte[]]$Data)
        $lenBytes = [System.BitConverter]::GetBytes([uint32]$Data.Length)
        [Array]::Reverse($lenBytes)
        $Stream.Write($lenBytes, 0, 4)

        $typeBytes = [System.Text.Encoding]::ASCII.GetBytes($Type)
        $Stream.Write($typeBytes, 0, 4)

        if ($Data.Length -gt 0) {
            $Stream.Write($Data, 0, $Data.Length)
        }

        # CRC32 over type + data
        $crcData = New-Object byte[] ($typeBytes.Length + $Data.Length)
        [Array]::Copy($typeBytes, 0, $crcData, 0, $typeBytes.Length)
        if ($Data.Length -gt 0) {
            [Array]::Copy($Data, 0, $crcData, $typeBytes.Length, $Data.Length)
        }
        $crc = Get-Crc32 $crcData
        $crcBytes = [System.BitConverter]::GetBytes([uint32]$crc)
        [Array]::Reverse($crcBytes)
        $Stream.Write($crcBytes, 0, 4)
    }

    # CRC32 lookup table
    function Get-Crc32 {
        param([byte[]]$Data)
        $table = New-Object uint32[] 256
        for ($i = 0; $i -lt 256; $i++) {
            [uint32]$c = $i
            for ($j = 0; $j -lt 8; $j++) {
                if ($c -band 1) { $c = 0xEDB88320 -bxor ($c -shr 1) }
                else { $c = $c -shr 1 }
            }
            $table[$i] = $c
        }
        [uint32]$crc = 0xFFFFFFFF
        foreach ($b in $Data) {
            $crc = $table[($crc -bxor $b) -band 0xFF] -bxor ($crc -shr 8)
        }
        return $crc -bxor 0xFFFFFFFF
    }

    # IHDR chunk (13 bytes data)
    $ihdr = New-Object byte[] 13
    $wBytes = [System.BitConverter]::GetBytes([uint32]$Width); [Array]::Reverse($wBytes)
    $hBytes = [System.BitConverter]::GetBytes([uint32]$Height); [Array]::Reverse($hBytes)
    [Array]::Copy($wBytes, 0, $ihdr, 0, 4)
    [Array]::Copy($hBytes, 0, $ihdr, 4, 4)
    $ihdr[8] = 8   # bit depth
    $ihdr[9] = 2   # color type (RGB)
    $ihdr[10] = 0  # compression
    $ihdr[11] = 0  # filter
    $ihdr[12] = 0  # interlace
    Write-PngChunk $ms 'IHDR' $ihdr

    # IDAT chunk — build raw image data, then DEFLATE compress
    # Each row: filter byte (0) + RGB pixels
    $rowSize = 1 + ($Width * 3)
    $rawData = New-Object byte[] ($rowSize * $Height)
    for ($y = 0; $y -lt $Height; $y++) {
        $offset = $y * $rowSize
        $rawData[$offset] = 0  # no filter
        for ($x = 0; $x -lt $Width; $x++) {
            $px = $offset + 1 + ($x * 3)
            $rawData[$px] = $R
            $rawData[$px + 1] = $G
            $rawData[$px + 2] = $B
        }
    }

    # Compress using DeflateStream
    $compMs = New-Object System.IO.MemoryStream
    # zlib header: CMF=0x78, FLG=0x01
    $compMs.WriteByte(0x78)
    $compMs.WriteByte(0x01)
    $deflate = New-Object System.IO.Compression.DeflateStream($compMs, [System.IO.Compression.CompressionMode]::Compress, $true)
    $deflate.Write($rawData, 0, $rawData.Length)
    $deflate.Close()

    # Adler-32 checksum
    [uint32]$a = 1; [uint32]$b2 = 0
    foreach ($byte in $rawData) {
        $a = ($a + $byte) % 65521
        $b2 = ($b2 + $a) % 65521
    }
    $adler = ($b2 -shl 16) -bor $a
    $adlerBytes = [System.BitConverter]::GetBytes([uint32]$adler)
    [Array]::Reverse($adlerBytes)
    $compMs.Write($adlerBytes, 0, 4)

    $idatData = $compMs.ToArray()
    $compMs.Dispose()
    Write-PngChunk $ms 'IDAT' $idatData

    # IEND chunk
    Write-PngChunk $ms 'IEND' ([byte[]]@())

    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $ms.Dispose()
}

# color.png: 192x192 blue (#5B6DEF)
New-MinimalPng -Path (Join-Path $appPackageDir 'color.png') -Width 192 -Height 192 -R 0x5B -G 0x6D -B 0xEF
Write-Log 'color.png generated (192x192).' 'INFO'

# outline.png: 32x32 white
New-MinimalPng -Path (Join-Path $appPackageDir 'outline.png') -Width 32 -Height 32 -R 0xFF -G 0xFF -B 0xFF
Write-Log 'outline.png generated (32x32).' 'INFO'

# Create ZIP package
$zipPath = Join-Path $logDir 'openclaw-teams-app.zip'

# Remove existing zip if present
if (Test-Path $zipPath) { Remove-Item $zipPath }

# Use Compress-Archive
Compress-Archive -Path (Join-Path $appPackageDir '*') -DestinationPath $zipPath
Write-Log "Teams App package: $zipPath" 'INFO'

# ============================================================
# Step 8: Write credentials to .env
# ============================================================
Write-Log 'Writing credentials...' 'STEP'

# Pause transcript for secrets
Stop-Transcript | Out-Null

$envContent = @"
# Teams Channel Setup - $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
TEAMS_APP_ID=$appId
TEAMS_APP_PASSWORD=$appPassword
TEAMS_TENANT_ID=$tenantId
TEAMS_BOT_NAME=$BotName
MESSAGING_ENDPOINT=$messagingEndpoint
VM_NAME=$vmName
VM_OS_TYPE=$vmOsType
VM_PUBLIC_IP=$vmIpAddress
FQDN=$vmFqdn
RESOURCE_GROUP=$ResourceGroup
SETUP_TIME=$($StartTime.ToString('yyyy-MM-ddTHH:mm:ss'))
"@
Set-Content -Path (Join-Path $logDir '.env') -Value $envContent -Encoding UTF8

Start-Transcript -Path $transcriptPath -Append | Out-Null
Write-Log 'Credentials saved to .env' 'INFO'

# ============================================================
# Step 9: Console summary
# ============================================================
$elapsed = (Get-Date) - $StartTime

Write-Host ""
Write-Host "=========================================="
Write-Host "  Teams Setup Complete!"
Write-Host "=========================================="
Write-Host "  Bot Name       : $BotName"
Write-Host "  App ID         : $appId"
Write-Host "  Tenant ID      : $tenantId"
Write-Host "  Endpoint       : $messagingEndpoint"
Write-Host "  VM             : $vmName ($vmOsType)"
Write-Host "  Elapsed        : $([math]::Round($elapsed.TotalSeconds))s"
Write-Host "=========================================="
Write-Host ""
Write-Host "  Output directory: $logDir"
Write-Host "  - setup-teams.log         : Setup transcript"
Write-Host "  - .env                    : Credentials (App ID, Secret, Tenant ID)"
Write-Host "  - openclaw-teams-app.zip  : Teams App manifest package"
Write-Host ""
Write-Host "=========================================="
Write-Host "  Remaining Manual Steps"
Write-Host "=========================================="
Write-Host ""
Write-Host "  1. Upload the Teams App package to your organization:" -ForegroundColor Cyan
Write-Host "     $zipPath" -ForegroundColor White
Write-Host ""
Write-Host "     Option A: Teams Client" -ForegroundColor Gray
Write-Host "       Apps -> Manage your apps -> Upload an app -> Upload a custom app" -ForegroundColor Gray
Write-Host ""
Write-Host "     Option B: Teams Admin Center (https://admin.teams.microsoft.com/)" -ForegroundColor Gray
Write-Host "       Teams apps -> Manage apps -> Upload new app" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. In Teams, search for 'OpenClaw' and add it to a team or start a DM." -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. (Optional) Test via Azure Portal first:" -ForegroundColor Cyan
Write-Host "     Azure Bot '$BotName' -> Test in Web Chat" -ForegroundColor Gray
Write-Host ""
Write-Host "  Full guide: docs/guide-teams.md" -ForegroundColor Gray
Write-Host ""

Stop-Transcript | Out-Null
