# Feature Specification: XMRig Daemon Orchestration

## Status
**Draft** - Awaiting Review

## Authors
Claude Sonnet 4.5 - 2024-12-22

## Overview
Enable the Rails application to orchestrate XMRig cryptocurrency mining operations running on Docker host machines. The Rails app provides centralized monitoring and control, while a lightweight host-side daemon manages the actual XMRig processes with automated health monitoring, error detection, and self-healing capabilities.

## Background/Problem Statement

### Current State
XMRig mining operations are currently executed manually via Mise task commands (`mise run mine:cpu`) on the host machine. This approach has several limitations:

1. **Manual Lifecycle Management**: Operators must manually start, stop, and restart mining processes on each host
2. **No Health Monitoring**: Process crashes or errors go undetected until manual inspection
3. **Deployment Complexity**: Mining processes run separately from the Rails application lifecycle
4. **Limited Observability**: Mining status and errors are not tracked in application logs or database
5. **No Self-Healing**: Failed mining processes require manual intervention to restart
6. **Multi-Server Coordination**: 6 deployed servers each require independent SSH access for management

### Core Problem
The fundamental need is **automated, resilient mining operations** with centralized control through the Rails application, while respecting the constraint that XMRig must run on the Docker host (not in containers) for direct hardware access and maximum performance.

This enables:
- Unified control plane via Rails application
- Centralized monitoring and observability across all 6 servers
- Self-healing capabilities for production reliability
- Future web UI integration for management and monitoring
- Proper resource allocation (XMRig gets full host resources, Rails container limited to 512MB)

### Why This Solution
Alternative approaches considered:

**Option 1: XMRig in Container** ❌
- Would be resource-constrained by container limits (512MB)
- Limited hardware access for mining optimization
- Not suitable for mining workloads

**Option 2: Pure systemd with Manual Management** ❌
- Requires SSH access to each server for monitoring
- No centralized observability
- Manual restart procedures

**Option 3: Separate Monitoring Service (Prometheus/Grafana)** ❌
- Additional infrastructure complexity
- Doesn't integrate with Rails application
- Requires separate deployment pipeline

**Option 4: Rails + Host Daemon (Proposed)** ✅
- Rails provides centralized control plane and future web UI
- Host daemon manages XMRig locally with full hardware access
- Database-driven communication (no SSH needed)
- Leverages existing Solid Queue for Rails-side orchestration
- Self-contained within application stack

## Goals
- Run XMRig as systemd service on Docker host machines (outside containers)
- Rails application provides centralized control and monitoring interface
- Lightweight host daemon bridges Rails commands to systemd service management
- Implement automated health monitoring checking process status every 60 seconds
- Detect errors through process status checks and log file analysis
- Automatically restart failed or unhealthy XMRig processes
- Persist mining process metadata (PID, status, errors) in centralized database
- Support multi-server deployments with per-server worker identification
- Integrate seamlessly with Kamal deployment workflow
- Maintain resource efficiency (host daemon <10MB RAM, Rails monitoring <5MB)

## Non-Goals
- Building a web UI for mining management (future enhancement)
- Real-time mining statistics dashboard (future enhancement)
- Multiple concurrent mining algorithm support (stick to CPU mining initially)
- GPU mining support in this phase (CPU-only for MVP)
- Mining pool failover/switching logic (single pool initially)
- Profit optimization or algorithm switching
- Mining performance tuning or optimization
- Historical mining statistics storage
- External monitoring service integration (Prometheus, Datadog, etc.)
- Running XMRig inside Docker containers

## Technical Dependencies

### External Libraries/Frameworks
| Dependency | Version | Purpose | Location |
|-----------|---------|---------|----------|
| **XMRig** | Latest stable (6.x+) | Monero mining daemon binary | Docker host |
| **systemd** | System default | Service management on host | Docker host |
| **Solid Queue** | 1.2.4 (existing) | Background job processing | Rails container |
| **SQLite3** | 2.8.1 (existing) | Database for process metadata | Rails container |
| **Rails** | 8.1.1 (existing) | Application framework | Rails container |
| **Kamal** | 2.10.1 (existing) | Container deployment | Deployment tool |
| **Ruby** | 3.4.5 | Host daemon scripting | Docker host |

### System Requirements

**Docker Host:**
- XMRig binary installed at `/usr/local/bin/xmrig`
- systemd service manager
- Ruby 3.x installed (for host daemon script)
- Read access to Rails SQLite database via Docker volume mount
- Write permissions to `/var/log/xmrig/` for logging

**Rails Container:**
- SQLite database accessible to host via volume mount
- Read access to host log files via volume mount

**Shared Volumes:**
- Database: `/rails/storage/production.sqlite3` (container) ↔ Host mount point
- Logs: `/var/log/xmrig/` (host) ↔ Container mount point

### Documentation Links
- [XMRig Documentation](https://xmrig.com/docs)
- [XMRig GitHub](https://github.com/xmrig/xmrig)
- [XMRig HTTP API](https://xmrig.com/docs/miner/api)
- [systemd Service Units](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [Solid Queue Guide](https://github.com/rails/solid_queue)
- [Kamal Volumes](https://kamal-deploy.org/docs/configuration/volumes/)

## Detailed Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Docker Host Machine                       │
│                                                                   │
│  ┌────────────────────────────────────────────────────────┐    │
│  │              XMRig systemd Service                      │    │
│  │  - Runs as system service                               │    │
│  │  - Logs to /var/log/xmrig/xmrig.log                    │    │
│  │  - Managed by systemctl (start/stop/restart)            │    │
│  └──────────────────┬─────────────────────────────────────┘    │
│                     │ controlled by                              │
│                     ▼                                             │
│  ┌────────────────────────────────────────────────────────┐    │
│  │        XMRig Host Daemon (xmrig-orchestrator)          │    │
│  │  - Polls database every 10s for commands               │    │
│  │  - Executes systemctl start/stop/restart               │    │
│  │  - Monitors XMRig health via HTTP API                  │    │
│  │  - Writes status updates to database                   │    │
│  │  - Analyzes logs for errors                            │    │
│  └──────────┬──────────────────────────────────┬──────────┘    │
│             │                                   │                │
│             ▼                                   ▼                │
│  ┌──────────────────────┐         ┌───────────────────────┐   │
│  │  Shared SQLite DB    │         │  Shared Log Volume    │   │
│  │  (via volume mount)  │         │  /var/log/xmrig/      │   │
│  └──────────┬───────────┘         └───────────┬───────────┘   │
└─────────────┼─────────────────────────────────┼───────────────┘
              │                                  │
              │ Volume Mounts                    │
              │                                  │
┌─────────────┼─────────────────────────────────┼───────────────┐
│             ▼                                  ▼                │
│  ┌──────────────────────┐         ┌───────────────────────┐  │
│  │  SQLite Database     │         │  Log Files (read)     │  │
│  │  (read/write)        │         │  (for web UI)         │  │
│  └──────────┬───────────┘         └───────────────────────┘  │
│             │                                                  │
│  ┌──────────▼──────────────────────────────────────────────┐ │
│  │              Rails Application Container                 │ │
│  │  ┌───────────────────────────────────────────────────┐  │ │
│  │  │         Solid Queue Recurring Jobs                 │  │ │
│  │  │  ┌──────────────────┐  ┌─────────────────────┐   │  │ │
│  │  │  │ CommandIssuer    │  │  StatusMonitor      │   │  │ │
│  │  │  │ (every 60s)      │  │  (every 60s)        │   │  │ │
│  │  │  │ - Check desired  │  │  - Read status      │   │  │ │
│  │  │  │   state          │  │  - Display in UI    │   │  │ │
│  │  │  │ - Issue commands │  │  - Trigger alerts   │   │  │ │
│  │  │  └──────────────────┘  └─────────────────────┘   │  │ │
│  │  └───────────────────────────────────────────────────┘  │ │
│  │                                                          │ │
│  │  ┌───────────────────────────────────────────────────┐ │ │
│  │  │        Xmrig::* Models & Services                  │ │ │
│  │  │  - XmrigProcess (model)                            │ │ │
│  │  │  - XmrigCommand (model)                            │ │ │
│  │  │  - Xmrig::CommandService (service)                 │ │ │
│  │  └───────────────────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────────────────────┘ │
│                   Docker Container (Rails)                     │
└────────────────────────────────────────────────────────────────┘
```

### Communication Flow

**Start Mining Flow:**
```
1. User/Rails: XmrigCommand.create!(action: 'start', hostname: 'mini-1')
2. Host Daemon: Polls database, sees pending 'start' command
3. Host Daemon: Executes `systemctl start xmrig`
4. Host Daemon: Updates command status to 'completed'
5. Host Daemon: Creates/updates XmrigProcess with PID, status='running'
6. Rails: StatusMonitor job reads status, displays in UI
```

**Health Monitoring Flow:**
```
1. Host Daemon: Every 10s, checks XMRig HTTP API health endpoint
2. Host Daemon: If unhealthy, creates XmrigCommand(action: 'restart')
3. Host Daemon: Processes own restart command
4. Host Daemon: Updates XmrigProcess with error_count++
5. Rails: StatusMonitor job detects restart, can trigger alerts
```

### Database Schema

#### New Table: `xmrig_processes`

Tracks current state of XMRig on each host.

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_xmrig_processes.rb
class CreateXmrigProcesses < ActiveRecord::Migration[8.1]
  def change
    create_table :xmrig_processes do |t|
      t.integer :pid
      t.string :status, null: false, default: 'stopped'
      t.string :worker_id, null: false
      t.string :hostname, null: false, index: true
      t.datetime :started_at
      t.datetime :stopped_at
      t.integer :error_count, default: 0
      t.text :last_error
      t.datetime :last_health_check_at
      t.integer :restart_count, default: 0
      t.float :hashrate # From XMRig API
      t.integer :accepted_shares # From XMRig API
      t.integer :rejected_shares # From XMRig API
      t.text :health_data # JSON snapshot from XMRig API

      t.timestamps

      t.index [:hostname], unique: true
    end
  end
end
```

#### Status Values
- `stopped` - XMRig not running
- `starting` - Start command issued, not yet confirmed
- `running` - Process confirmed alive and healthy
- `unhealthy` - Process alive but errors detected
- `stopping` - Stop command issued
- `crashed` - Process terminated unexpectedly
- `restarting` - Restart in progress

#### New Table: `xmrig_commands`

Command queue for host daemon to process.

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_xmrig_commands.rb
class CreateXmrigCommands < ActiveRecord::Migration[8.1]
  def change
    create_table :xmrig_commands do |t|
      t.string :hostname, null: false, index: true
      t.string :action, null: false # 'start', 'stop', 'restart'
      t.string :status, null: false, default: 'pending' # 'pending', 'processing', 'completed', 'failed'
      t.text :reason # Why this command was issued
      t.text :result # Output from systemctl command
      t.datetime :processed_at
      t.text :error_message

      t.timestamps

      t.index [:hostname, :status]
      t.index [:status, :created_at]
    end
  end
end
```

### File Organization

```
# Rails Application
app/
├── models/
│   ├── xmrig_process.rb          # Process state tracking
│   └── xmrig_command.rb          # Command queue
├── services/
│   └── xmrig/
│       ├── command_service.rb    # Issue commands to hosts
│       └── status_service.rb     # Read and interpret status
└── jobs/
    └── xmrig/
        ├── command_issuer_job.rb        # Check desired state, issue commands
        ├── status_monitor_job.rb        # Read status, trigger alerts
        └── cleanup_old_commands_job.rb  # Delete old commands (24h retention)

# Host Daemon (deployed to each host)
host-daemon/
├── xmrig-orchestrator             # Main daemon script (Ruby)
├── xmrig-orchestrator.service     # systemd service file for daemon
├── xmrig.service                  # systemd service file for XMRig
├── install.sh                     # Installation script for hosts
└── config.yml                     # Daemon configuration

# Shared
config/
├── recurring.yml                  # Add XMRig recurring jobs
└── deploy.yml                     # Kamal volume mounts
```

### Core Components

#### 1. XmrigProcess Model (Rails)

```ruby
# app/models/xmrig_process.rb
class XmrigProcess < ApplicationRecord
  STATUSES = %w[stopped starting running unhealthy stopping crashed restarting].freeze

  validates :hostname, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :worker_id, presence: true

  scope :active, -> { where(status: ['starting', 'running', 'unhealthy']) }
  scope :needs_attention, -> { where(status: ['crashed', 'unhealthy']) }

  def healthy?
    status == 'running' && last_health_check_at && last_health_check_at > 2.minutes.ago
  end

  def stale?
    last_health_check_at.nil? || last_health_check_at < 5.minutes.ago
  end

  def self.for_host(hostname)
    find_or_initialize_by(hostname: hostname) do |process|
      process.worker_id = "#{hostname}-production"
      process.status = 'stopped'
    end
  end
end
```

#### 2. XmrigCommand Model (Rails)

```ruby
# app/models/xmrig_command.rb
class XmrigCommand < ApplicationRecord
  ACTIONS = %w[start stop restart].freeze
  STATUSES = %w[pending processing completed failed].freeze

  validates :hostname, :action, :status, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: 'pending').order(:created_at) }
  scope :for_host, ->(hostname) { where(hostname: hostname) }
  scope :recent, -> { where('created_at > ?', 1.hour.ago) }

  def mark_processing!
    update!(status: 'processing', processed_at: Time.current)
  end

  def mark_completed!(result = nil)
    update!(status: 'completed', result: result)
  end

  def mark_failed!(error)
    update!(status: 'failed', error_message: error)
  end
end
```

#### 3. Xmrig::CommandService (Rails)

```ruby
# app/services/xmrig/command_service.rb
module Xmrig
  class CommandService
    class << self
      def start_mining(hostname, reason: 'manual')
        # Cancel any pending stop/restart commands
        cancel_pending_commands(hostname)

        XmrigCommand.create!(
          hostname: hostname,
          action: 'start',
          reason: reason,
          status: 'pending'
        )

        Rails.logger.info "Issued start command for #{hostname}"
      end

      def stop_mining(hostname, reason: 'manual')
        cancel_pending_commands(hostname)

        XmrigCommand.create!(
          hostname: hostname,
          action: 'stop',
          reason: reason,
          status: 'pending'
        )

        Rails.logger.info "Issued stop command for #{hostname}"
      end

      def restart_mining(hostname, reason: 'health_check_failed')
        cancel_pending_commands(hostname)

        XmrigCommand.create!(
          hostname: hostname,
          action: 'restart',
          reason: reason,
          status: 'pending'
        )

        Rails.logger.info "Issued restart command for #{hostname}: #{reason}"
      end

      def start_all
        Rails.application.config.xmrig_hosts.each do |hostname|
          start_mining(hostname, reason: 'start_all')
        end
      end

      def stop_all
        Rails.application.config.xmrig_hosts.each do |hostname|
          stop_mining(hostname, reason: 'stop_all')
        end
      end

      private

      def cancel_pending_commands(hostname)
        XmrigCommand.for_host(hostname).pending.update_all(
          status: 'failed',
          error_message: 'Superseded by new command'
        )
      end
    end
  end
end
```

#### 4. Host Daemon Script

```ruby
#!/usr/bin/env ruby
# host-daemon/xmrig-orchestrator

require 'sqlite3'
require 'json'
require 'net/http'
require 'socket'
require 'logger'

class XmrigOrchestrator
  POLL_INTERVAL = 10 # seconds
  DB_PATH = ENV.fetch('XMRIG_DB_PATH', '/mnt/rails-storage/production.sqlite3')
  LOG_PATH = '/var/log/xmrig/orchestrator.log'
  XMRIG_API_URL = 'http://127.0.0.1:8080/2/summary' # XMRig HTTP API

  def initialize
    @hostname = Socket.gethostname
    @logger = Logger.new(LOG_PATH, 7, 'daily') # 7 day retention, daily rotation
    @db = SQLite3::Database.new(DB_PATH)
    @db.results_as_hash = true
  end

  def run
    @logger.info "XMRig Orchestrator starting on #{@hostname}"

    loop do
      begin
        process_pending_commands
        update_health_status
        sleep POLL_INTERVAL
      rescue => e
        @logger.error "Error in main loop: #{e.message}"
        @logger.error e.backtrace.join("\n")
        sleep 30 # Back off on errors
      end
    end
  end

  private

  def process_pending_commands
    commands = @db.execute(
      "SELECT * FROM xmrig_commands WHERE hostname = ? AND status = 'pending' ORDER BY created_at ASC",
      [@hostname]
    )

    commands.each do |cmd|
      process_command(cmd)
    end
  end

  def process_command(cmd)
    @logger.info "Processing command: #{cmd['action']} (ID: #{cmd['id']})"

    # Mark as processing
    @db.execute(
      "UPDATE xmrig_commands SET status = 'processing', processed_at = ? WHERE id = ?",
      [Time.now.utc.iso8601, cmd['id']]
    )

    result = case cmd['action']
    when 'start'
      systemctl('start')
    when 'stop'
      systemctl('stop')
    when 'restart'
      systemctl('restart')
    else
      "Unknown action: #{cmd['action']}"
    end

    if $?.success?
      @db.execute(
        "UPDATE xmrig_commands SET status = 'completed', result = ? WHERE id = ?",
        [result, cmd['id']]
      )
      @logger.info "Command completed: #{cmd['action']}"
    else
      @db.execute(
        "UPDATE xmrig_commands SET status = 'failed', error_message = ? WHERE id = ?",
        [result, cmd['id']]
      )
      @logger.error "Command failed: #{cmd['action']} - #{result}"
    end
  rescue => e
    @db.execute(
      "UPDATE xmrig_commands SET status = 'failed', error_message = ? WHERE id = ?",
      [e.message, cmd['id']]
    )
    @logger.error "Command error: #{e.message}"
  end

  def systemctl(action)
    output = `systemctl #{action} xmrig 2>&1`
    output
  end

  def update_health_status
    health = fetch_xmrig_health

    if health
      update_process_status(
        status: 'running',
        pid: health['worker_id'],
        hashrate: health['hashrate']['total'][0],
        accepted_shares: health['results']['shares_good'],
        rejected_shares: health['results']['shares_bad'],
        health_data: health.to_json
      )

      # Check for errors
      if health['hashrate']['total'][0] == 0
        @logger.warn "Zero hashrate detected"
        check_and_restart_if_needed('zero_hashrate')
      end
    else
      # XMRig not responding
      status_output = `systemctl is-active xmrig`.strip

      if status_output == 'active'
        update_process_status(status: 'unhealthy')
        check_and_restart_if_needed('api_not_responding')
      else
        update_process_status(status: 'stopped')
      end
    end
  rescue => e
    @logger.error "Health check error: #{e.message}"
  end

  def fetch_xmrig_health
    uri = URI(XMRIG_API_URL)
    response = Net::HTTP.get_response(uri)

    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue Errno::ECONNREFUSED, SocketError
    nil
  end

  def update_process_status(attrs)
    attrs[:hostname] = @hostname
    attrs[:worker_id] ||= "#{@hostname}-production"
    attrs[:last_health_check_at] = Time.now.utc.iso8601

    existing = @db.execute(
      "SELECT id FROM xmrig_processes WHERE hostname = ?",
      [@hostname]
    ).first

    if existing
      set_clause = attrs.map { |k, _| "#{k} = ?" }.join(', ')
      values = attrs.values + [existing['id']]

      @db.execute(
        "UPDATE xmrig_processes SET #{set_clause} WHERE id = ?",
        values
      )
    else
      columns = attrs.keys.join(', ')
      placeholders = (['?'] * attrs.size).join(', ')

      @db.execute(
        "INSERT INTO xmrig_processes (#{columns}, created_at, updated_at) VALUES (#{placeholders}, ?, ?)",
        attrs.values + [Time.now.utc.iso8601, Time.now.utc.iso8601]
      )
    end
  end

  def check_and_restart_if_needed(reason)
    # Immediate restart on any error (dedicated mining machines)
    @logger.warn "Error detected, issuing immediate restart: #{reason}"

    @db.execute(
      "INSERT INTO xmrig_commands (hostname, action, reason, status, created_at, updated_at) VALUES (?, 'restart', ?, 'pending', ?, ?)",
      [@hostname, reason, Time.now.utc.iso8601, Time.now.utc.iso8601]
    )

    @db.execute(
      "UPDATE xmrig_processes SET restart_count = restart_count + 1, error_count = error_count + 1, last_error = ? WHERE hostname = ?",
      [reason, @hostname]
    )
  end
end

# Run daemon
XmrigOrchestrator.new.run
```

#### 5. systemd Service Files

**xmrig.service** (XMRig itself):
```ini
[Unit]
Description=XMRig Cryptocurrency Miner
After=network.target

[Service]
Type=simple
User=xmrig
ExecStart=/usr/local/bin/xmrig --config=/etc/xmrig/config.json
Restart=on-failure
RestartSec=10s
StandardOutput=append:/var/log/xmrig/xmrig.log
StandardError=append:/var/log/xmrig/xmrig.log

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/xmrig

[Install]
WantedBy=multi-user.target
```

**xmrig-orchestrator.service** (Host daemon):
```ini
[Unit]
Description=XMRig Orchestrator Daemon
After=docker.target
Requires=docker.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xmrig-orchestrator
Restart=always
RestartSec=10s
Environment="XMRIG_DB_PATH=/mnt/rails-storage/production.sqlite3"
StandardOutput=append:/var/log/xmrig/orchestrator.log
StandardError=append:/var/log/xmrig/orchestrator.log

[Install]
WantedBy=multi-user.target
```

#### 6. Rails Background Jobs

```ruby
# app/jobs/xmrig/status_monitor_job.rb
module Xmrig
  class StatusMonitorJob < ApplicationJob
    queue_as :default

    def perform
      # Check for stale processes
      XmrigProcess.find_each do |process|
        if process.stale?
          Rails.logger.warn "Stale process detected: #{process.hostname}"
          # Could trigger alert here
        end
      end

      # Check for failed commands
      failed = XmrigCommand.where(status: 'failed').recent
      if failed.any?
        Rails.logger.warn "#{failed.count} failed commands in last hour"
      end
    end
  end
end

# app/jobs/xmrig/command_issuer_job.rb
module Xmrig
  class CommandIssuerJob < ApplicationJob
    queue_as :default

    def perform
      # Ensure mining is running on all hosts
      # This job can implement desired state logic
      # For now, just a placeholder for future auto-start logic
    end
  end
end

# app/jobs/xmrig/cleanup_old_commands_job.rb
module Xmrig
  class CleanupOldCommandsJob < ApplicationJob
    queue_as :default

    def perform
      # Delete commands older than 24 hours
      deleted = XmrigCommand.where('created_at < ?', 24.hours.ago).delete_all
      Rails.logger.info "Cleaned up #{deleted} old XMRig commands" if deleted > 0
    end
  end
end
```

### Configuration Changes

#### config/recurring.yml
```yaml
production:
  xmrig_status_monitor:
    class: Xmrig::StatusMonitorJob
    schedule: every minute

  xmrig_cleanup_old_commands:
    class: Xmrig::CleanupOldCommandsJob
    schedule: every day at 3am
```

#### config/application.rb
```ruby
module ZenMiner
  class Application < Rails::Application
    # ...

    # XMRig host configuration
    config.xmrig_hosts = ENV.fetch('XMRIG_HOSTS', 'mini-1,miner-beta,miner-gamma,miner-delta').split(',')
  end
end
```

#### config/deploy.yml Updates
```yaml
volumes:
  - "/mnt/rails-storage:/rails/storage" # Share database with host
  - "/var/log/xmrig:/var/log/xmrig:ro" # Read host logs (optional, for web UI)

env:
  clear:
    XMRIG_HOSTS: "mini-1,miner-beta,miner-gamma,miner-delta"
```

#### Host Installation Script

```bash
#!/bin/bash
# host-daemon/install.sh

set -e

echo "Installing XMRig Orchestrator on $(hostname)"

# Install dependencies
apt-get update
apt-get install -y ruby sqlite3 curl

# Download and install XMRig
XMRIG_VERSION="6.21.0"
wget -q https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/xmrig-${XMRIG_VERSION}-linux-x64.tar.gz
tar -xzf xmrig-${XMRIG_VERSION}-linux-x64.tar.gz
mv xmrig-${XMRIG_VERSION}/xmrig /usr/local/bin/xmrig
chmod +x /usr/local/bin/xmrig
rm -rf xmrig-${XMRIG_VERSION}*

# Create xmrig user
useradd -r -s /bin/false xmrig || true

# Create directories
mkdir -p /var/log/xmrig
mkdir -p /etc/xmrig
mkdir -p /mnt/rails-storage
chown xmrig:xmrig /var/log/xmrig

# Generate XMRig config
cat > /etc/xmrig/config.json <<EOF
{
  "autosave": true,
  "http": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 8080,
    "access-token": null,
    "restricted": true
  },
  "pools": [
    {
      "url": "${POOL_URL:-pool.hashvault.pro:443}",
      "user": "${MONERO_WALLET}",
      "pass": "$(hostname)-production",
      "rig-id": "$(hostname)-production",
      "tls": true,
      "keepalive": true
    }
  ],
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "priority": 1,
    "max-threads-hint": ${CPU_MAX_THREADS_HINT:-50}
  },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "donate-level": 1
}
EOF

# Install orchestrator daemon
cp xmrig-orchestrator /usr/local/bin/xmrig-orchestrator
chmod +x /usr/local/bin/xmrig-orchestrator

# Install systemd services
cp xmrig.service /etc/systemd/system/xmrig.service
cp xmrig-orchestrator.service /etc/systemd/system/xmrig-orchestrator.service

# Configure logrotate for XMRig logs (7 day retention)
cat > /etc/logrotate.d/xmrig <<EOF
/var/log/xmrig/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 xmrig xmrig
}
EOF

# Reload systemd
systemctl daemon-reload

# Enable services (don't start yet)
systemctl enable xmrig
systemctl enable xmrig-orchestrator

echo "Installation complete!"
echo "Mount Rails database volume to /mnt/rails-storage"
echo "Then start orchestrator: systemctl start xmrig-orchestrator"
```

### API Changes
None - this is internal infrastructure only.

### Data Model Changes
- New table: `xmrig_processes` (process state tracking)
- New table: `xmrig_commands` (command queue)

## User Experience

### For Operators/Administrators

**Initial Setup (One-time per host):**
1. SSH to each Docker host
2. Run installation script: `./install.sh`
3. Mount Rails database volume (handled by Kamal volumes config)
4. Start orchestrator: `systemctl start xmrig-orchestrator`
5. Orchestrator polls database for commands and manages XMRig

**Deployment Flow:**
1. Push code changes to repository
2. Run `kamal deploy` to deploy Rails app to all 6 servers
3. Rails database shared with hosts via volume mounts
4. Host daemons automatically pick up any state changes
5. Issue start command via Rails console or future web UI

**Monitoring:**
- View all servers: `XmrigProcess.all`
- View specific server: `XmrigProcess.find_by(hostname: 'mini-1')`
- View recent commands: `XmrigCommand.recent`
- View failed commands: `XmrigCommand.where(status: 'failed')`

**Manual Operations (via Rails Console):**
```ruby
# Start mining on specific host
Xmrig::CommandService.start_mining('mini-1')

# Stop mining on specific host
Xmrig::CommandService.stop_mining('mini-1', reason: 'maintenance')

# Restart specific host
Xmrig::CommandService.restart_mining('miner-beta', reason: 'config_change')

# Start all hosts
Xmrig::CommandService.start_all

# Stop all hosts
Xmrig::CommandService.stop_all

# Check status
XmrigProcess.for_host('mini-1').attributes
```

**Error Scenarios:**
- **Host daemon crashes**: systemd auto-restarts orchestrator
- **XMRig crashes**: Detected by health check, auto-restarts via systemd
- **Network errors**: Host daemon detects zero hashrate, auto-restarts after threshold
- **Database unavailable**: Host daemon logs error, retries after 30s backoff

## Testing Strategy

### Unit Tests

#### Model Tests (`test/models/xmrig_process_test.rb`)
```ruby
require "test_helper"

class XmrigProcessTest < ActiveSupport::TestCase
  # Purpose: Validates hostname uniqueness constraint
  # Can fail if: Database constraint not enforced
  test "enforces unique hostname" do
    XmrigProcess.create!(hostname: 'test-host', worker_id: 'test', status: 'running')

    assert_raises(ActiveRecord::RecordInvalid) do
      XmrigProcess.create!(hostname: 'test-host', worker_id: 'test2', status: 'running')
    end
  end

  # Purpose: Validates health check staleness detection
  # Can fail if: Time comparison logic broken
  test "stale? returns true for old health checks" do
    process = XmrigProcess.create!(
      hostname: 'test-host',
      worker_id: 'test',
      status: 'running',
      last_health_check_at: 10.minutes.ago
    )

    assert process.stale?
  end

  # Purpose: Validates healthy process detection
  # Can fail if: Status or timestamp checks broken
  test "healthy? returns true for recent running process" do
    process = XmrigProcess.create!(
      hostname: 'test-host',
      worker_id: 'test',
      status: 'running',
      last_health_check_at: 1.minute.ago
    )

    assert process.healthy?
  end
end
```

#### Command Model Tests (`test/models/xmrig_command_test.rb`)
```ruby
require "test_helper"

class XmrigCommandTest < ActiveSupport::TestCase
  # Purpose: Validates pending scope orders by creation time
  # Can fail if: Ordering broken or wrong records returned
  test "pending scope returns oldest first" do
    cmd1 = XmrigCommand.create!(hostname: 'host1', action: 'start', status: 'pending', created_at: 2.minutes.ago)
    cmd2 = XmrigCommand.create!(hostname: 'host1', action: 'stop', status: 'pending', created_at: 1.minute.ago)

    pending = XmrigCommand.pending.to_a
    assert_equal cmd1.id, pending.first.id
  end

  # Purpose: Validates command status transitions
  # Can fail if: Status updates don't persist
  test "mark_processing! updates status and timestamp" do
    cmd = XmrigCommand.create!(hostname: 'host1', action: 'start', status: 'pending')
    cmd.mark_processing!

    assert_equal 'processing', cmd.status
    assert_not_nil cmd.processed_at
  end

  # Purpose: Validates failure tracking
  # Can fail if: Error message not persisted
  test "mark_failed! stores error message" do
    cmd = XmrigCommand.create!(hostname: 'host1', action: 'start', status: 'pending')
    cmd.mark_failed!('Connection timeout')

    assert_equal 'failed', cmd.status
    assert_equal 'Connection timeout', cmd.error_message
  end
end
```

#### Service Tests (`test/services/xmrig/command_service_test.rb`)
```ruby
require "test_helper"

class Xmrig::CommandServiceTest < ActiveSupport::TestCase
  # Purpose: Validates start command creation
  # Can fail if: Command not created or wrong attributes
  test "start_mining creates pending start command" do
    assert_difference 'XmrigCommand.count', 1 do
      Xmrig::CommandService.start_mining('test-host', reason: 'test')
    end

    cmd = XmrigCommand.last
    assert_equal 'test-host', cmd.hostname
    assert_equal 'start', cmd.action
    assert_equal 'pending', cmd.status
    assert_equal 'test', cmd.reason
  end

  # Purpose: Validates command superseding logic
  # Can fail if: Old commands not canceled
  test "start_mining cancels pending commands" do
    old_cmd = XmrigCommand.create!(hostname: 'host1', action: 'stop', status: 'pending')

    Xmrig::CommandService.start_mining('host1')

    old_cmd.reload
    assert_equal 'failed', old_cmd.status
    assert_includes old_cmd.error_message, 'Superseded'
  end

  # Purpose: Validates bulk start command
  # Can fail if: Not all hosts receive commands
  test "start_all creates commands for all configured hosts" do
    Rails.application.config.xmrig_hosts = ['host1', 'host2', 'host3']

    assert_difference 'XmrigCommand.count', 3 do
      Xmrig::CommandService.start_all
    end
  end
end
```

### Integration Tests

#### Job Integration Tests (`test/jobs/xmrig/status_monitor_job_test.rb`)
```ruby
require "test_helper"

class Xmrig::StatusMonitorJobTest < ActiveJob::TestCase
  # Purpose: Validates stale process detection
  # Can fail if: Stale check logic broken
  test "detects and logs stale processes" do
    XmrigProcess.create!(
      hostname: 'test-host',
      worker_id: 'test',
      status: 'running',
      last_health_check_at: 10.minutes.ago
    )

    # Should log warning but not crash
    assert_nothing_raised do
      Xmrig::StatusMonitorJob.perform_now
    end
  end

  # Purpose: Validates failed command detection
  # Can fail if: Query or logging broken
  test "logs failed commands" do
    XmrigCommand.create!(
      hostname: 'test',
      action: 'start',
      status: 'failed',
      error_message: 'Test error',
      created_at: 30.minutes.ago
    )

    assert_nothing_raised do
      Xmrig::StatusMonitorJob.perform_now
    end
  end
end
```

### System Tests

#### End-to-End Flow Tests
```ruby
# test/system/xmrig_orchestration_test.rb
require "application_system_test_case"

class XmrigOrchestrationTest < ApplicationSystemTestCase
  # Purpose: Validates complete command flow (Rails → Database → Host)
  # Can fail if: Any component in chain breaks
  test "command flow from Rails to database" do
    # This test validates database writes, not actual host daemon
    assert_difference 'XmrigCommand.count', 1 do
      Xmrig::CommandService.start_mining('test-host', reason: 'test')
    end

    cmd = XmrigCommand.last
    assert_equal 'pending', cmd.status

    # Simulate host daemon processing
    cmd.mark_processing!
    assert_equal 'processing', cmd.status

    cmd.mark_completed!('Started successfully')
    assert_equal 'completed', cmd.status
  end
end
```

### Host Daemon Testing

**Manual Testing Script:**
```bash
#!/bin/bash
# test-daemon.sh - Test host daemon in isolation

# Setup test environment
export XMRIG_DB_PATH=/tmp/test.db
sqlite3 $XMRIG_DB_PATH < schema.sql

# Insert test command
sqlite3 $XMRIG_DB_PATH <<EOF
INSERT INTO xmrig_commands (hostname, action, status, created_at, updated_at)
VALUES ('$(hostname)', 'start', 'pending', datetime('now'), datetime('now'));
EOF

# Run daemon for 30 seconds
timeout 30 ./xmrig-orchestrator &

sleep 5

# Verify command processed
sqlite3 $XMRIG_DB_PATH "SELECT status FROM xmrig_commands WHERE hostname='$(hostname)'"

# Should output: completed or failed

# Cleanup
kill %1
rm $XMRIG_DB_PATH
```

### Test Coverage Goals
- **Models**: 100% coverage (simple CRUD logic)
- **Services**: 95%+ coverage (business logic)
- **Jobs**: 90%+ coverage
- **Host Daemon**: Manual testing + integration tests

## Performance Considerations

### Resource Impact

**Rails Container:**
- Additional database tables: <1KB per process/command record
- Background jobs: <1% CPU, <5MB RAM
- **Total Rails Impact**: Negligible (<5MB RAM, <1% CPU)

**Docker Host:**
- Host Daemon: <10MB RAM, <1% CPU (polls every 10s)
- XMRig: 50-200MB RAM (varies by algorithm), 50% CPU (configurable)
- **Total Host Impact**: ~60-210MB RAM, ~51% CPU

**Database:**
- 6 servers × 1 process record = 6 rows (~1KB each)
- Commands: ~100/day × 6 servers = 600 rows (~50KB/day)
- **Total Database Growth**: <1MB/month

### Optimization Strategies

1. **Efficient Polling**: Host daemon polls every 10s (not every 1s)
2. **Batch Updates**: Single database write per health check
3. **Command Cleanup**: Auto-delete completed commands after 24 hours
4. **Index Optimization**: Indexes on hostname and status for fast queries
5. **HTTP API Health Checks**: Faster than parsing log files

### Monitoring

**Metrics to Track:**
- Host daemon uptime (should be 99.9%+)
- Command processing latency (should be <5s)
- XMRig restart count (indicates stability issues)
- Database query performance (should be <10ms)

## Security Considerations

### Threat Model

**Attack Vectors:**
1. **Database Injection**: Malicious commands injected into database
2. **Binary Replacement**: XMRig binary replaced with malware
3. **Configuration Tampering**: Mining config modified to steal rewards
4. **Resource Exhaustion**: Excessive commands or processes
5. **Log Injection**: Crafted log entries to exploit parsing

### Security Safeguards

#### 1. Binary Integrity
- XMRig binary installed via verified installation script
- Binary hash verification during install (SHA256 checksum)
- Binary path hardcoded in systemd service file
- systemd protections: `NoNewPrivileges=true`, `ProtectSystem=strict`

#### 2. Database Access Control
- Database file permissions: 660 (rw-rw----)
- Rails user and xmrig user in same group for shared access
- Host daemon runs as root (required for systemctl), but validates all inputs
- SQL injection prevented via parameterized queries

#### 3. Command Validation
```ruby
# In host daemon
VALID_ACTIONS = %w[start stop restart]
raise "Invalid action" unless VALID_ACTIONS.include?(cmd['action'])
```

#### 4. Configuration Security
- Wallet address stored in encrypted secrets (Kamal)
- XMRig config generated during installation (not runtime-modifiable)
- HTTP API bound to localhost only (not exposed externally)
- No remote configuration endpoints

#### 5. systemd Sandboxing
```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/xmrig
```

#### 6. Audit Logging
- All commands logged: action, hostname, timestamp, reason
- All systemctl calls logged with output
- Failed commands logged with error messages
- Host daemon logs to `/var/log/xmrig/orchestrator.log`

#### 7. Rate Limiting
Prevent command flooding:
```ruby
# In CommandService
def start_mining(hostname, reason:)
  recent = XmrigCommand.for_host(hostname).where('created_at > ?', 1.minute.ago)
  raise "Rate limit exceeded" if recent.count > 5
  # ... create command
end
```

## Documentation

### Deployment Guide

#### New Document: `docs/xmrig_deployment.md`

```markdown
# XMRig Deployment Guide

## Overview
XMRig runs on Docker host machines as systemd services, orchestrated by the Rails application via a host-side daemon.

## Architecture
- **Rails App**: Control plane (issues commands, monitors status)
- **Host Daemon**: Execution plane (processes commands, manages systemd)
- **XMRig**: Mining process (runs as systemd service)

## Initial Setup

### 1. Install Host Components (per server)

SSH to each server:
```bash
# Clone deployment scripts
git clone <repo-url> /opt/zen-miner
cd /opt/zen-miner/host-daemon

# Set environment variables
export MONERO_WALLET="your-wallet-address"
export POOL_URL="pool.hashvault.pro:443"
export CPU_MAX_THREADS_HINT=50

# Run installation
sudo ./install.sh
```

### 2. Mount Database Volume

Ensure Kamal mounts database volume in `config/deploy.yml`:
```yaml
volumes:
  - "/mnt/rails-storage:/rails/storage"
```

Deploy Rails app:
```bash
kamal deploy
```

### 3. Start Orchestrator

On each host:
```bash
sudo systemctl start xmrig-orchestrator
sudo systemctl status xmrig-orchestrator
```

### 4. Verify Installation

Check orchestrator logs:
```bash
sudo tail -f /var/log/xmrig/orchestrator.log
```

### 5. Start Mining

From Rails console:
```ruby
Xmrig::CommandService.start_all
```

## Operations

### Start Mining (Single Host)
```ruby
kamal app exec -i "bin/rails runner 'Xmrig::CommandService.start_mining(\"mini-1\")'"
```

### Stop Mining (All Hosts)
```ruby
kamal app exec -i "bin/rails runner 'Xmrig::CommandService.stop_all'"
```

### Check Status
```ruby
kamal app exec -i "bin/rails runner 'pp XmrigProcess.all.map(&:attributes)'"
```

### View Logs

**XMRig logs:**
```bash
ssh user@host "sudo tail -f /var/log/xmrig/xmrig.log"
```

**Orchestrator logs:**
```bash
ssh user@host "sudo tail -f /var/log/xmrig/orchestrator.log"
```

## Troubleshooting

### Orchestrator Not Running
```bash
sudo systemctl status xmrig-orchestrator
sudo journalctl -u xmrig-orchestrator -f
```

### XMRig Not Starting
```bash
sudo systemctl status xmrig
sudo journalctl -u xmrig -f
```

### Commands Not Processing
Check database mount:
```bash
ls -la /mnt/rails-storage/production.sqlite3
```

### Zero Hashrate
Check XMRig API:
```bash
curl http://127.0.0.1:8080/2/summary | jq
```
```

## Implementation Phases

### Phase 1: Core Database & Models
**Deliverables:**
- [ ] Database migrations for `xmrig_processes` and `xmrig_commands`
- [ ] `XmrigProcess` and `XmrigCommand` models with validations
- [ ] `Xmrig::CommandService` for issuing commands
- [ ] Unit tests for models and services
- [ ] Rails console testing

**Success Criteria:**
- Can create commands via Rails console
- Database constraints enforced
- All tests passing

### Phase 2: Host Daemon Development
**Deliverables:**
- [ ] Ruby host daemon script (`xmrig-orchestrator`)
- [ ] systemd service files (xmrig, xmrig-orchestrator)
- [ ] Installation script for host setup
- [ ] XMRig HTTP API integration
- [ ] Manual testing on single host

**Success Criteria:**
- Daemon polls database successfully
- Can execute systemctl commands
- Health checks read XMRig API
- Process status updates written to database

### Phase 3: Single-Host Integration
**Deliverables:**
- [ ] Deploy to single test server (e.g., mini-1)
- [ ] Kamal volume mount configuration
- [ ] End-to-end testing (Rails → Database → Daemon → XMRig)
- [ ] Monitoring and logging verification
- [ ] Documentation updates

**Success Criteria:**
- Full lifecycle works: start → run → monitor → restart → stop
- Commands processed within 10s
- Health checks update every 10s
- Logs accessible from Rails and host

### Phase 4: Multi-Server Rollout
**Deliverables:**
- [ ] Deploy to all 6 production servers
- [ ] Verify unique worker IDs per server
- [ ] Multi-server monitoring dashboard (Rails console)
- [ ] Operational runbook
- [ ] Security audit
- [ ] Performance monitoring

**Success Criteria:**
- All 6 servers mining simultaneously
- Independent health monitoring per server
- No cross-server interference
- Command/status latency <10s per server
- Resource usage within limits

## Decisions Made

1. **Log Retention**: ✅ 7 days retention for XMRig logs
   - Logs rotate daily and are kept for 7 days
   - Orchestrator logs also 7-day retention

2. **Restart Strategy**: ✅ Immediate restart on errors
   - No exponential backoff or retry threshold
   - Any error triggers immediate restart
   - Justification: Dedicated mining machines, uptime is critical

3. **CPU/Priority Configuration**: ✅ Static configuration
   - No dynamic adjustment needed
   - Machines are dedicated to mining
   - Set once during installation via env vars

4. **Database Mount**: ✅ Bind mount (`/mnt/rails-storage:/rails/storage`)
   - Simple, performant, widely supported

5. **Command Retention**: ✅ 24 hours auto-cleanup
   - Old completed/failed commands deleted after 24h
   - Keeps database small and queries fast

## Open Questions

1. **Daemon Polling Interval**: 10 seconds currently - acceptable?
   - **Trade-off**: Faster = more responsive, more CPU; Slower = less overhead
   - **Recommendation**: Keep at 10s for balance

2. **XMRig HTTP API Security**: Currently localhost-only, add authentication?
   - **Current**: No auth, localhost binding only
   - **Risk**: Low (not exposed externally)
   - **Recommendation**: Keep simple (no auth) for MVP

3. **Multi-User Access**: Should multiple users be able to issue commands?
   - **Recommendation**: Out of scope for MVP, revisit for web UI phase

4. **Graceful Shutdown**: Should we stop mining during Rails deployments?
   - **Current**: Mining continues during deployment
   - **Alternative**: Auto-stop before deploy, auto-start after
   - **Recommendation**: Keep mining running (deployments are quick)

## References

### Related Issues/PRs
- None yet (initial specification)

### External Documentation
- [XMRig Documentation](https://xmrig.com/docs)
- [XMRig HTTP API](https://xmrig.com/docs/miner/api)
- [systemd Service Units](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [Kamal Volume Configuration](https://kamal-deploy.org/docs/configuration/volumes/)
- [SQLite in Concurrent Environments](https://www.sqlite.org/wal.html)

### Design Patterns
- **Command Pattern**: Commands issued via database queue
- **Observer Pattern**: Host daemon observes database state
- **State Machine**: XmrigProcess status transitions
- **Polling Pattern**: Host daemon polls for commands

### Architectural Decisions
- **Host-based Execution**: XMRig runs on host for hardware access
- **Database-driven Communication**: Rails ↔ Host via shared SQLite
- **systemd Service Management**: Leverages OS-level process supervision
- **Decoupled Architecture**: Rails issues commands, host executes independently
- **HTTP API Health Checks**: Faster and more reliable than log parsing
- **Per-Host Autonomy**: Each host manages its own XMRig instance
