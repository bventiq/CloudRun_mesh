# setup_waker_sa.ps1
Write-Host "=== Setup Authenticated Worker (Waker SA) ===" -ForegroundColor Cyan

# 1. Get Project ID
$ProjectID = gcloud config get-value project 2>$null
if (-not $ProjectID) {
    Write-Host "Error: Could not detect GCP_PROJECT_ID." -ForegroundColor Red
    exit 1
}
Write-Host "Project: $ProjectID" -ForegroundColor Gray

$ServiceName = "meshcentral-server"
$Region = "us-central1"
$SaName = "meshcentral-waker"
$SaEmail = "$SaName@$ProjectID.iam.gserviceaccount.com"
$KeyFile = ".\waker-key.json"

# 2. Create Service Account (if not exists)
Write-Host "Creating Service Account '$SaName'..." -ForegroundColor Gray
gcloud iam service-accounts create $SaName --display-name="MeshCentral Waker SA" --project=$ProjectID 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "  (SA might already exist, proceeding...)" -ForegroundColor DarkGray }

# 3. Grant Invoker Role ONLY to this SA
Write-Host "Granting 'roles/run.invoker' to $SaEmail..." -ForegroundColor Gray
gcloud run services add-iam-policy-binding $ServiceName --region=$Region --member="serviceAccount:$SaEmail" --role="roles/run.invoker" --project=$ProjectID

# 4. REMOVE Public Access (allUsers)
Write-Host "REMOVING public access (allUsers)..." -ForegroundColor Yellow
gcloud run services remove-iam-policy-binding $ServiceName --region=$Region --member="allUsers" --role="roles/run.invoker" --project=$ProjectID

# 5. Create JSON Key
Write-Host "Creating JSON Key file..." -ForegroundColor Gray
if (Test-Path $KeyFile) { Remove-Item $KeyFile }
gcloud iam service-accounts keys create $KeyFile --iam-account=$SaEmail --project=$ProjectID

# 6. Output for Cloudflare
Write-Host "`n=== ACTION REQUIRED ===" -ForegroundColor Green
Write-Host "Please set the following secret in Cloudflare (Worker Settings > Variables > Secrets) or .dev.vars"
Write-Host "Variable Name: GCP_SA_KEY"
Write-Host "Value (Copy valid JSON below):" -ForegroundColor Cyan

# Compact JSON to one line for easier copying
$JsonContent = Get-Content $KeyFile -Raw
$CompactJson = $JsonContent -replace "\s+", ""
Write-Host $CompactJson -ForegroundColor White

# Clean up local key file for security? (Maybe ask user, but for now keep it so they can copy)
Write-Host "`n(The key is saved to $KeyFile. Delete it after adding to Cloudflare)" -ForegroundColor Gray
