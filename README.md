# Web Server Orchestrator (WSO)

A streamlined Docker Swarm-based web server orchestration system designed for managing multiple web services behind an nginx reverse proxy with automated SSL certificate management.

Technical support from Claude Code.
Moral support from [1C3](https://github.com/1C3).

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

All services communicate through a dedicated overlay network (`wso-net`) that enables service discovery by name. Nginx is the only service with published ports (80/443), while application services remain internal and accessible only through the reverse proxy.

### Deployment Approaches

WSO supports two deployment approaches:

**Declarative (Recommended):** Use Docker Compose files with `docker stack deploy`. This provides:
- Version-controlled service configurations
- Easy updates by redeploying the stack
- Clear service definitions in YAML format
- Better maintainability and reproducibility

**Imperative (Legacy):** Use shell scripts with `docker service create/update` commands. This is still supported for:
- Complex deployment workflows
- Extracting configurations from Docker images
- Backward compatibility with existing deployments

The declarative approach is recommended for new deployments.

```
┌─────────────────────────────────────────────┐
│              Docker Swarm                   │
│                                             │
│  ┌────────────────────────────────────┐     │
│  │  Nginx (Global Service)            │     │
│  │  - Port 80/443 (Published)         │     │
│  │  - SSL Termination                 │     │
│  │  - Reverse Proxy                   │     │
│  └─────────┬──────────────────────────┘     │
│            │ wso-net (overlay)              │
│  ┌─────────▼─────────┐  ┌──────────────┐    │
│  │  Service A        │  │  Service B   │    │
│  │  (Your App)       │  │  (Your App)  │    │
│  │  No public ports  │  │  No public   │    │
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
├── nginx-conf/                # Nginx configuration files
│   ├── ssl-common.conf
│   ├── proxy-common.conf
│   └── proxy.conf
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

WSO uses a declarative approach with Docker Stack templates and `docker stack deploy`. Variable substitution is handled using `docker stack config` as a preprocessor, which allows using a single template for all environments.

#### The Template Philosophy

**Key Concept:** One `stack-template.yml` for all environments (production, staging, development).

The template contains variables like `${IMAGE_TAG}` and `${ROOT_DIR}` that get interpolated at deployment time. This means:
- ✅ Same template file committed to git
- ✅ Different configurations per environment via variables
- ✅ No need for docker-compose dependency
- ✅ Native Docker Swarm tooling

#### Quick Start

1. Create a `stack-template.yml` file for your service (see `examples/stack-template.yml` for a complete template):

```yaml
version: '3.8'

services:
  webapp:
    # Use variables for environment-specific values
    # Note: Service will be named STACKNAME_webapp (e.g., myapp_webapp)
    image: my.registry.com/myapp:${IMAGE_TAG:-latest}
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
    environment:
      - DATABASE_URL=file:/data/sqlite/myapp.db
    volumes:
      - type: bind
        source: ${ROOT_DIR}/data/sqlite
        target: /data/sqlite
      - type: bind
        source: ${ROOT_DIR}/data/assets/myapp
        target: /data/assets
    networks:
      - wso-net

networks:
  wso-net:
    external: true
    name: wso-net
```

2. Deploy using `docker stack config` to interpolate variables:

```bash
# Production deployment
IMAGE_TAG=production ROOT_DIR=/srv/wso docker stack config -c stack-template.yml | docker stack deploy --compose-file - myapp

# Staging deployment
IMAGE_TAG=staging ROOT_DIR=/srv/wso docker stack config -c stack-template.yml | docker stack deploy --compose-file - myapp

# Development deployment
IMAGE_TAG=development ROOT_DIR=/srv/wso docker stack config -c stack-template.yml | docker stack deploy --compose-file - myapp
```

**Why `docker stack config`?**
- `docker stack deploy` does not support variable substitution (`${VAR}`)
- `docker stack config` interpolates variables and outputs the final configuration
- The output is piped directly to `docker stack deploy`
- Native Docker Swarm command (no docker-compose dependency needed)

3. Configure nginx for your service (see "Configuring Nginx" section below)

#### Docker Swarm Service Naming

**Important:** When you deploy a stack, Docker Swarm names services using the format `STACKNAME_SERVICENAME`.

Example:
```bash
# Deploy command
IMAGE_TAG=production ROOT_DIR=/srv/wso docker stack config -c stack-template.yml | \
  docker stack deploy --compose-file - myapp

# If your template has:
services:
  webapp:
    ...

# The full service name will be: myapp_webapp
```

**In nginx configurations, use the full service name:**
```nginx
location / {
    proxy_pass http://myapp_webapp:8080;  # STACKNAME_SERVICENAME:PORT
}
```

#### One Template, Multiple Environments

The key advantage is using **ONE template for ALL environments** by parametrizing with variables:

- `${IMAGE_TAG}` - Docker image tag (production, staging, development)
- `${ROOT_DIR}` - Installation directory
- Any custom variables you need (database URLs, replicas, etc.)

Example with custom variables:
```bash
IMAGE_TAG=v1.2.3 REPLICAS=3 ROOT_DIR=/srv/wso docker stack config -c stack-template.yml | docker stack deploy --compose-file - myapp
```

**Version Control Best Practice:**
- ✅ Commit `stack-template.yml` to git (it's your source of truth)
- ❌ Never commit interpolated files (they contain environment-specific values)
- 🔧 Use the same template across all environments

#### Updating a Service

Simply redeploy with updated variables or after modifying the template:
```bash
IMAGE_TAG=production ROOT_DIR=/srv/wso docker stack config -c stack-template.yml | docker stack deploy --compose-file - myapp
```

Docker Swarm will perform a rolling update automatically.

#### Alternative: Script-Based Deployment

You can wrap the deployment workflow in a shell script for automation. See `examples/service-deploy.sh` for a complete template.

This script-based approach:
- Uses `docker stack config + docker stack deploy` internally
- Extracts nginx configurations from Docker images automatically
- Handles environment-specific deployments
- Provides validation and error handling

**Usage:**
```bash
# Place your stack-template.yml and service-deploy.sh in your project directory
./service-deploy.sh production
./service-deploy.sh staging
./service-deploy.sh development
```

This approach is useful when you need to:
- Extract nginx configurations from Docker images
- Perform complex pre/post-deployment operations
- Automate multi-step deployment workflows
- Integrate with existing deployment scripts

### Remote Deployment

For automated deployments from CI/CD pipelines or remote machines, you have two options:

#### Option A: Declarative with Docker Stack (Recommended)

Upload your template file and deploy using docker stack config:

```bash
# Upload stack template
scp stack-template.yml deployer@your-server.com:~/myapp-stack-template.yml

# Deploy the stack via SSH with variable interpolation
ssh deployer@your-server.com "cd ~ && IMAGE_TAG=production ROOT_DIR=/srv/wso docker stack config -c myapp-stack-template.yml | docker stack deploy --compose-file - myapp"
```

**For CI/CD pipelines:**
```bash
# Example GitHub Actions / GitLab CI
scp stack-template.yml deployer@your-server.com:~/myapp-stack-template.yml
ssh deployer@your-server.com "cd ~ && IMAGE_TAG=${CI_COMMIT_TAG:-latest} ROOT_DIR=/srv/wso docker stack config -c myapp-stack-template.yml | docker stack deploy --compose-file - myapp"
```

#### Option B: Using Custom Deployment Scripts on Server (Advanced)

For teams with custom deployment workflows, you can still use the wrapper script system:

```bash
# Upload your custom deployment script
scp my-deploy.sh deployer@your-server.com:~/scripts/

# Execute via SSH
ssh deployer@your-server.com "cd ~/scripts && ./my-deploy.sh production"
```

Or use the legacy `/srv/wso/services/` structure if already configured:
```bash
ssh deployer@your-server.com sh /srv/wso/deploy-service.sh myapp [environment]
```

This requires the deployment script to be pre-installed on the server by an administrator.

**Optional: SSH Key Authentication for CI/CD:**

If you want to automate deployments without password prompts:

```bash
# On your CI/CD machine
ssh-copy-id deployer@your-server.com
```

Store the private key as a secret in your CI/CD system for fully automated deployments.

For GitHub Actions, you'll also need to add the server's SSH fingerprint to known_hosts. It's recommended to use ed25519 for consistency:

```bash
# Get server fingerprint with ed25519
ssh-keyscan -t ed25519 your-server.com
```

Then in your GitHub Action workflow:

```yaml
- name: Add known hosts
  run: |
    mkdir -p $HOME/.ssh
    echo "${{ vars.SSH_KNOWN_HOSTS }}" > $HOME/.ssh/known_hosts
```

Store the fingerprint output in a GitHub repository variable named `SSH_KNOWN_HOSTS`.

**Security Note:**
The `deployer` user has access to Docker commands but requires appropriate permissions. For production environments, consider implementing additional access controls and using SSH key-based authentication with restricted keys.

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

For single-environment deployments:
```bash
# Extract nginx config from Docker image
docker run --rm myapp:latest cat /app/nginx.conf > /tmp/myapp-nginx.conf

# Update nginx configuration safely
sh /srv/wso/scripts/update-nginx-config.sh myapp /tmp/myapp-nginx.conf
```

For multi-environment deployments:
```bash
# Extract environment-specific nginx config
ENVIRONMENT="production"  # or staging, development
docker run --rm myapp:${ENVIRONMENT} cat "/app/nginx-${ENVIRONMENT}.conf" > /tmp/myapp-nginx.conf

# Update nginx configuration with environment-specific name
sh /srv/wso/scripts/update-nginx-config.sh "myapp-${ENVIRONMENT}" /tmp/myapp-nginx.conf
```

**Note:** Your Docker images should include environment-specific nginx configurations (e.g., `/app/nginx-production.conf`, `/app/nginx-staging.conf`) if you plan to deploy multiple environments. These configs typically differ in domain names, SSL certificates, and upstream service names.

This approach ensures:
- No downtime due to syntax errors
- Nginx is only reloaded when configuration actually changes
- Automatic rollback on failure
- Centralized configuration management logic

### Configuring Nginx

1. Create an nginx configuration in `/srv/wso/nginx-conf/`:
```nginx
# Example: myapp.conf
server {
    listen [::]:443 ssl;
    listen 443 ssl;
    server_name myapp.example.com;

    # Certificates are mounted from $ROOT_DIR/data/letsencrypt to /etc/letsencrypt in nginx container
    ssl_certificate     /etc/letsencrypt/live/myapp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/myapp.example.com/privkey.pem;

    # Include common SSL configuration
    include /etc/nginx/conf.d/ssl-common.conf;

    location / {
        # Use STACKNAME_SERVICENAME format (e.g., if stack=myapp, service=webapp)
        proxy_pass http://myapp_webapp:8080;

        # Include common proxy configuration (headers, timeouts, buffering, websockets)
        include /etc/nginx/conf.d/proxy-common.conf;
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

**Note on common configuration files:**

WSO provides reusable configuration snippets to avoid duplication:
- **`ssl-common.conf`**: TLS protocols, ciphers, HSTS headers - included once per server block
- **`proxy-common.conf`**: Proxy headers, timeouts, buffering, websocket support - included in each proxy location

These files are automatically installed to `/srv/wso/nginx-conf/` and mounted into the nginx container at `/etc/nginx/conf.d/`. You can customize them to apply changes across all services.

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

### Updating the Nginx Stack

To update the nginx Docker image or configuration:

1. Edit `sources/docker-stack/nginx-compose.yml` to change the image version or configuration
2. Redeploy the stack using docker stack config:

```bash
cd /path/to/web-server-orchestrator
ROOT_DIR=/srv/wso docker stack config -c sources/docker-stack/nginx-compose.yml | docker stack deploy --compose-file - nginx
```

The stack will be updated with zero downtime using Docker Swarm's rolling update mechanism.

### Creating Additional Services

The recommended approach is to use Docker Stack templates with `docker stack config` and `docker stack deploy`:

```bash
# Create a stack-template.yml for your service (see examples/stack-template.yml)
IMAGE_TAG=production ROOT_DIR=/srv/wso docker stack config -c stack-template.yml | docker stack deploy --compose-file - myapp
```

Alternatively, you can still use imperative Docker service commands:

```bash
docker service create \
  --with-registry-auth \
  --name myapp-prod \
  --env DATABASE_URL="postgres://..." \
  --network wso-net \
  registry.example.com/myapp:latest
```

However, the declarative approach with compose files is preferred for better maintainability and version control.

## Templates and Examples

The `sources/` directory and examples contain templates and examples:

- `sources/docker-stack/` - Docker Stack compose files
  - `nginx-compose.yml` - Nginx service stack definition
- `examples/` - Example configurations and templates
  - `stack-template.yml` - Complete service deployment template with variables and documentation
  - `service-deploy.sh` - Service deployment script wrapper (alternative approach)
  - `nginx-proxy.conf` - Example nginx reverse proxy configuration
- `sources/nginx/` - Nginx configuration files
  - `proxy.conf` - Reverse proxy configuration example
  - `ssl-common.conf` - Common SSL settings (TLS protocols, ciphers, HSTS)
  - `proxy-common.conf` - Common proxy settings (headers, timeouts, buffering, websockets)
- `sources/scripts/` - System management scripts
  - `deploy-service.sh` - Secure service deployment wrapper
  - `nginx-reload.sh` - Nginx configuration reload
  - `update-nginx-config.sh` - Safe nginx config update with validation
  - `certbot-*.sh` - SSL certificate management scripts
- `sources/sudoers/` - Sudoers configuration (verified with visudo)
  - `deployer-deploy` - Sudoers rules for deployer user
- `sources/static/` - Default static files
  - `index.html` - Default nginx index page

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
- `/srv/wso/nginx-conf/` - Nginx configurations
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
