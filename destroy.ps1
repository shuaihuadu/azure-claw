<#
.SYNOPSIS
    Delete the OpenClaw resource group and all its resources.

.PARAMETER ResourceGroup
    Resource group name. Default: rg-openclaw

.PARAMETER Force
    Skip confirmation prompt.
#>

param(
    [string]$ResourceGroup = 'rg-openclaw',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Load shared functions
. "$PSScriptRoot/scripts/shared-functions.ps1"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts] [$Level] $Message"
}

# Check Azure CLI login
Write-Log 'Checking Azure CLI login status...'
az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Log 'Not logged in. Running az login...'
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure CLI login failed."
    }
}

# Check if resource group exists
Write-Log "Checking resource group '$ResourceGroup'..."
$exists = az group exists --name $ResourceGroup 2>&1
if ($exists -ne 'true') {
    Write-Log "Resource group '$ResourceGroup' does not exist. Nothing to clean up."
    return
}

# Confirmation prompt
if (-not $Force) {
    Write-Host ""
    Write-Host "WARNING: This will permanently delete resource group '$ResourceGroup' and ALL resources within it."
    Write-Host ""
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Log 'Cancelled.'
        return
    }
}

Write-Log "Deleting resource group '$ResourceGroup'..."
az group delete --name $ResourceGroup --yes --no-wait
Write-Log "Deletion initiated. The resource group will be removed in the background."

# Purge soft-deleted AI Services to prevent subdomain conflicts on re-deploy
Write-Log "Checking for soft-deleted AI Services resources to purge..."
$purged = Purge-SoftDeletedAIResource -NamePrefix 'openclaw-ai-'
if (-not $purged) {
    Write-Log "No soft-deleted AI resources found (or none matching 'openclaw-ai-*')." 'INFO'
}

Write-Host "[INFO] You can check status with: az group show --name $ResourceGroup"
