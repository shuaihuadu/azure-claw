<#
.SYNOPSIS
    Add Microsoft Foundry (Azure OpenAI) models to OpenClaw configuration.
    Idempotent: safe to run multiple times with the same or different models.

.PARAMETER Endpoint
    Microsoft Foundry endpoint URL.
    Example: https://my-resource.openai.azure.com/openai/v1

.PARAMETER ApiKey
    API key for the Foundry endpoint.

.PARAMETER ModelName
    One or more model deployment names to add.
    Example: gpt-4.1, gpt-5.1-chat, DeepSeek-V3.2

.PARAMETER ProviderName
    Provider name in OpenClaw config. Default: azure-openai.
    Use a different name if you have multiple Foundry endpoints.

.PARAMETER SetAsDefault
    Set the first model as the default primary model.

.PARAMETER ConfigPath
    Path to openclaw.json. Default: ~/.openclaw/openclaw.json

.PARAMETER DryRun
    Preview changes without writing to disk.

.EXAMPLE
    .\setup-foundry-model.ps1 `
        -Endpoint "https://my-resource.openai.azure.com/openai/v1" `
        -ApiKey "your-api-key" `
        -ModelName gpt-4.1

.EXAMPLE
    .\setup-foundry-model.ps1 `
        -Endpoint "https://my-resource.openai.azure.com/openai/v1" `
        -ApiKey "your-api-key" `
        -ModelName gpt-4.1, gpt-5.1-chat, DeepSeek-V3.2 `
        -SetAsDefault

.EXAMPLE
    .\setup-foundry-model.ps1 `
        -Endpoint "https://second-resource.openai.azure.com/openai/v1" `
        -ApiKey "another-key" `
        -ModelName gpt-5.4-mini `
        -ProviderName azure-openai-2
#>

param(
    [Parameter(Mandatory)]
    [string]$Endpoint,

    [Parameter(Mandatory)]
    [string]$ApiKey,

    [Parameter(Mandatory)]
    [string[]]$ModelName,

    [string]$ProviderName = 'azure-openai',

    [switch]$SetAsDefault,

    [string]$ConfigPath = (Join-Path $HOME '.openclaw' 'openclaw.json'),

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Model knowledge base
# ============================================================

# Known model specs: reasoning capability, input modalities, context window, max output tokens
$KnownModels = @{
    # GPT series
    'gpt-4.1'                 = @{ Reasoning = $false; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'gpt-4.1-mini'            = @{ Reasoning = $false; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'gpt-4.1-nano'            = @{ Reasoning = $false; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'gpt-5.1-chat'            = @{ Reasoning = $true; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'gpt-5.4-mini'            = @{ Reasoning = $true; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    # Grok series
    'grok-3'                  = @{ Reasoning = $false; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'grok-4-1-fast-reasoning' = @{ Reasoning = $true; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    # DeepSeek
    'DeepSeek-V3.2'           = @{ Reasoning = $false; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'DeepSeek-R1'             = @{ Reasoning = $true; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    # Kimi
    'Kimi-K2.5'               = @{ Reasoning = $false; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    # Phi
    'Phi-4-reasoning-plus'    = @{ Reasoning = $true; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'Phi-4'                   = @{ Reasoning = $false; Input = @('text'); Context = 16384; MaxTokens = 4096 }
}

# Default specs for unknown models
$DefaultSpec = @{ Reasoning = $false; Input = @('text'); Context = 131072; MaxTokens = 16384 }

function Get-ModelSpec {
    param([string]$Id)
    if ($KnownModels.ContainsKey($Id)) {
        return $KnownModels[$Id]
    }
    # Heuristic: model names containing reasoning keywords
    $r = $Id -match '(?i)(reasoning|think|\.1-chat|gpt-5|deepseek-r)'
    $img = $Id -match '(?i)(gpt-[45]|vision|multimodal)'
    $spec = $DefaultSpec.Clone()
    if ($r) { $spec.Reasoning = $true }
    if ($img) { $spec.Input = @('text', 'image') }
    return $spec
}

function Format-ModelDisplayName {
    param([string]$Id)
    # gpt-4.1 -> GPT 4.1, DeepSeek-V3.2 -> DeepSeek V3.2, gpt-5.1-chat -> GPT 5.1 Chat
    $words = $Id -split '-'
    $result = ($words | ForEach-Object {
            if ($_ -cmatch '^[a-z]') {
                (Get-Culture).TextInfo.ToTitleCase($_)
            }
            else {
                $_  # preserve existing casing (e.g. DeepSeek, V3.2)
            }
        }) -join ' '
    # Normalize well-known prefixes to uppercase
    $result = $result -replace '(?i)^Gpt ', 'GPT '
    return $result
}

# ============================================================
# Validate inputs
# ============================================================

# Basic input validation
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host '[ERROR] ApiKey cannot be empty.' -ForegroundColor Red
    exit 1
}
if ($Endpoint -notmatch '^https://') {
    Write-Host '[ERROR] Endpoint must start with https://' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "[START] setup-foundry-model.ps1" -ForegroundColor Cyan
Write-Host "  Provider:  $ProviderName" -ForegroundColor Cyan
Write-Host "  Endpoint:  $Endpoint" -ForegroundColor Cyan
Write-Host "  Models:    $($ModelName -join ', ')" -ForegroundColor Cyan
if ($DryRun) { Write-Host '  Mode:      DRY-RUN (no changes will be written)' -ForegroundColor Yellow }
Write-Host ''

# Normalize endpoint: ensure it ends with /openai/v1
$Endpoint = $Endpoint.TrimEnd('/')
if ($Endpoint -notmatch '/openai/v1$') {
    if ($Endpoint -match '/openai$') {
        $Endpoint = "$Endpoint/v1"
    }
    else {
        $Endpoint = "$Endpoint/openai/v1"
    }
    Write-Host "[INFO] Endpoint normalized to: $Endpoint" -ForegroundColor Yellow
}

# ============================================================
# Load or initialize config
# ============================================================

$configDir = Split-Path $ConfigPath -Parent

if (Test-Path $ConfigPath) {
    $raw = Get-Content -Path $ConfigPath -Raw -Encoding utf8
    $config = $raw | ConvertFrom-Json
    Write-Host "[INFO] Loaded existing config: $ConfigPath" -ForegroundColor Cyan
}
else {
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    $config = [PSCustomObject]@{}
    Write-Host "[INFO] No existing config found, creating new one." -ForegroundColor Yellow
}

# ============================================================
# Ensure structure: models.providers
# ============================================================

if (-not $config.PSObject.Properties['models']) {
    $config | Add-Member -NotePropertyName 'models' -NotePropertyValue ([PSCustomObject]@{})
}
if (-not $config.models.PSObject.Properties['providers']) {
    $config.models | Add-Member -NotePropertyName 'providers' -NotePropertyValue ([PSCustomObject]@{})
}

# ============================================================
# Create or update provider
# ============================================================

$providerExists = $config.models.providers.PSObject.Properties[$ProviderName]
$providerUpdated = $false
$modelsAdded = @()
$modelsSkipped = @()

if ($providerExists) {
    $provider = $config.models.providers.$ProviderName

    # Update endpoint and key if changed
    if ($provider.baseUrl -ne $Endpoint) {
        $provider.baseUrl = $Endpoint
        $providerUpdated = $true
        Write-Host "[UPDATE] Provider '$ProviderName' baseUrl -> $Endpoint" -ForegroundColor Yellow
    }
    if ($provider.apiKey -ne $ApiKey) {
        $provider.apiKey = $ApiKey
        $provider.headers.'api-key' = $ApiKey
        $providerUpdated = $true
        Write-Host "[UPDATE] Provider '$ProviderName' apiKey updated." -ForegroundColor Yellow
    }
    # Ensure api is set to openai-completions (best compatibility, see guide-model-troubleshooting.md)
    if ($provider.PSObject.Properties['api'] -and $provider.api -ne 'openai-completions') {
        $oldApi = $provider.api
        $provider.api = 'openai-completions'
        $providerUpdated = $true
        Write-Host "[UPDATE] Provider '$ProviderName' api: $oldApi -> openai-completions" -ForegroundColor Yellow
    }
}
else {
    $provider = [PSCustomObject]@{
        baseUrl    = $Endpoint
        apiKey     = $ApiKey
        api        = 'openai-completions'
        headers    = [PSCustomObject]@{ 'api-key' = $ApiKey }
        authHeader = $false
        models     = @()
    }
    $config.models.providers | Add-Member -NotePropertyName $ProviderName -NotePropertyValue $provider
    $providerUpdated = $true
    Write-Host "[CREATE] Provider '$ProviderName' created." -ForegroundColor Green
}

# Ensure models array exists
if (-not $provider.PSObject.Properties['models'] -or $null -eq $provider.models) {
    $provider.models = @()
}

# ============================================================
# Add models (idempotent: skip if id already exists)
# ============================================================

$existingIds = @($provider.models | ForEach-Object { $_.id })

foreach ($model in $ModelName) {
    $model = $model.Trim()
    if ($model -in $existingIds) {
        $modelsSkipped += $model
        Write-Host "[SKIP] Model '$model' already exists in provider '$ProviderName'." -ForegroundColor DarkGray
        continue
    }

    $spec = Get-ModelSpec -Id $model
    $displayName = Format-ModelDisplayName -Id $model

    $entry = [PSCustomObject]@{
        id            = $model
        name          = $displayName
        reasoning     = $spec.Reasoning
        input         = $spec.Input
        cost          = [PSCustomObject]@{
            input      = 0
            output     = 0
            cacheRead  = 0
            cacheWrite = 0
        }
        contextWindow = $spec.Context
        maxTokens     = $spec.MaxTokens
    }

    # Append to models array
    $provider.models = @($provider.models) + @($entry)
    $modelsAdded += $model
    Write-Host "[ADD] Model '$model' (reasoning=$($spec.Reasoning), context=$($spec.Context))" -ForegroundColor Green
}

# ============================================================
# Ensure agents.defaults structure for new models
# ============================================================

if ($modelsAdded.Count -gt 0) {
    if (-not $config.PSObject.Properties['agents']) {
        $config | Add-Member -NotePropertyName 'agents' -NotePropertyValue ([PSCustomObject]@{})
    }
    if (-not $config.agents.PSObject.Properties['defaults']) {
        $config.agents | Add-Member -NotePropertyName 'defaults' -NotePropertyValue ([PSCustomObject]@{})
    }
    if (-not $config.agents.defaults.PSObject.Properties['models']) {
        $config.agents.defaults | Add-Member -NotePropertyName 'models' -NotePropertyValue ([PSCustomObject]@{})
    }

    # Register each new model in agents.defaults.models (required for "configured" status)
    foreach ($addedModel in $modelsAdded) {
        $fullModelId = "$ProviderName/$addedModel"
        if (-not $config.agents.defaults.models.PSObject.Properties[$fullModelId]) {
            $config.agents.defaults.models | Add-Member -NotePropertyName $fullModelId -NotePropertyValue ([PSCustomObject]@{})
            Write-Host "[REGISTER] $fullModelId in agents.defaults.models" -ForegroundColor Green
        }
    }

    # Set default primary model if requested
    if ($SetAsDefault) {
        $firstModel = $ModelName[0].Trim()
        $fullId = "$ProviderName/$firstModel"
        if (-not $config.agents.defaults.PSObject.Properties['model']) {
            $config.agents.defaults | Add-Member -NotePropertyName 'model' -NotePropertyValue ([PSCustomObject]@{})
        }
        $config.agents.defaults.model | Add-Member -NotePropertyName 'primary' -NotePropertyValue $fullId -Force
        Write-Host "[SET] Default primary model -> $fullId" -ForegroundColor Cyan
    }
}

# ============================================================
# Summary
# ============================================================

Write-Host ''
Write-Host '========================================' -ForegroundColor White
Write-Host '  Setup Summary' -ForegroundColor White
Write-Host '========================================' -ForegroundColor White
Write-Host "  Provider:       $ProviderName"
Write-Host "  Endpoint:       $Endpoint"
Write-Host "  Models added:   $($modelsAdded.Count) ($($modelsAdded -join ', '))"
Write-Host "  Models skipped: $($modelsSkipped.Count) ($($modelsSkipped -join ', '))"

if ($modelsAdded.Count -eq 0 -and -not $providerUpdated) {
    Write-Host ''
    Write-Host '[INFO] No changes needed. Config is already up to date.' -ForegroundColor Cyan
    exit 0
}

# ============================================================
# Write config
# ============================================================

if ($DryRun) {
    Write-Host ''
    Write-Host '[DRY-RUN] Changes NOT written. Preview of models section:' -ForegroundColor Yellow
    Write-Host ''
    $preview = $config.models.providers.$ProviderName.models | ConvertTo-Json -Depth 10
    Write-Host $preview
    exit 0
}

# Backup before writing
$backupPath = "$ConfigPath.bak"
if (Test-Path $ConfigPath) {
    Copy-Item -Path $ConfigPath -Destination $backupPath -Force
    Write-Host "[BACKUP] $backupPath" -ForegroundColor DarkGray
}

$json = $config | ConvertTo-Json -Depth 20
# Ensure UTF-8 without BOM
[System.IO.File]::WriteAllText($ConfigPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "[WRITE] $ConfigPath" -ForegroundColor Green

# ============================================================
# Validate with openclaw if available
# ============================================================

$openclawCmd = Get-Command openclaw -ErrorAction SilentlyContinue
if ($openclawCmd) {
    Write-Host ''
    Write-Host '[VALIDATE] Running openclaw models list...' -ForegroundColor Cyan
    $output = & openclaw models list 2>&1 | Out-String
    if ($output -match 'Invalid config') {
        Write-Host '[WARN] Config validation failed.' -ForegroundColor Red
        if (Test-Path $backupPath) {
            Copy-Item -Path $backupPath -Destination $ConfigPath -Force
            Write-Host "[RESTORE] Restored from $backupPath" -ForegroundColor Red
        }
        else {
            Write-Host '[WARN] No backup available to restore.' -ForegroundColor Red
        }
        Write-Host ''
        Write-Host 'Validation error:' -ForegroundColor Red
        Write-Host $output -ForegroundColor Red
        exit 1
    }
    Write-Host $output
}

Write-Host ''
Write-Host 'Done. Run "openclaw models list" to verify.' -ForegroundColor Green
