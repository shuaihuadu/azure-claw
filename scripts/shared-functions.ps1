<#
.SYNOPSIS
    Shared helper functions for deploy.ps1 and setup-foundry-model.ps1.
    Dot-source this file: . "$PSScriptRoot/shared-functions.ps1"
#>

# ============================================================
# Model Knowledge Base
# ============================================================

$script:KnownModels = @{
    'gpt-4.1'                 = @{ Reasoning = $false; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'gpt-4.1-mini'            = @{ Reasoning = $false; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'gpt-4.1-nano'            = @{ Reasoning = $false; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'gpt-5.1-chat'            = @{ Reasoning = $true; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'gpt-5.4-mini'            = @{ Reasoning = $true; Input = @('text', 'image'); Context = 1048576; MaxTokens = 32768 }
    'grok-3'                  = @{ Reasoning = $false; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'grok-4-1-fast-reasoning' = @{ Reasoning = $true; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'DeepSeek-V3.2'           = @{ Reasoning = $false; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'DeepSeek-R1'             = @{ Reasoning = $true; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'Kimi-K2.5'               = @{ Reasoning = $false; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'Phi-4-reasoning-plus'    = @{ Reasoning = $true; Input = @('text'); Context = 131072; MaxTokens = 16384 }
    'Phi-4'                   = @{ Reasoning = $false; Input = @('text'); Context = 16384; MaxTokens = 4096 }
}

function Get-ModelSpec {
    param([string]$Id)
    if ($script:KnownModels.ContainsKey($Id)) { return $script:KnownModels[$Id] }
    $r = $Id -match '(?i)(reasoning|think|\.1-chat|gpt-5|deepseek-r)'
    $img = $Id -match '(?i)(gpt-[45]|vision|multimodal)'
    return @{ Reasoning = [bool]$r; Input = $(if ($img) { @('text', 'image') } else { @('text') }); Context = 131072; MaxTokens = 16384 }
}

function Format-ModelDisplayName {
    param([string]$Id)
    $result = ($Id -split '-' | ForEach-Object {
            if ($_ -cmatch '^[a-z]') { (Get-Culture).TextInfo.ToTitleCase($_) } else { $_ }
        }) -join ' '
    return $result -replace '(?i)^Gpt ', 'GPT '
}

# ============================================================
# Interactive Helpers
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

function Read-MultiChoice {
    param(
        [string]$Prompt,
        [string[]]$Options,
        [string[]]$Descriptions = @()
    )
    Write-Host ""
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $desc = if ($Descriptions.Count -gt $i -and $Descriptions[$i]) { "  $($Descriptions[$i])" } else { '' }
        Write-Host "    $($i + 1). $($Options[$i])$desc"
    }
    Write-Host "    A. Select all"
    while ($true) {
        $input = Read-Host "  Enter numbers (comma-separated, e.g. 1,3,5) or A for all"
        if ($input -match '^[Aa]$') { return $Options }
        $nums = $input -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $selected = @()
        $valid = $true
        foreach ($n in $nums) {
            $num = 0
            if ([int]::TryParse($n, [ref]$num) -and $num -ge 1 -and $num -le $Options.Count) {
                $selected += $Options[$num - 1]
            }
            else {
                Write-Host "  Invalid number: $n (must be 1-$($Options.Count))" -ForegroundColor Yellow
                $valid = $false
                break
            }
        }
        if ($valid -and $selected.Count -gt 0) { return $selected }
        if ($valid) { Write-Host "  Please select at least one item." -ForegroundColor Yellow }
    }
}

# ============================================================
# Deploy Foundry Config to VM
# ============================================================

function Deploy-FoundryConfigToVM {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string[]]$Models,
        [Parameter(Mandatory)][string]$VmResourceGroup,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$AdminUsername,
        [string]$ProviderName = 'azure-openai'
    )

    $pyModelLines = @()
    foreach ($m in $Models) {
        $spec = Get-ModelSpec -Id $m
        $name = Format-ModelDisplayName -Id $m
        $reasoning = if ($spec.Reasoning) { 'True' } else { 'False' }
        $inputList = ($spec.Input | ForEach-Object { "`"$_`"" }) -join ', '
        $pyModelLines += "    (`"$m`", `"$name`", $reasoning, [$inputList], $($spec.Context), $($spec.MaxTokens)),"
    }
    $pyModelsBlock = $pyModelLines -join "`n"
    $defaultModel = "$ProviderName/$($Models[0])"

    $tempScript = [System.IO.Path]::GetTempFileName()
    $scriptContent = @"
#!/bin/bash
set -euo pipefail
python3 << 'PYEOF'
import json

CONFIG = "/home/${AdminUsername}/.openclaw/openclaw.json"
PROVIDER = "$ProviderName"
ENDPOINT = "$Endpoint"
API_KEY = "$ApiKey"

MODELS = [
$pyModelsBlock
]

with open(CONFIG) as f:
    config = json.load(f)

config.setdefault("models", {}).setdefault("providers", {})
config["models"]["providers"][PROVIDER] = {
    "baseUrl": ENDPOINT,
    "apiKey": API_KEY,
    "api": "openai-completions",
    "headers": {"api-key": API_KEY},
    "authHeader": False,
    "models": []
}

provider = config["models"]["providers"][PROVIDER]
for mid, name, reasoning, inp, ctx, maxt in MODELS:
    provider["models"].append({
        "id": mid, "name": name, "reasoning": reasoning, "input": inp,
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": ctx, "maxTokens": maxt
    })

config.setdefault("agents", {}).setdefault("defaults", {}).setdefault("models", {})
for mid, *_ in MODELS:
    config["agents"]["defaults"]["models"][f"{PROVIDER}/{mid}"] = {}

config["agents"]["defaults"]["model"] = {"primary": "$defaultModel"}

with open(CONFIG, "w") as f:
    json.dump(config, f, indent=2)

print(f"OK: {len(MODELS)} models configured, default={PROVIDER}/{MODELS[0][0]}")
PYEOF
chown ${AdminUsername}:${AdminUsername} /home/${AdminUsername}/.openclaw/openclaw.json
systemctl restart openclaw.service 2>/dev/null || true
sleep 2
systemctl is-active openclaw.service 2>/dev/null && echo "Gateway: running" || echo "Gateway: not running"
"@
    Set-Content -Path $tempScript -Value $scriptContent -Encoding UTF8

    $result = az vm run-command invoke `
        --resource-group $VmResourceGroup `
        --name $VmName `
        --command-id RunShellScript `
        --scripts "@$tempScript" `
        --query "value[0].message" -o tsv 2>&1

    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    return $result
}

# ============================================================
# Normalize Foundry Endpoint
# ============================================================

function Normalize-FoundryEndpoint {
    param([string]$Endpoint)
    $Endpoint = $Endpoint.TrimEnd('/')
    if ($Endpoint -notmatch '/openai/v1$') {
        if ($Endpoint -match '/openai$') { $Endpoint = "$Endpoint/v1" }
        else { $Endpoint = "$Endpoint/openai/v1" }
    }
    return $Endpoint
}

# ============================================================
# Purge Soft-Deleted AI Services
# ============================================================

function Purge-SoftDeletedAIResource {
    <#
    .SYNOPSIS
        Find and purge soft-deleted Cognitive Services accounts whose name starts with a given prefix.
        Returns $true if at least one resource was purged.
    #>
    param(
        [string]$NamePrefix = 'openclaw-ai-'
    )

    # Use --query to filter server-side and get a flat list with the fields we need
    $deletedJson = az cognitiveservices account list-deleted `
        --query "[?starts_with(name, '$NamePrefix') || starts_with(properties.resourceName || '', '$NamePrefix')]" `
        --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] Failed to list soft-deleted AI resources: $deletedJson" -ForegroundColor Yellow
        return $false
    }

    $deleted = $deletedJson | ConvertFrom-Json
    if (-not $deleted -or @($deleted).Count -eq 0) { return $false }

    $purged = $false
    foreach ($item in @($deleted)) {
        # Extract resource name — try multiple property paths
        $resName = $null
        if ($item.name) { $resName = $item.name }
        if (-not $resName -and $item.properties -and $item.properties.resourceName) {
            $resName = $item.properties.resourceName
        }
        if (-not $resName) { continue }

        # Extract location
        $resLocation = $null
        if ($item.location) { $resLocation = $item.location }
        if (-not $resLocation -and $item.properties -and $item.properties.location) {
            $resLocation = $item.properties.location
        }
        if (-not $resLocation) { continue }

        # Extract resource group — try properties, then parse from ID
        $resGroup = $null
        if ($item.properties -and $item.properties.resourceGroup) {
            $resGroup = $item.properties.resourceGroup
        }
        if (-not $resGroup -and $item.id -and $item.id -match '/resourceGroups/([^/]+)') {
            $resGroup = $Matches[1]
        }
        if (-not $resGroup) { continue }

        Write-Host "[INFO] Purging soft-deleted AI resource '$resName' (location: $resLocation, RG: $resGroup)..."
        $purgeOutput = az cognitiveservices account purge `
            --name $resName `
            --resource-group $resGroup `
            --location $resLocation 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[INFO] Purged '$resName' successfully."
            $purged = $true
        }
        else {
            Write-Host "[WARN] Failed to purge '$resName': $purgeOutput" -ForegroundColor Yellow
        }
    }
    return $purged
}
