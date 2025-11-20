#!/bin/bash
################################################################################
# Web Server Orchestrator (WSO) - Installation Script
################################################################################
# This script automates the setup of a Docker Swarm-based web server with
# nginx reverse proxy and Let's Encrypt certificate management.
#
# Features:
# - Idempotent: Can be safely re-run on already configured servers
# - File synchronization with checksum verification
# - Interactive prompts for user-specific configuration
# - Support for Debian/Ubuntu systems
################################################################################

set -e  # Exit on error

################################################################################
# Color definitions for output
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
# Ask for installation directory
################################################################################
echo ""
log_info "Where would you like to install WSO?"
read -p "Installation path [/srv/wso]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/srv/wso}

log_info "Installation directory set to: $INSTALL_DIR"

# Set ROOT_DIR for the rest of the script
ROOT_DIR="$INSTALL_DIR"

################################################################################
# Detect OS and package manager
################################################################################
log_info "Detecting operating system..."

if [ -f /etc/debian_version ]; then
    OS="debian"
    PKG_MANAGER="apt"
    log_success "Detected Debian/Ubuntu system"
else
    log_error "Only Debian/Ubuntu systems are currently supported"
    exit 1
fi

################################################################################
# Install required packages
################################################################################
log_info "Installing required packages..."

# Update package lists
log_info "Updating package lists..."
apt update

# Install packages
PACKAGES="rsync sqlite3 ca-certificates curl docker.io docker-compose"

log_info "Installing: $PACKAGES"
apt install -y $PACKAGES

# Install MinIO Client (mc) for S3 backup
if command -v mc &> /dev/null; then
    log_success "MinIO client already installed"
else
    log_info "Installing MinIO client (mc)..."
    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
    chmod +x /usr/local/bin/mc
    log_success "MinIO client installed"
fi

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
# Create directory structure
################################################################################
log_info "Creating directory structure..."

mkdir -p "$ROOT_DIR"
mkdir -p "$ROOT_DIR/scripts"
mkdir -p "$ROOT_DIR/nginx-conf"
mkdir -p "$ROOT_DIR/static/default"
mkdir -p "$ROOT_DIR/static/sites"
mkdir -p "$ROOT_DIR/services"

# Data directory for runtime data (certificates, databases, assets)
mkdir -p "$ROOT_DIR/data/letsencrypt"
mkdir -p "$ROOT_DIR/data/letsencrypt-lib"
mkdir -p "$ROOT_DIR/data/sqlite"
mkdir -p "$ROOT_DIR/data/assets"
mkdir -p "$ROOT_DIR/data/secrets/certbot"

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
log_info "Copying source files..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy scripts
copy_file "$SCRIPT_DIR/sources/scripts/deploy-service.sh" "$ROOT_DIR/deploy-service.sh" "deploy-service.sh"
copy_file "$SCRIPT_DIR/sources/scripts/nginx-reload.sh" "$ROOT_DIR/scripts/nginx-reload.sh" "nginx-reload.sh"
copy_file "$SCRIPT_DIR/sources/scripts/update-nginx-config.sh" "$ROOT_DIR/scripts/update-nginx-config.sh" "update-nginx-config.sh"
copy_file "$SCRIPT_DIR/sources/scripts/certbot-gen.sh" "$ROOT_DIR/scripts/certbot-gen.sh" "certbot-gen.sh"
copy_file "$SCRIPT_DIR/sources/scripts/certbot-gen-ovh.sh" "$ROOT_DIR/scripts/certbot-gen-ovh.sh" "certbot-gen-ovh.sh"
copy_file "$SCRIPT_DIR/sources/scripts/certbot-renew.sh" "$ROOT_DIR/scripts/certbot-renew.sh" "certbot-renew.sh"

# Make scripts executable
chmod +x "$ROOT_DIR/deploy-service.sh" 2>/dev/null || true
chmod +x "$ROOT_DIR/scripts/"*.sh 2>/dev/null || true

# Copy nginx configuration files
copy_file "$SCRIPT_DIR/sources/nginx/default.conf" "$ROOT_DIR/nginx-conf/default.conf" "default.conf"
copy_file "$SCRIPT_DIR/sources/nginx/ssl-common.conf" "$ROOT_DIR/nginx-conf/ssl-common.conf" "ssl-common.conf"
copy_file "$SCRIPT_DIR/sources/nginx/proxy-common.conf" "$ROOT_DIR/nginx-conf/proxy-common.conf" "proxy-common.conf"

# Copy static files
copy_file "$SCRIPT_DIR/sources/static/index.html" "$ROOT_DIR/static/default/index.html" "default index.html"

# Copy cron script
copy_file "$SCRIPT_DIR/sources/scripts/certbot-cron.sh" "/etc/cron.daily/certbot-renew" "certbot cron job"
chmod +x /etc/cron.daily/certbot-renew 2>/dev/null || true

log_success "Source files copied"

################################################################################
# Check SSH password authentication configuration
################################################################################
log_info "Checking SSH password authentication..."

# Check current SSH configuration
if sshd -T 2>/dev/null | grep -q "^passwordauthentication yes"; then
    log_success "SSH password authentication is already enabled"
else
    echo ""
    log_warning "SSH password authentication is currently disabled."
    log_info "This is common on Debian/cloud systems and will prevent the 'deployer' user from logging in via SSH with password."
    echo ""
    read -p "Do you want to enable SSH password authentication? [y/N]: " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Create sshd_config.d directory if it doesn't exist
        mkdir -p /etc/ssh/sshd_config.d

        # Copy WSO SSH configuration file
        copy_file "$SCRIPT_DIR/sources/ssh/10-wso.conf" "/etc/ssh/sshd_config.d/10-wso.conf" "WSO SSH configuration"

        log_info "Restarting SSH service..."
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
        log_success "SSH password authentication enabled"
    else
        log_info "SSH configuration unchanged. You can use SSH keys for authentication."
        log_info "To add SSH keys: ssh-copy-id deployer@your-server"
    fi
fi

################################################################################
# Configure sudoers for deployer
################################################################################
log_info "Configuring sudoers for deployer..."

SUDOERS_FILE="/etc/sudoers.d/deployer-deploy"
SUDOERS_TEMP="/tmp/deployer-deploy.tmp.$$"

# Create temporary sudoers file with ROOT_DIR replaced
sed "s|ROOT_DIR|$ROOT_DIR|g" "$SCRIPT_DIR/sources/sudoers/deployer-deploy" > "$SUDOERS_TEMP"

# Verify syntax with visudo
if ! visudo -c -f "$SUDOERS_TEMP" >/dev/null 2>&1; then
    log_error "Sudoers file has invalid syntax! This should not happen."
    rm -f "$SUDOERS_TEMP"
    exit 1
fi

# If destination doesn't exist, install it
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
        # Files differ, ask user
        echo ""
        log_warning "Sudoers configuration differs from repository version"
        log_info "Current: $SUDOERS_FILE"
        echo ""
        echo "--- Current version ---"
        cat "$SUDOERS_FILE"
        echo ""
        echo "--- New version ---"
        cat "$SUDOERS_TEMP"
        echo ""
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
# Hide /srv from other users
################################################################################
log_info "Setting permissions on /srv..."
chmod -R o-rwx /srv 2>/dev/null || true

log_info "Setting permissions 755 for $ROOT_DIR/static..."
chmod -R 755 "$ROOT_DIR/static"
log_success "Permissions set"

################################################################################
# Docker registry login
################################################################################
echo ""
log_info "Docker registry configuration"

# Check if Docker credentials already exist
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
# Create overlay network for service communication
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
# Create or update nginx service
################################################################################
log_info "Checking nginx service..."

# Define nginx service configuration
NGINX_IMAGE="nginx:1.29-alpine"
NGINX_MOUNTS="
  --mount type=bind,src=$ROOT_DIR/nginx-conf,dst=/etc/nginx/conf.d
  --mount type=bind,src=$ROOT_DIR/static/default,dst=/usr/share/nginx/html
  --mount type=bind,src=$ROOT_DIR/static/sites,dst=/usr/share/nginx/sites
  --mount type=bind,src=$ROOT_DIR/data/letsencrypt,dst=/etc/letsencrypt
"

if docker service ls 2>/dev/null | grep -q "nginx"; then
    log_success "Nginx service already exists"

    # Get current nginx image
    CURRENT_IMAGE=$(docker service inspect nginx --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null | cut -d@ -f1)

    echo ""
    echo "Current nginx image: $CURRENT_IMAGE"
    echo "Target nginx image:  $NGINX_IMAGE"
    echo ""

    # Ensure nginx is connected to wso-net (idempotent)
    log_info "Ensuring nginx is connected to wso-net..."
    docker service update --network-add wso-net nginx >/dev/null 2>&1 || true

    if [ "$CURRENT_IMAGE" != "$NGINX_IMAGE" ]; then
        read -p "Do you want to update the nginx service to $NGINX_IMAGE? (y/N): " update_nginx

        if [ "$update_nginx" = "y" ] || [ "$update_nginx" = "Y" ]; then
            log_info "Updating nginx service image..."
            docker service update --image "$NGINX_IMAGE" nginx
            log_success "Nginx service updated to $NGINX_IMAGE"
        else
            log_info "Nginx service update skipped"
        fi
    else
        log_info "Nginx service is already running the target image"
    fi

    echo ""
    log_info "Note: Mount points are not updated for existing services."
    log_info "If you changed ROOT_DIR, you may need to recreate the service:"
    log_info "  docker service rm nginx"
    log_info "  Then re-run this installation script"
else
    log_info "Creating nginx service..."

    docker service create --mode global --name nginx \
      --network wso-net \
      --publish mode=host,target=80,published=80 \
      --publish mode=host,target=443,published=443 \
      --mount type=bind,src=$ROOT_DIR/nginx-conf,dst=/etc/nginx/conf.d \
      --mount type=bind,src=$ROOT_DIR/static/default,dst=/usr/share/nginx/html \
      --mount type=bind,src=$ROOT_DIR/static/sites,dst=/usr/share/nginx/sites \
      --mount type=bind,src=$ROOT_DIR/data/letsencrypt,dst=/etc/letsencrypt \
      "$NGINX_IMAGE"

    log_success "Nginx service created"
fi

################################################################################
# Final summary
################################################################################
echo ""
echo "================================================================================"
log_success "WSO Installation Complete!"
echo "================================================================================"
echo ""
log_info "Installation directory: $ROOT_DIR"
log_info "Deployer user: deployer"
log_info "Docker Swarm: active"
log_info "Nginx service: running"
echo ""
log_info "Next steps:"
echo "  1. Place your nginx configurations in: $ROOT_DIR/nginx-conf/"
echo "  2. Generate SSL certificates:"
echo "     - Webroot: $ROOT_DIR/scripts/certbot-gen.sh domain.com"
echo "     - Wildcard (OVH DNS): $ROOT_DIR/scripts/certbot-gen-ovh.sh '*.domain.com,domain.com'"
echo "  3. Reload nginx: $ROOT_DIR/scripts/nginx-reload.sh"
echo "  4. Deploy services: sudo sh $ROOT_DIR/deploy-service.sh <project-name>"
echo ""
log_info "Example nginx templates are available in the repository under sources/nginx/"
echo ""
log_info "To update the nginx service image:"
echo "  docker service update --image nginx:1.29-alpine nginx"
echo ""
echo "================================================================================"
