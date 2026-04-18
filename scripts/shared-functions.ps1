# Shared helper functions for deploy.ps1

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
