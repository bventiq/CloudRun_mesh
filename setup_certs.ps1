# setup_certs.ps1
# Generates self-signed Root CA and Server Certificates, then uploads to Secret Manager.

$ErrorActionPreference = "Stop"

# Load environment variables from .env file if it exists
if (Test-Path ".env") {
    Write-Host "Loading environment variables from .env file..."
    Get-Content ".env" | ForEach-Object {
        if ($_ -match "^\s*(?:export\s+)?([^#=]+)\s*=\s*(.*)$") {
            $key = $matches[1]
            $value = $matches[2]
            # Remove quotes if present
            if ($value -match "^['`"](.*)['`"]$") { $value = $matches[1] }
            [Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
    Write-Host "Loaded GCP_PROJECT_ID: $env:GCP_PROJECT_ID"
}
else {
    Write-Warning ".env file not found!"
}

if ([string]::IsNullOrWhiteSpace($env:GCP_PROJECT_ID)) {
    Write-Error "GCP_PROJECT_ID is empty. Please check your .env file."
    exit 1
}

# Configuration
if (-not [string]::IsNullOrWhiteSpace($env:DOMAIN)) {
    $Domain = $env:DOMAIN
}
else {
    $Domain = "mesh.example.com"
}
$Country = "JP"
$State = "Tokyo"
$Locality = "Chiyoda"
$Organization = "MeshCentral"
$OrganizationalUnit = "IT"
$Email = "admin@example.com"

# Check for GCloud
try {
    gcloud version | Out-Null
}
catch {
    Write-Warning "gcloud command might verify failed. If you have it, ignore this. If not, please install Google Cloud SDK."
}

# Helper to get absolute path
function Get-AbsPath($filename) {
    return Join-Path $PWD $filename
}

# --- 1. Generate Root CA ---
Write-Host "Generating Root CA..."
$rootCert = New-SelfSignedCertificate -CertStoreLocation Cert:\CurrentUser\My `
    -Subject "CN=MeshCentralRootCA, O=$Organization, C=$Country" `
    -KeyUsage CertSign, CRLSign `
    -KeySpec Signature `
    -KeyLength 2048 `
    -KeyExportPolicy Exportable `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(10)

# Export Root Private Key
$rootPwd = ConvertTo-SecureString -String "MeshCentralRootPassword123!" -Force -AsPlainText
$rootKeyPath = Get-AbsPath "root-cert-private.key"
$rootCrtPath = Get-AbsPath "root-cert-public.crt"

# Export Root Cert (Public)
Export-Certificate -Cert $rootCert -FilePath $rootCrtPath

# Export PFX
$rootPfxPath = Get-AbsPath "root-ca.pfx"
Export-PfxCertificate -Cert $rootCert -FilePath $rootPfxPath -Password $rootPwd

if (-not (Test-Path $rootPfxPath)) {
    Write-Error "Failed to create PFX at $rootPfxPath"
    exit 1
}

# Helper: Find OpenSSL
$OpenSSL = "openssl"
$possiblePaths = @(
    "C:\Program Files\Git\usr\bin\openssl.exe",
    "C:\Program Files\Git\mingw64\bin\openssl.exe",
    "C:\Program Files\Git\bin\openssl.exe",
    "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe",
    "$env:LOCALAPPDATA\Programs\Git\mingw64\bin\openssl.exe"
)

if (-not (Get-Command $OpenSSL -ErrorAction SilentlyContinue)) {
    foreach ($p in $possiblePaths) {
        if (Test-Path $p) {
            $OpenSSL = $p
            break
        }
    }
}

Write-Host "Using OpenSSL: $OpenSSL"

# Function to convert PFX to PEM (CRT/KEY)
function Convert-PfxToPem {
    param($PfxPath, $Pwd, $KeyOut, $CrtOut)
    
    if (-not (Test-Path $PfxPath)) { throw "PFX not found at $PfxPath" }

    # Try .NET export first (Cleanest if supported)
    try {
        $certCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $certCollection.Import($PfxPath, $Pwd, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        $cert = $certCollection[0]

        # CRT
        $crtPem = "-----BEGIN CERTIFICATE-----`n" + 
        [Convert]::ToBase64String($cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert), [System.Base64FormattingOptions]::InsertLineBreaks) + 
        "`n-----END CERTIFICATE-----"
        Set-Content -Path $CrtOut -Value $crtPem -Encoding Ascii

        # Key
        if ($cert.HasPrivateKey) {
            $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
            # Try newer method
            $keyBytes = $rsa.ExportPkcs8PrivateKey() 
            $keyPem = "-----BEGIN PRIVATE KEY-----`n" + 
            [Convert]::ToBase64String($keyBytes, [System.Base64FormattingOptions]::InsertLineBreaks) + 
            "`n-----END PRIVATE KEY-----"
            Set-Content -Path $KeyOut -Value $keyPem -Encoding Ascii
            return
        }
    }
    catch {
        Write-Warning ".NET Private Key Export Failed (Old .NET version?): $($_.Exception.Message)"
        Write-Host "Falling back to OpenSSL..."
    }

    # Fallback to OpenSSL
    if (Test-Path $OpenSSL) {
        # Export Key (Nodes = No Encrypt)
        & $OpenSSL pkcs12 -in $PfxPath -nocerts -nodes -passin "pass:$Pwd" -out $KeyOut
        # Export Cert
        & $OpenSSL pkcs12 -in $PfxPath -nokeys -clcerts -passin "pass:$Pwd" -out $CrtOut
    }
    else {
        throw "Could not export Private Key. .NET ExportPkcs8PrivateKey missing and OpenSSL not found in common paths. Please install Git for Windows or OpenSSL."
    }
}

Write-Host "Converting Root CA to PEM..."
Convert-PfxToPem -PfxPath $rootPfxPath -Pwd "MeshCentralRootPassword123!" -KeyOut $rootKeyPath -CrtOut $rootCrtPath


# --- 2. Generate Web Server Cert ---
Write-Host "Generating Web Server Certificate..."
$webCert = New-SelfSignedCertificate -CertStoreLocation Cert:\CurrentUser\My `
    -Signer $rootCert `
    -Subject "CN=$Domain, O=$Organization, C=$Country" `
    -KeyUsage KeyEncipherment, DigitalSignature `
    -KeySpec KeyExchange `
    -KeyLength 2048 `
    -KeyExportPolicy Exportable `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(2) `
    -TextExtension @("2.5.29.17={text}DNS=localhost&DNS=$Domain")

$webPfxPath = Get-AbsPath "web-server.pfx"
$webPwd = ConvertTo-SecureString -String "MeshCentralWebPassword123!" -Force -AsPlainText
Export-PfxCertificate -Cert $webCert -FilePath $webPfxPath -Password $webPwd

$webKeyPath = Get-AbsPath "webserver-cert-private.key"
$webCrtPath = Get-AbsPath "webserver-cert-public.crt"

Write-Host "Converting Web Server Cert to PEM..."
Convert-PfxToPem -PfxPath $webPfxPath -Pwd "MeshCentralWebPassword123!" -KeyOut $webKeyPath -CrtOut $webCrtPath

# Cleanup PFX
Remove-Item $rootPfxPath, $webPfxPath, $rootCrtPath.Replace(".crt", ".cer") -ErrorAction SilentlyContinue


# --- 3. Upload to Secret Manager ---
Write-Host "Uploading to Google Secret Manager..."

$secrets = @(
    @("mesh-root-key", $rootKeyPath),
    @("mesh-root-crt", $rootCrtPath),
    @("mesh-web-key", $webKeyPath),
    @("mesh-web-crt", $webCrtPath)
)

foreach ($pair in $secrets) {
    $name = $pair[0]
    $file = $pair[1]
    
    Write-Host "Processing $name..."
    # Check existence - Try to describe, if fails (NOT_FOUND), then create.
    # We turn off ErrorAction Stop locally for this check
    $secretExists = $false
    try {
        gcloud secrets describe $name --project "$env:GCP_PROJECT_ID" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $secretExists = $true }
    }
    catch {
        # Ignore error
    }

    if (-not $secretExists) {
        Write-Host "Creating secret $name..."
        gcloud secrets create $name --replication-policy="automatic" --project "$env:GCP_PROJECT_ID"
    }
    
    # Add version
    gcloud secrets versions add $name --data-file="$file" --project "$env:GCP_PROJECT_ID"
    
    # Grant Access
    # Ensure Cloud Run service account can access it (Simplified check)
    $PROJECT_NUMBER = (gcloud projects describe $env:GCP_PROJECT_ID --format="value(projectNumber)")
    $SERVICE_ACCOUNT = "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
  
    gcloud secrets add-iam-policy-binding $name `
        --project "$env:GCP_PROJECT_ID" `
        --member="serviceAccount:${SERVICE_ACCOUNT}" `
        --role="roles/secretmanager.secretAccessor" > $null
}


# --- 4. Upload to GCS Bucket ---
$BucketName = "meshcentral-data-$env:GCP_PROJECT_ID"
Write-Host "Uploading certificates to GCS Bucket: gs://$BucketName/ ..."

try {
    gsutil cp "$rootCrtPath" "gs://$BucketName/root-cert-public.crt"
    gsutil cp "$rootKeyPath" "gs://$BucketName/root-cert-private.key"
    Write-Host "Certificates uploaded successfully to GCS."
}
catch {
    Write-Warning "Failed to upload to GCS. Please ensure the bucket exists and you have permissions."
    Write-Warning "Manual upload required: gsutil cp ... gs://$BucketName/"
}

Write-Host "Done! Secrets created and files uploaded."
Write-Host "Root CRT: $rootCrtPath"
Write-Host "Web CRT: $webCrtPath"
