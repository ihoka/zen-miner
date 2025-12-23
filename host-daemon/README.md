# XMRig Host Daemon

Host-side components for XMRig daemon orchestration. These files are deployed to Docker hosts to manage XMRig mining processes via systemd.

## Architecture

```
Docker Host
├── XMRig (systemd service)           → Mining process
├── xmrig-orchestrator (daemon)       → Polls Rails DB, manages XMRig
└── /mnt/rails-storage (volume)       → Shared SQLite database
```

## Files

| File | Purpose |
|------|---------|
| `xmrig-orchestrator` | Ruby daemon that polls database and manages systemd |
| `xmrig.service` | systemd service file for XMRig mining process |
| `xmrig-orchestrator.service` | systemd service file for orchestrator daemon |
| `install.sh` | Installation script for host setup |
| `config.json.template` | XMRig configuration template |

## Installation

### Prerequisites

- Ubuntu/Debian host (systemd-based)
- Root access
- Docker container with Rails app deployed
- Database volume mounted at `/mnt/rails-storage`

### Setup

1. **Set environment variables:**
   ```bash
   export MONERO_WALLET="your-wallet-address"
   export POOL_URL="pool.hashvault.pro:443"        # Optional, defaults to this
   export CPU_MAX_THREADS_HINT="50"                # Optional, defaults to 50
   export XMRIG_VERSION="6.21.0"                   # Optional, defaults to 6.21.0
   ```

2. **Run installation script:**
   ```bash
   sudo ./install.sh
   ```

3. **Verify database mount:**
   ```bash
   ls -la /mnt/rails-storage/production.sqlite3
   ```

4. **Start orchestrator:**
   ```bash
   sudo systemctl start xmrig-orchestrator
   sudo systemctl status xmrig-orchestrator
   ```

5. **Issue start command from Rails:**
   ```ruby
   Xmrig::CommandService.start_mining
   ```

## Operation

### Starting Mining

From Rails console:
```ruby
Xmrig::CommandService.start_mining
```

The orchestrator daemon will:
1. Poll database every 10 seconds
2. See pending "start" command
3. Execute `systemctl start xmrig`
4. Update command status to "completed"
5. Begin health monitoring

### Stopping Mining

From Rails console:
```ruby
Xmrig::CommandService.stop_mining(reason: 'maintenance')
```

### Restarting Mining

From Rails console:
```ruby
Xmrig::CommandService.restart_mining(reason: 'config_change')
```

### Checking Status

**Rails-side:**
```ruby
XmrigProcess.find_by(hostname: 'mini-1')
```

**Host-side:**
```bash
# Orchestrator status
sudo systemctl status xmrig-orchestrator
sudo journalctl -u xmrig-orchestrator -f

# XMRig status
sudo systemctl status xmrig
sudo journalctl -u xmrig -f

# XMRig API
curl http://127.0.0.1:8080/2/summary | jq
```

## Updating the Orchestrator Daemon

When code changes are made to the orchestrator daemon (`host-daemon/xmrig-orchestrator`), you must update all deployed hosts since the orchestrator runs outside the Docker container.

### Automated Update via SSH (Recommended)

From your local development machine:

```bash
# Update all hosts
bin/update-orchestrators-ssh

# Update specific host without confirmation
bin/update-orchestrators-ssh --host mini-1 --yes

# Dry run (show what would be executed)
bin/update-orchestrators-ssh --dry-run

# Verbose mode (show all SSH commands)
bin/update-orchestrators-ssh --verbose
```

**What the script does:**
1. SSHs to each host as `deploy` user
2. Detects xmrig binary location and creates symlink if needed
3. Copies the latest orchestrator daemon to `/usr/local/bin/`
4. Restarts the `xmrig-orchestrator` service
5. Verifies successful restart

**Output example:**
```
============================================================
XMRig Orchestrator Update (via SSH)
============================================================

Hosts to update:
  - mini-1
  - miner-beta
  - miner-gamma
  - miner-delta

Continue? [y/N]: y

[12:45:01] Updating mini-1...
[12:45:06] ✓ mini-1 updated successfully (5s)

Success: 4 hosts
```

### Manual Update (Single Host)

If you prefer to update a single host manually:

```bash
# From local dev machine
scp host-daemon/xmrig-orchestrator deploy@mini-1:/tmp/

# SSH to host
ssh deploy@mini-1

# On the host
sudo cp /tmp/xmrig-orchestrator /usr/local/bin/xmrig-orchestrator
sudo chmod +x /usr/local/bin/xmrig-orchestrator
sudo systemctl restart xmrig-orchestrator
sudo systemctl status xmrig-orchestrator
```

### When to Update

Update the orchestrator daemon after:
- Database schema changes affecting `xmrig_commands` or `xmrig_processes` tables
- Changes to orchestrator logic or command processing
- Bug fixes in the daemon code
- XMRig API endpoint changes
- After seeing "no such column" or other SQLite errors in orchestrator logs

### Verification

After updating, verify the orchestrator is running correctly:

```bash
# Check service status on all hosts
for host in mini-1 miner-beta miner-gamma miner-delta; do
  echo "=== $host ==="
  ssh deploy@$host 'sudo systemctl status xmrig-orchestrator'
done

# Check recent logs
ssh deploy@mini-1 'sudo journalctl -u xmrig-orchestrator -n 50'

# Verify no errors
ssh deploy@mini-1 'sudo grep -i error /var/log/xmrig/orchestrator.log | tail -20'
```

**Security Note:** The update script uses direct SSH (not container-based) to maintain security boundaries. The Rails container never has write access to the host filesystem.

## Health Monitoring

The orchestrator daemon monitors XMRig health every 10 seconds via HTTP API:

- **Checks:**
  - Process alive (systemd status)
  - HTTP API responding
  - Hashrate > 0

- **Auto-restart triggers:**
  - Zero hashrate
  - API not responding
  - systemd reports failure

- **Restart policy:**
  - Immediate restart on any error (no backoff)
  - Restarts logged with reason

## Logs

**Locations:**
- Orchestrator: `/var/log/xmrig/orchestrator.log`
- XMRig: `/var/log/xmrig/xmrig.log`

**Retention:**
- 7 days (managed by logrotate)
- Daily rotation with compression

**Viewing:**
```bash
# Tail orchestrator logs
sudo tail -f /var/log/xmrig/orchestrator.log

# Tail XMRig logs
sudo tail -f /var/log/xmrig/xmrig.log

# Journalctl (systemd logs)
sudo journalctl -u xmrig-orchestrator -f
sudo journalctl -u xmrig -f
```

## Troubleshooting

### Orchestrator Not Starting

```bash
# Check status
sudo systemctl status xmrig-orchestrator

# Check logs
sudo journalctl -u xmrig-orchestrator -n 50

# Common issues:
# 1. Database not mounted
ls -la /mnt/rails-storage/production.sqlite3

# 2. Ruby not installed
which ruby

# 3. Permissions on script
ls -la /usr/local/bin/xmrig-orchestrator
```

### XMRig Not Starting

```bash
# Check status
sudo systemctl status xmrig

# Check logs
sudo journalctl -u xmrig -n 50

# Common issues:
# 1. Config file invalid
cat /etc/xmrig/config.json | jq

# 2. Binary missing
ls -la /usr/local/bin/xmrig

# 3. Log directory permissions
ls -la /var/log/xmrig/
```

### Commands Not Processing

```bash
# Check database access
sudo sqlite3 /mnt/rails-storage/production.sqlite3 "SELECT * FROM xmrig_commands WHERE hostname='$(hostname)' ORDER BY created_at DESC LIMIT 5;"

# Check orchestrator is polling
sudo journalctl -u xmrig-orchestrator -f
# Should see "Processing command" messages

# Check for pending commands
sudo sqlite3 /mnt/rails-storage/production.sqlite3 "SELECT id, action, status, created_at FROM xmrig_commands WHERE hostname='$(hostname)' AND status='pending';"
```

### Zero Hashrate

```bash
# Check XMRig API
curl http://127.0.0.1:8080/2/summary | jq '.hashrate'

# Check pool connection
curl http://127.0.0.1:8080/2/summary | jq '.connection'

# Check CPU usage
top | grep xmrig

# Check systemd restart count
systemctl show xmrig | grep NRestarts
```

## Uninstall

```bash
# Stop services
sudo systemctl stop xmrig-orchestrator
sudo systemctl stop xmrig

# Disable services
sudo systemctl disable xmrig-orchestrator
sudo systemctl disable xmrig

# Remove files
sudo rm /usr/local/bin/xmrig
sudo rm /usr/local/bin/xmrig-orchestrator
sudo rm /etc/systemd/system/xmrig.service
sudo rm /etc/systemd/system/xmrig-orchestrator.service
sudo rm /etc/logrotate.d/xmrig
sudo rm -rf /etc/xmrig
sudo rm -rf /var/log/xmrig

# Reload systemd
sudo systemctl daemon-reload

# Remove user (optional)
sudo userdel xmrig
```

## Security

- **Orchestrator runs as root:** Required for systemctl commands
- **XMRig runs as 'xmrig' user:** Non-privileged systemd service
- **systemd sandboxing:**
  - `NoNewPrivileges=true`
  - `PrivateTmp=true`
  - `ProtectSystem=strict`
  - `ProtectHome=true`
- **HTTP API:** Localhost-only binding (127.0.0.1)
- **Database access:** Read/write via volume mount

## Configuration

### Changing Pool

Edit `/etc/xmrig/config.json` and restart:
```bash
sudo systemctl restart xmrig
```

### Changing CPU Threads

Edit `/etc/xmrig/config.json`:
```json
{
  "cpu": {
    "max-threads-hint": 75
  }
}
```

Then restart:
```bash
sudo systemctl restart xmrig
```

### Changing Polling Interval

Edit `/usr/local/bin/xmrig-orchestrator`:
```ruby
POLL_INTERVAL = 5  # Change from 10 to 5 seconds
```

Then restart:
```bash
sudo systemctl restart xmrig-orchestrator
```

## Development

### Testing Locally

```bash
# Syntax check
ruby -c xmrig-orchestrator

# Test with dummy database
export XMRIG_DB_PATH=/tmp/test.db
export XMRIG_LOG_PATH=/tmp/orchestrator.log
ruby xmrig-orchestrator
```

### Debugging

```bash
# Run orchestrator in foreground
sudo /usr/local/bin/xmrig-orchestrator

# Check environment
sudo systemctl show xmrig-orchestrator | grep Environment

# Test systemctl access
sudo -u root systemctl status xmrig
```
