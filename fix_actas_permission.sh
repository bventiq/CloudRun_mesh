#!/bin/bash
# fix_actas_permission.sh
# Fix Cloud Run Deployment Permission (Auto)

set -e

echo "=== Fix Cloud Run Deployment Permission (Auto) ==="

# 1. Get Project ID
PROJECT_ID="${GCP_PROJECT_ID:-}"
if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
fi

if [ -z "$PROJECT_ID" ]; then
    echo "Error: Could not detect GCP_PROJECT_ID from env or gcloud config." >&2
    exit 1
fi
echo "Project: $PROJECT_ID"

# 2. Identify Runtime SA
RUNTIME_SA="meshcentral-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
echo "Runtime SA: $RUNTIME_SA"

# 3. Identify Deployer SA
DEPLOYER_SA="${GCP_SERVICE_ACCOUNT:-}"

if [ -z "$DEPLOYER_SA" ]; then
    echo "Searching for Deployer Service Account..."
    ALL_SAS=$(gcloud iam service-accounts list --project "$PROJECT_ID" --format="value(email)")

    # Filter out runtime SA, default compute SA, and appspot SA
    CANDIDATES=$(echo "$ALL_SAS" | grep -v "$RUNTIME_SA" \
        | grep -v "compute@developer.gserviceaccount.com" \
        | grep -v "appspot.gserviceaccount.com" \
        || true)

    CANDIDATE_COUNT=$(echo "$CANDIDATES" | grep -c . || true)

    if [ "$CANDIDATE_COUNT" -eq 1 ]; then
        DEPLOYER_SA="$CANDIDATES"
        echo "Found likely Deployer SA: $DEPLOYER_SA"
    elif [ "$CANDIDATE_COUNT" -gt 1 ]; then
        # Try to find one with 'github'
        GITHUB_SA=$(echo "$CANDIDATES" | grep "github" || true)
        if [ -n "$GITHUB_SA" ]; then
            DEPLOYER_SA=$(echo "$GITHUB_SA" | head -1)
            echo "Found likely Deployer SA (by name): $DEPLOYER_SA"
        else
            DEPLOYER_SA=$(echo "$CANDIDATES" | head -1)
            echo "WARNING: Ambiguous SAs found. Using first candidate: $DEPLOYER_SA"
        fi
    fi
fi

if [ -z "$DEPLOYER_SA" ]; then
    echo "Error: Could not auto-detect Deployer Service Account." >&2
    exit 1
fi

# 4. Grant Permission
echo "Granting 'iam.serviceAccountUser' role..."
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
    --member="serviceAccount:$DEPLOYER_SA" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID"

echo "Done! You can now re-run the GitHub Action."
