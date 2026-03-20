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

# Check if resource group exists
$exists = az group exists --name $ResourceGroup 2>&1
if ($exists -ne 'true') {
    Write-Host "[INFO] Resource group '$ResourceGroup' does not exist. Nothing to clean up."
    return
}

# Confirmation prompt
if (-not $Force) {
    Write-Host ""
    Write-Host "WARNING: This will permanently delete resource group '$ResourceGroup' and ALL resources within it."
    Write-Host ""
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Host "[INFO] Cancelled."
        return
    }
}

Write-Host "[INFO] Deleting resource group '$ResourceGroup'..."
az group delete --name $ResourceGroup --yes --no-wait
Write-Host "[INFO] Deletion initiated. The resource group will be removed in the background."
Write-Host "[INFO] You can check status with: az group show --name $ResourceGroup"
