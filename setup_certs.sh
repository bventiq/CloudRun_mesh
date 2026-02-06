#!/bin/bash
# setup_certs.sh
# Generates self-signed Root CA and Server Certificates, then uploads to Secret Manager.

set -e

# Load environment variables from .env file if it exists
if [ -f ".env" ]; then
    echo "Loading environment variables from .env file..."
    # Export variables while stripping 'export' keyword and handling quotes
    set -a
    source <(grep -v '^#' .env | sed -E 's/^export[[:space:]]+//g' | sed -E 's/^([^=]+)=['\''"]?([^'\''"]*)['\''"]?$/\1=\2/')
    set +a
    echo "Loaded GCP_PROJECT_ID: $GCP_PROJECT_ID"
else
    echo "WARNING: .env file not found!" >&2
fi

if [ -z "$GCP_PROJECT_ID" ]; then
    echo "ERROR: GCP_PROJECT_ID is empty. Please check your .env file." >&2
    exit 1
fi

# Configuration
if [ -n "$DOMAIN" ]; then
    DOMAIN_NAME="$DOMAIN"
else
    DOMAIN_NAME="mesh.example.com"
fi

COUNTRY="JP"
STATE="Tokyo"
LOCALITY="Chiyoda"
ORGANIZATION="MeshCentral"
ORGANIZATIONAL_UNIT="IT"
EMAIL="admin@example.com"

# Check for required tools
if ! command -v gcloud &> /dev/null; then
    echo "WARNING: gcloud command not found. Please install Google Cloud SDK." >&2
fi

if ! command -v openssl &> /dev/null; then
    echo "ERROR: openssl command not found. Please install openssl." >&2
    exit 1
fi

# File paths
ROOT_KEY="root-cert-private.key"
ROOT_CRT="root-cert-public.crt"
WEB_KEY="webserver-cert-private.key"
WEB_CRT="webserver-cert-public.crt"

# --- 1. Generate Root CA ---
echo "Generating Root CA..."

# Create Root CA private key
openssl genrsa -out "$ROOT_KEY" 2048

# Create Root CA certificate (valid for 10 years)
openssl req -new -x509 -days 3650 -key "$ROOT_KEY" -out "$ROOT_CRT" \
    -subj "/C=$COUNTRY/O=$ORGANIZATION/CN=MeshCentralRootCA"

echo "Root CA generated:"
echo "  Private Key: $ROOT_KEY"
echo "  Certificate: $ROOT_CRT"

# --- 2. Generate Web Server Certificate ---
echo "Generating Web Server Certificate..."

# Create Web Server private key
openssl genrsa -out "$WEB_KEY" 2048

# Create Certificate Signing Request (CSR)
WEB_CSR="webserver.csr"
openssl req -new -key "$WEB_KEY" -out "$WEB_CSR" \
    -subj "/C=$COUNTRY/O=$ORGANIZATION/CN=$DOMAIN_NAME"

# Create OpenSSL config for SAN (Subject Alternative Names)
EXT_FILE="webserver-ext.cnf"
cat > "$EXT_FILE" <<EOF
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=localhost
DNS.2=$DOMAIN_NAME
EOF

# Sign the Web Server certificate with Root CA (valid for 2 years)
openssl x509 -req -in "$WEB_CSR" -CA "$ROOT_CRT" -CAkey "$ROOT_KEY" \
    -CAcreateserial -out "$WEB_CRT" -days 730 -sha256 -extfile "$EXT_FILE"

echo "Web Server Certificate generated:"
echo "  Private Key: $WEB_KEY"
echo "  Certificate: $WEB_CRT"

# Cleanup temporary files
rm -f "$WEB_CSR" "$EXT_FILE" "${ROOT_CRT}.srl"

# --- 3. Upload to Secret Manager ---
echo "Uploading to Google Secret Manager..."

SECRETS=(
    "mesh-root-key:$ROOT_KEY"
    "mesh-root-crt:$ROOT_CRT"
    "mesh-web-key:$WEB_KEY"
    "mesh-web-crt:$WEB_CRT"
)

for secret_pair in "${SECRETS[@]}"; do
    IFS=':' read -r name file <<< "$secret_pair"

    echo "Processing $name..."

    # Check if secret exists
    if gcloud secrets describe "$name" --project "$GCP_PROJECT_ID" &> /dev/null; then
        echo "Secret $name already exists, adding new version..."
    else
        echo "Creating secret $name..."
        gcloud secrets create "$name" \
            --replication-policy="automatic" \
            --project "$GCP_PROJECT_ID"
    fi

    # Add version
    gcloud secrets versions add "$name" \
        --data-file="$file" \
        --project "$GCP_PROJECT_ID"

    # Grant access to Cloud Run default service account
    PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)")
    SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

    gcloud secrets add-iam-policy-binding "$name" \
        --project "$GCP_PROJECT_ID" \
        --member="serviceAccount:${SERVICE_ACCOUNT}" \
        --role="roles/secretmanager.secretAccessor" \
        --quiet > /dev/null
done

# --- 4. Upload to GCS Bucket ---
BUCKET_NAME="meshcentral-data-${GCP_PROJECT_ID}"
echo "Uploading certificates to GCS Bucket: gs://$BUCKET_NAME/ ..."

if gsutil cp "$ROOT_CRT" "gs://$BUCKET_NAME/root-cert-public.crt" && \
   gsutil cp "$ROOT_KEY" "gs://$BUCKET_NAME/root-cert-private.key"; then
    echo "Certificates uploaded successfully to GCS."
else
    echo "WARNING: Failed to upload to GCS. Please ensure the bucket exists and you have permissions." >&2
    echo "Manual upload required: gsutil cp $ROOT_CRT gs://$BUCKET_NAME/root-cert-public.crt" >&2
fi

echo ""
echo "Done! Secrets created and uploaded."
echo "Root CA Certificate: $ROOT_CRT"
echo "Web Server Certificate: $WEB_CRT"
echo ""
echo "You can now deploy your MeshCentral service with these certificates."
