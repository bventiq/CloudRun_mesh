#!/bin/bash
# setup_gh_secrets.sh
# Restore GitHub Secrets & Variables (Smart Mode)

set -e

echo "=== Restore GitHub Secrets & Variables (Smart Mode) ==="

# Cache current remote config
REMOTE_VARS=$(gh variable list --json name --jq '.[].name' 2>/dev/null || echo "")
REMOTE_SECRETS=$(gh secret list --json name --jq '.[].name' 2>/dev/null || echo "")

set_var() {
    local name="$1"
    local default="$2"

    if echo "$REMOTE_VARS" | grep -qx "$name"; then
        echo "  $name is already set on GitHub."
        return
    fi

    # Check env
    val="${!name}"
    if [ -z "$val" ]; then
        prompt="Enter $name"
        if [ -n "$default" ]; then prompt="$prompt (default: $default)"; fi
        read -rp "$prompt: " val
        if [ -z "$val" ] && [ -n "$default" ]; then val="$default"; fi
    fi

    if [ -n "$val" ]; then
        echo "Setting $name..."
        gh variable set "$name" --body "$val"
    else
        echo "  Skipped $name (No value)"
    fi
}

set_secret() {
    local name="$1"

    if echo "$REMOTE_SECRETS" | grep -qx "$name"; then
        echo "  $name (Secret) is already set on GitHub."
        return
    fi

    # Check env
    val="${!name}"
    if [ -z "$val" ]; then
        read -rp "Enter $name: " val
    fi

    if [ -n "$val" ]; then
        echo "Setting $name..."
        gh secret set "$name" --body "$val"
    else
        echo "  Skipped $name (No value)"
    fi
}

# --- Variables ---
set_var "GCP_PROJECT_ID" ""
set_var "DOMAIN" ""
set_var "MESHCENTRAL_VERSION" "1.1.56"

# --- Secrets ---
set_secret "GCP_WORKLOAD_IDENTITY_PROVIDER"
set_secret "GCP_SERVICE_ACCOUNT"

echo ""
echo "Configuration Check Complete!"
