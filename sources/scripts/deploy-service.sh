#!/bin/sh
set -eu

# =============================================================================
# WSO Deployment Functions Library
# =============================================================================
# This file can be sourced by deployment scripts to use reusable functions,
# or executed directly as a wrapper for service-specific deployment scripts.
#
# Usage in deployment scripts:
#   . /srv/wso/deploy-service.sh  # Source this file to get functions
#   deploy "app-staging" "/app/etc/nginx.conf" "/app/etc/stack-compose.yml" "$IMAGE_NAME"
# =============================================================================

# -----------------------------------------------------------------------------
# deploy() - Master deployment function
# -----------------------------------------------------------------------------
# Handles the complete deployment workflow:
#   1. Pulls Docker image
#   2. Extracts nginx config and stack compose file from image
#   3. Deploys stack using docker stack config + docker stack deploy
#   4. Updates nginx configuration with proper timing (before/after deploy)
#
# Parameters:
#   $1 - SERVICE_NAME: Stack name and nginx config name (e.g., "app-staging")
#   $2 - NGINX_CONFIG_PATH: Path to nginx config inside container
#   $3 - STACK_COMPOSE_PATH: Path to stack compose file inside container
#   $4 - IMAGE_NAME: Full Docker image name (e.g., "registry.com/app:tag")
#
# Environment variables (must be set before calling):
#   ROOT_DIR: WSO installation directory (default: /srv/wso)
#   IMAGE_TAG, and any other variables needed by docker stack config
#
# Example:
#   SERVICE_NAME="myapp-staging"
#   IMAGE_NAME="my.registry.com/myapp:staging"
#   IMAGE_TAG="staging"
#   ROOT_DIR="/srv/wso"
#   deploy "$SERVICE_NAME" "/app/etc/nginx.conf" "/app/etc/stack-compose.yml" "$IMAGE_NAME"
# -----------------------------------------------------------------------------
deploy() {
    # Validate parameters
    if [ $# -ne 4 ]; then
        echo "Error: deploy() requires exactly 4 parameters" >&2
        echo "Usage: deploy <service-name> <nginx-config-path> <stack-compose-path> <image-name>" >&2
        return 1
    fi

    local SERVICE_NAME="$1"
    local NGINX_CONFIG_PATH="$2"
    local STACK_COMPOSE_PATH="$3"
    local IMAGE_NAME="$4"

    # Use ROOT_DIR from environment or default
    local ROOT_DIR="${ROOT_DIR:-/srv/wso}"

    # Temporary files
    local TEMP_NGINX_CONFIG="/tmp/${SERVICE_NAME}-nginx-$$.conf"
    local TEMP_STACK_COMPOSE="/tmp/${SERVICE_NAME}-stack-$$.yml"
    local TEMP_CONTAINER="${SERVICE_NAME}-tmp-$$"

    # Cleanup function
    _cleanup() {
        rm -f "$TEMP_NGINX_CONFIG" "$TEMP_STACK_COMPOSE"
        docker rm -f "$TEMP_CONTAINER" 2>/dev/null || true
    }
    trap _cleanup EXIT

    echo "========================================"
    echo "Deploying: ${SERVICE_NAME}"
    echo "Image: ${IMAGE_NAME}"
    echo "========================================"

    # Pull latest image
    echo "Pulling image: $IMAGE_NAME"
    if ! docker pull "$IMAGE_NAME"; then
        echo "Error: Failed to pull image" >&2
        return 1
    fi

    # Start temporary container to extract files
    echo "Starting temporary container to extract deployment files..."
    if ! docker run --rm --name "$TEMP_CONTAINER" -d "$IMAGE_NAME" sleep 30 2>/dev/null; then
        echo "Error: Could not start temporary container from image" >&2
        return 1
    fi

    # Extract stack compose file
    echo "Extracting stack compose file from: $STACK_COMPOSE_PATH"
    if docker cp "${TEMP_CONTAINER}:${STACK_COMPOSE_PATH}" "$TEMP_STACK_COMPOSE" 2>/dev/null; then
        echo "Stack compose file extracted successfully"
        HAS_STACK_COMPOSE=true
    else
        echo "Error: No stack compose file found in image at ${STACK_COMPOSE_PATH}" >&2
        HAS_STACK_COMPOSE=false
    fi

    # Extract nginx configuration
    echo "Extracting nginx configuration from: $NGINX_CONFIG_PATH"
    if docker cp "${TEMP_CONTAINER}:${NGINX_CONFIG_PATH}" "$TEMP_NGINX_CONFIG" 2>/dev/null; then
        echo "Nginx configuration extracted successfully"
        HAS_NGINX_CONFIG=true
    else
        echo "Error: No nginx configuration found in image at ${NGINX_CONFIG_PATH}" >&2
        HAS_NGINX_CONFIG=false
    fi

    # Stop temporary container
    docker stop "$TEMP_CONTAINER" >/dev/null 2>&1

    # Exit if required files are missing
    if [ "$HAS_STACK_COMPOSE" = false ]; then
        echo "Error: Stack compose file is required for deployment" >&2
        echo "Please ensure your image contains a file at: ${STACK_COMPOSE_PATH}" >&2
        return 1
    fi

    if [ "$HAS_NGINX_CONFIG" = false ]; then
        echo "Error: Nginx configuration is required for deployment" >&2
        echo "Please ensure your image contains a file at: ${NGINX_CONFIG_PATH}" >&2
        return 1
    fi

    # Check if stack already exists
    STACK_EXISTS=false
    if docker stack ls --format '{{.Name}}' | grep -q "^${SERVICE_NAME}$"; then
        STACK_EXISTS=true
        echo "Stack already exists: $SERVICE_NAME"
    fi

    # If stack exists, update nginx config BEFORE deploying
    # This ensures nginx is ready when the service updates
    if [ "$STACK_EXISTS" = true ]; then
        echo "Updating nginx configuration before deployment..."
        sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$SERVICE_NAME" "$TEMP_NGINX_CONFIG"
    fi

    # Deploy stack using docker stack config + docker stack deploy
    echo "Deploying stack: $SERVICE_NAME"
    if ! docker stack config -c "$TEMP_STACK_COMPOSE" | \
        docker stack deploy --with-registry-auth --compose-file - "$SERVICE_NAME"; then
        echo "Error: Stack deployment failed" >&2
        return 1
    fi

    # If stack is new, update nginx config AFTER deploying
    # The service needs to be running for nginx to test the proxy connection
    if [ "$STACK_EXISTS" = false ]; then
        echo "Waiting for service to be ready..."
        sleep 5

        echo "Creating nginx configuration after deployment..."
        sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$SERVICE_NAME" "$TEMP_NGINX_CONFIG"
    fi

    echo "========================================"
    echo "Deployment completed successfully"
    echo "Stack: ${SERVICE_NAME}"
    echo "Image: ${IMAGE_NAME}"
    echo "Nginx config: ${SERVICE_NAME}.conf"
    echo ""
    echo "Useful commands:"
    echo "  View services: docker stack services ${SERVICE_NAME}"
    echo "  View logs:     docker service logs <service-name>"
    echo "  Remove stack:  docker stack rm ${SERVICE_NAME}"
    echo "========================================"
}

# =============================================================================
# Wrapper Mode - Execute service-specific deployment scripts
# =============================================================================
# When this script is executed with arguments (not sourced), it acts as a
# secure wrapper that sources service-specific configuration scripts from
# /srv/wso/services/<project>/deploy.sh
#
# Protocol:
#   1. Parent sources the child script
#   2. Child script sets WSO_* configuration variables
#   3. Parent validates variables and executes deploy()
#
# Required variables in child script:
#   WSO_SERVICE_NAME      - Stack name and nginx config name
#   WSO_IMAGE_NAME        - Full Docker image name
#   WSO_NGINX_CONFIG_PATH - Path to nginx config inside container
#   WSO_STACK_COMPOSE_PATH - Path to stack compose file inside container
# =============================================================================

# Check if script is being sourced or executed
# This uses a POSIX-compatible method: return succeeds only when sourced
_wso_sourced=0
(return 0 2>/dev/null) && _wso_sourced=1

# Only run wrapper code if script is being executed (not sourced)
if [ "$_wso_sourced" = "0" ]; then
    # Determine ROOT_DIR from script location (portable)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    ROOT_DIR="$SCRIPT_DIR"
    export ROOT_DIR

    # Percorso base dei servizi
    BASE="$ROOT_DIR/services"

    # 1) Verifica presenza parametri
    if [ $# -lt 2 ]; then
      printf "Uso: %s <project> <environment> [args...]\n" "$(basename "$0")" >&2
      printf "Esempio: %s myapp staging\n" "$(basename "$0")" >&2
      printf "Esempio: %s myapp production\n" "$(basename "$0")" >&2
      exit 1
    fi

    project="$1"
    environment="$2"
    shift 2  # Rimuove i primi due parametri, lasciando gli altri in $@

    # 2) Valida il nome progetto: solo lettere, numeri, trattino e underscore (niente slash o ..)
    case "$project" in
      *[!/0-9A-Za-z_-]*|""|*/*|*..*)
        echo "Error: Invalid project name '$project'" >&2
        echo "Allowed: letters, digits, hyphens, underscores" >&2
        exit 1
        ;;
    esac

    # 3) Valida environment (deve essere un tag Docker valido)
    if ! expr "$environment" : '[A-Za-z0-9_][A-Za-z0-9._-]\{0,127\}$' >/dev/null 2>&1; then
        echo "Error: Invalid environment '$environment'" >&2
        echo "Must be 1-128 characters: letters, digits, underscore, period, hyphen" >&2
        echo "Cannot start with period or hyphen" >&2
        exit 1
    fi

    # 4) Costruisci percorso script di deploy del progetto
    target="$BASE/$project/deploy.sh"

    # 5) Controlla che esista ed è leggibile
    if [ ! -f "$target" ]; then
      echo "Error: Deployment script not found: $target" >&2
      exit 1
    fi

    # 6) Source the child script to get configuration via WSO_* variables
    # Pass environment and any additional arguments
    echo "Loading deployment configuration from: $target"
    . "$target" "$environment" "$@"

    # 7) Validate required configuration variables
    if [ -z "${WSO_SERVICE_NAME:-}" ]; then
        echo "Error: WSO_SERVICE_NAME not set in $target" >&2
        exit 1
    fi

    if [ -z "${WSO_IMAGE_NAME:-}" ]; then
        echo "Error: WSO_IMAGE_NAME not set in $target" >&2
        exit 1
    fi

    if [ -z "${WSO_NGINX_CONFIG_PATH:-}" ]; then
        echo "Error: WSO_NGINX_CONFIG_PATH not set in $target" >&2
        exit 1
    fi

    if [ -z "${WSO_STACK_COMPOSE_PATH:-}" ]; then
        echo "Error: WSO_STACK_COMPOSE_PATH not set in $target" >&2
        exit 1
    fi

    # 8) Execute deployment with configuration from child script
    deploy "$WSO_SERVICE_NAME" "$WSO_NGINX_CONFIG_PATH" "$WSO_STACK_COMPOSE_PATH" "$WSO_IMAGE_NAME"
fi

# If we're here, the script was sourced - functions are now available
