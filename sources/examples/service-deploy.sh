
#!/bin/sh
# Example service deployment script
# This script demonstrates how to deploy a service with nginx configuration updates
# Usage: ./deploy.sh [environment]
# Example: ./deploy.sh staging
# Example: ./deploy.sh production
set -eu

# Get environment from argument (default: production)
ENVIRONMENT="${1:-production}"

# Validate environment parameter
case "$ENVIRONMENT" in
    staging|production|development|dev|prod)
        ;;
    *)
        echo "Error: Invalid environment '$ENVIRONMENT'" >&2
        echo "Usage: $0 [staging|production|development]" >&2
        exit 1
        ;;
esac

# Configuration
SERVICE_NAME="myapp"
IMAGE_TAG="$ENVIRONMENT"
IMAGE_NAME="my.registry.com/myapp:${IMAGE_TAG}"
DOCKER_SERVICE_NAME="${SERVICE_NAME}-${ENVIRONMENT}"
NGINX_CONFIG_NAME="${SERVICE_NAME}-${ENVIRONMENT}"
ROOT_DIR="${ROOT_DIR:-/srv/wso}"
TEMP_NGINX_CONFIG="/tmp/${SERVICE_NAME}-${ENVIRONMENT}-nginx-$$.conf"

# Cleanup on exit
cleanup() {
    rm -f "$TEMP_NGINX_CONFIG"
}
trap cleanup EXIT

echo "================================"
echo "Deploying ${SERVICE_NAME} to ${ENVIRONMENT}"
echo "================================"

# Pull latest image
echo "Pulling image: $IMAGE_NAME"
docker pull "$IMAGE_NAME"

# Extract nginx configuration from image
# Assumes the image contains environment-specific nginx configs:
# - /app/nginx-production.conf
# - /app/nginx-staging.conf
# - /app/nginx-development.conf
echo "Extracting nginx configuration from image..."
docker run --rm "$IMAGE_NAME" cat "/app/nginx-${ENVIRONMENT}.conf" > "$TEMP_NGINX_CONFIG"

# Update nginx configuration
echo "Updating nginx configuration for ${SERVICE_NAME}-${ENVIRONMENT}..."
sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$NGINX_CONFIG_NAME" "$TEMP_NGINX_CONFIG"

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

echo "================================"
echo "Deployment of ${SERVICE_NAME} to ${ENVIRONMENT} completed successfully"
echo "Service: ${DOCKER_SERVICE_NAME}"
echo "Nginx config: ${NGINX_CONFIG_NAME}.conf"
echo "================================"