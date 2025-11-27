#!/bin/sh
set -eu

# WSO Host Secret Reader
# Decrypts and outputs host secrets stored as systemd-creds
#
# Usage:
#   cat-global-secret.sh <service> <secret_name>
#
# Example:
#   TOKEN=$(sh /usr/lib/wso/scripts/cat-global-secret.sh myapp-staging backup_token)
#   curl -H "Authorization: Bearer $TOKEN" https://api.example.com/backup
#
# Host secrets are stored in /etc/credstore.encrypted/ as:
#   /etc/credstore.encrypted/{service}_{secret_name}.cred
#
# Where service is the full stack name (e.g., myapp-staging, myapp-production)

# Check arguments
if [ $# -lt 2 ]; then
    cat >&2 <<EOF
Usage: $0 <service> <secret_name>

Examples:
  $0 myapp-staging backup_token
  $0 myapp-production backup_token
  TOKEN=\$(sh $0 myapp-staging backup_token)

Host secrets are namespaced as: {service}_{secret_name}
Where service is the full stack name (e.g., myapp-staging)
EOF
    exit 1
fi

SERVICE="$1"
SECRET_NAME="$2"

# Build credential name
CRED_NAME="${SERVICE}_${SECRET_NAME}"
CRED_FILE="/etc/credstore.encrypted/${CRED_NAME}.cred"

# Check if credential file exists
if [ ! -f "$CRED_FILE" ]; then
    echo "Error: Host secret '$CRED_NAME' not found at $CRED_FILE" >&2
    echo "Available secrets for service '$SERVICE':" >&2
    ls -1 /etc/credstore.encrypted/${SERVICE}_*.cred 2>/dev/null | sed 's|.*/||; s|\.cred$||' >&2 || echo "  (none)" >&2
    exit 1
fi

# Decrypt and output secret using systemd-creds
if ! systemd-creds decrypt "$CRED_FILE" - 2>/dev/null; then
    echo "Error: Failed to decrypt host secret '$CRED_NAME'" >&2
    echo "Ensure systemd-creds is available and the credential file is valid" >&2
    exit 1
fi
