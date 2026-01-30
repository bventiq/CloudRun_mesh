# setup_gh_secrets.ps1
Write-Host "=== Restore GitHub Secrets & Variables (Smart Mode) ===" -ForegroundColor Cyan

# Cache current remote config
$RemoteVars = try { gh variable list --json name --jq '.[].name' } catch { @() }
$RemoteSecrets = try { gh secret list --json name --jq '.[].name' } catch { @() }

function Set-Var {
    param($Name, $Default)
    if ($RemoteVars -contains $Name) {
        Write-Host "✔ $Name is already set on GitHub." -ForegroundColor Gray
        return
    }
    
    # Check Env
    $Val = (Get-Item "Env:$Name" -ErrorAction SilentlyContinue).Value
    if (-not $Val) {
        $Prompt = "Enter $Name"
        if ($Default) { $Prompt += " (default: $Default)" }
        $Val = Read-Host $Prompt
        if (-not $Val -and $Default) { $Val = $Default }
    }
    
    if ($Val) {
        Write-Host "Setting $Name..."
        gh variable set $Name --body "$Val"
    }
    else {
        Write-Host "Skipped $Name (No value)" -ForegroundColor Yellow
    }
}

function Set-Secret {
    param($Name)
    if ($RemoteSecrets -contains $Name) {
        Write-Host "✔ $Name (Secret) is already set on GitHub." -ForegroundColor Gray
        return
    }

    # Check Env
    $Val = (Get-Item "Env:$Name" -ErrorAction SilentlyContinue).Value
    if (-not $Val) {
        $Val = Read-Host "Enter $Name"
    }
    
    if ($Val) {
        Write-Host "Setting $Name..."
        gh secret set $Name --body "$Val"
    }
    else {
        Write-Host "Skipped $Name (No value)" -ForegroundColor Yellow
    }
}

# --- Variables ---
Set-Var "GCP_PROJECT_ID" ""
Set-Var "DOMAIN" ""
Set-Var "MESHCENTRAL_VERSION" "1.1.56"

# --- Secrets ---
Set-Secret "GCP_WORKLOAD_IDENTITY_PROVIDER"
Set-Secret "GCP_SERVICE_ACCOUNT"

Write-Host "`nConfiguration Check Complete!" -ForegroundColor Green
