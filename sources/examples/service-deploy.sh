
#!/bin/sh
# Example service deployment script
# This script demonstrates how to deploy a service with nginx configuration updates
set -eu

# Configuration
SERVICE_NAME="myapp"
IMAGE_NAME="my.registry.com/myapp:production"
DOCKER_SERVICE_NAME="${SERVICE_NAME}-prod"
ROOT_DIR="${ROOT_DIR:-/srv/wso}"
TEMP_NGINX_CONFIG="/tmp/${SERVICE_NAME}-nginx-$$.conf"

# Cleanup on exit
cleanup() {
    rm -f "$TEMP_NGINX_CONFIG"
}
trap cleanup EXIT

# Pull latest image
echo "Pulling image: $IMAGE_NAME"
docker pull "$IMAGE_NAME"

# Extract nginx configuration from image
# Assumes the image contains nginx config at /app/nginx.conf or similar path
echo "Extracting nginx configuration from image..."
docker run --rm "$IMAGE_NAME" cat /app/nginx.conf > "$TEMP_NGINX_CONFIG"

# Update nginx configuration
echo "Updating nginx configuration..."
sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$SERVICE_NAME" "$TEMP_NGINX_CONFIG"

# Check if service exists
if docker service ls --format '{{.Name}}' | grep -q "^${DOCKER_SERVICE_NAME}$"; then
    # Update existing service
    echo "Updating existing service: $DOCKER_SERVICE_NAME"
    docker service update \
        --with-registry-auth \
        --image "$IMAGE_NAME" \
        "$DOCKER_SERVICE_NAME"
else
    # Create new service
    echo "Creating new service: $DOCKER_SERVICE_NAME"
    docker service create \
        --with-registry-auth \
        --name "$DOCKER_SERVICE_NAME" \
        --network ingress \
        --env DATABASE_URL="file:/data/sqlite/${SERVICE_NAME}.db" \
        --mount type=bind,source="$ROOT_DIR/data/sqlite",target=/data/sqlite \
        --mount type=bind,source="$ROOT_DIR/data/assets/${SERVICE_NAME}",target=/data/assets \
        "$IMAGE_NAME"
fi

echo "Deployment completed successfully"