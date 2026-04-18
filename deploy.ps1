<#
.SYNOPSIS
    Deploy OpenClaw to Azure VM (Ubuntu 24.04 LTS or Windows 11).
    Run without parameters for interactive guided setup.

.PARAMETER Location
    Azure region. Default: eastasia

.PARAMETER VmSize
    VM size SKU. Default: Standard_D4s_v5

.PARAMETER OsType
    Operating system: Ubuntu or Windows. Default: Ubuntu

.PARAMETER AdminUsername
    VM admin username. Default: azureclaw

.PARAMETER AdminPassword
    VM admin password. Auto-generated if not provided.

.PARAMETER ResourceGroup
    Resource group name. Default: rg-openclaw

.PARAMETER EnablePublicHttps
    Enable public HTTPS access via Caddy + Let's Encrypt. Default: on.
    Pass -EnablePublicHttps:$false to disable.

.EXAMPLE
    .\deploy.ps1
    # Interactive guided setup

.EXAMPLE
    .\deploy.ps1 -Location eastasia -OsType Ubuntu
    # Non-interactive with explicit parameters
#>

param(
    [string]$Location = '',
    [string]$VmSize = '',
    [ValidateSet('Ubuntu', 'Windows', '')]
    [string]$OsType = '',
    [string]$AdminUsername = '',
    [string]$AdminPassword = '',
    [string]$ResourceGroup = '',
    [switch]$EnablePublicHttps
)

$ErrorActionPreference = 'Stop'

# Load shared functions (interactive helpers)
. "$PSScriptRoot/scripts/shared-functions.ps1"

$TemplateFile = Join-Path $PSScriptRoot 'infra' 'main.bicep'
$StartTime = Get-Date
$LastDeployFile = Join-Path $PSScriptRoot 'logs' '.last-deploy.json'

# ============================================================
# Logging infrastructure
# ============================================================
# Pre-create logs directory so we can capture the full transcript
$timestamp = $StartTime.ToString('yyyyMMddHHmmss')
$logDir = Join-Path $PSScriptRoot 'logs' $timestamp
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$transcriptPath = Join-Path $logDir 'deploy.log'
Start-Transcript -Path $transcriptPath -Append | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts] [$Level] $Message"
}

# ============================================================
# Helper: Generate a strong random password
# ============================================================
function New-StrongPassword {
    param([int]$Length = 16)
    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lower = 'abcdefghijklmnopqrstuvwxyz'
    $digits = '0123456789'
    $special = '!@#$%^&*()-_=+'
    $all = $upper + $lower + $digits + $special
    $pw = @()
    $pw += $upper[(Get-Random -Maximum $upper.Length)]
    $pw += $upper[(Get-Random -Maximum $upper.Length)]
    $pw += $lower[(Get-Random -Maximum $lower.Length)]
    $pw += $lower[(Get-Random -Maximum $lower.Length)]
    $pw += $digits[(Get-Random -Maximum $digits.Length)]
    $pw += $digits[(Get-Random -Maximum $digits.Length)]
    $pw += $special[(Get-Random -Maximum $special.Length)]
    $pw += $special[(Get-Random -Maximum $special.Length)]
    $remaining = $Length - $pw.Count
    for ($i = 0; $i -lt $remaining; $i++) {
        $pw += $all[(Get-Random -Maximum $all.Length)]
    }
    return -join ($pw | Get-Random -Count $pw.Count)
}

# ============================================================
# Load last deployment preferences (if any)
# ============================================================
$lastDeploy = $null
if (Test-Path $LastDeployFile) {
    try {
        $lastDeploy = Get-Content -Path $LastDeployFile -Raw -Encoding utf8 | ConvertFrom-Json
        Write-Log "Loaded previous deployment preferences from $LastDeployFile" 'INFO'
    }
    catch {
        Write-Log 'Failed to load previous preferences, using defaults.' 'WARN'
    }
}

function Get-LastValue {
    param([string]$Key, [string]$Fallback = '')
    if ($lastDeploy -and $lastDeploy.PSObject.Properties[$Key]) {
        $v = $lastDeploy.$Key
        if (-not [string]::IsNullOrEmpty($v)) { return $v }
    }
    return $Fallback
}

# ============================================================
# Determine if running in interactive mode
# ============================================================
# Interactive mode when no meaningful parameters are provided
# Default: HTTPS enabled unless explicitly disabled via -EnablePublicHttps:$false
if (-not $PSBoundParameters.ContainsKey('EnablePublicHttps')) {
    $EnablePublicHttps = $true
}
$isInteractive = ($PSBoundParameters.Count -eq 0)

# ============================================================
# Step 0: Ensure Azure CLI login
# ============================================================
Write-Host ""
Write-Host "=========================================="
Write-Host "  OpenClaw Azure VM Deployment"
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

# ============================================================
# Interactive setup
# ============================================================
if ($isInteractive) {
    Write-Host ""
    Write-Log 'No parameters provided. Starting interactive setup...' 'INFO'
    Write-Host "(Tip: pass parameters directly to skip interactive mode, e.g. .\deploy.ps1 -Location eastasia)"
    Write-Host ""

    # --- Select subscription ---
    Write-Log 'Querying available subscriptions...' 'STEP'
    $subscriptions = az account list --query "[?state=='Enabled']" --output json | ConvertFrom-Json
    if ($subscriptions.Count -eq 0) {
        Write-Error "No enabled Azure subscriptions found."
    }
    if ($subscriptions.Count -eq 1) {
        $selectedSub = $subscriptions[0]
        Write-Log "Only one subscription available: $($selectedSub.name)" 'INFO'
    }
    else {
        $subNames = $subscriptions | ForEach-Object { $_.name }
        $subDescs = $subscriptions | ForEach-Object { "($($_.id.Substring(0, 8))...)" }
        $selectedSubName = Read-Choice -Prompt "[1/7] Select Azure subscription:" `
            -Options $subNames -Descriptions $subDescs -Default 1
        $selectedSub = $subscriptions | Where-Object { $_.name -eq $selectedSubName } | Select-Object -First 1
    }
    if ($selectedSub.id -ne $accountInfo.id) {
        Write-Log "Switching to subscription: $($selectedSub.name)..." 'INFO'
        az account set --subscription $selectedSub.id
        $accountInfo = az account show --output json | ConvertFrom-Json
    }
    Write-Log "Using subscription: $($accountInfo.name) ($($accountInfo.id))" 'INFO'

    # --- Select resource group ---
    Write-Host ""
    Write-Log 'Querying existing resource groups...' 'STEP'
    $existingRgs = az group list --query "[].{name:name, location:location}" --output json | ConvertFrom-Json

    $lastRg = Get-LastValue 'ResourceGroup' 'rg-openclaw'
    Write-Host "[2/7] Resource group:"
    Write-Host "    1. Create new (or reuse '$lastRg')"

    $rgOptions = @($lastRg)
    $rgDescs = @('(default)')
    if ($existingRgs.Count -gt 0) {
        $otherRgs = $existingRgs | Where-Object { $_.name -ne $lastRg } | Sort-Object name
        foreach ($rg in $otherRgs) {
            $rgOptions += $rg.name
            $rgDescs += "($($rg.location))"
        }
    }
    # Add custom option
    for ($i = 1; $i -lt $rgOptions.Count; $i++) {
        Write-Host "    $($i + 1). $($rgOptions[$i])  $($rgDescs[$i])"
    }
    Write-Host "    $($rgOptions.Count + 1). Enter custom name"

    while ($true) {
        $rgInput = Read-Host "  Choice [1]"
        if ([string]::IsNullOrWhiteSpace($rgInput)) { $rgInput = '1' }
        $rgNum = 0
        if ([int]::TryParse($rgInput, [ref]$rgNum)) {
            if ($rgNum -eq 1) {
                $ResourceGroup = $lastRg
                break
            }
            elseif ($rgNum -ge 2 -and $rgNum -le $rgOptions.Count) {
                $ResourceGroup = $rgOptions[$rgNum - 1]
                break
            }
            elseif ($rgNum -eq $rgOptions.Count + 1) {
                while ($true) {
                    $customRg = Read-Host "  Enter resource group name"
                    if (-not [string]::IsNullOrWhiteSpace($customRg) -and $customRg -match '^[a-zA-Z0-9._-]+$') {
                        $ResourceGroup = $customRg.Trim()
                        break
                    }
                    Write-Host "  Invalid name. Use letters, numbers, dots, hyphens, underscores." -ForegroundColor Yellow
                }
                break
            }
        }
        Write-Host "  Invalid choice." -ForegroundColor Yellow
    }
    Write-Log "Resource group: $ResourceGroup" 'INFO'

    # --- Select region ---
    Write-Host ""
    Write-Log 'Querying available regions for this subscription...' 'STEP'
    $regions = az account list-locations --query "[?metadata.regionType=='Physical'].{name:name, displayName:displayName}" --output json | ConvertFrom-Json

    # Preferred regions (commonly used, good latency for Asia/US/EU)
    $preferredRegions = @('eastasia', 'southeastasia', 'eastus', 'eastus2', 'westus2', 'westeurope', 'japaneast', 'koreacentral')
    $availablePreferred = @()
    foreach ($pr in $preferredRegions) {
        $match = $regions | Where-Object { $_.name -eq $pr }
        if ($match) { $availablePreferred += $match }
    }

    if ($availablePreferred.Count -gt 0) {
        $regionNames = $availablePreferred | ForEach-Object { $_.name }
        $regionDescs = $availablePreferred | ForEach-Object { "($($_.displayName))" }
        # Use last region as default if it's in the list; if not, inject it
        $regionDefault = 1
        $lastLocation = Get-LastValue 'Location'
        if ($lastLocation) {
            $idx = [array]::IndexOf($regionNames, $lastLocation)
            if ($idx -ge 0) {
                $regionDefault = $idx + 1
            }
            else {
                # Last region not in preferred list — add it if it's a valid region
                $lastMatch = $regions | Where-Object { $_.name -eq $lastLocation }
                if ($lastMatch) {
                    $availablePreferred = @($lastMatch) + @($availablePreferred)
                    $regionNames = $availablePreferred | ForEach-Object { $_.name }
                    $regionDescs = $availablePreferred | ForEach-Object { "($($_.displayName))" }
                    $regionDefault = 1
                }
            }
        }
        $Location = Read-Choice -Prompt "[3/7] Select Azure region:" `
            -Options $regionNames -Descriptions $regionDescs -Default $regionDefault -AllowCustom
    }
    else {
        $allRegionNames = ($regions | Sort-Object name | ForEach-Object { $_.name })
        Write-Host "[3/7] No preferred regions available. Enter a region name."
        Write-Host "  Available: $($allRegionNames -join ', ')"
        while ($true) {
            $Location = (Read-Host "  Region").Trim()
            if ($Location -and ($allRegionNames -contains $Location)) { break }
            Write-Host "  Invalid region. Choose from the list above." -ForegroundColor Yellow
        }
    }
    Write-Log "Selected region: $Location" 'INFO'

    # --- Select OS type ---
    $osDefault = if ((Get-LastValue 'OsType') -eq 'Windows') { 2 } else { 1 }
    $OsType = Read-Choice -Prompt "[4/7] Select operating system:" `
        -Options @('Ubuntu', 'Windows') `
        -Descriptions @('24.04 LTS (recommended, 4GB+ RAM)', '11 via WSL2 (requires 8GB+ RAM)') `
        -Default $osDefault
    Write-Log "Selected OS: $OsType" 'INFO'

    # --- Select VM size (query available sizes for region) ---
    Write-Host ""
    Write-Log "Querying available VM sizes in '$Location'..." 'STEP'

    # Recommended sizes matching the OS choice
    if ($OsType -eq 'Windows') {
        $recommendedSizes = @('Standard_D4s_v5', 'Standard_B2as_v2', 'Standard_B4as_v2', 'Standard_D2s_v5')
    }
    else {
        $recommendedSizes = @('Standard_D4s_v5', 'Standard_B2als_v2', 'Standard_B2as_v2', 'Standard_B4as_v2', 'Standard_D2s_v5')
    }

    # Query actually available sizes in the region
    $availableSizes = az vm list-sizes --location $Location --output json | ConvertFrom-Json

    $validRecommended = @()
    foreach ($rs in $recommendedSizes) {
        $match = $availableSizes | Where-Object { $_.name -eq $rs }
        if ($match) {
            $validRecommended += @{
                Name     = $match.name
                Cores    = $match.numberOfCores
                MemoryGB = [math]::Round($match.memoryInMB / 1024, 0)
            }
        }
    }

    if ($validRecommended.Count -gt 0) {
        # If last VM size is available but not in recommended, inject it at the top
        $lastVmSize = Get-LastValue 'VmSize'
        if ($lastVmSize -and ($lastVmSize -notin ($validRecommended | ForEach-Object { $_.Name }))) {
            $lastMatch = $availableSizes | Where-Object { $_.name -eq $lastVmSize }
            if ($lastMatch) {
                $validRecommended = @(@{
                        Name     = $lastMatch.name
                        Cores    = $lastMatch.numberOfCores
                        MemoryGB = [math]::Round($lastMatch.memoryInMB / 1024, 0)
                    }) + @($validRecommended)
            }
        }
        $sizeNames = $validRecommended | ForEach-Object { $_.Name }
        $sizeDescs = $validRecommended | ForEach-Object { "($($_.Cores) vCPU, $($_.MemoryGB) GB RAM)" }
        # Use last VM size as default
        $sizeDefault = 1
        if ($lastVmSize) {
            $idx = [array]::IndexOf($sizeNames, $lastVmSize)
            if ($idx -ge 0) { $sizeDefault = $idx + 1 }
        }
        $VmSize = Read-Choice -Prompt "[5/7] Select VM size:" `
            -Options $sizeNames -Descriptions $sizeDescs -Default $sizeDefault -AllowCustom
    }
    else {
        Write-Host "  No recommended sizes available in this region." -ForegroundColor Yellow
        Write-Host "  Available sizes: $($availableSizes.Count) total"
        while ($true) {
            $VmSize = (Read-Host "  Enter VM size SKU (e.g., Standard_B2s)").Trim()
            $match = $availableSizes | Where-Object { $_.name -eq $VmSize }
            if ($match) { break }
            Write-Host "  Size '$VmSize' is not available in '$Location'." -ForegroundColor Yellow
        }
    }

    # Warn if Windows + small memory
    $selectedSizeInfo = $availableSizes | Where-Object { $_.name -eq $VmSize }
    if ($selectedSizeInfo -and $OsType -eq 'Windows' -and $selectedSizeInfo.memoryInMB -lt 8192) {
        Write-Host ""
        Write-Host "  WARNING: Windows 11 + WSL2 requires at least 8 GB RAM." -ForegroundColor Yellow
        Write-Host "  Selected '$VmSize' has only $([math]::Round($selectedSizeInfo.memoryInMB / 1024, 0)) GB." -ForegroundColor Yellow
        $confirm = Read-Host "  Continue anyway? (y/N)"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "  Please re-run and select a larger VM size." -ForegroundColor Yellow
            exit 1
        }
    }
    Write-Log "Selected VM size: $VmSize" 'INFO'

    # --- Admin credentials ---
    Write-Host ""
    $lastUser = Get-LastValue 'AdminUsername' 'azureclaw'
    $inputUser = Read-Host "[6/7] Admin username [$lastUser]"
    $AdminUsername = if ([string]::IsNullOrWhiteSpace($inputUser)) { $lastUser } else { $inputUser.Trim() }

    $secPw = Read-Host "  Password (leave empty to auto-generate)" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPw)
    $inputPw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $AdminPassword = if ([string]::IsNullOrWhiteSpace($inputPw)) { '' } else { $inputPw }
    Write-Log "Admin username: $AdminUsername" 'INFO'

    # --- Enable HTTPS ---
    Write-Host ""
    Write-Host "[7/7] Enable public HTTPS? (Caddy + Let's Encrypt auto-certificate)"
    Write-Host "  This adds password-protected HTTPS access via the Azure VM domain name."
    $lastHttps = (Get-LastValue 'EnablePublicHttps') -eq 'true'
    $httpsDefault = if ($lastHttps -eq $false -and (Get-LastValue 'EnablePublicHttps') -ne $null) { 'N' } else { 'Y' }
    $httpsInput = Read-Host "  Enable? (Y/n) [$httpsDefault]"
    if ([string]::IsNullOrWhiteSpace($httpsInput)) {
        $EnablePublicHttps = ($httpsDefault -eq 'Y')
    }
    else {
        $EnablePublicHttps = ($httpsInput -ne 'n' -and $httpsInput -ne 'N')
    }

    # --- Summary and confirm ---
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Deployment Summary"
    Write-Host "=========================================="
    Write-Host "  Subscription   : $($accountInfo.name)"
    Write-Host "  Location       : $Location"
    Write-Host "  OS Type        : $OsType"
    Write-Host "  VM Size        : $VmSize"
    Write-Host "  Admin Username : $AdminUsername"
    Write-Host "  Admin Password : $(if ([string]::IsNullOrEmpty($AdminPassword)) { '(auto-generate)' } else { '********' })"
    Write-Host "  Public HTTPS   : $EnablePublicHttps"
    Write-Host "  Resource Group : $ResourceGroup"
    Write-Host "=========================================="
    Write-Host ""
    $proceed = Read-Host "Proceed with deployment? (Y/n) [Y]"
    if ($proceed -eq 'n' -or $proceed -eq 'N') {
        Write-Host "[INFO] Cancelled."
        exit 0
    }
}
else {
    Write-Log 'Non-interactive mode: applying defaults for unset parameters.' 'INFO'
    if ([string]::IsNullOrEmpty($Location)) { $Location = Get-LastValue 'Location' 'eastasia' }
    if ([string]::IsNullOrEmpty($OsType)) { $OsType = Get-LastValue 'OsType' 'Ubuntu' }
    if ([string]::IsNullOrEmpty($VmSize)) { $VmSize = Get-LastValue 'VmSize' 'Standard_D4s_v5' }
    if ([string]::IsNullOrEmpty($ResourceGroup)) { $ResourceGroup = Get-LastValue 'ResourceGroup' 'rg-openclaw' }
    if ([string]::IsNullOrEmpty($AdminUsername)) { $AdminUsername = Get-LastValue 'AdminUsername' 'azureclaw' }
}

# ============================================================
# Save deployment preferences for next run
# ============================================================
$saveData = [PSCustomObject]@{
    Location          = $Location
    OsType            = $OsType
    VmSize            = $VmSize
    AdminUsername     = $AdminUsername
    ResourceGroup     = $ResourceGroup
    EnablePublicHttps = $EnablePublicHttps.ToString().ToLower()
    SavedAt           = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
}
try {
    $saveDir = Split-Path $LastDeployFile -Parent
    if (-not (Test-Path $saveDir)) { New-Item -ItemType Directory -Path $saveDir -Force | Out-Null }
    $saveData | ConvertTo-Json | Set-Content -Path $LastDeployFile -Encoding UTF8
    Write-Log "Saved deployment preferences to $LastDeployFile" 'INFO'
}
catch {
    Write-Log "Failed to save preferences: $_" 'WARN'
}

# --- 1. Password generation ---

if ([string]::IsNullOrEmpty($AdminPassword)) {
    $AdminPassword = New-StrongPassword
    Write-Log 'Admin password auto-generated.' 'INFO'
}

$GatewayPassword = New-StrongPassword
Write-Log 'Gateway password auto-generated.' 'INFO'

Write-Host ""
Write-Host "=========================================="
Write-Host "  Deploying..."
Write-Host "=========================================="
Write-Host "  Location       : $Location"
Write-Host "  OS Type        : $OsType"
Write-Host "  VM Size        : $VmSize"
Write-Host "  Admin Username : $AdminUsername"
Write-Host "  Public HTTPS   : $EnablePublicHttps"
Write-Host "  Resource Group : $ResourceGroup"
Write-Host "=========================================="
Write-Host ""

# --- Check if resource group already exists ---

$rgExists = az group exists --name $ResourceGroup 2>&1
if ($rgExists -eq 'true') {
    $existingRg = az group show --name $ResourceGroup --output json | ConvertFrom-Json
    Write-Log "Resource group '$ResourceGroup' already exists in '$($existingRg.location)'." 'WARN'
    Write-Host "  Existing resources will be updated or may conflict." -ForegroundColor Yellow
    if (-not $isInteractive) {
        Write-Log 'Proceeding with existing resource group (non-interactive mode).' 'INFO'
    }
    else {
        $rgConfirm = Read-Host "  Continue with existing resource group? (Y/n) [Y]"
        if ($rgConfirm -eq 'n' -or $rgConfirm -eq 'N') {
            Write-Host "[INFO] Cancelled. Run .\destroy.ps1 first to clean up, then re-deploy."
            exit 0
        }
    }
}

# --- Create resource group ---

Write-Log "Creating resource group '$ResourceGroup' in '$Location'..." 'STEP'
az group create --name $ResourceGroup --location $Location --output none
Write-Log 'Resource group ready.' 'INFO'

# --- Deploy Bicep template ---

Write-Log 'Deploying Bicep template (this may take several minutes)...' 'STEP'

# Pause transcript to prevent passwords from leaking into deploy.log
Stop-Transcript | Out-Null

$deploymentResult = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $TemplateFile `
    --parameters `
    location=$Location `
    osType=$OsType `
    vmSize=$VmSize `
    adminUsername=$AdminUsername `
    adminPassword=$AdminPassword `
    enablePublicHttps=$($EnablePublicHttps.ToString().ToLower()) `
    gatewayPassword=$GatewayPassword `
    --output json | ConvertFrom-Json

# Resume transcript (safe — no more secrets in command output)
Start-Transcript -Path $transcriptPath -Append | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Check the Azure Portal for details."
}

# --- Capture deployment outputs ---

$publicIpAddress = $deploymentResult.properties.outputs.publicIpAddress.value
$vmFqdn = $deploymentResult.properties.outputs.fqdn.value
$vmName = $deploymentResult.properties.outputs.vmName.value
$deployedOsType = $deploymentResult.properties.outputs.osType.value
$deployedAdminUsername = $deploymentResult.properties.outputs.adminUsername.value

Write-Log 'Deployment succeeded.' 'INFO'
Write-Log "Public IP: $publicIpAddress" 'INFO'
Write-Log "FQDN: $vmFqdn" 'INFO'

# --- Write .env ---

Write-Log 'Writing deployment artifacts...' 'STEP'

$envContent = @"
ADMIN_USERNAME=$deployedAdminUsername
ADMIN_PASSWORD=$AdminPassword
VM_PUBLIC_IP=$publicIpAddress
FQDN=$vmFqdn
OS_TYPE=$deployedOsType
VM_SIZE=$VmSize
LOCATION=$Location
RESOURCE_GROUP=$ResourceGroup
ENABLE_PUBLIC_HTTPS=$($EnablePublicHttps.ToString().ToLower())
GATEWAY_PASSWORD=$GatewayPassword
DEPLOY_TIME=$($StartTime.ToString('yyyy-MM-ddTHH:mm:ss'))
"@
Set-Content -Path (Join-Path $logDir '.env') -Value $envContent -Encoding UTF8

# --- Generate guide.md ---

Write-Log 'Generating operation guide...' 'STEP'

$guideHeader = @"
# OpenClaw 部署操作指南

## 部署信息

- 部署时间: $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
- 公网 IP: $publicIpAddress
- 域名: $vmFqdn
- 操作系统: $(if ($deployedOsType -eq 'Ubuntu') { 'Ubuntu 24.04 LTS' } else { 'Windows 11' })
- VM 规格: $VmSize
- 资源组: $ResourceGroup
- 公网 HTTPS: $(if ($EnablePublicHttps) { '已启用 (Caddy + Let''s Encrypt)' } else { '未启用' })

> 敏感信息（用户名/密码）保存在同目录下的 ``.env`` 文件中。

"@

if ($deployedOsType -eq 'Ubuntu') {
    if ($EnablePublicHttps) {
        $guideBody = @"
## 一、连接远程服务器

使用 SSH 密码登录（`deploy.ps1` 部署时密码在同目录 ``.env``；Portal 一键部署时即表单填写的 `adminPassword`）：

``````bash
ssh ${deployedAdminUsername}@${publicIpAddress}
``````

## 二、连接 OpenClaw

1. 浏览器访问 Web 控制台（HTTPS）: https://${vmFqdn}
2. 检查服务状态: ``sudo systemctl status openclaw``
3. 检查 Caddy 状态: ``sudo systemctl status caddy``
4. 查看日志: ``journalctl -u openclaw -f``

### 凭据速查

**Gateway 登录密码**

- 使用 ``deploy.ps1`` 部署：见本目录 ``.env`` 文件的 ``GATEWAY_PASSWORD`` 字段
- 使用 Azure Portal 一键部署：即你在部署表单中填写的 ``gatewayPassword``
- 忘了？SSH 进 VM 执行：
  ``````bash
  sudo systemctl cat openclaw | grep OPENCLAW_GATEWAY_PASSWORD
  ``````

**Control Token（仅 macOS / iOS / Android 客户端或 CLI 远程连接时需要）**

``````bash
# 查看当前 token
jq -r '.gateway.auth.token // "<not set>"' ~/.openclaw/openclaw.json

# 没有则生成一个新 token
openclaw doctor --generate-gateway-token
sudo systemctl restart openclaw
``````

> 详见 [运维手册 §10 Gateway Control Token](../../docs/zh/guide-operations.md#gateway-control-tokengatewayauthtoken)。

> **首次连接节奏**：(三) 加白 Origin（如需）→ SSH 运行 ``openclaw onboard`` 配置模型 API Key → 浏览器用正确密码登录触发配对 → (四) 服务器端 ``openclaw devices approve --latest`` → ``openclaw doctor`` 自检。

## 三、配置访问 Origin（如需追加）

部署脚本已自动将 ``https://${vmFqdn}`` 加入 Control UI 白名单。如果还需要从其他 origin（自定义域名、内网代理、IP 直连等）访问，SSH 进 VM 后执行：

``````bash
# 用空格分隔多个 origin，单引号包裹整个 JSON 数组
openclaw config set gateway.controlUi.allowedOrigins \
  '["https://${vmFqdn}", "https://your-extra-domain.com"]'
sudo systemctl restart openclaw
``````

> 浏览器若报 ``origin not allowed``，详见 [运维手册 §11.1](../../docs/zh/guide-operations.md#111-control-ui-origin-not-allowed)。

## 四、设备配对

首次通过浏览器连接 Gateway 前，请先 SSH/RDP 进 VM 运行 ``openclaw onboard`` 配置模型 API Key 与 token，再按以下步骤完成设备配对：

1. 在浏览器中打开 Web 控制台，输入 Gateway Password 后连接
2. 页面会显示 **"pairing required"**，表示需要在服务器端审批
3. SSH 登录服务器，执行以下命令审批最新的配对请求：

``````bash
openclaw devices approve --latest
``````

4. 审批后浏览器会自动连接成功

> **注意**: 每个新浏览器/设备都需要重新配对和审批。配对基于浏览器存储的 device token，更换浏览器、清除浏览器数据或使用隐私模式都需要重新配对。
>
> 常用设备管理命令：
> - ``openclaw devices list`` — 查看已配对设备
> - ``openclaw devices approve --latest`` — 审批最新请求
> - ``openclaw devices remove <id>`` — 移除设备

## 五、清理资源

``````powershell
.\destroy.ps1
``````
"@
    }
    else {
        $guideBody = @"
## 一、连接远程服务器

使用 SSH 密码登录（`deploy.ps1` 部署时密码在同目录 ``.env``；Portal 一键部署时即表单填写的 `adminPassword`）：

``````bash
ssh ${deployedAdminUsername}@${publicIpAddress}
``````

## 二、连接 OpenClaw

1. 浏览器访问 Web 控制台: http://${publicIpAddress}:18789
2. 检查服务状态: ``sudo systemctl status openclaw``
3. 查看日志: ``journalctl -u openclaw -f``

### 凭据速查

**Gateway 登录密码**

- 使用 ``deploy.ps1`` 部署：见本目录 ``.env`` 文件的 ``GATEWAY_PASSWORD`` 字段
- 使用 Azure Portal 一键部署：即你在部署表单中填写的 ``gatewayPassword``
- 忘了？SSH 进 VM 执行：
  ``````bash
  sudo systemctl cat openclaw | grep OPENCLAW_GATEWAY_PASSWORD
  ``````

**Control Token（仅 macOS / iOS / Android 客户端或 CLI 远程连接时需要）**

``````bash
# 查看当前 token
jq -r '.gateway.auth.token // "<not set>"' ~/.openclaw/openclaw.json

# 没有则生成一个新 token
openclaw doctor --generate-gateway-token
sudo systemctl restart openclaw
``````

> 详见 [运维手册 §10 Gateway Control Token](../../docs/zh/guide-operations.md#gateway-control-tokengatewayauthtoken)。

> **首次连接节奏**：(三) 加白 Origin（**必做**）→ SSH 运行 ``openclaw onboard`` 配置模型 API Key → 浏览器用正确密码登录触发配对 → (四) 服务器端 ``openclaw devices approve --latest`` → ``openclaw doctor`` 自检。

## 三、配置访问 Origin（必做）

Gateway 默认只信 loopback origin；从公网 IP 访问浏览器会被拦截，必须把访问 origin 加白：

``````bash
openclaw config set gateway.controlUi.allowedOrigins \
  '["http://${publicIpAddress}:18789"]'
sudo systemctl restart openclaw
``````

> 详见 [运维手册 §11.1](../../docs/zh/guide-operations.md#111-control-ui-origin-not-allowed)。

## 四、设备配对

首次通过浏览器连接 Gateway 前，请先 SSH/RDP 进 VM 运行 ``openclaw onboard`` 配置模型 API Key 与 token，再按以下步骤完成设备配对：

1. 在浏览器中打开 Web 控制台，输入 Gateway Password 后连接
2. 页面会显示 **"pairing required"**，表示需要在服务器端审批
3. SSH 登录服务器，执行以下命令审批最新的配对请求：

``````bash
openclaw devices approve --latest
``````

4. 审批后浏览器会自动连接成功

> **注意**: 每个新浏览器/设备都需要重新配对和审批。配对基于浏览器存储的 device token，更换浏览器、清除浏览器数据或使用隐私模式都需要重新配对。
>
> 常用设备管理命令：
> - ``openclaw devices list`` — 查看已配对设备
> - ``openclaw devices approve --latest`` — 审批最新请求
> - ``openclaw devices remove <id>`` — 移除设备

## 五、清理资源

``````powershell
.\destroy.ps1
``````
"@
    }
}
else {
    if ($EnablePublicHttps) {
        $guideBody = @"
## 一、连接远程服务器

使用远程桌面连接（`deploy.ps1` 部署时密码在同目录 ``.env``；Portal 一键部署时即表单填写的 `adminPassword`）：

``````powershell
mstsc /v:${publicIpAddress}
``````

## 二、连接 OpenClaw

1. 外网浏览器访问（HTTPS）: https://${vmFqdn}
2. RDP 登录后本地访问: http://localhost:18789
3. 打开 PowerShell 运行: ``openclaw doctor``

### 凭据速查

**Gateway 登录密码**

- 使用 ``deploy.ps1`` 部署：见本目录 ``.env`` 文件的 ``GATEWAY_PASSWORD`` 字段
- 使用 Azure Portal 一键部署：即你在部署表单中填写的 ``gatewayPassword``
- 忘了？RDP 后在 PowerShell 执行：
  ``````powershell
  wsl -d Ubuntu -u openclaw -- sudo systemctl cat openclaw ``| Select-String OPENCLAW_GATEWAY_PASSWORD
  ``````

**Control Token（仅 macOS / iOS / Android 客户端或 CLI 远程连接时需要）**

``````powershell
# 查看当前 token
wsl -d Ubuntu -u openclaw -- jq -r '.gateway.auth.token // "<not set>"' ~/.openclaw/openclaw.json

# 没有则生成一个新 token
wsl -d Ubuntu -u openclaw -- openclaw doctor --generate-gateway-token
wsl -d Ubuntu -u openclaw -- sudo systemctl restart openclaw
``````

> 详见 [运维手册 §10 Gateway Control Token](../../docs/zh/guide-operations.md#gateway-control-tokengatewayauthtoken)。

> **首次连接节奏**：(三) 加白 Origin（如需）→ SSH 运行 ``openclaw onboard`` 配置模型 API Key → 浏览器用正确密码登录触发配对 → (四) 服务器端 ``openclaw devices approve --latest`` → ``openclaw doctor`` 自检。

## 三、配置访问 Origin（如需追加）

部署脚本已自动将 ``https://${vmFqdn}`` 加入 Control UI 白名单。如需从其他 origin 访问，RDP 后在 PowerShell 执行：

``````powershell
wsl -d Ubuntu -u openclaw -- openclaw config set gateway.controlUi.allowedOrigins ``
  '["https://${vmFqdn}", "https://your-extra-domain.com"]'
wsl -d Ubuntu -u openclaw -- sudo systemctl restart openclaw
``````

> 详见 [运维手册 §11.1](../../docs/zh/guide-operations.md#111-control-ui-origin-not-allowed)。

## 四、设备配对

首次通过浏览器连接 Gateway 前，请先 SSH/RDP 进 VM 运行 ``openclaw onboard`` 配置模型 API Key 与 token，再按以下步骤完成设备配对：

1. 在浏览器中打开 Web 控制台，输入 Gateway Password 后连接
2. 页面会显示 **"pairing required"**，表示需要在服务器端审批
3. RDP 登录服务器，打开 PowerShell 执行：

``````powershell
wsl -d Ubuntu -u openclaw -- openclaw devices approve --latest
``````

4. 审批后浏览器会自动连接成功

> **注意**: 每个新浏览器/设备都需要重新配对和审批。配对基于浏览器存储的 device token，更换浏览器、清除浏览器数据或使用隐私模式都需要重新配对。
>
> 常用设备管理命令：
> - ``wsl -d Ubuntu -u openclaw -- openclaw devices list`` — 查看已配对设备
> - ``wsl -d Ubuntu -u openclaw -- openclaw devices approve --latest`` — 审批最新请求
> - ``wsl -d Ubuntu -u openclaw -- openclaw devices remove <id>`` — 移除设备

## 五、清理资源

``````powershell
.\destroy.ps1
``````
"@
    }
    else {
        $guideBody = @"
## 一、连接远程服务器

使用远程桌面连接（`deploy.ps1` 部署时密码在同目录 ``.env``；Portal 一键部署时即表单填写的 `adminPassword`）：

``````powershell
mstsc /v:${publicIpAddress}
``````

## 二、连接 OpenClaw

1. RDP 登录后打开浏览器访问: http://localhost:18789
2. 打开 PowerShell 运行: ``openclaw doctor``
3. 运行交互式配置: ``openclaw onboard --install-daemon``

### 凭据速查

**Gateway 登录密码**

- 使用 ``deploy.ps1`` 部署：见本目录 ``.env`` 文件的 ``GATEWAY_PASSWORD`` 字段
- 使用 Azure Portal 一键部署：即你在部署表单中填写的 ``gatewayPassword``
- 忘了？RDP 后在 PowerShell 执行：
  ``````powershell
  wsl -d Ubuntu -u openclaw -- sudo systemctl cat openclaw ``| Select-String OPENCLAW_GATEWAY_PASSWORD
  ``````

**Control Token（仅 macOS / iOS / Android 客户端或 CLI 远程连接时需要）**

``````powershell
# 查看当前 token
wsl -d Ubuntu -u openclaw -- jq -r '.gateway.auth.token // "<not set>"' ~/.openclaw/openclaw.json

# 没有则生成一个新 token
wsl -d Ubuntu -u openclaw -- openclaw doctor --generate-gateway-token
wsl -d Ubuntu -u openclaw -- sudo systemctl restart openclaw
``````

> 详见 [运维手册 §10 Gateway Control Token](../../docs/zh/guide-operations.md#gateway-control-tokengatewayauthtoken)。

## 三、设备配对

首次通过浏览器连接 Gateway 前，请先 SSH/RDP 进 VM 运行 ``openclaw onboard`` 配置模型 API Key 与 token，再按以下步骤完成设备配对：

1. 在浏览器中打开 Web 控制台，输入 Gateway Password 后连接
2. 页面会显示 **"pairing required"**，表示需要在服务器端审批
3. 在 RDP 桌面打开 PowerShell 执行：

``````powershell
wsl -d Ubuntu -u openclaw -- openclaw devices approve --latest
``````

4. 审批后浏览器会自动连接成功

> **注意**: 每个新浏览器/设备都需要重新配对和审批。配对基于浏览器存储的 device token，更换浏览器、清除浏览器数据或使用隐私模式都需要重新配对。
>
> 常用设备管理命令：
> - ``wsl -d Ubuntu -u openclaw -- openclaw devices list`` — 查看已配对设备
> - ``wsl -d Ubuntu -u openclaw -- openclaw devices approve --latest`` — 审批最新请求
> - ``wsl -d Ubuntu -u openclaw -- openclaw devices remove <id>`` — 移除设备

## 四、清理资源

``````powershell
.\destroy.ps1
``````
"@
    }
}

Set-Content -Path (Join-Path $logDir 'guide.md') -Value ($guideHeader + $guideBody) -Encoding UTF8

# --- Console summary ---

Write-Host ""
Write-Host "=========================================="
Write-Host "  Deployment Complete!"
Write-Host "=========================================="
Write-Host "  Public IP      : $publicIpAddress"
Write-Host "  FQDN           : $vmFqdn"
Write-Host "  VM Name        : $vmName"
Write-Host "  OS Type        : $deployedOsType"
Write-Host "  Admin Username : $deployedAdminUsername"
if ($EnablePublicHttps) {
    Write-Host "  HTTPS URL      : https://$vmFqdn"
}
Write-Host "=========================================="
Write-Host ""
Write-Host "  Logs directory : $logDir"
Write-Host "  - deploy.log   : Full deployment transcript"
Write-Host "  - .env         : Credentials & connection info"
Write-Host "  - guide.md     : Operation guide"
Write-Host ""

if ($deployedOsType -eq 'Ubuntu') {
    Write-Host "  Connect: ssh ${deployedAdminUsername}@${publicIpAddress}"
    if ($EnablePublicHttps) {
        Write-Host "  Web UI:  https://${vmFqdn}"
    }
    else {
        Write-Host "  Web UI:  http://${publicIpAddress}:18789"
    }
}
else {
    Write-Host "  Connect: mstsc /v:${publicIpAddress}"
    if ($EnablePublicHttps) {
        Write-Host "  Web UI:  https://${vmFqdn}"
    }
    else {
        Write-Host "  Web UI:  http://localhost:18789 (after RDP login)"
    }
}

Write-Host ""
# Stop transcript
Stop-Transcript | Out-Null
