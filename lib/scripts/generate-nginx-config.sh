#!/bin/sh
set -eu

# generate-nginx-config.sh - Generate nginx configuration from manifest domains
# Usage: generate-nginx-config.sh <service-name> <manifest-path> <output-file>
#
# This script reads the 'domains' array from a WSO manifest and generates
# a complete nginx configuration with:
# - Server blocks for each domain (port 80 and 443)
# - ACME challenge location for certbot
# - Optional force HTTPS redirect
# - Service-specific subdomain on chdev.eu

log() {
    printf "[generate-nginx-config] %s\n" "$*" >&2
}

error() {
    printf "[generate-nginx-config ERROR] %s\n" "$*" >&2
}

die() {
    error "$@"
    exit 1
}

check_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        die "yq is not installed. Install with: sudo dnf install yq"
    fi

    # Detect yq version (Go vs Python)
    if yq --help 2>&1 | grep -q "eval"; then
        YQ_TYPE="go"
    else
        YQ_TYPE="python"
    fi
}

# =============================================================================
# Setup
# =============================================================================

if [ $# -ne 3 ]; then
    cat >&2 <<EOF
Usage: $0 <service-name> <manifest-path> <output-file>

Example:
  $0 myapp-staging /tmp/manifest.yml /tmp/nginx-config.conf

This script generates nginx configuration from the 'domains' array in the manifest.
EOF
    exit 1
fi

check_yq

SERVICE_NAME="$1"
MANIFEST_PATH="$2"
OUTPUT_FILE="$3"

# WSO Paths (hardcoded)
readonly ACME_WEBROOT="/var/lib/wso/acme-challenge"

if [ ! -f "$MANIFEST_PATH" ]; then
    die "Manifest file not found: $MANIFEST_PATH"
fi

# =============================================================================
# Parse Manifest
# =============================================================================

parse_manifest() {
    if [ "$YQ_TYPE" = "go" ]; then
        yq eval "$1" "$MANIFEST_PATH"
    else
        yq -r "$1" "$MANIFEST_PATH"
    fi
}

log "Parsing manifest: $MANIFEST_PATH"

FORCE_HTTPS="$(parse_manifest '.force_https // false')"
DOMAINS_COUNT="$(parse_manifest '.domains | length')"

if [ "$DOMAINS_COUNT" = "null" ]; then
    DOMAINS_COUNT=0
fi

log "  Service: $SERVICE_NAME"
log "  Custom domains: $DOMAINS_COUNT"
log "  Force HTTPS: $FORCE_HTTPS"

# =============================================================================
# Generate Configuration
# =============================================================================

TEMP_OUTPUT="/tmp/${SERVICE_NAME}-nginx-gen-$$.conf"

# Header comment
cat > "$TEMP_OUTPUT" <<EOF
# Nginx configuration for service: $SERVICE_NAME
# Generated automatically by WSO from manifest domains
# Do not edit manually - changes will be overwritten on next deployment

EOF

# =============================================================================
# Generate server blocks for each domain
# =============================================================================

if [ "$DOMAINS_COUNT" -gt 0 ]; then
    log "Generating server blocks for custom domains..."
fi

i=0
while [ $i -lt "$DOMAINS_COUNT" ]; do
    DOMAIN="$(parse_manifest ".domains[$i].domain")"
    CERT_NAME="$(parse_manifest ".domains[$i].cert_name // \"${SERVICE_NAME}_${DOMAIN}\"")"
    CONTAINER_NAME="$(parse_manifest ".domains[$i].container_name")"
    PORT="$(parse_manifest ".domains[$i].port // 8080")"

    if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "null" ]; then
        error "Domain at index $i is empty or null, skipping"
        i=$((i + 1))
        continue
    fi

    if [ -z "$CONTAINER_NAME" ] || [ "$CONTAINER_NAME" = "null" ]; then
        error "container_name for domain '$DOMAIN' is required"
        i=$((i + 1))
        continue
    fi

    UPSTREAM="${SERVICE_NAME}_${CONTAINER_NAME}"
    CERT_PATH="/etc/letsencrypt/live/${CERT_NAME}"

    log "  - $DOMAIN -> $UPSTREAM:$PORT (cert: $CERT_NAME)"

    # Generate HTTP (port 80) server block
    cat >> "$TEMP_OUTPUT" <<EOF

# HTTP server block for $DOMAIN
server {
    listen [::]:80;
    listen 80;
    server_name $DOMAIN;

    # ACME challenge for Let's Encrypt certificate validation
    location /.well-known/acme-challenge {
        alias ${ACME_WEBROOT}/.well-known/acme-challenge;
        try_files \$uri =404;
    }

EOF

    if [ "$FORCE_HTTPS" = "true" ]; then
        # Force HTTPS redirect
        cat >> "$TEMP_OUTPUT" <<EOF
    # Force HTTPS redirect
    location / {
        return 301 https://\$host\$request_uri;
    }
}

EOF
    else
        # Proxy to container
        cat >> "$TEMP_OUTPUT" <<EOF
    # Proxy to container
    location / {
        proxy_pass http://${UPSTREAM}:${PORT};
        include /etc/nginx/conf.d/includes/proxy-common.conf;
    }
}

EOF
    fi

    # Generate HTTPS (port 443) server block
    cat >> "$TEMP_OUTPUT" <<EOF
# HTTPS server block for $DOMAIN
server {
    listen [::]:443 ssl;
    listen 443 ssl;
    server_name $DOMAIN;

    # SSL Certificate paths
    ssl_certificate     ${CERT_PATH}/fullchain.pem;
    ssl_certificate_key ${CERT_PATH}/privkey.pem;

    # Include common SSL configuration
    include /etc/nginx/conf.d/includes/ssl-common.conf;

    # Proxy to container
    location / {
        proxy_pass http://${UPSTREAM}:${PORT};
        include /etc/nginx/conf.d/includes/proxy-common.conf;
    }

    # Custom error pages
    error_page 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}

EOF

    i=$((i + 1))
done

# =============================================================================
# Add service-specific chdev.eu subdomain
# =============================================================================

log "Adding service-specific chdev.eu subdomain..."

CHDEV_DOMAIN="${SERVICE_NAME}.chdev.eu"
CHDEV_CERT_PATH="/etc/letsencrypt/live/chdev.eu"

# Determine container and port for chdev.eu subdomain
# Priority: default_domain > domains[0]
DEFAULT_CONTAINER="$(parse_manifest '.default_domain.container_name // .domains[0].container_name')"
DEFAULT_PORT="$(parse_manifest '.default_domain.port // .domains[0].port // 8080')"

if [ -z "$DEFAULT_CONTAINER" ] || [ "$DEFAULT_CONTAINER" = "null" ]; then
    die "Either 'default_domain.container_name' or 'domains[0].container_name' must be specified"
fi

CHDEV_UPSTREAM="${SERVICE_NAME}_${DEFAULT_CONTAINER}"

log "  - $CHDEV_DOMAIN -> $CHDEV_UPSTREAM:$DEFAULT_PORT (cert: chdev.eu wildcard)"

cat >> "$TEMP_OUTPUT" <<EOF
# HTTP server block for service-specific chdev.eu subdomain
server {
    listen [::]:80;
    listen 80;
    server_name $CHDEV_DOMAIN;

    # ACME challenge for Let's Encrypt certificate validation
    location /.well-known/acme-challenge {
        alias ${ACME_WEBROOT}/.well-known/acme-challenge;
        try_files \$uri =404;
    }

EOF

if [ "$FORCE_HTTPS" = "true" ]; then
    cat >> "$TEMP_OUTPUT" <<EOF
    # Force HTTPS redirect
    location / {
        return 301 https://\$host\$request_uri;
    }
}

EOF
else
    cat >> "$TEMP_OUTPUT" <<EOF
    # Proxy to container
    location / {
        proxy_pass http://${CHDEV_UPSTREAM}:${DEFAULT_PORT};
        include /etc/nginx/conf.d/includes/proxy-common.conf;
    }
}

EOF
fi

cat >> "$TEMP_OUTPUT" <<EOF
# HTTPS server block for service-specific chdev.eu subdomain
server {
    listen [::]:443 ssl;
    listen 443 ssl;
    server_name $CHDEV_DOMAIN;

    # SSL Certificate paths (using chdev.eu wildcard)
    ssl_certificate     ${CHDEV_CERT_PATH}/fullchain.pem;
    ssl_certificate_key ${CHDEV_CERT_PATH}/privkey.pem;

    # Include common SSL configuration
    include /etc/nginx/conf.d/includes/ssl-common.conf;

    # Proxy to container
    location / {
        proxy_pass http://${CHDEV_UPSTREAM}:${DEFAULT_PORT};
        include /etc/nginx/conf.d/includes/proxy-common.conf;
    }

    # Custom error pages
    error_page 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF

# =============================================================================
# Save output
# =============================================================================

mv "$TEMP_OUTPUT" "$OUTPUT_FILE" || die "Failed to save output to $OUTPUT_FILE"

log "Nginx configuration generated successfully: $OUTPUT_FILE"
exit 0
