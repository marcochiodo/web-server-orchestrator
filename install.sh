#!/bin/bash
################################################################################
# Web Server Orchestrator (WSO) - Installation Script
################################################################################
# Installs WSO following Linux FHS (Filesystem Hierarchy Standard)
#
# Installation paths:
#   /usr/bin/wso-*            - Public commands
#   /usr/lib/wso/             - Libraries and internal scripts
#   /etc/wso/                 - Configuration
#   /var/lib/wso/             - Runtime data
#
# Usage:
#   sudo ./install.sh
################################################################################

set -e  # Exit on error

################################################################################
# Color definitions
################################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Logging functions
################################################################################
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

################################################################################
# Check if running as root
################################################################################
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root. Please use 'sudo' or switch to root user."
    exit 1
fi

log_success "Running as root"

################################################################################
# Detect OS and package manager
################################################################################
log_info "Detecting operating system..."

if [ -f /etc/debian_version ]; then
    OS="debian"
    PKG_MANAGER="apt"
    log_success "Detected Debian/Ubuntu system"
elif [ -f /etc/fedora-release ]; then
    OS="fedora"
    PKG_MANAGER="dnf"
    log_success "Detected Fedora system"
else
    log_error "Unsupported OS. WSO supports Debian/Ubuntu and Fedora."
    exit 1
fi

################################################################################
# Install required packages
################################################################################
log_info "Installing required packages..."

if [ "$PKG_MANAGER" = "apt" ]; then
    apt update
    PACKAGES="rsync ca-certificates curl docker.io yq fail2ban gettext-base"
elif [ "$PKG_MANAGER" = "dnf" ]; then
    PACKAGES="rsync ca-certificates curl docker yq fail2ban gettext"
fi

log_info "Installing: $PACKAGES"
$PKG_MANAGER install -y $PACKAGES

# Ensure Docker service is running
systemctl enable docker
systemctl start docker

log_success "All packages installed"

################################################################################
# Create deployer user if not exists
################################################################################
log_info "Checking for deployer user..."

if id "deployer" &>/dev/null; then
    log_success "User 'deployer' already exists"
else
    log_info "Creating user 'deployer'..."
    useradd -m -d /home/deployer deployer -u 1010 -s "/bin/bash"

    echo ""
    log_warning "Please set a password for user 'deployer':"
    passwd deployer

    log_success "User 'deployer' created"
fi

################################################################################
# Create directory structure (FHS compliant)
################################################################################
log_info "Creating directory structure..."

# /usr/lib/wso - Code and libraries
mkdir -p /usr/lib/wso/scripts
mkdir -p /usr/lib/wso/docker
mkdir -p /usr/lib/wso/www-default

# /etc/wso - Configuration
mkdir -p /etc/wso/nginx-includes

# /var/lib/wso - Runtime data
mkdir -p /var/lib/wso/nginx
mkdir -p /var/lib/wso/letsencrypt
mkdir -p /var/lib/wso/letsencrypt-lib
mkdir -p /var/lib/wso/acme-challenge/.well-known/acme-challenge
mkdir -p /var/lib/wso/data

log_success "Directory structure created"

################################################################################
# File copy helper with checksum verification
################################################################################
copy_file() {
    local src="$1"
    local dst="$2"
    local description="$3"

    # If destination doesn't exist, copy directly
    if [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        log_success "Created: $description"
        return 0
    fi

    # Calculate checksums
    src_checksum=$(md5sum "$src" | awk '{print $1}')
    dst_checksum=$(md5sum "$dst" | awk '{print $1}')

    # If checksums are identical, skip
    if [ "$src_checksum" = "$dst_checksum" ]; then
        log_info "Unchanged: $description"
        return 0
    fi

    # Checksums differ, ask user
    echo ""
    log_warning "File differs: $description"
    log_info "Destination: $dst"
    read -p "Do you want to update it? [y/N]: " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cp "$src" "$dst"
        log_success "Updated: $description"
    else
        log_info "Skipped: $description"
    fi
}

################################################################################
# Copy source files
################################################################################
log_info "Copying WSO files..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy public commands to /usr/bin
copy_file "$SCRIPT_DIR/bin/wso-deploy" "/usr/bin/wso-deploy" "wso-deploy"
copy_file "$SCRIPT_DIR/bin/wso-cert-gen" "/usr/bin/wso-cert-gen" "wso-cert-gen"
copy_file "$SCRIPT_DIR/bin/wso-cert-gen-ovh" "/usr/bin/wso-cert-gen-ovh" "wso-cert-gen-ovh"
copy_file "$SCRIPT_DIR/bin/wso-cert-renew" "/usr/bin/wso-cert-renew" "wso-cert-renew"
copy_file "$SCRIPT_DIR/bin/wso-nginx-reload" "/usr/bin/wso-nginx-reload" "wso-nginx-reload"
copy_file "$SCRIPT_DIR/bin/wso-nginx-restart" "/usr/bin/wso-nginx-restart" "wso-nginx-restart"
copy_file "$SCRIPT_DIR/bin/wso-nginx-verify" "/usr/bin/wso-nginx-verify" "wso-nginx-verify"

# Make executable
chmod +x /usr/bin/wso-*

# Copy internal scripts to /usr/lib/wso/scripts
copy_file "$SCRIPT_DIR/lib/scripts/generate-nginx-config.sh" "/usr/lib/wso/scripts/generate-nginx-config.sh" "generate-nginx-config.sh"
copy_file "$SCRIPT_DIR/lib/scripts/generate-crontab.sh" "/usr/lib/wso/scripts/generate-crontab.sh" "generate-crontab.sh"
copy_file "$SCRIPT_DIR/lib/scripts/update-nginx-config.sh" "/usr/lib/wso/scripts/update-nginx-config.sh" "update-nginx-config.sh"
copy_file "$SCRIPT_DIR/lib/scripts/cat-global-secret.sh" "/usr/lib/wso/scripts/cat-global-secret.sh" "cat-global-secret.sh"

chmod +x /usr/lib/wso/scripts/*.sh

# Copy docker compose
copy_file "$SCRIPT_DIR/lib/docker/system-compose.yml" "/usr/lib/wso/docker/system-compose.yml" "system-compose.yml"

# Copy nginx configuration files to /var/lib/wso/nginx
# Note: default.conf will be processed later with envsubst after MAIN_DOMAIN is set
cp "$SCRIPT_DIR/lib/nginx/default.conf" "/tmp/wso-default.conf.template"
copy_file "$SCRIPT_DIR/lib/nginx/ssl-common.conf" "/etc/wso/nginx-includes/ssl-common.conf" "ssl-common.conf"
copy_file "$SCRIPT_DIR/lib/nginx/proxy-common.conf" "/etc/wso/nginx-includes/proxy-common.conf" "proxy-common.conf"

# Copy static default website
copy_file "$SCRIPT_DIR/lib/www-default/index.html" "/usr/lib/wso/www-default/index.html" "default index.html"

log_success "WSO files copied"

################################################################################
# Configure wso.conf
################################################################################
log_info "Configuring WSO..."

# Load existing config if present
if [ -f "/etc/wso/wso.conf" ]; then
    source /etc/wso/wso.conf
fi

# Check if MAIN_DOMAIN is defined and not empty
if [ -z "${MAIN_DOMAIN:-}" ]; then
    echo ""
    log_info "Main domain configuration for service subdomains"
    echo "  This domain will be used for service subdomains (e.g., service-name.example.com)"
    read -p "Enter main domain: " MAIN_DOMAIN

    if [ -z "$MAIN_DOMAIN" ]; then
        log_error "Main domain cannot be empty"
        exit 1
    fi

    # Update or create config file
    if [ -f "/etc/wso/wso.conf" ]; then
        # Check if MAIN_DOMAIN line exists
        if grep -q "^MAIN_DOMAIN=" /etc/wso/wso.conf; then
            # Update existing line
            sed -i "s|^MAIN_DOMAIN=.*|MAIN_DOMAIN=$MAIN_DOMAIN|" /etc/wso/wso.conf
            log_success "WSO configuration updated"
        else
            # Append MAIN_DOMAIN to existing file
            echo "MAIN_DOMAIN=$MAIN_DOMAIN" >> /etc/wso/wso.conf
            log_success "WSO configuration updated"
        fi
    else
        # Create new config file
        cat > /etc/wso/wso.conf <<EOF
# WSO Global Configuration
# Main domain for service subdomains (e.g., service-name.$MAIN_DOMAIN)
MAIN_DOMAIN=$MAIN_DOMAIN
EOF
        log_success "WSO configuration created"
    fi
else
    log_success "MAIN_DOMAIN already configured: $MAIN_DOMAIN"
fi

# Generate default.conf with MAIN_DOMAIN substituted
export MAIN_DOMAIN
if [ -f /tmp/wso-default.conf.template ]; then
    envsubst '$MAIN_DOMAIN' < /tmp/wso-default.conf.template > /tmp/wso-default.conf.generated
    rm /tmp/wso-default.conf.template

    if [ ! -f /var/lib/wso/nginx/default.conf ]; then
        cp /tmp/wso-default.conf.generated /var/lib/wso/nginx/default.conf
        log_success "Created: nginx default.conf"
    else
        src_checksum=$(md5sum /tmp/wso-default.conf.generated | awk '{print $1}')
        dst_checksum=$(md5sum /var/lib/wso/nginx/default.conf | awk '{print $1}')

        if [ "$src_checksum" = "$dst_checksum" ]; then
            log_info "Unchanged: nginx default.conf"
        else
            echo ""
            log_warning "File differs: nginx default.conf"
            read -p "Do you want to update it? [y/N]: " -n 1 -r
            echo

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cp /tmp/wso-default.conf.generated /var/lib/wso/nginx/default.conf
                log_success "Updated: nginx default.conf"
            else
                log_info "Skipped: nginx default.conf"
            fi
        fi
    fi
    rm /tmp/wso-default.conf.generated
fi

################################################################################
# Configure sudoers
################################################################################
log_info "Configuring sudoers for deployer..."

SUDOERS_FILE="/etc/sudoers.d/wso-deployer"
SUDOERS_TEMP="/tmp/wso-deployer.tmp.$$"

# Copy sudoers file
cp "$SCRIPT_DIR/etc/sudoers.d/wso-deployer" "$SUDOERS_TEMP"

# Verify syntax with visudo
if ! visudo -c -f "$SUDOERS_TEMP" >/dev/null 2>&1; then
    log_error "Sudoers file has invalid syntax!"
    rm -f "$SUDOERS_TEMP"
    exit 1
fi

# Install sudoers file
if [ ! -f "$SUDOERS_FILE" ]; then
    install -m 0440 "$SUDOERS_TEMP" "$SUDOERS_FILE"
    rm -f "$SUDOERS_TEMP"
    log_success "Sudoers configuration created"
else
    # Check if files differ
    src_checksum=$(md5sum "$SUDOERS_TEMP" | awk '{print $1}')
    dst_checksum=$(md5sum "$SUDOERS_FILE" | awk '{print $1}')

    if [ "$src_checksum" = "$dst_checksum" ]; then
        log_info "Unchanged: sudoers configuration"
        rm -f "$SUDOERS_TEMP"
    else
        echo ""
        log_warning "Sudoers configuration differs"
        read -p "Do you want to update it? [y/N]: " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            install -m 0440 "$SUDOERS_TEMP" "$SUDOERS_FILE"
            log_success "Updated: sudoers configuration"
        else
            log_info "Skipped: sudoers configuration"
        fi
        rm -f "$SUDOERS_TEMP"
    fi
fi

################################################################################
# Configure SSH
################################################################################
log_info "Checking SSH password authentication..."

if sshd -T 2>/dev/null | grep -q "^passwordauthentication yes"; then
    log_success "SSH password authentication is already enabled"
else
    echo ""
    log_warning "SSH password authentication is currently disabled."
    read -p "Do you want to enable SSH password authentication? [y/N]: " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p /etc/ssh/sshd_config.d
        copy_file "$SCRIPT_DIR/etc/ssh/10-wso.conf" "/etc/ssh/sshd_config.d/10-wso.conf" "WSO SSH configuration"

        log_info "Restarting SSH service..."
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        log_success "SSH password authentication enabled"
    else
        log_info "SSH configuration unchanged"
    fi
fi

################################################################################
# Configure fail2ban
################################################################################
log_info "Configuring fail2ban for SSH protection..."

copy_file "$SCRIPT_DIR/etc/fail2ban/jail.local" "/etc/fail2ban/jail.local" "fail2ban jail.local"

log_info "Starting fail2ban service..."
systemctl enable fail2ban
systemctl restart fail2ban

log_success "fail2ban configured and running"

################################################################################
# Install cron job for certificate renewal
################################################################################
log_info "Installing certificate renewal cron job..."

copy_file "$SCRIPT_DIR/etc/cron.d/wso-cert-renew" "/etc/cron.d/wso-cert-renew" "wso-cert-renew cron"
chmod 644 /etc/cron.d/wso-cert-renew

log_success "Certificate renewal cron job installed"

################################################################################
# Docker registry login
################################################################################
echo ""
log_info "Docker registry configuration"

if [ -f ~/.docker/config.json ] && grep -q '"auths"' ~/.docker/config.json 2>/dev/null; then
    log_success "Docker registry credentials already configured"
else
    read -p "Do you want to login to a Docker registry? [y/N]: " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Use custom registry endpoint? [y/N]: " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "Registry URL: " REGISTRY_URL
            read -p "Username: " REGISTRY_USER
            read -sp "Password: " REGISTRY_PASS
            echo

            echo "$REGISTRY_PASS" | docker login "$REGISTRY_URL" -u "$REGISTRY_USER" --password-stdin
        else
            read -p "Docker Hub username: " REGISTRY_USER
            read -sp "Docker Hub password: " REGISTRY_PASS
            echo

            echo "$REGISTRY_PASS" | docker login -u "$REGISTRY_USER" --password-stdin
        fi

        log_success "Docker registry login successful"
    else
        log_info "Skipping Docker registry login"
    fi
fi

################################################################################
# Initialize Docker Swarm
################################################################################
echo ""
log_info "Checking Docker Swarm status..."

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log_success "Docker Swarm already initialized"
else
    log_info "Initializing Docker Swarm..."
    docker swarm init
    log_success "Docker Swarm initialized"
fi

################################################################################
# Create overlay network
################################################################################
log_info "Checking overlay network..."

if docker network ls | grep -q "wso-net"; then
    log_success "Overlay network 'wso-net' already exists"
else
    log_info "Creating overlay network 'wso-net'..."
    docker network create --driver overlay --attachable wso-net
    log_success "Overlay network 'wso-net' created"
fi

################################################################################
# Generate wildcard certificate for main domain
################################################################################
echo ""
log_info "Wildcard SSL certificate generation"

MAIN_CERT_PATH="/var/lib/wso/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem"

if [ -f "$MAIN_CERT_PATH" ]; then
    log_success "Certificate for $MAIN_DOMAIN already exists"

    read -p "Do you want to regenerate the wildcard certificate? [y/N]: " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        GENERATE_CERT=true
    else
        GENERATE_CERT=false
    fi
else
    read -p "Do you want to generate the wildcard certificate? [y/N]: " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        GENERATE_CERT=true
    else
        GENERATE_CERT=false
    fi
fi

if [ "$GENERATE_CERT" = true ]; then
    echo ""
    log_info "Certificate domain configuration"
    echo "  Enter domains separated by space:"
    echo "  - Main domain only: example.com"
    echo "    → Generates: example.com, *.example.com"
    echo "  - With subdomains: example.com api.example.com"
    echo "    → Generates: example.com, *.example.com, api.example.com, *.api.example.com"
    echo ""
    read -p "Enter domains [$MAIN_DOMAIN]: " CERT_DOMAINS
    CERT_DOMAINS=${CERT_DOMAINS:-$MAIN_DOMAIN}

    # Build certificate domains list with wildcards
    CERT_LIST=""
    for domain in $CERT_DOMAINS; do
        if [ -z "$CERT_LIST" ]; then
            CERT_LIST="$domain,*.$domain"
        else
            CERT_LIST="$CERT_LIST,$domain,*.$domain"
        fi
    done

    log_info "Generating certificate for: $CERT_LIST"
    wso-cert-gen-ovh "$CERT_LIST"
    log_success "Wildcard certificate generated"
fi

################################################################################
# Deploy system stack
################################################################################
log_info "Checking system stack..."

SYSTEM_STACK_NAME="system"
SYSTEM_COMPOSE_FILE="/usr/lib/wso/docker/system-compose.yml"

if docker service ls 2>/dev/null | grep -q "system_nginx"; then
    log_success "System stack already exists"

    CURRENT_IMAGE=$(docker service inspect system_nginx --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null | cut -d@ -f1)

    echo ""
    echo "Current nginx image: $CURRENT_IMAGE"
    echo "Target nginx image:  nginx:1.29-alpine"
    echo ""

    read -p "Do you want to redeploy the system stack? [y/N]: " redeploy_system

    if [ "$redeploy_system" = "y" ] || [ "$redeploy_system" = "Y" ]; then
        log_info "Deploying system stack..."
        docker stack deploy --compose-file "$SYSTEM_COMPOSE_FILE" "$SYSTEM_STACK_NAME"

        log_info "Verifying nginx is running..."
        if wso-nginx-verify 30; then
            log_success "System stack redeployed and verified"
        else
            log_error "Nginx verification failed - check 'docker service ps system_nginx'"
            exit 1
        fi
    else
        log_info "System stack deployment skipped"
    fi
else
    log_info "Deploying system stack..."
    docker stack deploy --compose-file "$SYSTEM_COMPOSE_FILE" "$SYSTEM_STACK_NAME"

    log_info "Verifying nginx is running..."
    if wso-nginx-verify 30; then
        log_success "System stack deployed and verified"
    else
        log_error "Nginx verification failed - check 'docker service ps system_nginx'"
        exit 1
    fi
fi

################################################################################
# Final summary
################################################################################
echo ""
echo "================================================================================"
log_success "WSO Installation Complete!"
echo "================================================================================"
echo ""
log_info "Installed components:"
echo "  Commands:      /usr/bin/wso-*"
echo "  Libraries:     /usr/lib/wso/"
echo "  Configuration: /etc/wso/"
echo "  Data:          /var/lib/wso/"
echo ""
log_info "System status:"
echo "  Deployer user: deployer"
echo "  Docker Swarm:  active"
echo "  System stack:  running"
echo "  fail2ban:      active (SSH protection)"
echo ""
log_info "Next steps:"
echo "  1. Deploy a service:"
echo "     wso-deploy manifest.yml"
echo ""
echo "  2. Generate SSL certificates:"
echo "     wso-cert-gen domain.com"
echo "     wso-cert-gen-ovh '*.domain.com,domain.com'"
echo ""
echo "  3. Manage nginx:"
echo "     wso-nginx-reload   # Reload configuration"
echo "     wso-nginx-restart  # Restart nginx (graceful)"
echo ""
log_info "Documentation:"
echo "  Example manifest: $SCRIPT_DIR/examples/wso-deploy.yml"
echo "  GitHub Actions:   $SCRIPT_DIR/examples/github-action-deploy.yml"
echo ""
echo "================================================================================"
