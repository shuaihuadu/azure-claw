<#
.SYNOPSIS
    Configure Microsoft Foundry (Azure OpenAI) models on an OpenClaw VM.
    Standalone tool — can be run independently from deploy.ps1.

.DESCRIPTION
    Three configuration modes:
      [1] Select existing Azure AI resource (auto-detect endpoint, key, models)
      [2] Create new Foundry resource       (provision resource + deploy models)
      [3] Manual input                       (provide endpoint, key, models)

    Auto-discovers the target VM and deploys configuration remotely via
    'az vm run-command invoke'.

.PARAMETER ResourceGroup
    Resource group containing the VM. Auto-detected if not specified.

.PARAMETER VmName
    Name of the target VM. Default: openclaw-vm

.PARAMETER AdminUsername
    VM admin username. Auto-detected from VM metadata if not specified.

.EXAMPLE
    .\setup-foundry-model.ps1
    # Interactive: auto-discovers VM, walks through configuration

.EXAMPLE
    .\setup-foundry-model.ps1 -ResourceGroup rg-openclaw
    # Specify resource group explicitly
#>

param(
    [string]$ResourceGroup,
    [string]$VmName = 'openclaw-vm',
    [string]$AdminUsername
)

$ErrorActionPreference = 'Stop'

# Load shared functions
. "$PSScriptRoot/shared-functions.ps1"

Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host '  OpenClaw — Foundry Model Configuration' -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host ''

# ============================================================
# 1. Ensure Azure CLI login
# ============================================================

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host '  Not logged in to Azure CLI. Running az login...' -ForegroundColor Yellow
    az login --output none
    $account = az account show --output json | ConvertFrom-Json
}
Write-Host "  Subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan

# ============================================================
# 2. Discover target VM
# ============================================================

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    Write-Host ''
    Write-Host '  Searching for OpenClaw VMs...' -ForegroundColor Cyan

    $vms = az vm list --query "[?name=='$VmName'].{name:name, rg:resourceGroup, location:location}" `
        --output json 2>$null | ConvertFrom-Json

    if (-not $vms -or $vms.Count -eq 0) {
        Write-Host "  No VM named '$VmName' found in this subscription." -ForegroundColor Red
        Write-Host "  Specify -ResourceGroup explicitly, or deploy first with deploy.ps1." -ForegroundColor Yellow
        exit 1
    }
    elseif ($vms.Count -eq 1) {
        $ResourceGroup = $vms[0].rg
        Write-Host "  Found VM '$VmName' in resource group '$ResourceGroup'." -ForegroundColor Green
    }
    else {
        $rgNames = $vms | ForEach-Object { $_.rg }
        $rgDescs = $vms | ForEach-Object { "($($_.location))" }
        $ResourceGroup = Read-Choice -Prompt "  Multiple VMs found. Select resource group:" `
            -Options $rgNames -Descriptions $rgDescs -Default 1
    }
}
else {
    # Verify VM exists
    $vmCheck = az vm show --resource-group $ResourceGroup --name $VmName `
        --query "name" --output tsv 2>$null
    if (-not $vmCheck) {
        Write-Host "  VM '$VmName' not found in resource group '$ResourceGroup'." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Target VM: $VmName (rg=$ResourceGroup)" -ForegroundColor Cyan
}

# ============================================================
# 3. Detect admin username
# ============================================================

if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
    $AdminUsername = az vm show --resource-group $ResourceGroup --name $VmName `
        --query "osProfile.adminUsername" --output tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
        $AdminUsername = 'azureclaw'
    }
}
Write-Host "  Admin user: $AdminUsername" -ForegroundColor Cyan

# ============================================================
# 4. Select configuration mode
# ============================================================

Write-Host ''
Write-Host '  Configure Azure OpenAI / Microsoft Foundry models for OpenClaw.'
Write-Host ''
Write-Host '    [1] Select existing Azure AI resource  (auto-detect endpoint, key, models)'
Write-Host '    [2] Create new Foundry resource         (provision resource + deploy models)'
Write-Host '    [3] Manual input                        (provide endpoint, key, models)'
Write-Host '    [Q] Quit'
Write-Host ''

$foundryMode = ''
while ($true) {
    $input = Read-Host '  Choice'
    if ($input -match '^[Qq]$') { Write-Host '  Cancelled.' -ForegroundColor Gray; exit 0 }
    if ($input -in @('1', '2', '3')) { $foundryMode = $input; break }
    Write-Host '  Invalid choice. Enter 1, 2, 3, or Q.' -ForegroundColor Yellow
}

$configSuccess = $false

# =========================================================
# Mode 1: Select existing Azure AI resource
# =========================================================
if ($foundryMode -eq '1') {
    Write-Host ''
    Write-Host '  Querying Azure AI resources...' -ForegroundColor Cyan

    $aiResources = az cognitiveservices account list `
        --query "[?kind=='AIServices' || kind=='OpenAI'].{name:name, kind:kind, location:location, rg:resourceGroup, endpoint:properties.endpoints.\"OpenAI Language Model Instance API\"}" `
        --output json 2>&1 | ConvertFrom-Json

    if (-not $aiResources -or $aiResources.Count -eq 0) {
        Write-Host '  No Azure AI / OpenAI resources found.' -ForegroundColor Yellow
        Write-Host '  Choose option [2] to create one, or [3] for manual input.' -ForegroundColor Yellow
        exit 1
    }

    $resNames = $aiResources | ForEach-Object { $_.name }
    $resDescs = $aiResources | ForEach-Object { "($($_.kind), $($_.location), rg=$($_.rg))" }

    $selectedResName = Read-Choice -Prompt '  Select Azure AI resource:' `
        -Options $resNames -Descriptions $resDescs -Default 1
    $selectedRes = $aiResources | Where-Object { $_.name -eq $selectedResName } | Select-Object -First 1

    Write-Host ''
    Write-Host "  Selected: $($selectedRes.name) ($($selectedRes.kind), $($selectedRes.location))" -ForegroundColor Cyan

    # Get API key
    Write-Host '  Retrieving API key...' -ForegroundColor Cyan
    $keys = az cognitiveservices account keys list `
        --name $selectedRes.name `
        --resource-group $selectedRes.rg `
        --output json 2>&1 | ConvertFrom-Json

    $foundryApiKey = $keys.key1
    $foundryEndpoint = $selectedRes.endpoint
    if (-not $foundryEndpoint) {
        $foundryEndpoint = "https://$($selectedRes.name).openai.azure.com/"
    }
    $foundryEndpoint = Normalize-FoundryEndpoint $foundryEndpoint

    Write-Host "  Endpoint: $foundryEndpoint" -ForegroundColor Cyan

    # List deployed models
    Write-Host '  Querying deployed models...' -ForegroundColor Cyan
    $deployments = az cognitiveservices account deployment list `
        --name $selectedRes.name `
        --resource-group $selectedRes.rg `
        --query "[].{deployment:name, model:properties.model.name, sku:sku.name}" `
        --output json 2>&1 | ConvertFrom-Json

    if (-not $deployments -or $deployments.Count -eq 0) {
        Write-Host '  No model deployments found.' -ForegroundColor Yellow
        Write-Host '  Deploy models in the Foundry portal first, or use option [2].' -ForegroundColor Yellow
        exit 1
    }

    $modelNames = $deployments | ForEach-Object { $_.deployment }
    $modelDescs = $deployments | ForEach-Object { "(model=$($_.model), sku=$($_.sku))" }

    $selectedModels = Read-MultiChoice -Prompt '  Select models to configure:' `
        -Options $modelNames -Descriptions $modelDescs

    Write-Host ''
    Write-Host "  Endpoint: $foundryEndpoint" -ForegroundColor Cyan
    Write-Host "  Models:   $($selectedModels -join ', ')" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Deploying configuration to VM...' -ForegroundColor Cyan

    $result = Deploy-FoundryConfigToVM `
        -Endpoint $foundryEndpoint `
        -ApiKey $foundryApiKey `
        -Models $selectedModels `
        -VmResourceGroup $ResourceGroup `
        -VmName $VmName `
        -AdminUsername $AdminUsername

    if ($result -match 'OK:') {
        Write-Host "  [OK] $($result -split "`n" | Select-String 'OK:' | Select-Object -First 1)" -ForegroundColor Green
        Write-Host "  $($result -split "`n" | Select-String 'Gateway:' | Select-Object -First 1)" -ForegroundColor Green
        $configSuccess = $true
    }
    else {
        Write-Host '  [WARN] Configuration may have failed:' -ForegroundColor Yellow
        Write-Host "  $result" -ForegroundColor Gray
    }
}

# =========================================================
# Mode 2: Create new Foundry resource
# =========================================================
elseif ($foundryMode -eq '2') {
    Write-Host ''

    # Resource name
    $uniqueSuffix = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    $defaultResName = "openclaw-ai-$uniqueSuffix"
    $resNameInput = Read-Host "  Resource name [$defaultResName]"
    $foundryResName = if ([string]::IsNullOrWhiteSpace($resNameInput)) { $defaultResName } else { $resNameInput.Trim() }

    # Resource group (reuse VM's RG)
    $foundryRg = $ResourceGroup
    Write-Host "  Resource group: $foundryRg (same as VM)"

    # Location
    $vmLocation = az vm show --resource-group $ResourceGroup --name $VmName `
        --query "location" --output tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($vmLocation)) { $vmLocation = 'eastus' }
    $foundryLocation = $vmLocation
    Write-Host "  Location: $foundryLocation (same as VM)"
    Write-Host ''
    Write-Host '  Note: Not all models are available in every region.'
    Write-Host "  If model deployment fails, try 'eastus', 'eastus2', or 'westus2'."
    $locInput = Read-Host "  Use different location? (enter region or press Enter to keep $foundryLocation)"
    if (-not [string]::IsNullOrWhiteSpace($locInput)) { $foundryLocation = $locInput.Trim() }

    Write-Host ''
    Write-Host "  Creating Foundry resource '$foundryResName' in '$foundryLocation'..." -ForegroundColor Cyan

    az cognitiveservices account create `
        --name $foundryResName `
        --resource-group $foundryRg `
        --kind AIServices `
        --sku s0 `
        --location $foundryLocation `
        --allow-project-management `
        --output none 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host '  [ERROR] Failed to create Foundry resource.' -ForegroundColor Red
        exit 1
    }

    # Set custom domain
    Write-Host "  Setting custom domain '$foundryResName'..." -ForegroundColor Cyan
    az cognitiveservices account update `
        --name $foundryResName `
        --resource-group $foundryRg `
        --custom-domain $foundryResName `
        --output none 2>&1

    Write-Host '  Foundry resource created.' -ForegroundColor Green

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

    Write-Host "  Endpoint: $foundryEndpoint" -ForegroundColor Cyan

    # List available models
    Write-Host '  Querying available models for deployment...' -ForegroundColor Cyan

    $availableModels = az cognitiveservices account list-models `
        --name $foundryResName `
        --resource-group $foundryRg `
        --output json 2>&1 | ConvertFrom-Json

    # Filter to chat completion models with GlobalStandard/Standard SKU
    $chatModels = @()
    foreach ($m in $availableModels) {
        if ($m.format -ne 'OpenAI') { continue }
        $caps = $m.capabilities
        if (-not $caps -or $caps.chatCompletion -ne 'true') { continue }
        $hasGlobalStandard = ($m.skus | Where-Object { $_.name -match 'GlobalStandard|Standard' }) -ne $null
        if (-not $hasGlobalStandard) { continue }
        $existing = $chatModels | Where-Object { $_.name -eq $m.name }
        if ($existing) {
            if ($m.version -gt $existing.version) {
                $chatModels = @($chatModels | Where-Object { $_.name -ne $m.name }) + @($m)
            }
        }
        else {
            $chatModels += $m
        }
    }

    # Sort: popular models first
    $popularNames = @('gpt-4.1', 'gpt-4.1-mini', 'gpt-5.1-chat', 'gpt-5.4-mini', 'gpt-5', 'o4-mini')
    $sortedModels = @()
    foreach ($pn in $popularNames) {
        $match = $chatModels | Where-Object { $_.name -eq $pn }
        if ($match) { $sortedModels += $match }
    }
    foreach ($cm in $chatModels) {
        if ($cm.name -notin $popularNames) { $sortedModels += $cm }
    }

    if ($sortedModels.Count -eq 0) {
        Write-Host '  No deployable chat models found in this region.' -ForegroundColor Yellow
        exit 1
    }

    $modelNames = $sortedModels | ForEach-Object { $_.name }
    $modelDescs = $sortedModels | ForEach-Object { "(v$($_.version))" }

    $selectedModels = Read-MultiChoice -Prompt '  Select models to deploy:' `
        -Options $modelNames -Descriptions $modelDescs

    Write-Host ''
    $deployedModels = @()

    foreach ($modelName in $selectedModels) {
        $modelInfo = $sortedModels | Where-Object { $_.name -eq $modelName } | Select-Object -First 1
        $skuName = 'GlobalStandard'
        $hasSku = $modelInfo.skus | Where-Object { $_.name -eq 'GlobalStandard' }
        if (-not $hasSku) {
            $skuName = ($modelInfo.skus | Select-Object -First 1).name
        }

        Write-Host "  Deploying '$modelName' (sku=$skuName)..." -ForegroundColor Cyan
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
        Write-Host ''
        Write-Host '  Configuring deployed models on VM...' -ForegroundColor Cyan

        $result = Deploy-FoundryConfigToVM `
            -Endpoint $foundryEndpoint `
            -ApiKey $foundryApiKey `
            -Models $deployedModels `
            -VmResourceGroup $ResourceGroup `
            -VmName $VmName `
            -AdminUsername $AdminUsername

        if ($result -match 'OK:') {
            Write-Host "  [OK] $($result -split "`n" | Select-String 'OK:' | Select-Object -First 1)" -ForegroundColor Green
            Write-Host "  $($result -split "`n" | Select-String 'Gateway:' | Select-Object -First 1)" -ForegroundColor Green
            $configSuccess = $true
        }
        else {
            Write-Host '  [WARN] VM configuration may have failed:' -ForegroundColor Yellow
            Write-Host "  $result" -ForegroundColor Gray
        }
    }
    else {
        Write-Host '  No models were deployed successfully.' -ForegroundColor Yellow
    }
}

# =========================================================
# Mode 3: Manual input
# =========================================================
elseif ($foundryMode -eq '3') {
    Write-Host ''
    $foundryEndpoint = Read-Host '  Foundry Endpoint URL (e.g. https://xxx.openai.azure.com)'

    if ([string]::IsNullOrWhiteSpace($foundryEndpoint)) {
        Write-Host '  Cancelled.' -ForegroundColor Gray
        exit 0
    }

    $foundryEndpoint = Normalize-FoundryEndpoint $foundryEndpoint

    $foundryApiKey = Read-Host '  API Key'
    if ([string]::IsNullOrWhiteSpace($foundryApiKey)) {
        Write-Host '  Cancelled.' -ForegroundColor Gray
        exit 0
    }

    Write-Host ''
    Write-Host '  Enter model deployment names (comma-separated).'
    Write-Host '  Common models: gpt-4.1, gpt-4.1-mini, gpt-5.1-chat, DeepSeek-V3.2'
    $modelInput = Read-Host '  Models'

    if ([string]::IsNullOrWhiteSpace($modelInput)) {
        Write-Host '  Cancelled.' -ForegroundColor Gray
        exit 0
    }

    $foundryModels = $modelInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($foundryModels.Count -eq 0) {
        Write-Host '  No models specified.' -ForegroundColor Yellow
        exit 1
    }

    Write-Host ''
    Write-Host "  Endpoint: $foundryEndpoint" -ForegroundColor Cyan
    Write-Host "  Models:   $($foundryModels -join ', ')" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Deploying configuration to VM...' -ForegroundColor Cyan

    $result = Deploy-FoundryConfigToVM `
        -Endpoint $foundryEndpoint `
        -ApiKey $foundryApiKey `
        -Models $foundryModels `
        -VmResourceGroup $ResourceGroup `
        -VmName $VmName `
        -AdminUsername $AdminUsername

    if ($result -match 'OK:') {
        Write-Host "  [OK] $($result -split "`n" | Select-String 'OK:' | Select-Object -First 1)" -ForegroundColor Green
        Write-Host "  $($result -split "`n" | Select-String 'Gateway:' | Select-Object -First 1)" -ForegroundColor Green
        $configSuccess = $true
    }
    else {
        Write-Host '  [WARN] Configuration may have failed:' -ForegroundColor Yellow
        Write-Host "  $result" -ForegroundColor Gray
    }
}

# ============================================================
# Summary
# ============================================================

Write-Host ''
if ($configSuccess) {
    Write-Host '  Foundry model configuration complete.' -ForegroundColor Green
    Write-Host "  Access: http://<VM_IP>:18789" -ForegroundColor Cyan
}
else {
    Write-Host '  Configuration was not completed.' -ForegroundColor Yellow
    Write-Host '  You can re-run this script to try again.' -ForegroundColor Yellow
}
Write-Host ''
