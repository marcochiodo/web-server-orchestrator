# Web Server Orchestrator (WSO)

A streamlined Docker Swarm-based web server orchestration system designed for managing multiple web services behind an nginx reverse proxy with automated SSL certificate management.

## Features

- **Docker Swarm Integration**: Leverage Docker Swarm's native orchestration capabilities
- **Nginx Reverse Proxy**: Global nginx service with automatic configuration reloading
- **SSL/TLS Management**: Automated Let's Encrypt certificate generation and renewal
- **Multi-Service Support**: Deploy and manage multiple web services with isolated configurations
- **Idempotent Installation**: Safe to re-run installation script on existing systems
- **Secure Deployment**: Dedicated deployer user with restricted sudo privileges
- **Self-Contained**: All runtime data (certificates, databases, assets) stored in installation directory

## Architecture

WSO orchestrates containerized web services using Docker Swarm, with a globally deployed nginx container acting as a reverse proxy. Each service runs in its own container, and nginx configurations are dynamically mounted, allowing for hot-reloading without service interruption.

```
┌─────────────────────────────────────────────┐
│              Docker Swarm                    │
│                                              │
│  ┌────────────────────────────────────┐     │
│  │  Nginx (Global Service)            │     │
│  │  - Port 80/443                     │     │
│  │  - SSL Termination                 │     │
│  │  - Reverse Proxy                   │     │
│  └─────────┬──────────────────────────┘     │
│            │                                 │
│  ┌─────────▼─────────┐  ┌──────────────┐   │
│  │  Service A        │  │  Service B    │   │
│  │  (Your App)       │  │  (Your App)   │   │
│  └───────────────────┘  └──────────────┘    │
└─────────────────────────────────────────────┘
```

## Prerequisites

- A Debian/Ubuntu-based server (VPS or dedicated)
- Root or sudo access
- Internet connectivity

## Getting Started

### Quick Installation

1. Clone the repository:
```bash
git clone https://github.com/marcochiodo/web-server-orchestrator
cd web-server-orchestrator
```

2. Run the installation script as root:
```bash
sudo bash init.sh
```

The script will:
- Install required packages (Docker, utilities)
- Create the deployer user
- Set up the directory structure
- Configure Docker Swarm
- Deploy the nginx service
- Set up SSL certificate automation

3. Follow the interactive prompts to configure:
   - Installation directory (default: `/srv/wso`)
   - Deployer user password
   - Docker registry credentials (if needed)

### Post-Installation

After installation, your WSO instance will be ready at the configured directory (default: `/srv/wso`).

## Usage

### Directory Structure

```
/srv/wso/
├── deploy-service.sh          # Service deployment wrapper
├── scripts/
│   ├── nginx-reload.sh        # Reload nginx configuration
│   ├── update-nginx-config.sh # Update and validate nginx config for a service
│   ├── certbot-gen.sh         # Generate SSL certificates
│   └── certbot-renew.sh       # Renew SSL certificates
├── nginx-templates/           # Nginx configuration templates
│   ├── ssl-common.conf.template
│   └── proxy.template
├── static/
│   ├── default/              # Default webroot for nginx
│   └── sites/                # Static sites directory
├── services/
│   └── <project-name>/       # Individual service directories
│       └── deploy.sh         # Service-specific deployment script
└── data/                     # Runtime data (not in git)
    ├── letsencrypt/          # SSL certificates
    ├── letsencrypt-lib/      # Certbot data
    ├── sqlite/               # SQLite databases
    └── assets/               # Static assets and files
```

### Deploying a Service

1. Create a directory for your service:
```bash
mkdir -p /srv/wso/services/myapp
```

2. Create a `deploy.sh` script. A complete example that includes nginx configuration updates:
```bash
#!/bin/sh
# Example deployment script with nginx configuration updates
set -eu

# Configuration
SERVICE_NAME="myapp"
IMAGE_NAME="registry.example.com/myapp:latest"
DOCKER_SERVICE_NAME="${SERVICE_NAME}-prod"
ROOT_DIR="${ROOT_DIR:-/srv/wso}"
TEMP_NGINX_CONFIG="/tmp/${SERVICE_NAME}-nginx-$$.conf"

# Cleanup on exit
cleanup() {
    rm -f "$TEMP_NGINX_CONFIG"
}
trap cleanup EXIT

# Pull latest image
docker pull "$IMAGE_NAME"

# Extract nginx configuration from the image
# (assumes the image contains nginx config at /app/nginx.conf)
docker run --rm "$IMAGE_NAME" cat /app/nginx.conf > "$TEMP_NGINX_CONFIG"

# Update nginx configuration (with checksum comparison and validation)
sh "$ROOT_DIR/scripts/update-nginx-config.sh" "$SERVICE_NAME" "$TEMP_NGINX_CONFIG"

# Update or create the Docker service
if docker service ls --format '{{.Name}}' | grep -q "^${DOCKER_SERVICE_NAME}$"; then
    docker service update --with-registry-auth --image "$IMAGE_NAME" "$DOCKER_SERVICE_NAME"
else
    docker service create \
        --with-registry-auth \
        --name "$DOCKER_SERVICE_NAME" \
        --network ingress \
        "$IMAGE_NAME"
fi
```

See `sources/examples/service-deploy.sh` for a more detailed template.

3. Make it executable:
```bash
chmod +x /srv/wso/services/myapp/deploy.sh
```

4. Deploy using the wrapper script:
```bash
sudo sh /srv/wso/deploy-service.sh myapp
```

### Remote Deployment

For automated deployments from CI/CD pipelines or remote machines, you can use SSH to trigger service deployments:

```bash
ssh deployer@your-server.com sh /srv/wso/deploy-service.sh myapp
```

Replace `/srv/wso` with your actual installation directory if different.

**Important Prerequisites:**
- The service's `deploy.sh` script must already exist on the server at `/srv/wso/services/<service-name>/deploy.sh`
- The script must be executable (`chmod +x`)
- **The deployment script must be uploaded by a system administrator with root access**
- The `deployer` user has restricted permissions and can only execute the deployment command, not create or modify files

**Setup workflow:**

1. **Initial setup (performed by administrator with root access):**
```bash
# As root, create the service directory
ssh root@your-server.com mkdir -p /srv/wso/services/myapp

# Upload the deploy script as root
scp deploy.sh root@your-server.com:/srv/wso/services/myapp/

# Make it executable
ssh root@your-server.com chmod +x /srv/wso/services/myapp/deploy.sh
```

2. **Automated deployments (from CI/CD or development machines):**
```bash
# The deployer user can trigger the deployment
ssh deployer@your-server.com sh /srv/wso/deploy-service.sh myapp
```

You will be prompted for the `deployer` user password. For CI/CD automation, you can optionally configure SSH key authentication to avoid password prompts.

**Optional: SSH Key Authentication for CI/CD:**

If you want to automate deployments without password prompts:

```bash
# On your CI/CD machine
ssh-copy-id deployer@your-server.com
```

Store the private key as a secret in your CI/CD system for fully automated deployments.

**Security Note:**
The `deployer` user has minimal privileges by design. It can only execute the `deploy-service.sh` wrapper script via sudo, which validates and runs service-specific deployment scripts. This architecture prevents unauthorized system modifications while enabling safe automated deployments.

### Automated Nginx Configuration Updates

The `update-nginx-config.sh` script automates the process of updating nginx configurations with built-in safety checks:

**Usage:**
```bash
/srv/wso/scripts/update-nginx-config.sh <service-name> <source-config-file>
```

**What it does:**
1. Compares checksums between the new and existing configuration
2. Skips update if configurations are identical (avoiding unnecessary reloads)
3. Creates a backup of the existing configuration
4. Installs the new configuration
5. Tests nginx syntax with `nginx -t`
6. Reloads nginx if syntax is valid
7. Rolls back to the backup if validation fails

**Example usage in deployment scripts:**
```bash
# Extract nginx config from Docker image
docker run --rm myapp:latest cat /app/nginx.conf > /tmp/myapp-nginx.conf

# Update nginx configuration safely
sh /srv/wso/scripts/update-nginx-config.sh myapp /tmp/myapp-nginx.conf
```

This approach ensures:
- No downtime due to syntax errors
- Nginx is only reloaded when configuration actually changes
- Automatic rollback on failure
- Centralized configuration management logic

### Configuring Nginx

1. Create an nginx configuration in `/srv/wso/nginx-templates/`:
```nginx
# Example: myapp.conf.template
server {
    listen [::]:443 ssl;
    listen 443 ssl;
    server_name myapp.example.com;

    # Certificates are mounted from $ROOT_DIR/data/letsencrypt to /etc/letsencrypt in nginx container
    ssl_certificate     /etc/letsencrypt/live/myapp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/myapp.example.com/privkey.pem;

    include /etc/nginx/conf.d/ssl-common.conf;

    location / {
        proxy_pass http://myapp-service:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

2. Generate SSL certificate:
```bash
/srv/wso/scripts/certbot-gen.sh myapp.example.com
```

3. Reload nginx:
```bash
/srv/wso/scripts/nginx-reload.sh
```

### SSL Certificate Management

**Generate a new certificate:**
```bash
/srv/wso/scripts/certbot-gen.sh example.com,www.example.com
```

**Renew certificates:**
```bash
/srv/wso/scripts/certbot-renew.sh
```

Certificates are automatically renewed via a daily cron job at `/etc/cron.daily/certbot-renew`.

### Updating the Nginx Service

To update the nginx Docker image:

```bash
docker service update --image nginx:1.29-alpine nginx
```

Or use a specific version:
```bash
docker service update --image nginx:1.27-alpine nginx
```

### Creating Additional Services

Services can be created using standard Docker Swarm commands:

```bash
docker service create \
  --with-registry-auth \
  --name myapp-prod \
  --env DATABASE_URL="postgres://..." \
  --network ingress \
  registry.example.com/myapp:latest
```

## Templates and Examples

The `sources/` directory contains templates and examples:

- `sources/nginx/` - Nginx configuration templates
  - `proxy.template` - Reverse proxy configuration example
  - `ssl-common.conf.template` - Common SSL settings
- `sources/scripts/` - System management scripts
  - `deploy-service.sh` - Secure service deployment wrapper
  - `nginx-reload.sh` - Nginx configuration reload
  - `update-nginx-config.sh` - Safe nginx config update with validation
  - `certbot-*.sh` - SSL certificate management scripts
- `sources/sudoers/` - Sudoers configuration (verified with visudo)
  - `deployer-deploy` - Sudoers rules for deployer user
- `sources/static/` - Default static files
  - `index.html` - Default nginx index page
- `sources/examples/` - Example deployment scripts
  - `service-deploy.sh` - Service deployment script template

## Security Considerations

- The deployer user has restricted sudo access (only for deployment script)
- Sudoers configuration is validated with `visudo -c` before installation
- All files in `/srv` are protected from other users
- SSL certificates use modern TLS protocols (TLS 1.2+)
- HSTS headers are enabled by default
- Services communicate internally via Docker's overlay network
- File integrity is verified via checksums before updates

## Maintenance

### Logs

View nginx logs:
```bash
docker service logs nginx
```

View service logs:
```bash
docker service logs <service-name>
```

### Backup

Important directories to backup:
- `/srv/wso/nginx-templates/` - Nginx configurations
- `/srv/wso/services/` - Service deployment scripts
- `/srv/wso/data/` - SSL certificates, databases, and runtime data
  - `/srv/wso/data/letsencrypt/` - SSL certificates (most critical)
  - `/srv/wso/data/sqlite/` - Application databases
  - `/srv/wso/data/assets/` - Static assets

## Troubleshooting

### Nginx configuration syntax errors

Test configuration before reloading:
```bash
docker exec $(docker ps -q -f name=nginx) nginx -t
```

### Certificate generation fails

Ensure:
- DNS records point to your server
- Port 80 is accessible (Let's Encrypt validation)
- The default webroot is accessible: `/srv/wso/static/default/`
- The data directory has correct permissions: `/srv/wso/data/letsencrypt/`

### Service deployment fails

Check:
- Docker registry authentication: `docker login`
- Service exists: `docker service ls`
- Service logs: `docker service logs <service-name>`

## Re-running Installation

The `init.sh` script is idempotent and can be safely re-run on configured systems. It will:
- Skip existing users and services
- Compare file checksums and prompt for updates only when content differs
- Validate sudoers syntax with `visudo -c` before applying changes
- Show diff for critical files (like sudoers) before updating
- Preserve existing configurations when declined

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Support

For issues and questions, please open an issue on the GitHub repository.

---

**Web Server Orchestrator** - Simple, secure, scalable web service orchestration.
