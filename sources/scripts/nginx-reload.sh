#!/bin/sh
set -e

# Find nginx container
NGINX_CONTAINER=$(docker ps -q -f name=nginx)

if [ -z "$NGINX_CONTAINER" ]; then
    echo "Error: Nginx container not found" >&2
    exit 1
fi

echo "Testing nginx configuration..."

# Test configuration
if ! docker exec "$NGINX_CONTAINER" nginx -t 2>&1; then
    echo "Error: Nginx configuration test failed" >&2
    echo "Nginx was NOT reloaded" >&2
    exit 1
fi

echo "Configuration test passed"
echo "Reloading nginx..."

# Reload nginx
if docker exec "$NGINX_CONTAINER" nginx -s reload; then
    echo "Nginx reloaded successfully"
else
    echo "Error: Nginx reload failed" >&2
    exit 1
fi