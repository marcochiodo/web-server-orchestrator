#!/bin/sh
# Example service deployment configuration script
#
# This script is sourced by /srv/wso/deploy-service.sh and provides deployment
# configuration via WSO_* environment variables.
#
# Protocol:
#   1. Parent validates project name and environment
#   2. Parent sources this script passing environment as $1
#   3. This script sets WSO_* configuration variables
#   4. Parent validates variables and executes deployment
#
# Required variables to set:
#   WSO_SERVICE_NAME       - Stack name and nginx config name (e.g., "myapp-staging")
#   WSO_IMAGE_NAME         - Full Docker image name (e.g., "registry.com/myapp:tag")
#   WSO_NGINX_CONFIG_PATH  - Path to nginx config inside the container
#   WSO_STACK_COMPOSE_PATH - Path to stack compose file inside the container
#
# Optional: Export environment variables for docker stack config interpolation
#   IMAGE_TAG, ROOT_DIR, DATABASE_URL, etc.
#
# Usage: sh /srv/wso/deploy-service.sh myapp <environment>
# Example: sh /srv/wso/deploy-service.sh myapp staging
# Example: sh /srv/wso/deploy-service.sh myapp production
set -eu

# =============================================================================
# Get environment from argument (validated by parent)
# =============================================================================
ENVIRONMENT="$1"

# =============================================================================
# Project Configuration
# =============================================================================
PROJECT_NAME="myapp"                      # Base project name
DOCKER_REGISTRY="my.registry.com"         # Your Docker registry
WORKDIR="/app"                            # Container working directory where files are stored

# =============================================================================
# WSO Deployment Configuration (read by parent)
# =============================================================================
# These variables tell deploy-service.sh what to deploy and how

# Service and image configuration
WSO_SERVICE_NAME="${PROJECT_NAME}-${ENVIRONMENT}"              # Stack name and nginx config name
WSO_IMAGE_NAME="${DOCKER_REGISTRY}/${PROJECT_NAME}:${ENVIRONMENT}"  # Full image name

# Paths to files inside the Docker container
WSO_NGINX_CONFIG_PATH="${WORKDIR}/etc/wso-nginx-${ENVIRONMENT}.conf"
WSO_STACK_COMPOSE_PATH="${WORKDIR}/etc/stack-compose.yml"

# =============================================================================
# Environment variables for docker stack config
# =============================================================================
# These variables will be interpolated by docker stack config into the compose file
# Add any variables your stack-compose.yml template uses (e.g., ${IMAGE_TAG}, ${ROOT_DIR})

export ENVIRONMENT="${ENVIRONMENT}"
export ROOT_DIR="${ROOT_DIR:-/srv/wso}"

# Example: Add more variables if your template needs them
# export DATABASE_URL="postgres://user:pass@db:5432/myapp"
# export REPLICAS="2"
# export MEMORY_LIMIT="512M"

# =============================================================================
# Optional: Custom pre-deployment logic
# =============================================================================
# You can add custom validation or setup here if needed

if [ "$ENVIRONMENT" = "production" ]; then
    echo "Deploying to PRODUCTION environment"
    # Add production-specific checks or settings...
fi