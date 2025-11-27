#!/bin/sh
# update-nginx-config.sh - Update nginx configuration for a service
# Usage: update-nginx-config.sh <service-name> <source-config-file>
#
# This script:
# - Compares checksums between new and existing nginx config
# - Updates the config file if different
# - Validates nginx syntax before applying
# - Reloads nginx if validation passes
# - Rolls back on validation failure

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root" >&2
    exit 1
fi

if [ $# -ne 2 ]; then
    echo "Usage: $0 <service-name> <source-config-file>" >&2
    echo "Example: $0 myapp /tmp/myapp-nginx.conf" >&2
    exit 1
fi

SERVICE_NAME="$1"
SOURCE_FILE="$2"

# WSO Paths (hardcoded)
readonly NGINX_CONF_DIR="/var/lib/wso/nginx"
TARGET_FILE="${NGINX_CONF_DIR}/${SERVICE_NAME}.conf"
BACKUP_FILE="${TARGET_FILE}.backup"

# Validate service name (alphanumeric, dash, underscore only)
if ! echo "$SERVICE_NAME" | grep -Eq '^[a-zA-Z0-9_-]+$'; then
    echo "Error: Invalid service name. Only alphanumeric characters, dashes, and underscores allowed." >&2
    exit 1
fi

# Check if source file exists and is readable
if [ ! -f "$SOURCE_FILE" ] || [ ! -r "$SOURCE_FILE" ]; then
    echo "Error: Source file '$SOURCE_FILE' does not exist or is not readable" >&2
    exit 1
fi

# Calculate checksums
SOURCE_CHECKSUM=$(sha256sum "$SOURCE_FILE" | cut -d' ' -f1)
if [ -f "$TARGET_FILE" ]; then
    TARGET_CHECKSUM=$(sha256sum "$TARGET_FILE" | cut -d' ' -f1)
else
    TARGET_CHECKSUM=""
fi

# Compare checksums
if [ "$SOURCE_CHECKSUM" = "$TARGET_CHECKSUM" ]; then
    echo "Nginx configuration for '$SERVICE_NAME' is already up to date (checksum match)"
    exit 0
fi

echo "Updating nginx configuration for service '$SERVICE_NAME'..."

# Backup existing file if it exists
if [ -f "$TARGET_FILE" ]; then
    echo "Creating backup: $BACKUP_FILE"
    cp "$TARGET_FILE" "$BACKUP_FILE"
fi

# Copy new configuration
echo "Installing new configuration: $TARGET_FILE"
cp "$SOURCE_FILE" "$TARGET_FILE"

# Get nginx container ID (from system stack)
NGINX_CONTAINER=$(docker ps -q -f name=system_nginx | head -n 1)

if [ -z "$NGINX_CONTAINER" ]; then
    echo "Error: Nginx container not found. Is system stack running?" >&2
    # Restore backup if it exists
    if [ -f "$BACKUP_FILE" ]; then
        echo "Restoring backup configuration..."
        mv "$BACKUP_FILE" "$TARGET_FILE"
    fi
    exit 1
fi

# Test nginx configuration
echo "Testing nginx configuration syntax..."
if docker exec "$NGINX_CONTAINER" nginx -t 2>&1; then
    echo "Nginx configuration syntax is valid"

    # Reload nginx
    echo "Reloading nginx..."
    if docker exec "$NGINX_CONTAINER" nginx -s reload; then
        echo "Nginx reloaded successfully"

        # Remove backup on success
        if [ -f "$BACKUP_FILE" ]; then
            rm "$BACKUP_FILE"
        fi

        echo "Nginx configuration for '$SERVICE_NAME' updated successfully"
        exit 0
    else
        echo "Error: Failed to reload nginx" >&2
        # Restore backup
        if [ -f "$BACKUP_FILE" ]; then
            echo "Restoring backup configuration..."
            mv "$BACKUP_FILE" "$TARGET_FILE"
        fi
        exit 1
    fi
else
    echo "Error: Nginx configuration syntax test failed" >&2

    # Restore backup
    if [ -f "$BACKUP_FILE" ]; then
        echo "Restoring backup configuration..."
        mv "$BACKUP_FILE" "$TARGET_FILE"
    else
        # No backup, remove the invalid file
        echo "Removing invalid configuration file..."
        rm "$TARGET_FILE"
    fi

    exit 1
fi
