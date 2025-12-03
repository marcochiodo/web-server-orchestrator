#!/bin/sh
set -eu

# WSO Host Secret Reader
# Reads host secrets stored as plain files with root-only permissions
#
# Usage:
#   cat-global-secret.sh <service> <secret_name>
#
# Example:
#   TOKEN=$(sh /usr/lib/wso/scripts/cat-global-secret.sh myapp-staging backup_token)
#   curl -H "Authorization: Bearer $TOKEN" https://api.example.com/backup
#
# Host secrets are stored in /var/lib/wso/secrets/ as:
#   /var/lib/wso/secrets/{service}_{secret_name}
#
# Where service is the full stack name (e.g., myapp-staging, myapp-production)
# Files have 400 permissions (only root can read)

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

# Build secret file path
SECRET_FILE="/var/lib/wso/secrets/${SERVICE}_${SECRET_NAME}"

# Check if secret file exists
if [ ! -f "$SECRET_FILE" ]; then
    echo "Error: Host secret '${SERVICE}_${SECRET_NAME}' not found at $SECRET_FILE" >&2
    echo "Available secrets for service '$SERVICE':" >&2
    ls -1 /var/lib/wso/secrets/${SERVICE}_* 2>/dev/null | sed 's|.*/||' >&2 || echo "  (none)" >&2
    exit 1
fi

# Read and output secret
cat "$SECRET_FILE"
