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

**Prerequisites**: Ruby and XMRig must be installed and available in PATH before running the installation script.

For each mining host, SSH in and run:

```bash
# SSH to host machine
ssh user@mining-host

# Verify prerequisites are installed
ruby --version  # Should show Ruby 3.x or later
xmrig --version # Should show XMRig installation

# Clone repository (or copy host-daemon directory)
git clone https://github.com/yourusername/zen-miner.git
cd zen-miner/host-daemon

# ⚠️  SECURITY WARNING ⚠️
# NEVER commit wallet addresses to version control
# NEVER echo these values in scripts or logs
# Store wallet addresses securely (use environment variables or secrets manager)

# Set required environment variables
export MONERO_WALLET="your-monero-wallet-address"  # ⚠️  Keep secret!
export WORKER_ID="unique-worker-id"                # Unique identifier for this host
export POOL_URL="pool.hashvault.pro:443"           # Optional
export CPU_MAX_THREADS_HINT="50"                   # Optional

# Run installation script as root
sudo ./install.sh
```

The installation script will:
1. Verify Ruby and XMRig are installed
2. Install system dependencies (SQLite3, sudo)
3. Create `xmrig` and `xmrig-orchestrator` system users
4. Configure sudo permissions for orchestrator
5. Generate XMRig configuration
6. Install orchestrator daemon
7. Set up systemd services
8. Configure log rotation (7-day retention)

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
# Start mining (uses WORKER_ID from environment)
Xmrig::CommandService.start_mining

# Stop mining
Xmrig::CommandService.stop_mining(reason: 'maintenance')

# Restart mining
Xmrig::CommandService.restart_mining(reason: 'config_change')
```

### Updating Orchestrator Daemon

After making changes to `host-daemon/xmrig-orchestrator`, update all hosts:

#### First Time Setup: Add SSH Host Keys

For security, SSH host keys must be verified before deployment:

```bash
# Add all configured hosts to known_hosts (first time only)
bin/update-orchestrators-ssh --add-hosts

# Or list currently known hosts
bin/update-orchestrators-ssh --list-hosts
```

**⚠️ Security Note:** SSH host keys are stored in `~/.ssh/known_hosts` (standard SSH location) to prevent MITM attacks. Each user must verify their own mining hosts before deployment.

#### Updating Hosts

```bash
# Update all hosts via SSH (with host key verification)
bin/update-orchestrators-ssh

# Update specific host
bin/update-orchestrators-ssh --host mini-1 --yes

# Dry run (show what would be executed)
bin/update-orchestrators-ssh --dry-run

# Show binary checksum (for verification)
bin/update-orchestrators-ssh --show-checksum

# Skip host key verification (INSECURE - only for testing)
bin/update-orchestrators-ssh --skip-host-verification
```

**When to update orchestrators:**
- After database migrations affecting `xmrig_commands` or `xmrig_processes` tables
- After changes to orchestrator code logic
- After bug fixes in the daemon
- If seeing "no such column" errors in orchestrator logs

**Security Features:**
- ✅ SSH host key verification prevents MITM attacks
- ✅ SHA256 checksum verification ensures binary integrity
- ✅ Parallel deployment with 10 concurrent workers
- ✅ 5-minute timeout per host prevents hanging
- ✅ Memory protection (output truncated at 100KB)

**Binary Checksum Verification:**

The deployment process automatically verifies file integrity using SHA256 checksums:

1. **Pre-deployment**: Calculate SHA256 checksum of local `host-daemon/xmrig-orchestrator` file
2. **Post-copy**: Verify checksum on each remote host after file transfer
3. **Failure handling**: Deployment aborts if checksum doesn't match

To view the checksum before deployment:
```bash
bin/update-orchestrators-ssh --show-checksum
```

This prevents:
- Corrupted file transfers
- Tampering during transit
- Deployment of unintended binaries

**Note:** The update script uses direct SSH (not container-based) for security. Rails containers never have write access to the host filesystem.

### Deployment Checklist

When deploying changes:

```bash
# 1. Deploy Rails application
bin/kamal deploy

# 2. Update orchestrators if daemon code changed
bin/update-orchestrators-ssh

# 3. Verify health
bin/kamal logs
ssh deploy@mini-1 'sudo systemctl status xmrig-orchestrator'
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
