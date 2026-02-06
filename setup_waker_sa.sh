#!/bin/bash
# setup_waker_sa.sh
# Setup Authenticated Worker (Waker Service Account)

set -e

echo "=== Setup Authenticated Worker (Waker SA) ==="

# 1. Get Project ID
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo "Error: Could not detect GCP_PROJECT_ID." >&2
    exit 1
fi
echo "Project: $PROJECT_ID"

SERVICE_NAME="meshcentral-server"
REGION="us-central1"
SA_NAME="meshcentral-waker"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_FILE="./waker-key.json"

# 2. Create Service Account (if not exists)
echo "Creating Service Account '$SA_NAME'..."
gcloud iam service-accounts create "$SA_NAME" \
    --display-name="MeshCentral Waker SA" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  (SA might already exist, proceeding...)"

# 3. Grant Invoker Role ONLY to this SA
echo "Granting 'roles/run.invoker' to $SA_EMAIL..."
gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
    --region="$REGION" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/run.invoker" \
    --project="$PROJECT_ID"

# 4. REMOVE Public Access (allUsers)
echo "REMOVING public access (allUsers)..."
gcloud run services remove-iam-policy-binding "$SERVICE_NAME" \
    --region="$REGION" \
    --member="allUsers" \
    --role="roles/run.invoker" \
    --project="$PROJECT_ID" 2>/dev/null || echo "  (allUsers binding might not exist, proceeding...)"

# 5. Create JSON Key
echo "Creating JSON Key file..."
[ -f "$KEY_FILE" ] && rm "$KEY_FILE"
gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID"

# 6. Output for Cloudflare
echo ""
echo "=== ACTION REQUIRED ==="
echo "Please set the following secret in Cloudflare (Worker Settings > Variables > Secrets) or .dev.vars"
echo "Variable Name: GCP_SA_KEY"
echo "Value (Copy valid JSON below):"
echo ""

# Compact JSON to one line for easier copying
tr -d '\n\t ' < "$KEY_FILE"
echo ""

echo ""
echo "(The key is saved to $KEY_FILE. Delete it after adding to Cloudflare)"
