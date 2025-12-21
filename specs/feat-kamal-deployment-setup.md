# Kamal Deployment Setup for Production

## Status
Draft (Simplified - Single Server)

## Authors
- Claude Code Assistant
- Date: 2025-12-21

## Overview

Configure Kamal for production deployment of the Zen Miner Rails application using Docker Hub as the container registry, Cloudflare for SSL/proxy, and SQLite with persistent volume storage.

**Note**: This is an open source project. Secrets are managed via 1Password/Bitwarden and fetched at deploy time by maintainers.

## Background/Problem Statement

### Current State
The project has Kamal partially configured with placeholder values:
- `config/deploy.yml` exists with template configuration
- `Dockerfile` is production-ready with multi-stage builds
- `.kamal/secrets` configured to read `RAILS_MASTER_KEY` from `config/master.key`
- Kamal gem already in Gemfile and `bin/kamal` wrapper present

### Issues with Current Configuration
1. **Placeholder Server IPs**: `192.168.0.1` is not a real production server
2. **Local Registry**: `localhost:5555` won't work for multi-server deployments
3. **No SSL Configuration**: Proxy/SSL settings are commented out
4. **Missing Multi-Server Strategy**: No load balancing or role-based deployment configured
5. **No CI/CD Integration**: Manual deployment only

### Core Problem
The application cannot be deployed to production because the Kamal configuration uses placeholder values and lacks proper registry, SSL, and multi-server configuration.

## Goals

- Configure Docker Hub as the container registry with proper authentication
- Set up multi-server deployment (6 servers) with Cloudflare load balancing
- Enable Cloudflare proxy integration with proper SSL settings
- Use SQLite per server (no shared state needed yet)
- Establish secrets management via 1Password/Bitwarden (open source friendly)
- Set up health checks and zero-downtime deployments

## Non-Goals

- Redis or other cache services (using Solid Cache/Queue)
- Custom load balancer configuration (Cloudflare handles this)
- CI/CD pipeline automation (manual deployment by maintainers)
- Kubernetes or container orchestration beyond Kamal
- Multi-region deployment
- Blue-green deployment strategy (Kamal uses rolling updates)

## Technical Dependencies

### Required
| Dependency | Version | Purpose |
|------------|---------|---------|
| Kamal | 2.x (bundled) | Deployment orchestration |
| Docker | 24.0+ | Container runtime on servers |
| Ruby | 3.4.5 | Application runtime |
| Thruster | (bundled) | HTTP asset caching/compression |

### External Services
| Service | Purpose | Configuration |
|---------|---------|---------------|
| Docker Hub | Container registry | Username + access token |
| Cloudflare | SSL termination, CDN, proxy | DNS + proxy enabled |
| SSH | Server access | Key-based authentication |

### Server Requirements
Each deployment server needs:
- Docker installed and running
- SSH access for deployment user
- Outbound access to Docker Hub
- Ports 80/443 open for web traffic
- Sufficient disk space for SQLite database

## Server Prerequisites & Setup

Before running `kamal setup`, each Arch Linux server must be configured with the following components.

### 1. Install Docker

```bash
# Update system
sudo pacman -Syu

# Install Docker
sudo pacman -S docker

# Enable and start Docker service
sudo systemctl enable docker
sudo systemctl start docker

# Verify Docker is running
sudo docker --version
```

### 2. Create Deployment User & Configure SSH

```bash
# Create a deployment user (if not using root)
sudo useradd -m -G docker deploy

# Add your SSH public key to the deployment user
sudo mkdir -p /home/deploy/.ssh
sudo vim /home/deploy/.ssh/authorized_keys  # Paste your public key
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

### 3. Configure Firewall

```bash
# If using ufw (needs to be installed)
sudo pacman -S ufw
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw enable

# Or with iptables directly
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

### 4. Verify Outbound Connectivity

```bash
# Test connection to Docker Hub
curl -I https://hub.docker.com

# Test Docker pull
sudo docker pull hello-world
sudo docker run hello-world
```

### 5. Verify SSH Access from Local Machine

Before running `kamal setup`, verify SSH access from your local machine:

```bash
# Test SSH connection (replace with your server)
ssh deploy@server1.example.com "docker ps"

# If successful, you should see Docker container list (empty initially)
```

### Server Setup Checklist

For each of your 6 servers:

- [ ] Docker installed and running (`systemctl status docker`)
- [ ] Deployment user created and added to `docker` group
- [ ] SSH key-based authentication configured
- [ ] Ports 80, 443, and 22 accessible
- [ ] Outbound HTTPS to Docker Hub working
- [ ] Sufficient disk space (recommend at least 20GB free)

Once all servers are configured, run:

```bash
bin/kamal setup
```

This will bootstrap Kamal on each server and deploy your application.

## Detailed Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CLOUDFLARE                                   │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  DNS: app.example.com → Cloudflare Proxy (Load Balanced)    │    │
│  │  SSL: Full mode (Cloudflare → HTTP → Servers)               │    │
│  │  Caching: Static assets cached at edge                      │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
          ┌─────────┬─────────┬─────┴─────┬─────────┬─────────┐
          ▼         ▼         ▼           ▼         ▼         ▼
     ┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐┌────────┐
     │Server 1││Server 2││Server 3││Server 4││Server 5││Server 6│
     │────────││────────││────────││────────││────────││────────│
     │ kamal- ││ kamal- ││ kamal- ││ kamal- ││ kamal- ││ kamal- │
     │ proxy  ││ proxy  ││ proxy  ││ proxy  ││ proxy  ││ proxy  │
     │   ↓    ││   ↓    ││   ↓    ││   ↓    ││   ↓    ││   ↓    │
     │ Rails  ││ Rails  ││ Rails  ││ Rails  ││ Rails  ││ Rails  │
     │ + Puma ││ + Puma ││ + Puma ││ + Puma ││ + Puma ││ + Puma │
     │   ↓    ││   ↓    ││   ↓    ││   ↓    ││   ↓    ││   ↓    │
     │SQLite  ││SQLite  ││SQLite  ││SQLite  ││SQLite  ││SQLite  │
     │(local) ││(local) ││(local) ││(local) ││(local) ││(local) │
     └────────┘└────────┘└────────┘└────────┘└────────┘└────────┘
```

Each server has its own SQLite database (no shared state). This is suitable for
stateless workers or applications without models yet. When shared database is
needed, migrate to PostgreSQL (e.g., Neon).

### Secrets Management (Open Source)

Since this is an open source project, secrets are **never stored in the repository**. Maintainers fetch secrets from their password manager at deploy time using Kamal's built-in adapters.

| Secret | Storage | Who Has Access |
|--------|---------|----------------|
| `RAILS_MASTER_KEY` | 1Password/Bitwarden vault | Maintainers only |
| `KAMAL_REGISTRY_USERNAME` | 1Password/Bitwarden vault | Maintainers only |
| `KAMAL_REGISTRY_PASSWORD` | 1Password/Bitwarden vault | Maintainers only |
| SSH keys | Each maintainer's `~/.ssh/` | Individual |
| Server IPs, domain | `config/deploy.yml` (public) | Everyone |

### Configuration Changes

#### 1. Updated `config/deploy.yml`

```yaml
# Name of your application. Used to uniquely configure containers.
service: zen_miner

# Name of the container image.
image: your-dockerhub-username/zen_miner

# Deploy to these servers (6 servers behind Cloudflare load balancing)
servers:
  web:
    - server1.example.com
    - server2.example.com
    - server3.example.com
    - server4.example.com
    - server5.example.com
    - server6.example.com

# Cloudflare proxy configuration
# SSL is terminated at Cloudflare, so we don't need Let's Encrypt here
# Set Cloudflare SSL/TLS mode to "Full"
proxy:
  ssl: false  # Cloudflare handles SSL
  host: app.example.com  # Replace with your domain
  healthcheck:
    path: /up
    interval: 3

# Container registry - Docker Hub
registry:
  server: docker.io
  username: your-dockerhub-username
  password:
    - KAMAL_REGISTRY_PASSWORD

# Environment variables
env:
  secret:
    - RAILS_MASTER_KEY
  clear:
    # Solid Queue runs in Puma process
    SOLID_QUEUE_IN_PUMA: true

    # Cloudflare sends X-Forwarded-For, trust the proxy
    RAILS_ASSUME_SSL: true

    # 2 Puma workers per server
    WEB_CONCURRENCY: 2

    # Log level for production
    RAILS_LOG_LEVEL: info

# Kamal aliases for common operations
aliases:
  console: app exec --interactive --reuse "bin/rails console"
  shell: app exec --interactive --reuse "bash"
  logs: app logs -f
  dbc: app exec --interactive --reuse "bin/rails dbconsole"

# Persistent storage for Active Storage uploads
volumes:
  - "zen_miner_storage:/rails/storage"

# Asset bridging between deployments
asset_path: /rails/public/assets

# Build configuration
builder:
  arch: amd64
```

#### 2. Updated `.kamal/secrets`

```bash
# Secrets for Kamal deployment - fetched from password manager
# This file is safe to commit - it contains NO actual secrets

# =============================================================================
# 1PASSWORD INTEGRATION (recommended)
# =============================================================================
# Prerequisites:
#   1. Install 1Password CLI: https://developer.1password.com/docs/cli/get-started/
#   2. Sign in: op signin
#   3. Create vault item "Zen Miner Production" with fields:
#      - KAMAL_REGISTRY_USERNAME (Docker Hub username)
#      - KAMAL_REGISTRY_PASSWORD (Docker Hub access token)
#      - RAILS_MASTER_KEY (from config/master.key)

SECRETS=$(kamal secrets fetch \
  --adapter 1password \
  --account your-team.1password.com \
  --from "Private/Zen Miner Production" \
  KAMAL_REGISTRY_USERNAME KAMAL_REGISTRY_PASSWORD RAILS_MASTER_KEY)

KAMAL_REGISTRY_USERNAME=$(kamal secrets extract KAMAL_REGISTRY_USERNAME $SECRETS)
KAMAL_REGISTRY_PASSWORD=$(kamal secrets extract KAMAL_REGISTRY_PASSWORD $SECRETS)
RAILS_MASTER_KEY=$(kamal secrets extract RAILS_MASTER_KEY $SECRETS)

# =============================================================================
# BITWARDEN INTEGRATION (alternative)
# =============================================================================
# Uncomment below and comment out 1Password section above if using Bitwarden
#
# Prerequisites:
#   1. Install Bitwarden CLI: https://bitwarden.com/help/cli/
#   2. Login and unlock: bw login && bw unlock
#   3. Create secure note "Zen Miner Production" with fields
#
# SECRETS=$(kamal secrets fetch \
#   --adapter bitwarden \
#   --from "Zen Miner Production" \
#   KAMAL_REGISTRY_USERNAME KAMAL_REGISTRY_PASSWORD RAILS_MASTER_KEY)
#
# KAMAL_REGISTRY_USERNAME=$(kamal secrets extract KAMAL_REGISTRY_USERNAME $SECRETS)
# KAMAL_REGISTRY_PASSWORD=$(kamal secrets extract KAMAL_REGISTRY_PASSWORD $SECRETS)
# RAILS_MASTER_KEY=$(kamal secrets extract RAILS_MASTER_KEY $SECRETS)
```

### Rails Configuration Changes

#### 3. Update `config/environments/production.rb`

Add/verify these settings for Cloudflare proxy:

```ruby
# config/environments/production.rb

# Trust Cloudflare proxy headers
config.assume_ssl = true
config.force_ssl = true

# Cloudflare IP ranges for trusted proxies
config.action_dispatch.trusted_proxies = ActionDispatch::RemoteIp::TRUSTED_PROXIES + [
  # Cloudflare IPv4 ranges (update periodically from https://www.cloudflare.com/ips/)
  IPAddr.new("173.245.48.0/20"),
  IPAddr.new("103.21.244.0/22"),
  IPAddr.new("103.22.200.0/22"),
  IPAddr.new("103.31.4.0/22"),
  IPAddr.new("141.101.64.0/18"),
  IPAddr.new("108.162.192.0/18"),
  IPAddr.new("190.93.240.0/20"),
  IPAddr.new("188.114.96.0/20"),
  IPAddr.new("197.234.240.0/22"),
  IPAddr.new("198.41.128.0/17"),
  IPAddr.new("162.158.0.0/15"),
  IPAddr.new("104.16.0.0/13"),
  IPAddr.new("104.24.0.0/14"),
  IPAddr.new("172.64.0.0/13"),
  IPAddr.new("131.0.72.0/22"),
]

# Ensure proper host headers from Cloudflare
config.hosts << "app.example.com"  # Replace with your domain
config.hosts << /.*\.example\.com/ # Allow subdomains if needed
```

### File Organization

```
zen-miner/
├── .kamal/
│   ├── hooks/
│   │   ├── pre-build           # Run tests before build
│   │   ├── pre-deploy          # Database backup before deploy
│   │   └── post-deploy         # Notify on successful deploy
│   └── secrets                 # Secret extraction script
├── config/
│   ├── deploy.yml              # Main Kamal configuration
│   └── environments/
│       └── production.rb       # Cloudflare proxy settings
├── Dockerfile                  # Multi-stage production build
└── bin/
    └── kamal                   # Kamal CLI wrapper
```

### Deployment Hooks

#### 4. Pre-deploy backup hook (`.kamal/hooks/pre-deploy`)

```bash
#!/bin/bash
# Backup SQLite database before deployment

echo "Creating pre-deploy backup..."
kamal app exec --reuse "cp /rails/storage/production.sqlite3 /rails/storage/backup-$(date +%Y%m%d-%H%M%S).sqlite3" || true
echo "Backup complete (or no existing database)"
```

#### 5. Post-deploy notification (`.kamal/hooks/post-deploy`)

```bash
#!/bin/bash
# Notify on successful deployment

VERSION=$(cat .kamal/version 2>/dev/null || echo "unknown")
echo "Deployment of version $VERSION complete!"

# Optional: Send notification (uncomment and configure)
# curl -X POST "https://api.example.com/notify" \
#   -H "Content-Type: application/json" \
#   -d "{\"text\": \"Zen Miner deployed: $VERSION\"}"
```

### Cloudflare Configuration

Required Cloudflare settings:

| Setting | Value | Location |
|---------|-------|----------|
| SSL/TLS Mode | Full | SSL/TLS > Overview |
| Always Use HTTPS | On | SSL/TLS > Edge Certificates |
| Minimum TLS Version | 1.2 | SSL/TLS > Edge Certificates |
| Proxy Status | Proxied (orange cloud) | DNS > Records |

## User Experience

### For Developers

1. **First-time setup**:
   ```bash
   # Install Kamal (if not using bundled)
   gem install kamal

   # Set up Docker Hub credentials
   export KAMAL_REGISTRY_PASSWORD="your-docker-hub-token"

   # Bootstrap server (first time only)
   bin/kamal setup
   ```

2. **Regular deployments**:
   ```bash
   # Deploy latest code
   bin/kamal deploy

   # View logs
   bin/kamal logs

   # Rails console
   bin/kamal console

   # Rollback if needed
   bin/kamal rollback
   ```

3. **Debugging**:
   ```bash
   # SSH to container
   bin/kamal shell

   # Check app status
   bin/kamal app details

   # View container info
   bin/kamal proxy details
   ```

### For Operations

1. **Monitoring**: Use Cloudflare Analytics for traffic patterns
2. **Backups**: Automated via pre-deploy hook + manual with `bin/kamal backup`
3. **Scaling**: Add server IPs to `config/deploy.yml` and run `bin/kamal setup`

## Testing Strategy

### Pre-deployment Validation

```bash
# Validate configuration syntax
bin/kamal config

# Dry-run to see what would be deployed
bin/kamal deploy --dry-run

# Check registry connectivity
docker login docker.io
```

### Health Check Testing

```ruby
# test/integration/health_check_test.rb
# Purpose: Verify the /up endpoint responds correctly for Kamal health checks

require "test_helper"

class HealthCheckTest < ActionDispatch::IntegrationTest
  test "/up returns 200 for healthy app" do
    get "/up"
    assert_response :success
  end

  test "/up returns appropriate status when database is unavailable" do
    # This test verifies the health check correctly reports database issues
    # The actual implementation depends on how /up is configured
    skip "Implement based on your health check controller logic"
  end
end
```

### Deployment Testing Checklist

| Test | Command | Expected Result |
|------|---------|-----------------|
| Config valid | `bin/kamal config` | No errors, shows parsed config |
| Registry auth | `docker login docker.io` | Login succeeded |
| SSH access | `ssh deploy@your-server 'docker ps'` | Lists containers |
| DNS resolution | `dig app.example.com` | Returns Cloudflare IPs |
| SSL valid | `curl -I https://app.example.com` | HTTP 200, valid cert |

### Rollback Testing

```bash
# Test rollback procedure before production
bin/kamal rollback --version [previous-version]
```

## Performance Considerations

### Container Resource Limits

```yaml
# In deploy.yml servers section
servers:
  web:
    - 123.45.67.89
    options:
      memory: 512m
      cpus: 1
```

### Puma Configuration

The default `config/puma.rb` should work, but consider:
- `WEB_CONCURRENCY=2` for 1GB RAM servers
- `WEB_CONCURRENCY=4` for 2GB+ RAM servers

### Asset Performance

- Thruster provides automatic gzip compression
- Cloudflare caches static assets at edge
- `asset_path` bridging prevents 404s during deployment

### Cold Start Optimization

- Bootsnap precompilation in Dockerfile reduces boot time
- jemalloc for reduced memory fragmentation

## Security Considerations

### Secrets Management

| Secret | Storage | Access |
|--------|---------|--------|
| RAILS_MASTER_KEY | `config/master.key` (gitignored) | Read at deploy time |
| KAMAL_REGISTRY_PASSWORD | Environment variable | Set in CI or shell |
| SSH Keys | Local `~/.ssh/` | Used by Kamal for deployment |

### Container Security

- Runs as non-root user (`rails:rails` UID 1000)
- Read-only root filesystem (except mounted volumes)
- No SSH daemon in container

### Network Security

- Cloudflare WAF protects against common attacks
- Only ports 80/443 exposed via proxy
- Container-to-container communication via Docker network

### Credential Rotation

1. **Docker Hub Token**: Rotate annually, update `KAMAL_REGISTRY_PASSWORD`
2. **Rails Master Key**: Rotate if compromised, requires re-encryption of credentials
3. **SSH Keys**: Use ed25519, rotate if compromised

## Documentation

### To Create

1. **DEPLOYMENT.md**: Step-by-step deployment guide
2. **Update README.md**: Add deployment section
3. **Runbook**: Common operations and troubleshooting

### To Update

- `AGENTS.md`: Add Kamal commands to available tasks section

## Implementation Phases

### Phase 1: Core Configuration
- Update `config/deploy.yml` with real values
- Configure Docker Hub registry
- Set up first server with `bin/kamal setup`
- Verify basic deployment works

### Phase 2: Production Hardening
- Configure Cloudflare DNS and proxy
- Update Rails production config for proxy
- Add health check endpoint
- Set up pre-deploy backup hook

### Phase 3: Operational Readiness
- Create deployment documentation
- Set up monitoring via Cloudflare Analytics
- Establish backup and restore procedures
- Document rollback procedures

## Open Questions

1. **Server Provisioning**: How will servers be provisioned? (Manual, Terraform, cloud provider?)
2. **Domain Name**: What domain will be used for production?
3. **Docker Hub Account**: Personal account or organization?
4. **Backup Strategy**: Where should SQLite backups be stored long-term? (S3, local, etc.)
5. **Scaling Trigger**: At what traffic level should we consider moving to PostgreSQL?
6. **Monitoring**: Should we add application monitoring (New Relic, Datadog, etc.)?

## References

- [Kamal Documentation](https://kamal-deploy.org/)
- [Kamal GitHub Repository](https://github.com/basecamp/kamal)
- [Cloudflare SSL/TLS Modes](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/)
- [Cloudflare IP Ranges](https://www.cloudflare.com/ips/)
- [Rails 8 Deployment Guide](https://guides.rubyonrails.org/deployment.html)
- [Thruster Documentation](https://github.com/basecamp/thruster)
- [SQLite in Production](https://litestream.io/)
