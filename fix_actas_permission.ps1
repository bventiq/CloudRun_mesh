# fix_actas_permission.ps1
Write-Host "=== Fix Cloud Run Deployment Permission (Auto) ===" -ForegroundColor Cyan

# 1. Get Project ID
$ProjectID = (Get-Item "Env:GCP_PROJECT_ID" -ErrorAction SilentlyContinue).Value
if (-not $ProjectID) {
    # Try gcloud config
    $ProjectID = gcloud config get-value project 2>$null
}

if (-not $ProjectID) {
    Write-Host "Error: Could not detect GCP_PROJECT_ID from Env or gcloud config." -ForegroundColor Red
    exit 1
}
Write-Host "Project: $ProjectID" -ForegroundColor Gray

# 2. Identify Runtime SA
$RuntimeSA = "meshcentral-runtime@$ProjectID.iam.gserviceaccount.com"
Write-Host "Runtime SA: $RuntimeSA" -ForegroundColor Gray

# 3. Identify Deployer SA
# Try Env first
$DeployerSA = (Get-Item "Env:GCP_SERVICE_ACCOUNT" -ErrorAction SilentlyContinue).Value

if (-not $DeployerSA) {
    # List SAs and look for 'github' or 'deploy' or 'action' in email/display name
    Write-Host "Searching for Deployer Service Account..." -ForegroundColor Gray
    $SAs = gcloud iam service-accounts list --project $ProjectID --format="value(email)"
    
    # Filter out the runtime SA and default compute SA
    $Candidates = $SAs | Where-Object { 
        $_ -ne $RuntimeSA -and 
        $_ -notlike "*compute@developer.gserviceaccount.com" -and
        $_ -notlike "*appspot.gserviceaccount.com"
    }

    if ($Candidates.Count -eq 1) {
        $DeployerSA = $Candidates
        Write-Host "Found likely Deployer SA: $DeployerSA" -ForegroundColor Yellow
    }
    elseif ($Candidates.Count -gt 1) {
        # Try to find one with 'github'
        $GithubSA = $Candidates | Where-Object { $_ -match "github" }
        if ($GithubSA) {
            $DeployerSA = $GithubSA
            Write-Host "Found likely Deployer SA (by name): $DeployerSA" -ForegroundColor Yellow
        }
        else {
            # Pick the first one as fallback, but warn
            $DeployerSA = $Candidates[0]
            Write-Host "Ambiguous SAs found. Using first candidate: $DeployerSA" -ForegroundColor Yellow
        }
    }
}

if (-not $DeployerSA) {
    Write-Host "Error: Could not auto-detect Deployer Service Account." -ForegroundColor Red
    exit 1
}

# 4. Grant Permission
Write-Host "Granting 'iam.serviceAccountUser' role..." -ForegroundColor Cyan
$Cmd = "gcloud iam service-accounts add-iam-policy-binding $RuntimeSA --member='serviceAccount:$DeployerSA' --role='roles/iam.serviceAccountUser' --project=$ProjectID"
Invoke-Expression $Cmd

Write-Host "Done! You can now Re-run the GitHub Action." -ForegroundColor Green
