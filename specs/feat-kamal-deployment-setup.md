# Kamal Deployment Setup for Multi-Server Production

## Status
Draft

## Authors
- Claude Code Assistant
- Date: 2025-12-21

## Overview

Configure Kamal for production deployment of the Zen Miner Rails application across multiple servers, using Docker Hub as the container registry, Cloudflare for SSL/proxy, and SQLite with persistent volume storage.

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
- Set up multi-server deployment with role-based server assignment
- Enable Cloudflare proxy integration with proper SSL settings
- Configure SQLite persistence across deployments with shared volume strategy
- Establish secrets management best practices
- Create deployment workflow documentation
- Set up health checks and zero-downtime deployments

## Non-Goals

- Database migration to PostgreSQL (using SQLite with volumes)
- Redis or other cache services
- Custom load balancer configuration (Cloudflare handles this)
- CI/CD pipeline automation (manual deployment focus)
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

## Detailed Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CLOUDFLARE                                   │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  DNS: app.example.com → Cloudflare Proxy                    │    │
│  │  SSL: Full (strict) mode                                    │    │
│  │  Caching: Static assets cached at edge                      │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
         ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
         │   Server 1   │ │   Server 2   │ │   Server N   │
         │  (Primary)   │ │    (Web)     │ │    (Web)     │
         │──────────────│ │──────────────│ │──────────────│
         │ kamal-proxy  │ │ kamal-proxy  │ │ kamal-proxy  │
         │      ↓       │ │      ↓       │ │      ↓       │
         │ Rails + Puma │ │ Rails + Puma │ │ Rails + Puma │
         │ + Thruster   │ │ + Thruster   │ │ + Thruster   │
         │      ↓       │ │      ↓       │ │      ↓       │
         │  SQLite DB   │ │  (Read-only) │ │  (Read-only) │
         │  (Primary)   │ │              │ │              │
         └──────────────┘ └──────────────┘ └──────────────┘
                │
         ┌──────────────┐
         │ Persistent   │
         │ Volume       │
         │ /rails/      │
         │ storage      │
         └──────────────┘
```

### Multi-Server SQLite Strategy

Since SQLite doesn't support concurrent writes from multiple servers, there are two approaches:

**Option A: Single Primary Server (Recommended for this setup)**
- One server handles all database writes
- Other servers are stateless web frontends (if read-only features needed)
- Simple, reliable, matches current architecture

**Option B: Litestream Replication (Future Enhancement)**
- Use Litestream to replicate SQLite to S3
- Read replicas can serve read-only traffic
- More complex but allows scaling reads

For this spec, we'll implement **Option A** with a single-server primary model initially, with clear upgrade path to multi-server when needed.

### Configuration Changes

#### 1. Updated `config/deploy.yml`

```yaml
# Name of your application. Used to uniquely configure containers.
service: zen_miner

# Name of the container image.
image: your-dockerhub-username/zen_miner

# Deploy to these servers.
servers:
  web:
    - 123.45.67.89  # Primary server - replace with actual IP
    # Add more servers when scaling:
    # - 123.45.67.90
    # - 123.45.67.91
    hosts:
      123.45.67.89:
        labels:
          role: primary
    options:
      memory: 512m

# Cloudflare proxy configuration
# SSL is terminated at Cloudflare, so we don't need Let's Encrypt here
# Set Cloudflare SSL/TLS mode to "Full" (not "Full strict" since we're using HTTP internally)
proxy:
  ssl: false  # Cloudflare handles SSL
  host: app.example.com  # Replace with your domain
  # Health check configuration
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

    # Single server - 2 Puma workers recommended
    WEB_CONCURRENCY: 2

    # Log level for production
    RAILS_LOG_LEVEL: info

# Kamal aliases for common operations
aliases:
  console: app exec --interactive --reuse "bin/rails console"
  shell: app exec --interactive --reuse "bash"
  logs: app logs -f
  dbc: app exec --interactive --reuse "bin/rails dbconsole"
  backup: app exec "cp /rails/storage/production.sqlite3 /rails/storage/backup-$(date +%Y%m%d-%H%M%S).sqlite3"

# Persistent storage for SQLite and Active Storage
volumes:
  - "zen_miner_storage:/rails/storage"

# Asset bridging between deployments
asset_path: /rails/public/assets

# Build configuration
builder:
  arch: amd64
  # Use multi-platform builds if deploying to ARM servers
  # multiarch: true

  # For faster builds on M1/M2 Macs, use a remote amd64 builder:
  # remote: ssh://docker@your-build-server

# SSH configuration (optional, for non-root deployment)
# ssh:
#   user: deploy
#   keys:
#     - ~/.ssh/id_ed25519
```

#### 2. Updated `.kamal/secrets`

```bash
# Secrets for Kamal deployment
# DO NOT COMMIT ACTUAL VALUES - use environment variables or password manager

# Docker Hub access token (create at https://hub.docker.com/settings/security)
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD

# Rails master key for credentials decryption
RAILS_MASTER_KEY=$(cat config/master.key)

# Alternative: Use 1Password or similar
# SECRETS=$(kamal secrets fetch --adapter 1password --account my-account --from Vault/ZenMiner KAMAL_REGISTRY_PASSWORD RAILS_MASTER_KEY)
# KAMAL_REGISTRY_PASSWORD=$(kamal secrets extract KAMAL_REGISTRY_PASSWORD ${SECRETS})
# RAILS_MASTER_KEY=$(kamal secrets extract RAILS_MASTER_KEY ${SECRETS})
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
