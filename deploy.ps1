<#
.SYNOPSIS
    Deploy OpenClaw to Azure VM (Ubuntu 24.04 LTS or Windows 11).
    Run without parameters for interactive guided setup.

.PARAMETER Location
    Azure region. Default: eastasia

.PARAMETER VmSize
    VM size SKU. Default: Standard_B2s

.PARAMETER OsType
    Operating system: Ubuntu or Windows. Default: Ubuntu

.PARAMETER AdminUsername
    VM admin username. Default: azureclaw

.PARAMETER AdminPassword
    VM admin password. Auto-generated if not provided.

.PARAMETER EnablePublicHttps
    Enable public HTTPS access via Caddy + Let's Encrypt. Default: off.

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
    [switch]$EnablePublicHttps
)

$ErrorActionPreference = 'Stop'
$ResourceGroup = 'rg-openclaw'
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
# Helper: Prompt user to pick from a numbered list
# ============================================================
function Read-Choice {
    param(
        [string]$Prompt,
        [string[]]$Options,
        [string[]]$Descriptions = @(),
        [int]$Default = 1,
        [switch]$AllowCustom
    )
    Write-Host ""
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $desc = if ($Descriptions.Count -gt $i -and $Descriptions[$i]) { "  $($Descriptions[$i])" } else { '' }
        Write-Host "    $($i + 1). $($Options[$i])$desc"
    }
    if ($AllowCustom) {
        Write-Host "    $($Options.Count + 1). Custom (enter manually)"
    }
    $maxChoice = if ($AllowCustom) { $Options.Count + 1 } else { $Options.Count }
    while ($true) {
        $input = Read-Host "  Choice [$Default]"
        if ([string]::IsNullOrWhiteSpace($input)) { $input = "$Default" }
        $num = 0
        if ([int]::TryParse($input, [ref]$num) -and $num -ge 1 -and $num -le $maxChoice) {
            if ($AllowCustom -and $num -eq $maxChoice) {
                while ($true) {
                    $custom = Read-Host "  Enter value"
                    if (-not [string]::IsNullOrWhiteSpace($custom)) { return $custom.Trim() }
                    Write-Host "  Value cannot be empty." -ForegroundColor Yellow
                }
            }
            return $Options[$num - 1]
        }
        Write-Host "  Invalid choice. Enter 1-$maxChoice." -ForegroundColor Yellow
    }
}

# ============================================================
# Load last deployment preferences (if any)
# ============================================================
$lastDeploy = $null
if (Test-Path $LastDeployFile) {
    try {
        $lastDeploy = Get-Content -Path $LastDeployFile -Raw -Encoding utf8 | ConvertFrom-Json
        Write-Log "Loaded previous deployment preferences from $LastDeployFile" 'INFO'
    } catch {
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
$isInteractive = ($PSBoundParameters.Count -eq 0) -or
($PSBoundParameters.Count -eq 1 -and $PSBoundParameters.ContainsKey('EnablePublicHttps') -and -not $EnablePublicHttps)

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
        $selectedSubName = Read-Choice -Prompt "[1/6] Select Azure subscription:" `
            -Options $subNames -Descriptions $subDescs -Default 1
        $selectedSub = $subscriptions | Where-Object { $_.name -eq $selectedSubName } | Select-Object -First 1
    }
    if ($selectedSub.id -ne $accountInfo.id) {
        Write-Log "Switching to subscription: $($selectedSub.name)..." 'INFO'
        az account set --subscription $selectedSub.id
        $accountInfo = az account show --output json | ConvertFrom-Json
    }
    Write-Log "Using subscription: $($accountInfo.name) ($($accountInfo.id))" 'INFO'

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
            } else {
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
        $Location = Read-Choice -Prompt "[2/6] Select Azure region:" `
            -Options $regionNames -Descriptions $regionDescs -Default $regionDefault -AllowCustom
    }
    else {
        $allRegionNames = ($regions | Sort-Object name | ForEach-Object { $_.name })
        Write-Host "[2/6] No preferred regions available. Enter a region name."
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
    $OsType = Read-Choice -Prompt "[3/6] Select operating system:" `
        -Options @('Ubuntu', 'Windows') `
        -Descriptions @('22.04 LTS (recommended, 4GB+ RAM)', '11 via WSL2 (requires 8GB+ RAM)') `
        -Default $osDefault
    Write-Log "Selected OS: $OsType" 'INFO'

    # --- Select VM size (query available sizes for region) ---
    Write-Host ""
    Write-Log "Querying available VM sizes in '$Location'..." 'STEP'

    # Recommended sizes matching the OS choice
    if ($OsType -eq 'Windows') {
        $recommendedSizes = @('Standard_B2ms', 'Standard_B4ms', 'Standard_D2s_v5', 'Standard_D4s_v5')
    }
    else {
        $recommendedSizes = @('Standard_B2s', 'Standard_B2ms', 'Standard_B4ms', 'Standard_D2s_v5')
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
        $VmSize = Read-Choice -Prompt "[4/6] Select VM size:" `
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
    $inputUser = Read-Host "[5/6] Admin username [$lastUser]"
    $AdminUsername = if ([string]::IsNullOrWhiteSpace($inputUser)) { $lastUser } else { $inputUser.Trim() }

    $secPw = Read-Host "  Password (leave empty to auto-generate)" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPw)
    $inputPw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $AdminPassword = if ([string]::IsNullOrWhiteSpace($inputPw)) { '' } else { $inputPw }
    Write-Log "Admin username: $AdminUsername" 'INFO'

    # --- Enable HTTPS ---
    Write-Host ""
    Write-Host "[6/6] Enable public HTTPS? (Caddy + Let's Encrypt auto-certificate)"
    Write-Host "  This adds password-protected HTTPS access via the Azure VM domain name."
    $lastHttps = (Get-LastValue 'EnablePublicHttps') -eq 'true'
    $httpsDefault = if ($lastHttps) { 'Y' } else { 'N' }
    $httpsInput = Read-Host "  Enable? (y/N) [$httpsDefault]"
    if ([string]::IsNullOrWhiteSpace($httpsInput)) {
        $EnablePublicHttps = $lastHttps
    } else {
        $EnablePublicHttps = ($httpsInput -eq 'y' -or $httpsInput -eq 'Y')
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
    if ([string]::IsNullOrEmpty($VmSize)) { $VmSize = Get-LastValue 'VmSize' 'Standard_B2s' }
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
    EnablePublicHttps = $EnablePublicHttps.ToString().ToLower()
    SavedAt           = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
}
try {
    $saveDir = Split-Path $LastDeployFile -Parent
    if (-not (Test-Path $saveDir)) { New-Item -ItemType Directory -Path $saveDir -Force | Out-Null }
    $saveData | ConvertTo-Json | Set-Content -Path $LastDeployFile -Encoding UTF8
    Write-Log "Saved deployment preferences to $LastDeployFile" 'INFO'
} catch {
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

使用 SSH 密码登录（用户名和密码参见 ``.env`` 文件）：

``````bash
ssh ${deployedAdminUsername}@${publicIpAddress}
``````

## 二、连接 OpenClaw

1. 浏览器访问 Web 控制台（HTTPS）: https://${vmFqdn}
2. 登录密码参见 ``.env`` 文件中的 ``GATEWAY_PASSWORD``
3. 检查服务状态: ``sudo systemctl status openclaw``
4. 检查 Caddy 状态: ``sudo systemctl status caddy``
5. 运行交互式配置: ``openclaw onboard``
6. 查看日志: ``journalctl -u openclaw -f``

## 三、清理资源

``````powershell
.\destroy.ps1
``````
"@
    }
    else {
        $guideBody = @"
## 一、连接远程服务器

使用 SSH 密码登录（用户名和密码参见 ``.env`` 文件）：

``````bash
ssh ${deployedAdminUsername}@${publicIpAddress}
``````

## 二、连接 OpenClaw

1. 浏览器访问 Web 控制台: http://${publicIpAddress}:18789
2. 登录密码参见 ``.env`` 文件中的 ``GATEWAY_PASSWORD``
3. 检查服务状态: ``sudo systemctl status openclaw``
4. 运行交互式配置: ``openclaw onboard``
5. 查看日志: ``journalctl -u openclaw -f``

## 三、清理资源

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

使用远程桌面连接（用户名和密码参见 ``.env`` 文件）：

``````powershell
mstsc /v:${publicIpAddress}
``````

## 二、连接 OpenClaw

1. 外网浏览器访问（HTTPS）: https://${vmFqdn}
2. 登录密码参见 ``.env`` 文件中的 ``GATEWAY_PASSWORD``
3. RDP 登录后本地访问: http://localhost:18789
4. 打开 PowerShell 运行: ``openclaw doctor``
5. 运行交互式配置: ``openclaw onboard --install-daemon``

## 三、清理资源

``````powershell
.\destroy.ps1
``````
"@
    }
    else {
        $guideBody = @"
## 一、连接远程服务器

使用远程桌面连接（用户名和密码参见 ``.env`` 文件）：

``````powershell
mstsc /v:${publicIpAddress}
``````

## 二、连接 OpenClaw

1. RDP 登录后打开浏览器访问: http://localhost:18789
2. 登录密码参见 ``.env`` 文件中的 ``GATEWAY_PASSWORD``
3. 打开 PowerShell 运行: ``openclaw doctor``
4. 运行交互式配置: ``openclaw onboard --install-daemon``

## 三、清理资源

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
