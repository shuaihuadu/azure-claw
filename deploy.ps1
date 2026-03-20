<#
.SYNOPSIS
    Deploy OpenClaw to Azure VM (Ubuntu 24.04 LTS or Windows 11).

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
#>

param(
    [string]$Location = 'eastasia',
    [string]$VmSize = 'Standard_B2s',
    [ValidateSet('Ubuntu', 'Windows')]
    [string]$OsType = 'Ubuntu',
    [string]$AdminUsername = 'azureclaw',
    [string]$AdminPassword = '',
    [switch]$EnablePublicHttps
)

$ErrorActionPreference = 'Stop'
$ResourceGroup = 'rg-openclaw'
$TemplateFile = Join-Path $PSScriptRoot 'infra' 'main.bicep'
$StartTime = Get-Date

# --- 1. Parameter handling ---

if ([string]::IsNullOrEmpty($AdminPassword)) {
    # Generate a strong random password that meets Azure VM requirements:
    # 12-72 chars, at least 1 uppercase, 1 lowercase, 1 digit, 1 special char
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
    for ($i = 0; $i -lt 8; $i++) {
        $pw += $all[(Get-Random -Maximum $all.Length)]
    }
    $AdminPassword = -join ($pw | Get-Random -Count $pw.Count)
    Write-Host "[INFO] Admin password auto-generated."
}

# Generate gateway password if EnablePublicHttps is set
$GatewayPassword = ''
if ($EnablePublicHttps) {
    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lower = 'abcdefghijklmnopqrstuvwxyz'
    $digits = '0123456789'
    $special = '!@#$%^&*()-_=+'
    $all = $upper + $lower + $digits + $special
    $gpw = @()
    $gpw += $upper[(Get-Random -Maximum $upper.Length)]
    $gpw += $lower[(Get-Random -Maximum $lower.Length)]
    $gpw += $digits[(Get-Random -Maximum $digits.Length)]
    $gpw += $special[(Get-Random -Maximum $special.Length)]
    for ($i = 0; $i -lt 12; $i++) {
        $gpw += $all[(Get-Random -Maximum $all.Length)]
    }
    $GatewayPassword = -join ($gpw | Get-Random -Count $gpw.Count)
    Write-Host "[INFO] Gateway password auto-generated."
}

Write-Host ""
Write-Host "=========================================="
Write-Host "  OpenClaw Azure VM Deployment"
Write-Host "=========================================="
Write-Host "  Location       : $Location"
Write-Host "  OS Type        : $OsType"
Write-Host "  VM Size        : $VmSize"
Write-Host "  Admin Username : $AdminUsername"
Write-Host "  Public HTTPS   : $EnablePublicHttps"
Write-Host "  Resource Group : $ResourceGroup"
Write-Host "=========================================="
Write-Host ""

# --- 2. Check Azure CLI login ---

Write-Host "[STEP 1/5] Checking Azure CLI login status..."
$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Not logged in. Running 'az login'..."
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure CLI login failed."
    }
}
$accountInfo = az account show --output json | ConvertFrom-Json
Write-Host "[INFO] Logged in as: $($accountInfo.user.name) (Subscription: $($accountInfo.name))"

# --- 3. Create resource group ---

Write-Host "[STEP 2/5] Creating resource group '$ResourceGroup' in '$Location'..."
az group create --name $ResourceGroup --location $Location --output none
Write-Host "[INFO] Resource group ready."

# --- 4. Deploy Bicep template ---

Write-Host "[STEP 3/5] Deploying Bicep template (this may take several minutes)..."
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

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Check the Azure Portal for details."
}

# --- 5. Capture deployment outputs ---

$publicIpAddress = $deploymentResult.properties.outputs.publicIpAddress.value
$vmFqdn = $deploymentResult.properties.outputs.fqdn.value
$vmName = $deploymentResult.properties.outputs.vmName.value
$deployedOsType = $deploymentResult.properties.outputs.osType.value
$deployedAdminUsername = $deploymentResult.properties.outputs.adminUsername.value
$deployedEnableHttps = $deploymentResult.properties.outputs.enablePublicHttps.value

Write-Host "[INFO] Deployment succeeded."
Write-Host "[INFO] Public IP: $publicIpAddress"
Write-Host "[INFO] FQDN: $vmFqdn"

# --- 6. Create logs directory ---

Write-Host "[STEP 4/5] Writing deployment logs..."
$timestamp = $StartTime.ToString('yyyyMMddHHmmss')
$logDir = Join-Path $PSScriptRoot 'logs' $timestamp
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# --- 7. Write deploy.log ---

$endTime = Get-Date
$duration = $endTime - $StartTime

$logContent = @"
# OpenClaw Deployment Log
# =======================
# Deployment Time : $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
# Duration        : $($duration.ToString('hh\:mm\:ss'))
# Location        : $Location
# OS Type         : $OsType
# VM Size         : $VmSize
# Admin Username  : $AdminUsername
# Admin Password  : ********
# Public HTTPS    : $EnablePublicHttps
# Gateway Password: ********
# Resource Group  : $ResourceGroup
# Public IP       : $publicIpAddress
# FQDN            : $vmFqdn
# VM Name         : $vmName
# Subscription    : $($accountInfo.name)
# Status          : Succeeded
"@
Set-Content -Path (Join-Path $logDir 'deploy.log') -Value $logContent -Encoding UTF8

# --- 8. Write .env ---

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

# --- 9. Generate guide.md ---

Write-Host "[STEP 5/5] Generating operation guide..."

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
2. 检查服务状态: ``sudo systemctl status openclaw``
3. 运行交互式配置: ``openclaw onboard``
4. 查看日志: ``journalctl -u openclaw -f``

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
2. 打开 PowerShell 运行: ``openclaw doctor``
3. 运行交互式配置: ``openclaw onboard --install-daemon``

## 三、清理资源

``````powershell
.\destroy.ps1
``````
"@
    }
}

Set-Content -Path (Join-Path $logDir 'guide.md') -Value ($guideHeader + $guideBody) -Encoding UTF8

# --- 10. Console summary ---

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
Write-Host "  - deploy.log   : Deployment log (sanitized)"
Write-Host "  - .env         : Credentials & connection info"
Write-Host "  - guide.md     : Operation guide"
Write-Host ""

if ($deployedOsType -eq 'Ubuntu') {
    Write-Host "  Connect: ssh ${deployedAdminUsername}@${publicIpAddress}"
    Write-Host "  Web UI:  http://${publicIpAddress}:18789"
}
else {
    Write-Host "  Connect: mstsc /v:${publicIpAddress}"
    Write-Host "  Web UI:  http://localhost:18789 (after RDP login)"
}

Write-Host ""
