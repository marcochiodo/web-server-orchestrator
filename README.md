# Web Server Orchestrator (WSO)

A streamlined Docker Swarm-based orchestration system for managing web services behind an nginx reverse proxy with automated SSL certificates.

Technical support from Claude Code.
Moral support from [1C3](https://github.com/1C3).

## Features

- **Docker Swarm orchestration** with automated service discovery
- **Nginx reverse proxy** with hot-reload configuration
- **Automated SSL/TLS** via Let's Encrypt (webroot + DNS wildcard)
- **Declarative deployment** via YAML manifests
- **Multi-environment support** with isolated configurations
- **FHS-compliant installation** following Linux standards

## Architecture

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

Services communicate through the `wso-net` overlay network. Nginx is the only service with published ports, while applications remain internal and accessible only through the reverse proxy.

## Installation

### Prerequisites

- Debian/Ubuntu or Fedora server
- Root or sudo access
- Internet connectivity

### Quick Start

```bash
# Clone repository
git clone https://github.com/marcochiodo/web-server-orchestrator
cd web-server-orchestrator

# Install WSO
sudo ./install.sh
```

The installer will:
- Install required packages (Docker, yq, utilities)
- Create the `deployer` user
- Set up directory structure following FHS
- Initialize Docker Swarm
- Deploy the system stack (nginx)
- Configure certificate auto-renewal

## Directory Structure

WSO follows the Linux Filesystem Hierarchy Standard (FHS):

```
/usr/bin/
├── wso-deploy              # Deploy services from manifest
├── wso-cert-gen            # Generate SSL certificates (webroot)
├── wso-cert-gen-ovh        # Generate wildcard certificates (DNS)
├── wso-cert-renew          # Renew all certificates
└── wso-nginx-reload        # Reload nginx configuration

/usr/lib/wso/
├── scripts/                # Internal scripts
├── docker/                 # Docker compose files
│   └── system-compose.yml
└── www-default/            # Default website

/etc/wso/
├── wso.conf                # Global configuration
└── nginx-includes/         # Nginx include files
    ├── ssl-common.conf
    └── proxy-common.conf

/var/lib/wso/
├── nginx/                  # Nginx configurations (generated)
├── letsencrypt/            # SSL certificates
├── acme-challenge/         # ACME webroot
└── data/                   # Service data
    └── service-name/       # Created per service
```

## Usage

### Deploying a Service

Create a manifest file (see `examples/wso-deploy.yml`):

```yaml
version: "2.0"

service: myapp-production

# Docker stack configuration
stack:
  version: '3.8'
  services:
    webapp:
      image: registry.com/myapp:latest
      environment:
        - API_KEY={{API_KEY}}
      volumes:
        - type: bind
          source: /var/lib/wso/data/myapp-production
          target: /data
      networks:
        - wso-net
  networks:
    wso-net:
      external: true

# Domains with automatic nginx config generation
force_https: true
domains:
  - domain: example.com
    cert_name: myapp_example.com
    container_name: webapp
    port: 8080

# Cron jobs with host secrets
cron_jobs:
  - schedule: "0 2 * * *"
    command: "curl -H \"Authorization: Bearer $TOKEN\" https://api.example.com/backup"
    secrets:
      TOKEN: backup_token

# Host secrets (stored in /var/lib/wso/secrets/)
secrets:
  backup_token: "{{BACKUP_TOKEN}}"
```

Deploy the service:

```bash
wso-deploy manifest.yml
```

WSO will automatically:
1. Manage host secrets in /var/lib/wso/secrets/
2. Generate SSL certificates if missing
3. Generate nginx configuration from domains
4. Deploy the Docker stack
5. Generate and install crontab
6. Validate and reload nginx

### Managing SSL Certificates

Generate certificate for a domain:
```bash
wso-cert-gen example.com myapp_example.com
```

Generate wildcard certificate (DNS-01):
```bash
wso-cert-gen-ovh "chdev.eu,*.chdev.eu"
```

Certificates are automatically renewed daily via cron.

### Nginx Configuration

Nginx configurations are **automatically generated** from the manifest `domains` section. No manual nginx files needed!

Each domain gets:
- HTTP server (port 80) with ACME challenge
- HTTPS server (port 443) with SSL
- Automatic redirect to HTTPS (if `force_https: true`)
- Service-specific subdomain on chdev.eu

Manual reload if needed:
```bash
wso-nginx-reload
```

### Service Data Management

Each service can have persistent data in `/var/lib/wso/data/service-name/`:

```yaml
# In manifest
data_uid: 1000  # Optional, default: 1000
```

The directory is created with the specified UID ownership, allowing containers to write data.

## Examples

See the `examples/` directory for:
- `wso-deploy.yml` - Complete deployment manifest (includes stack configuration)
- `github-action-deploy.yml` - CI/CD integration

## Maintenance

### View Logs

```bash
# System nginx
docker service logs system_nginx

# Your service
docker service logs myapp-production_webapp
```

### Backup

Important paths to backup:
- `/etc/wso/` - Configuration
- `/var/lib/wso/letsencrypt/` - SSL certificates
- `/var/lib/wso/data/` - Service data

### Update System Stack

```bash
docker stack deploy --compose-file /usr/lib/wso/docker/system-compose.yml system
```

## Troubleshooting

**Certificate generation fails:**
- Check DNS records point to your server
- Ensure port 80 is accessible
- Verify ACME challenge directory exists

**Nginx syntax errors:**
```bash
docker exec $(docker ps -q -f name=system_nginx) nginx -t
```

**Service deployment fails:**
- Check Docker registry authentication
- Verify service exists: `docker service ls`
- Check logs: `docker service logs <service-name>`

## Security

- Deployer user with restricted sudo access
- All secrets stored with root-only permissions (400)
- Services isolated in overlay network
- Modern TLS protocols (TLS 1.2+) with HSTS
- File integrity verification via checksums

## Contributing

Contributions welcome! Please submit a Pull Request.

## License

Apache License 2.0 - see [LICENSE](LICENSE) file.

---

**Web Server Orchestrator** - Simple, secure, scalable.
