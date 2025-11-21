#!/bin/sh
# Example service deployment script using docker stack config + docker stack deploy
# This script demonstrates the declarative approach with environment-specific deployments
#
# Concept: Use a stack-template.yml with variables (${IMAGE_TAG}, ${ROOT_DIR})
#          docker stack config interpolates variables to create final config
#          docker stack deploy deploys the interpolated config
#
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
PROJECT_NAME="myapp"              # Used for stack name and image name
SERVICE_NAME="webapp"              # Service name inside compose file
STACK_NAME="${PROJECT_NAME}"
IMAGE_TAG="$ENVIRONMENT"
NGINX_CONFIG_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
ROOT_DIR="${ROOT_DIR:-/srv/wso}"
TEMPLATE_FILE="./stack-template.yml"
TEMP_NGINX_CONFIG="/tmp/${PROJECT_NAME}-${ENVIRONMENT}-nginx-$$.conf"
TEMP_CONTAINER="${PROJECT_NAME}-tmp-$$"

# Cleanup on exit
cleanup() {
    rm -f "$TEMP_NGINX_CONFIG"
    docker rm -f "$TEMP_CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT

echo "================================"
echo "Deploying ${PROJECT_NAME} (${ENVIRONMENT})"
echo "================================"

# Check if template file exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file not found: $TEMPLATE_FILE" >&2
    echo "Please create a stack-template.yml file in the current directory" >&2
    echo "See examples/stack-template.yml for a template" >&2
    exit 1
fi

# Pull latest image
IMAGE_NAME="my.registry.com/${PROJECT_NAME}:${IMAGE_TAG}"
echo "Pulling image: $IMAGE_NAME"
docker pull "$IMAGE_NAME"

# Extract nginx configuration from image
# This assumes your Docker image contains environment-specific nginx configs:
# - /app/nginx-production.conf
# - /app/nginx-staging.conf
# - /app/nginx-development.conf
echo "Extracting nginx configuration from image..."

if docker run --rm --name "$TEMP_CONTAINER" -d "$IMAGE_NAME" sleep 30 2>/dev/null; then
    # Try to extract nginx config from container
    if docker cp "${TEMP_CONTAINER}:/app/nginx-${ENVIRONMENT}.conf" "$TEMP_NGINX_CONFIG" 2>/dev/null; then
        echo "Nginx configuration extracted successfully"
        HAS_NGINX_CONFIG=true
    else
        echo "Error: No nginx configuration found in image at /app/nginx-${ENVIRONMENT}.conf" >&2
        HAS_NGINX_CONFIG=false
    fi
    docker stop "$TEMP_CONTAINER" >/dev/null 2>&1
else
    echo "Error: Could not extract nginx configuration from image" >&2
    HAS_NGINX_CONFIG=false
fi

# Exit if nginx config is missing
if [ "$HAS_NGINX_CONFIG" = false ]; then
    echo "Error: Nginx configuration is required for deployment" >&2
    echo "Please ensure your image contains /app/nginx-${ENVIRONMENT}.conf" >&2
    exit 1
fi

# Check if stack already exists
STACK_EXISTS=false
if docker stack ls --format '{{.Name}}' | grep -q "^${STACK_NAME}$"; then
    STACK_EXISTS=true
    echo "Stack already exists: $STACK_NAME"
fi

# If stack exists, update nginx config BEFORE deploying
# This ensures nginx is ready when the service updates
if [ "$STACK_EXISTS" = true ]; then
    echo "Updating nginx configuration for ${PROJECT_NAME}-${ENVIRONMENT}..."
    sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$NGINX_CONFIG_NAME" "$TEMP_NGINX_CONFIG"
fi

# Deploy stack using docker stack config + docker stack deploy
echo "Deploying stack: $STACK_NAME"
IMAGE_TAG="$IMAGE_TAG" ROOT_DIR="$ROOT_DIR" docker stack config -c "$TEMPLATE_FILE" | \
    docker stack deploy --with-registry-auth --compose-file - "$STACK_NAME"

# If stack is new, update nginx config AFTER deploying
# The service needs to be running for nginx to test the proxy connection
if [ "$STACK_EXISTS" = false ]; then
    echo "Waiting for service to be ready..."
    sleep 5

    echo "Creating nginx configuration for ${PROJECT_NAME}-${ENVIRONMENT}..."
    sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$NGINX_CONFIG_NAME" "$TEMP_NGINX_CONFIG"
fi

echo "================================"
echo "Deployment completed successfully"
echo "Stack: ${STACK_NAME}"
echo "Service: ${STACK_NAME}_${SERVICE_NAME}"
echo "Environment: ${ENVIRONMENT}"
echo "Image: ${IMAGE_NAME}"
echo "Nginx config: ${NGINX_CONFIG_NAME}.conf"
echo ""
echo "Useful commands:"
echo "  View logs:    docker service logs ${STACK_NAME}_${SERVICE_NAME}"
echo "  Scale:        docker service scale ${STACK_NAME}_${SERVICE_NAME}=3"
echo "  Remove stack: docker stack rm ${STACK_NAME}"
echo "================================"
