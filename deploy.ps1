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

.PARAMETER ResourceGroup
    Resource group name. Default: rg-openclaw

.PARAMETER EnablePublicHttps
    Enable public HTTPS access via Caddy + Let's Encrypt. Default: off.

.PARAMETER EnableFoundry
    Automatically create Azure AI (Microsoft Foundry) resource and deploy a model during Bicep deployment.

.PARAMETER FoundryModelName
    Model name to deploy when EnableFoundry is set. Default: gpt-4.1

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
    [switch]$EnablePublicHttps,
    [switch]$EnableFoundry,
    [string]$FoundryModelName = ''
)

$ErrorActionPreference = 'Stop'

# Load shared functions (model knowledge base, interactive helpers, etc.)
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
        $selectedSubName = Read-Choice -Prompt "[1/8] Select Azure subscription:" `
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
    Write-Host "[2/8] Resource group:"
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
        $Location = Read-Choice -Prompt "[3/8] Select Azure region:" `
            -Options $regionNames -Descriptions $regionDescs -Default $regionDefault -AllowCustom
    }
    else {
        $allRegionNames = ($regions | Sort-Object name | ForEach-Object { $_.name })
        Write-Host "[3/8] No preferred regions available. Enter a region name."
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
    $OsType = Read-Choice -Prompt "[4/8] Select operating system:" `
        -Options @('Ubuntu', 'Windows') `
        -Descriptions @('24.04 LTS (recommended, 4GB+ RAM)', '11 via WSL2 (requires 8GB+ RAM)') `
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
        $VmSize = Read-Choice -Prompt "[5/8] Select VM size:" `
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
    $inputUser = Read-Host "[6/8] Admin username [$lastUser]"
    $AdminUsername = if ([string]::IsNullOrWhiteSpace($inputUser)) { $lastUser } else { $inputUser.Trim() }

    $secPw = Read-Host "  Password (leave empty to auto-generate)" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPw)
    $inputPw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $AdminPassword = if ([string]::IsNullOrWhiteSpace($inputPw)) { '' } else { $inputPw }
    Write-Log "Admin username: $AdminUsername" 'INFO'

    # --- Enable HTTPS ---
    Write-Host ""
    Write-Host "[7/8] Enable public HTTPS? (Caddy + Let's Encrypt auto-certificate)"
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

    # --- Enable Foundry ---
    Write-Host ""
    Write-Host "[8/8] Auto-create Microsoft Foundry (Azure AI) resource?"
    Write-Host "  This provisions an Azure AI Services resource and deploys a model during deployment."
    Write-Host "  You can also configure models manually after deployment."
    $lastFoundry = (Get-LastValue 'EnableFoundry') -eq 'true'
    $foundryDefault = if ($lastFoundry) { 'Y' } else { 'N' }
    $foundryInput = Read-Host "  Enable? (y/N) [$foundryDefault]"
    if ([string]::IsNullOrWhiteSpace($foundryInput)) {
        $EnableFoundry = ($foundryDefault -eq 'Y')
    }
    else {
        $EnableFoundry = ($foundryInput -eq 'y' -or $foundryInput -eq 'Y')
    }

    if ($EnableFoundry) {
        $lastModel = Get-LastValue 'FoundryModelName' 'gpt-4.1'
        $modelInput = Read-Host "  Model name [$lastModel]"
        $FoundryModelName = if ([string]::IsNullOrWhiteSpace($modelInput)) { $lastModel } else { $modelInput.Trim() }
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
    Write-Host "  Enable Foundry : $EnableFoundry$(if ($EnableFoundry) { " (model: $FoundryModelName)" })"
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
    if ([string]::IsNullOrEmpty($ResourceGroup)) { $ResourceGroup = Get-LastValue 'ResourceGroup' 'rg-openclaw' }
    if ([string]::IsNullOrEmpty($AdminUsername)) { $AdminUsername = Get-LastValue 'AdminUsername' 'azureclaw' }
    if ([string]::IsNullOrEmpty($FoundryModelName)) { $FoundryModelName = Get-LastValue 'FoundryModelName' 'gpt-4.1' }
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
    EnableFoundry     = $EnableFoundry.ToString().ToLower()
    FoundryModelName  = $FoundryModelName
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
Write-Host "  Enable Foundry : $EnableFoundry$(if ($EnableFoundry) { " (model: $FoundryModelName)" })"
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
    enableFoundry=$($EnableFoundry.ToString().ToLower()) `
    foundryModelName=$(if ($EnableFoundry -and $FoundryModelName) { $FoundryModelName } else { 'gpt-4.1' }) `
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

## 三、设备配对

首次通过浏览器连接 Gateway 时，需要进行设备配对：

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

## 四、清理资源

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

## 三、设备配对

首次通过浏览器连接 Gateway 时，需要进行设备配对：

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

## 四、清理资源

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

## 三、设备配对

首次通过浏览器连接 Gateway 时，需要进行设备配对：

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

## 四、清理资源

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

## 三、设备配对

首次通过浏览器连接 Gateway 时，需要进行设备配对：

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

# ============================================================
# Optional: Configure Microsoft Foundry models
# ============================================================

$configureFoundry = $false

if ($EnableFoundry) {
    Write-Host ""
    Write-Host "  [INFO] Foundry resource and model '$FoundryModelName' were provisioned during Bicep deployment." -ForegroundColor Green
    Write-Host "  The install script has auto-configured OpenClaw with the deployed model." -ForegroundColor Green
    Write-Host "  To add more models later, run: scripts/setup-foundry-model.ps1" -ForegroundColor Gray
    $configureFoundry = $true
}
elseif ($isInteractive) {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  AI Model Configuration"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "  Configure Azure OpenAI / Microsoft Foundry models for OpenClaw?"
    Write-Host "  You can also configure later via: scripts/setup-foundry-model.ps1"
    Write-Host ""
    Write-Host "    [1] Select existing Azure AI resource  (auto-detect endpoint, key, models)"
    Write-Host "    [2] Create new Foundry resource         (provision resource + deploy models)"
    Write-Host "    [3] Manual input                        (provide endpoint, key, models)"
    Write-Host "    [S] Skip"
    Write-Host ""

    $foundryMode = ''
    while ($true) {
        $foundryInput = Read-Host "  Choice [S]"
        if ([string]::IsNullOrWhiteSpace($foundryInput) -or $foundryInput -match '^[Ss]$') {
            $foundryMode = 'skip'; break
        }
        if ($foundryInput -in @('1', '2', '3')) {
            $foundryMode = $foundryInput; break
        }
        Write-Host "  Invalid choice. Enter 1, 2, 3, or S." -ForegroundColor Yellow
    }

    # =========================================================
    # Mode 1: Select existing Azure AI resource
    # =========================================================
    if ($foundryMode -eq '1') {
        Write-Host ""
        Write-Log 'Querying Azure AI resources in current subscription...' 'STEP'

        $aiResources = az cognitiveservices account list `
            --query "[?kind=='AIServices' || kind=='OpenAI'].{name:name, kind:kind, location:location, rg:resourceGroup, endpoint:properties.endpoints.\"OpenAI Language Model Instance API\"}" `
            --output json 2>&1 | ConvertFrom-Json

        if (-not $aiResources -or $aiResources.Count -eq 0) {
            Write-Host "  No Azure AI / OpenAI resources found in this subscription." -ForegroundColor Yellow
            Write-Host "  Choose option [2] to create a new resource, or [3] for manual input." -ForegroundColor Yellow
        }
        else {
            $resNames = $aiResources | ForEach-Object { $_.name }
            $resDescs = $aiResources | ForEach-Object { "($($_.kind), $($_.location), rg=$($_.rg))" }

            $selectedResName = Read-Choice -Prompt "  Select Azure AI resource:" `
                -Options $resNames -Descriptions $resDescs -Default 1
            $selectedRes = $aiResources | Where-Object { $_.name -eq $selectedResName } | Select-Object -First 1

            Write-Host ""
            Write-Log "Selected: $($selectedRes.name) ($($selectedRes.kind), $($selectedRes.location))" 'INFO'

            # Get API key
            Write-Log 'Retrieving API key...' 'STEP'
            $keys = az cognitiveservices account keys list `
                --name $selectedRes.name `
                --resource-group $selectedRes.rg `
                --output json 2>&1 | ConvertFrom-Json

            $foundryApiKey = $keys.key1
            $foundryEndpoint = $selectedRes.endpoint
            if (-not $foundryEndpoint) {
                # Fallback: construct from resource name
                $foundryEndpoint = "https://$($selectedRes.name).openai.azure.com/"
            }
            $foundryEndpoint = Normalize-FoundryEndpoint $foundryEndpoint

            Write-Log "Endpoint: $foundryEndpoint" 'INFO'
            Write-Log 'API key retrieved.' 'INFO'

            # List deployed models
            Write-Log 'Querying deployed models...' 'STEP'
            $deployments = az cognitiveservices account deployment list `
                --name $selectedRes.name `
                --resource-group $selectedRes.rg `
                --query "[].{deployment:name, model:properties.model.name, sku:sku.name}" `
                --output json 2>&1 | ConvertFrom-Json

            if (-not $deployments -or $deployments.Count -eq 0) {
                Write-Host "  No model deployments found on this resource." -ForegroundColor Yellow
                Write-Host "  Deploy models in the Foundry portal first, or choose option [2]." -ForegroundColor Yellow
            }
            else {
                $modelNames = $deployments | ForEach-Object { $_.deployment }
                $modelDescs = $deployments | ForEach-Object { "(model=$($_.model), sku=$($_.sku))" }

                $selectedModels = Read-MultiChoice -Prompt "  Select models to configure:" `
                    -Options $modelNames -Descriptions $modelDescs

                Write-Host ""
                Write-Host "  Endpoint: $foundryEndpoint" -ForegroundColor Cyan
                Write-Host "  Models:   $($selectedModels -join ', ')" -ForegroundColor Cyan
                Write-Host ""

                Write-Log 'Deploying Foundry configuration to VM...' 'STEP'
                try {
                    $result = Deploy-FoundryConfigToVM `
                        -Endpoint $foundryEndpoint `
                        -ApiKey $foundryApiKey `
                        -Models $selectedModels `
                        -VmResourceGroup $ResourceGroup `
                        -VmName $vmName `
                        -AdminUsername $deployedAdminUsername

                    if ($result -match 'OK:') {
                        Write-Host "  [OK] $($result -split "`n" | Select-String 'OK:' | Select-Object -First 1)" -ForegroundColor Green
                        Write-Host "  $($result -split "`n" | Select-String 'Gateway:' | Select-Object -First 1)" -ForegroundColor Green
                        $configureFoundry = $true

                        # Save to .env
                        $envFile = Join-Path $logDir '.env'
                        Add-Content -Path $envFile -Value "FOUNDRY_ENDPOINT=$foundryEndpoint"
                        Add-Content -Path $envFile -Value "FOUNDRY_MODELS=$($selectedModels -join ',')"
                        Add-Content -Path $envFile -Value "FOUNDRY_DEFAULT_MODEL=azure-openai/$($selectedModels[0])"
                    }
                    else {
                        Write-Host "  [WARN] Configuration may have failed:" -ForegroundColor Yellow
                        Write-Host "  $result" -ForegroundColor Gray
                    }
                }
                catch {
                    Write-Host "  [WARN] Failed: $_" -ForegroundColor Yellow
                }
            }
        }
    }

    # =========================================================
    # Mode 2: Create new Foundry resource
    # =========================================================
    elseif ($foundryMode -eq '2') {
        Write-Host ""
        Write-Log 'Creating new Microsoft Foundry resource...' 'STEP'

        # Resource name
        $uniqueSuffix = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
        $defaultResName = "openclaw-ai-$uniqueSuffix"
        $resNameInput = Read-Host "  Resource name [$defaultResName]"
        $foundryResName = if ([string]::IsNullOrWhiteSpace($resNameInput)) { $defaultResName } else { $resNameInput.Trim() }

        # Resource group (reuse deployment RG or create new)
        $foundryRg = $ResourceGroup
        Write-Host "  Resource group: $foundryRg (same as VM)"

        # Location — pick from regions with AI services, or use VM's location
        $foundryLocation = $Location
        Write-Host "  Location: $foundryLocation (same as VM)"
        Write-Host ""
        Write-Host "  Note: Not all models are available in every region."
        Write-Host "  If model deployment fails, try 'eastus', 'eastus2', or 'westus2'."
        $locInput = Read-Host "  Use different location? (enter region or press Enter to keep $foundryLocation)"
        if (-not [string]::IsNullOrWhiteSpace($locInput)) { $foundryLocation = $locInput.Trim() }

        Write-Host ""
        Write-Log "Creating Foundry resource '$foundryResName' in '$foundryLocation'..." 'STEP'

        # Create the AI Services resource
        az cognitiveservices account create `
            --name $foundryResName `
            --resource-group $foundryRg `
            --kind AIServices `
            --sku s0 `
            --location $foundryLocation `
            --allow-project-management `
            --output none 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [ERROR] Failed to create Foundry resource." -ForegroundColor Red
            Write-Host "  You can configure later via: scripts/setup-foundry-model.ps1" -ForegroundColor Yellow
        }
        else {
            # Set custom domain (required for OpenAI endpoint)
            Write-Log "Setting custom domain '$foundryResName'..." 'STEP'
            az cognitiveservices account update `
                --name $foundryResName `
                --resource-group $foundryRg `
                --custom-domain $foundryResName `
                --output none 2>&1

            Write-Log 'Foundry resource created successfully.' 'INFO'

            # Get endpoint and key
            $newRes = az cognitiveservices account show `
                --name $foundryResName `
                --resource-group $foundryRg `
                --query "{endpoint:properties.endpoints.\"OpenAI Language Model Instance API\"}" `
                --output json 2>&1 | ConvertFrom-Json

            $keys = az cognitiveservices account keys list `
                --name $foundryResName `
                --resource-group $foundryRg `
                --output json 2>&1 | ConvertFrom-Json

            $foundryEndpoint = Normalize-FoundryEndpoint ($newRes.endpoint ?? "https://${foundryResName}.openai.azure.com/")
            $foundryApiKey = $keys.key1

            Write-Log "Endpoint: $foundryEndpoint" 'INFO'
            Write-Log 'API key retrieved.' 'INFO'

            # List available models for deployment
            Write-Host ""
            Write-Log 'Querying available models for deployment...' 'STEP'

            $availableModels = az cognitiveservices account list-models `
                --name $foundryResName `
                --resource-group $foundryRg `
                --output json 2>&1 | ConvertFrom-Json

            # Filter to chat completion models with GlobalStandard SKU
            $chatModels = @()
            foreach ($m in $availableModels) {
                if ($m.format -ne 'OpenAI') { continue }
                $caps = $m.capabilities
                if (-not $caps -or $caps.chatCompletion -ne 'true') { continue }
                $hasGlobalStandard = ($m.skus | Where-Object { $_.name -match 'GlobalStandard|Standard' }) -ne $null
                if (-not $hasGlobalStandard) { continue }
                # Prefer latest version of each model name
                $existing = $chatModels | Where-Object { $_.name -eq $m.name }
                if ($existing) {
                    # Keep newer version
                    if ($m.version -gt $existing.version) {
                        $chatModels = @($chatModels | Where-Object { $_.name -ne $m.name }) + @($m)
                    }
                }
                else {
                    $chatModels += $m
                }
            }

            # Suggest popular models first
            $popularNames = @('gpt-4.1', 'gpt-4.1-mini', 'gpt-5.1-chat', 'gpt-5.4-mini', 'gpt-5', 'o4-mini')
            $sortedModels = @()
            foreach ($pn in $popularNames) {
                $match = $chatModels | Where-Object { $_.name -eq $pn }
                if ($match) { $sortedModels += $match }
            }
            # Add remaining
            foreach ($cm in $chatModels) {
                if ($cm.name -notin $popularNames) { $sortedModels += $cm }
            }

            if ($sortedModels.Count -eq 0) {
                Write-Host "  No deployable chat models found in this region." -ForegroundColor Yellow
            }
            else {
                $modelNames = $sortedModels | ForEach-Object { $_.name }
                $modelDescs = $sortedModels | ForEach-Object { "(v$($_.version))" }

                $selectedModels = Read-MultiChoice -Prompt "  Select models to deploy:" `
                    -Options $modelNames -Descriptions $modelDescs

                Write-Host ""
                $deployedModels = @()

                foreach ($modelName in $selectedModels) {
                    $modelInfo = $sortedModels | Where-Object { $_.name -eq $modelName } | Select-Object -First 1
                    $skuName = 'GlobalStandard'
                    $hasSku = $modelInfo.skus | Where-Object { $_.name -eq 'GlobalStandard' }
                    if (-not $hasSku) {
                        $skuName = ($modelInfo.skus | Select-Object -First 1).name
                    }

                    Write-Log "Deploying model '$modelName' (sku=$skuName)..." 'STEP'
                    az cognitiveservices account deployment create `
                        --name $foundryResName `
                        --resource-group $foundryRg `
                        --deployment-name $modelName `
                        --model-name $modelName `
                        --model-version $modelInfo.version `
                        --model-format OpenAI `
                        --sku-capacity 10 `
                        --sku-name $skuName `
                        --output none 2>&1

                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  [OK] $modelName deployed." -ForegroundColor Green
                        $deployedModels += $modelName
                    }
                    else {
                        Write-Host "  [WARN] Failed to deploy $modelName (may not be available in $foundryLocation)." -ForegroundColor Yellow
                    }
                }

                if ($deployedModels.Count -gt 0) {
                    Write-Host ""
                    Write-Log 'Configuring deployed models on VM...' 'STEP'
                    try {
                        $result = Deploy-FoundryConfigToVM `
                            -Endpoint $foundryEndpoint `
                            -ApiKey $foundryApiKey `
                            -Models $deployedModels `
                            -VmResourceGroup $ResourceGroup `
                            -VmName $vmName `
                            -AdminUsername $deployedAdminUsername

                        if ($result -match 'OK:') {
                            Write-Host "  [OK] $($result -split "`n" | Select-String 'OK:' | Select-Object -First 1)" -ForegroundColor Green
                            Write-Host "  $($result -split "`n" | Select-String 'Gateway:' | Select-Object -First 1)" -ForegroundColor Green
                            $configureFoundry = $true

                            $envFile = Join-Path $logDir '.env'
                            Add-Content -Path $envFile -Value "FOUNDRY_RESOURCE=$foundryResName"
                            Add-Content -Path $envFile -Value "FOUNDRY_RESOURCE_GROUP=$foundryRg"
                            Add-Content -Path $envFile -Value "FOUNDRY_ENDPOINT=$foundryEndpoint"
                            Add-Content -Path $envFile -Value "FOUNDRY_MODELS=$($deployedModels -join ',')"
                            Add-Content -Path $envFile -Value "FOUNDRY_DEFAULT_MODEL=azure-openai/$($deployedModels[0])"
                        }
                        else {
                            Write-Host "  [WARN] VM configuration may have failed:" -ForegroundColor Yellow
                            Write-Host "  $result" -ForegroundColor Gray
                        }
                    }
                    catch {
                        Write-Host "  [WARN] Failed to configure VM: $_" -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host "  No models were deployed successfully." -ForegroundColor Yellow
                }
            }
        }
    }

    # =========================================================
    # Mode 3: Manual input (original flow)
    # =========================================================
    elseif ($foundryMode -eq '3') {
        Write-Host ""
        $foundryEndpoint = Read-Host "  Foundry Endpoint URL (e.g. https://xxx.openai.azure.com)"

        if (-not [string]::IsNullOrWhiteSpace($foundryEndpoint)) {
            $foundryEndpoint = Normalize-FoundryEndpoint $foundryEndpoint

            $foundryApiKey = Read-Host "  API Key"
            if (-not [string]::IsNullOrWhiteSpace($foundryApiKey)) {
                Write-Host ""
                Write-Host "  Enter model deployment names (comma-separated)."
                Write-Host "  Common models: gpt-4.1, gpt-4.1-mini, gpt-5.1-chat, DeepSeek-V3.2"
                $modelInput = Read-Host "  Models"

                if (-not [string]::IsNullOrWhiteSpace($modelInput)) {
                    $foundryModels = $modelInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                    if ($foundryModels.Count -gt 0) {
                        Write-Host ""
                        Write-Host "  Endpoint: $foundryEndpoint" -ForegroundColor Cyan
                        Write-Host "  Models:   $($foundryModels -join ', ')" -ForegroundColor Cyan
                        Write-Host ""

                        Write-Log 'Deploying Foundry configuration to VM...' 'STEP'
                        try {
                            $result = Deploy-FoundryConfigToVM `
                                -Endpoint $foundryEndpoint `
                                -ApiKey $foundryApiKey `
                                -Models $foundryModels `
                                -VmResourceGroup $ResourceGroup `
                                -VmName $vmName `
                                -AdminUsername $deployedAdminUsername

                            if ($result -match 'OK:') {
                                Write-Host "  [OK] $($result -split "`n" | Select-String 'OK:' | Select-Object -First 1)" -ForegroundColor Green
                                Write-Host "  $($result -split "`n" | Select-String 'Gateway:' | Select-Object -First 1)" -ForegroundColor Green
                                $configureFoundry = $true

                                $envFile = Join-Path $logDir '.env'
                                Add-Content -Path $envFile -Value "FOUNDRY_ENDPOINT=$foundryEndpoint"
                                Add-Content -Path $envFile -Value "FOUNDRY_MODELS=$($foundryModels -join ',')"
                                Add-Content -Path $envFile -Value "FOUNDRY_DEFAULT_MODEL=azure-openai/$($foundryModels[0])"
                            }
                            else {
                                Write-Host "  [WARN] Configuration may have failed:" -ForegroundColor Yellow
                                Write-Host "  $result" -ForegroundColor Gray
                            }
                        }
                        catch {
                            Write-Host "  [WARN] Failed: $_" -ForegroundColor Yellow
                        }
                    }
                }
            }
        }

        if (-not $configureFoundry) {
            Write-Host "  Skipped. Configure later via: scripts/setup-foundry-model.ps1" -ForegroundColor Gray
        }
    }

    if ($configureFoundry) {
        Write-Host ""
        Write-Host "  AI model configuration complete." -ForegroundColor Green
    }
}

# Stop transcript
Stop-Transcript | Out-Null
