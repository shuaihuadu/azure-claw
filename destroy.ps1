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

# First, purge any already soft-deleted AI resources from previous deletions
Write-Log "Purging any previously soft-deleted AI Services resources..."
Purge-SoftDeletedAIResource -NamePrefix 'openclaw-ai-' | Out-Null

# List AI Services accounts in the RG before deletion (for purge after)
$aiAccounts = az cognitiveservices account list --resource-group $ResourceGroup --query "[?starts_with(name, 'openclaw-ai-')].{name:name, location:location}" --output json 2>&1 | ConvertFrom-Json
$hasAiAccounts = ($aiAccounts -and @($aiAccounts).Count -gt 0)

# Delete the resource group (synchronous to ensure AI resources enter soft-deleted state)
if ($hasAiAccounts) {
    Write-Log "Found AI Services account(s) in '$ResourceGroup'. Deleting synchronously to enable purge..." 'INFO'
    az group delete --name $ResourceGroup --yes
    Write-Log "Resource group deleted." 'INFO'

    # Now purge the soft-deleted AI resources
    Write-Log "Purging soft-deleted AI Services resources..."
    Start-Sleep -Seconds 5
    $purged = Purge-SoftDeletedAIResource -NamePrefix 'openclaw-ai-'
    if ($purged) {
        Write-Log "AI resources purged. Re-deploy will not hit subdomain conflicts." 'INFO'
    }
    else {
        Write-Host "[WARN] Could not purge AI resources. If re-deploying within 48h, run:" -ForegroundColor Yellow
        Write-Host "  az cognitiveservices account list-deleted --output table" -ForegroundColor Yellow
        Write-Host "  az cognitiveservices account purge --name <name> --resource-group $ResourceGroup --location <location>" -ForegroundColor Yellow
    }
}
else {
    az group delete --name $ResourceGroup --yes --no-wait
    Write-Log "Deletion initiated. The resource group will be removed in the background."
}

Write-Host "[INFO] You can check status with: az group show --name $ResourceGroup"
