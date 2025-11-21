#!/bin/sh
set -eu

# WSO Managed Deployment System
# Wrapper that sources service configuration scripts and executes deployments.
#
# Protocol:
#   1. Service script at /srv/wso/services/<project>/deploy.sh sets WSO_* variables
#   2. This wrapper validates and executes the deployment
#
# Required WSO_* variables:
#   WSO_SERVICE_NAME, WSO_IMAGE_NAME, WSO_NGINX_CONFIG_PATH, WSO_STACK_COMPOSE_PATH

# Determine ROOT_DIR from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
export ROOT_DIR

# Check arguments
if [ $# -lt 2 ]; then
  printf "Usage: %s <project> <environment>\n" "$(basename "$0")" >&2
  printf "Example: %s myapp staging\n" "$(basename "$0")" >&2
  exit 1
fi

project="$1"
environment="$2"
shift 2

# Validate project name
case "$project" in
  *[!/0-9A-Za-z_-]*|""|*/*|*..*)
    echo "Error: Invalid project name '$project'" >&2
    exit 1
    ;;
esac

# Validate environment (must be valid Docker tag)
if ! expr "$environment" : '[A-Za-z0-9_][A-Za-z0-9._-]\{0,127\}$' >/dev/null 2>&1; then
    echo "Error: Invalid environment '$environment'" >&2
    echo "Must be 1-128 chars: letters, digits, underscore, period, hyphen" >&2
    exit 1
fi

# Source service configuration
target="$ROOT_DIR/services/$project/deploy.sh"
if [ ! -f "$target" ]; then
  echo "Error: Deployment script not found: $target" >&2
  exit 1
fi

echo "Loading configuration from: $target"
. "$target" "$environment" "$@"

# Validate required WSO_* variables
for var in WSO_SERVICE_NAME WSO_IMAGE_NAME WSO_NGINX_CONFIG_PATH WSO_STACK_COMPOSE_PATH; do
    eval "value=\${${var}:-}"
    if [ -z "$value" ]; then
        echo "Error: $var not set in $target" >&2
        exit 1
    fi
done

# Setup deployment
SERVICE_NAME="$WSO_SERVICE_NAME"
IMAGE_NAME="$WSO_IMAGE_NAME"
NGINX_CONFIG_PATH="$WSO_NGINX_CONFIG_PATH"
STACK_COMPOSE_PATH="$WSO_STACK_COMPOSE_PATH"

TEMP_NGINX_CONFIG="/tmp/${SERVICE_NAME}-nginx-$$.conf"
TEMP_STACK_COMPOSE="/tmp/${SERVICE_NAME}-stack-$$.yml"
TEMP_CONTAINER="${SERVICE_NAME}-tmp-$$"

cleanup() {
    rm -f "$TEMP_NGINX_CONFIG" "$TEMP_STACK_COMPOSE"
    docker rm -f "$TEMP_CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT

echo "========================================"
echo "Deploying: ${SERVICE_NAME}"
echo "Image: ${IMAGE_NAME}"
echo "========================================"

# Pull image
echo "Pulling image..."
docker pull "$IMAGE_NAME" || exit 1

# Start temporary container
echo "Starting temporary container..."
docker run --rm --name "$TEMP_CONTAINER" -d "$IMAGE_NAME" sleep 30 2>/dev/null || exit 1

# Extract files from container
echo "Extracting stack compose..."
if ! docker cp "${TEMP_CONTAINER}:${STACK_COMPOSE_PATH}" "$TEMP_STACK_COMPOSE" 2>/dev/null; then
    echo "Error: Stack compose not found at ${STACK_COMPOSE_PATH}" >&2
    exit 1
fi

echo "Extracting nginx config..."
if ! docker cp "${TEMP_CONTAINER}:${NGINX_CONFIG_PATH}" "$TEMP_NGINX_CONFIG" 2>/dev/null; then
    echo "Error: Nginx config not found at ${NGINX_CONFIG_PATH}" >&2
    exit 1
fi

docker stop "$TEMP_CONTAINER" >/dev/null 2>&1

# Check if stack exists
STACK_EXISTS=false
docker stack ls --format '{{.Name}}' | grep -q "^${SERVICE_NAME}$" && STACK_EXISTS=true

# Update nginx before deploy if stack exists
if [ "$STACK_EXISTS" = true ]; then
    echo "Updating nginx configuration..."
    sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$SERVICE_NAME" "$TEMP_NGINX_CONFIG"
fi

# Deploy stack
echo "Deploying stack..."
docker stack config -c "$TEMP_STACK_COMPOSE" | \
    docker stack deploy --with-registry-auth --compose-file - "$SERVICE_NAME" || exit 1

# Update nginx after deploy if stack is new
if [ "$STACK_EXISTS" = false ]; then
    echo "Waiting for service..."
    sleep 5
    echo "Creating nginx configuration..."
    sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$SERVICE_NAME" "$TEMP_NGINX_CONFIG"
fi

echo "========================================"
echo "Deployment completed"
echo "Stack: ${SERVICE_NAME}"
echo "Image: ${IMAGE_NAME}"
echo ""
echo "Commands:"
echo "  docker stack services ${SERVICE_NAME}"
echo "  docker service logs <service-name>"
echo "  docker stack rm ${SERVICE_NAME}"
echo "========================================"
