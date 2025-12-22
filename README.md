# Zen Miner

An open source Rails application for orchestrating cryptocurrency mining rigs. Manage multiple XMRig miners from a centralized web interface with real-time monitoring and configuration management.

## Features

- **Multi-Rig Orchestration**: Manage multiple mining rigs from a single dashboard
- **Real-Time Monitoring**: WebSocket-powered live updates via Action Cable
- **XMRig Integration**: Full support for CPU, GPU, and hybrid mining configurations
- **Zero-Downtime Deployments**: Kamal-based container deployments across multiple servers
- **PWA-Ready**: Progressive Web App support for mobile access
- **Background Jobs**: Solid Queue for reliable job processing

## Tech Stack

- **Framework**: Ruby on Rails 8.1
- **Ruby Version**: 3.4.5
- **Database**: SQLite3 (with Solid Cache, Solid Queue, Solid Cable)
- **Frontend**: Hotwire (Turbo + Stimulus)
- **Asset Pipeline**: Propshaft with Import Maps
- **Deployment**: Kamal with Docker
- **Web Server**: Puma with Thruster

## Getting Started

### Prerequisites

- Ruby 3.4.5
- SQLite3
- XMRig (for mining operations)

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/zen-miner.git
   cd zen-miner
   ```

2. Install dependencies:
   ```bash
   bundle install
   ```

3. Setup the database:
   ```bash
   bin/rails db:setup
   ```

4. Start the development server:
   ```bash
   bin/dev
   ```

5. Visit `http://localhost:3000`

### Running Tests

```bash
# Run all tests
bin/rails test

# Run system tests
bin/rails test:system
```

## Configuration

### Mining Configurations

XMRig configuration files are stored in `configs/`:

| File | Purpose |
|------|---------|
| `configs/cpu.json` | CPU-only mining |
| `configs/gpu.json` | GPU mining (OpenCL/CUDA) |
| `configs/hybrid.json` | Combined CPU+GPU mining |

### Environment Variables

Configure via Rails credentials or environment variables:

| Variable | Description |
|----------|-------------|
| `RAILS_MASTER_KEY` | Rails encrypted credentials key |
| `MONERO_WALLET` | Destination wallet address |

## Deployment

Zen Miner uses [Kamal](https://kamal-deploy.org/) for container deployments with a unique architecture where the Rails app runs in Docker containers while XMRig mining daemons run directly on the host machines.

### Architecture Overview

```
Docker Host
├── Rails App (Docker container)     → Web interface, API, job processing
│   └── SQLite DB @ /rails/storage   → Shared via volume mount
├── XMRig (systemd service)          → Mining process (runs on host)
├── Orchestrator (systemd daemon)    → Command processor (runs on host)
└── /mnt/rails-storage               → Shared volume for database
```

### Prerequisites

1. **Docker hosts configured** with Kamal access
2. **Environment variables set**:
   - `RAILS_MASTER_KEY` - Rails credentials encryption key
   - `MONERO_WALLET` - Monero wallet address for mining rewards
3. **Kamal 2.10.1+** installed locally
4. **SSH access** to all host machines

### Step 1: Deploy Rails Application

```bash
# First-time setup
bin/kamal setup

# Deploy latest changes
bin/kamal deploy

# Verify deployment
bin/kamal logs
```

This deploys the Rails app with:
- SQLite database in `/rails/storage` (mounted as Docker volume)
- Puma web server with Thruster
- Solid Queue for background jobs
- Action Cable for real-time updates

### Step 2: Deploy Host Daemons

**CRITICAL**: Host daemons must be installed AFTER Rails deployment to ensure database is available.

For each mining host, SSH in and run:

```bash
# SSH to host machine
ssh user@mining-host

# Clone repository (or copy host-daemon directory)
git clone https://github.com/yourusername/zen-miner.git
cd zen-miner/host-daemon

# Set required environment variables
export MONERO_WALLET="your-monero-wallet-address"
export POOL_URL="pool.hashvault.pro:443"  # Optional
export CPU_MAX_THREADS_HINT="50"          # Optional
export XMRIG_VERSION="6.21.0"             # Optional

# Run installation script as root
sudo ./install.sh
```

The installation script will:
1. Install dependencies (Ruby, SQLite3, wget)
2. Download and verify XMRig binary (with SHA256 checksum)
3. Create `xmrig` and `xmrig-orchestrator` system users
4. Configure sudo permissions for orchestrator
5. Set up systemd services
6. Configure log rotation (7-day retention)

### Step 3: Start Orchestrator Service

```bash
# Start the orchestrator daemon
sudo systemctl start xmrig-orchestrator

# Check status
sudo systemctl status xmrig-orchestrator

# View logs
sudo journalctl -u xmrig-orchestrator -f
```

### Step 4: Issue Mining Commands

From Rails console or web interface:

```ruby
# Start mining on a host
Xmrig::CommandService.start_mining('hostname')

# Stop mining
Xmrig::CommandService.stop_mining('hostname', reason: 'maintenance')

# Restart mining
Xmrig::CommandService.restart_mining('hostname', reason: 'config_change')

# Start all configured hosts
Xmrig::CommandService.start_all
```

### Database Migration Between Deployments

When deploying Rails updates with database migrations:

```bash
# 1. Deploy Rails app (migrations run automatically)
bin/kamal deploy

# 2. Restart orchestrator daemons on each host to pick up schema changes
ssh host1 'sudo systemctl restart xmrig-orchestrator'
ssh host2 'sudo systemctl restart xmrig-orchestrator'
# ... repeat for all hosts
```

### Volume Mount Configuration

The database is shared between Rails container and host daemons via volume mount:

```yaml
# config/deploy.yml
volumes:
  - "/mnt/rails-storage:/rails/storage"
```

**Important**: Ensure `/mnt/rails-storage` exists on all hosts before deployment.

### Health Monitoring

The orchestrator daemon monitors XMRig health every 10 seconds:

- **Checks**: Process status, HTTP API response, hashrate > 0
- **Auto-restart**: Immediate restart on any error (no backoff)
- **Logging**: Structured logs to `/var/log/xmrig/orchestrator.log`

View health status:

```bash
# From host
curl http://127.0.0.1:8080/2/summary | jq

# From Rails console
XmrigProcess.find_by(hostname: 'host1')
```

### Troubleshooting Deployment

**Issue**: Orchestrator can't connect to database

```bash
# Check volume mount
ls -la /mnt/rails-storage/production.sqlite3

# Check database permissions
sudo -u xmrig-orchestrator sqlite3 /mnt/rails-storage/production.sqlite3 "SELECT 1"

# Check orchestrator logs
sudo journalctl -u xmrig-orchestrator -n 50
```

**Issue**: XMRig won't start

```bash
# Check XMRig service
sudo systemctl status xmrig

# Check XMRig logs
sudo journalctl -u xmrig -n 50

# Validate config
cat /etc/xmrig/config.json | jq
```

**Issue**: Commands not processing

```bash
# Check for pending commands in database
sudo sqlite3 /mnt/rails-storage/production.sqlite3 \
  "SELECT * FROM xmrig_commands WHERE hostname='$(hostname)' AND status='pending'"

# Check orchestrator is running
sudo systemctl is-active xmrig-orchestrator
```

### Security Considerations

- **Orchestrator privileges**: Runs as dedicated `xmrig-orchestrator` user (not root)
- **Sudo configuration**: NOPASSWD only for specific systemctl commands
- **XMRig sandboxing**: systemd security directives (NoNewPrivileges, PrivateTmp, ProtectSystem)
- **Database concurrency**: SQLite WAL mode enabled for multi-process access
- **Binary verification**: SHA256 checksum validation for XMRig downloads
- **Wallet validation**: Monero address format validation before installation

### Production Checklist

Before deploying to production:

- [ ] Rails app deployed and database accessible
- [ ] Host daemons installed on all mining hosts
- [ ] Orchestrator services running and healthy
- [ ] XMRig configuration validated
- [ ] Database volume mount working
- [ ] Health monitoring operational
- [ ] Logs being collected and rotated
- [ ] Test mining commands working
- [ ] Firewall rules configured (if needed)
- [ ] Monitoring and alerting set up

See `config/deploy.yml` for full Kamal configuration.

## Development

### Directory Structure

```
zen-miner/
├── app/                    # Application code
│   ├── controllers/        # Request handlers
│   ├── models/             # Database models
│   ├── views/              # HTML templates
│   ├── javascript/         # Stimulus controllers
│   └── jobs/               # Background jobs
├── config/                 # Configuration
│   ├── deploy.yml          # Kamal deployment
│   └── database.yml        # Database settings
├── configs/                # XMRig mining configs
├── db/                     # Database migrations
├── specs/                  # Feature specifications
└── test/                   # Test suite
```

### Code Quality

The project uses:
- **RuboCop** with Rails Omakase style
- **Brakeman** for security scanning
- **Bundler Audit** for dependency vulnerabilities

Run all checks:
```bash
bin/rubocop
bin/brakeman
bundle exec bundler-audit
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is open source. See the LICENSE file for details.

## Acknowledgments

- [XMRig](https://xmrig.com/) - High performance Monero miner
- [Kamal](https://kamal-deploy.org/) - Deploy web apps anywhere
- [Hotwire](https://hotwired.dev/) - HTML over the wire
