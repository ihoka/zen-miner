# Feature Specification: Simplify Installation and Update Scripts

**Status:** Draft
**Author:** Claude
**Date:** 2024-12-24
**Type:** Feature Enhancement

---

## Overview

Simplify the `host-daemon/install` and `bin/update-orchestrators-ssh` scripts by removing idempotency checks and always overwriting scripts, configuration files, and systemd service files when run. Both scripts will ensure services are restarted to apply changes immediately.

---

## Background/Problem Statement

The current installation and update scripts were designed with idempotency in mind - they check if steps are already completed and skip them to avoid redundant work. This creates several problems:

### Current Issues

1. **Complex State Management**: The orchestrator installer has 8 different steps that each check completion state via `completed?` methods, adding complexity and potential for stale state detection.

2. **Incomplete Updates**: The `bin/update-orchestrators-ssh` script only updates the orchestrator binary but doesn't update:
   - XMRig configuration files (`/etc/xmrig/config.json`)
   - Systemd service files (`xmrig.service`, `xmrig-orchestrator.service`)
   - This means environment variable changes (wallet, pool, worker ID) require manual intervention or SSH into each host.

3. **Unclear Behavior**: Users cannot easily "refresh" a host configuration by re-running the installer - it will skip most steps if files already exist, even if they're outdated.

4. **Incorrect XMRig Path**: Both installer and updater scripts assume XMRig binary should be at `/usr/local/bin/xmrig`, but the actual path is `/usr/bin/xmrig`. This causes unnecessary symlink creation and path confusion.
   - `daemon_installer.rb:11` - `XMRIG_SYMLINK = '/usr/local/bin/xmrig'` (wrong)
   - `orchestrator_updater.rb:260,262,267` - references to `/usr/local/bin/xmrig` (wrong)

4. **Service Restart Uncertainty**: While the systemd installer attempts to restart the orchestrator if it's running (systemd_installer.rb:120-157), this only happens during initial installation, not during updates.

### Real-World Scenario

When updating environment variables (e.g., changing MONERO_WALLET or POOL_URL):

1. User runs `bin/update-orchestrators-ssh` - only binary is updated
2. Config files remain unchanged with old values
3. User must manually SSH to each host and run installer again
4. Installer may skip config generation if file exists
5. User must manually restart services

This is operationally complex for a mining rig deployment where configurations need to be updated quickly across all hosts.

---

## Goals

- **Simplicity**: Remove all idempotency checks and state management from installer
- **Predictability**: Scripts always overwrite all files (scripts, configs, service files) on every run
- **Consistency**: Update script brings remote hosts to exact same state as local configuration
- **Operational Efficiency**: Single command updates all aspects of host configuration
- **Service Continuity**: Always restart services to apply changes immediately
- **Correct Paths**: Fix XMRig binary path from `/usr/local/bin/xmrig` to `/usr/bin/xmrig`

---

## Non-Goals

- Preserving backward compatibility with existing `completed?` idempotency pattern
- Adding rollback mechanisms (out of scope for this change)
- Handling service downtime during restart (acceptable for mining rig use case)
- Supporting partial updates (always full update)
- Maintaining update history or change tracking
- Creating additional symlinks (use actual XMRig path directly)

---

## Technical Dependencies

### Existing Dependencies
- Ruby 3.x (already in use)
- `concurrent-ruby` gem (already in use for parallel SSH execution)
- SSH access to remote hosts via `deploy` user
- Sudo privileges on remote hosts for systemd operations

### System Requirements
- Systemd on all managed hosts
- XMRig binary available in PATH
- Environment variables: `MONERO_WALLET`, `WORKER_ID`, `POOL_URL` (optional), `CPU_MAX_THREADS_HINT` (optional)

### No New Dependencies
This feature simplifies existing code and doesn't require additional libraries.

---

## Detailed Design

### Architecture Changes

#### 1. Installer Orchestrator Simplification

**Current Architecture** (host-daemon/lib/installer/orchestrator.rb:14-23):
```ruby
STEP_CLASSES = %w[
  PrerequisiteChecker    # Checks Ruby/XMRig exist
  UserManager            # Creates/validates xmrig user
  SudoConfigurator       # Configures sudoers
  DirectoryManager       # Creates directories
  ConfigGenerator        # Generates /etc/xmrig/config.json
  DaemonInstaller        # Installs orchestrator binary
  SystemdInstaller       # Installs systemd services
  LogrotateConfigurator  # Configures logrotate
].freeze
```

Each step has a `completed?` method that checks if work is needed (orchestrator.rb:48-51).

**New Architecture**:
- Remove all `completed?` methods from step classes
- Remove completion check logic from orchestrator (orchestrator.rb:48-51)
- Always execute all steps unconditionally
- Simplify BaseStep to remove state checking infrastructure

**Files to Modify**:
- `host-daemon/lib/installer/orchestrator.rb` - Remove lines 48-51 (completion check)
- `host-daemon/lib/installer/base_step.rb` - Remove `completed?` requirement
- All step classes - Remove `completed?` method implementations

#### 2. Update Script Enhancement

**Current Behavior** (lib/orchestrator_updater.rb:255-290):
- Only copies orchestrator binary
- Creates XMRig symlink at `/usr/local/bin/xmrig` (WRONG - should be `/usr/bin/xmrig`)
- Restarts xmrig-orchestrator service
- **Does NOT update**: Config files, systemd services, or environment variable changes

**New Behavior**:
- Execute full installation on each update
- Transfer all necessary files: orchestrator binary, service files, config sources
- Regenerate config from current environment variables
- Overwrite all systemd service files
- **Fix XMRig path**: Use `/usr/bin/xmrig` directly, remove symlink creation logic
- Restart both `xmrig-orchestrator` and `xmrig` services

**Implementation Approach**:

Instead of custom update commands in SSHExecutor, run the full installer remotely:

```ruby
def update_orchestrator
  if @dry_run
    return {
      success: true,
      output: "[DRY RUN] Would run full installation on #{@hostname}",
      error: ""
    }
  end

  # Transfer installation package (orchestrator binary + installer scripts)
  temp_dir = "#{@temp_prefix}-install"

  update_script = <<~BASH
    set -e

    # 1. Extract installation files to temp directory
    mkdir -p #{temp_dir}
    cd #{temp_dir}

    # 2. Run installer with current environment
    # Environment variables are passed through SSH session
    sudo -E ruby install

    # 3. Cleanup
    cd /
    rm -rf #{temp_dir}

    # 4. Verify both services are running
    sudo systemctl is-active xmrig-orchestrator
    sudo systemctl is-active xmrig
  BASH

  stdout, stderr, status = ssh(update_script)

  {
    success: status.success?,
    output: stdout,
    error: stderr
  }
end
```

#### 3. Service Restart Strategy

**Current**: Only restarts orchestrator if it was already running (systemd_installer.rb:120-157)

**New**: Always restart both services unconditionally

```ruby
def restart_services
  # Restart orchestrator service (controls mining operations)
  result = run_command('sudo', 'systemctl', 'restart', 'xmrig-orchestrator')
  return result if result.failure?

  logger.info "   ✓ Orchestrator restarted"

  # Restart xmrig service (actual mining process)
  # This may not be running if mining is stopped - that's OK
  result = run_command('sudo', 'systemctl', 'restart', 'xmrig')

  # Don't fail if xmrig isn't running (expected when mining is stopped)
  if result[:success]
    logger.info "   ✓ XMRig service restarted"
  else
    logger.info "   ℹ XMRig service not restarted (may not be running)"
  end

  # Verify orchestrator is running
  sleep(2)
  result = run_command('sudo', 'systemctl', 'is-active', '--quiet', 'xmrig-orchestrator')

  if result[:success]
    logger.info "   ✓ Services verified"
    Result.success("Services restarted")
  else
    Result.failure(
      "Orchestrator failed to start. Check logs: sudo journalctl -u xmrig-orchestrator -n 50"
    )
  end
end
```

### Code Structure and File Organization

```
host-daemon/
├── install                           # Entry point (unchanged)
├── xmrig-orchestrator               # Binary (unchanged)
├── xmrig.service                    # Service file (unchanged)
├── xmrig-orchestrator.service       # Service file (unchanged)
└── lib/installer/
    ├── orchestrator.rb              # MODIFIED: Remove completion checks
    ├── base_step.rb                 # MODIFIED: Remove completed? requirement
    ├── config_generator.rb          # MODIFIED: Remove completed?, always overwrite
    ├── daemon_installer.rb          # MODIFIED: Remove completed?, always overwrite
    ├── systemd_installer.rb         # MODIFIED: Remove completed?, always restart
    ├── logrotate_configurator.rb    # MODIFIED: Remove completed?
    ├── directory_manager.rb         # MODIFIED: Remove completed?
    ├── sudo_configurator.rb         # MODIFIED: Remove completed?
    ├── user_manager.rb              # MODIFIED: Remove completed?
    ├── prerequisite_checker.rb      # UNCHANGED: Still validates requirements
    └── result.rb                    # UNCHANGED

lib/
└── orchestrator_updater.rb          # MODIFIED: Transfer installer package, run full install

bin/
└── update-orchestrators-ssh         # UNCHANGED: Entry point
```

### Implementation Details

#### Phase 1: Installer Simplification

**Step 1: Modify BaseStep**
```ruby
# host-daemon/lib/installer/base_step.rb
module Installer
  class BaseStep
    attr_reader :logger, :options

    def initialize(logger:, **options)
      @logger = logger
      @options = options
    end

    # Description of what this step does
    def description
      raise NotImplementedError, "Subclass must implement #description"
    end

    # Execute the step
    # @return [Result] success or failure result
    def execute
      raise NotImplementedError, "Subclass must implement #execute"
    end

    # REMOVED: completed? method no longer needed

    # ... helper methods remain unchanged ...
  end
end
```

**Step 2: Modify Orchestrator**
```ruby
# host-daemon/lib/installer/orchestrator.rb
def execute
  logger.info "=========================================="
  logger.info "XMRig Orchestrator Installation"
  logger.info "=========================================="
  logger.info ""

  load_step_classes
  steps = instantiate_steps
  total_steps = steps.length

  steps.each_with_index do |step, index|
    step_number = index + 1
    description = step.description

    # REMOVED: Completion check - always execute
    logger.info "[#{step_number}/#{total_steps}] #{description}..."

    result = step.execute

    if result.success?
      logger.info "   ✓ #{result.message}"
      results << result
    else
      logger.error "   ✗ #{result.message}"
      results << result
      return false
    end
  end

  display_completion_message
  true
end
```

**Step 3: Update Each Step Class**

Remove `completed?` methods from:
- ConfigGenerator (config_generator.rb:65-67)
- DaemonInstaller (daemon_installer.rb:38-40)
- SystemdInstaller (systemd_installer.rb:41-47)
- DirectoryManager
- SudoConfigurator
- UserManager
- LogrotateConfigurator

**Step 4: Force Config Overwrite**
```ruby
# host-daemon/lib/installer/config_generator.rb
def write_config_file(config)
  json_content = JSON.pretty_generate(config)
  temp_file = "#{CONFIG_FILE}.tmp"

  # Always overwrite - remove any existing file first
  run_command('sudo', 'rm', '-f', CONFIG_FILE, temp_file)

  # Write new config
  result = run_command('sudo', 'bash', '-c', "cat > #{temp_file} <<'EOF'\n#{json_content}\nEOF")
  return Result.failure(...) unless result[:success]

  # Move to final location
  result = run_command('sudo', 'mv', temp_file, CONFIG_FILE)
  return Result.failure(...) unless result[:success]

  logger.info "   ✓ Config overwritten: #{CONFIG_FILE}"
  Result.success("Config file written successfully")
end
```

**Step 5: Always Restart Services**
```ruby
# host-daemon/lib/installer/systemd_installer.rb
def execute
  # Install service files
  SERVICES.each do |service_info|
    result = install_service_file(service_info)
    return result if result.failure?
  end

  # Reload systemd
  result = reload_systemd
  return result if result.failure?

  # Enable services
  SERVICES.each do |service_info|
    result = enable_service(service_info[:name])
    return result if result.failure?
  end

  # Always restart services (CHANGED from conditional restart)
  result = restart_services
  return result if result.failure?

  Result.success("Systemd services installed and enabled")
end

def restart_services
  # Restart orchestrator (always should be running)
  result = run_command('sudo', 'systemctl', 'restart', 'xmrig-orchestrator')
  return result if result.failure?

  logger.info "   ✓ Orchestrator restarted"

  # Restart xmrig if it's enabled (may not be running)
  run_command('sudo', 'systemctl', 'restart', 'xmrig')

  # Wait for startup
  sleep(2)

  # Verify orchestrator is running
  result = run_command('sudo', 'systemctl', 'is-active', '--quiet', 'xmrig-orchestrator')

  if result[:success]
    logger.info "   ✓ Services verified"
    Result.success("Services restarted")
  else
    Result.failure("Orchestrator failed to start. Check logs: sudo journalctl -u xmrig-orchestrator -n 50")
  end
end
```

#### Phase 2: Update Script Enhancement

**Current Update Package**: Only orchestrator binary

**New Update Package**: Full installer directory structure

**Step 1: Create Installation Package Transfer**

```ruby
# lib/orchestrator_updater.rb - SSHExecutor class

def copy_installation_package
  return true if @dry_run

  # Create remote temp directory
  stdout, stderr, status = ssh("mkdir -p #{@temp_dir}")
  return false unless status.success?

  # Transfer installation files
  files_to_transfer = [
    'host-daemon/install',
    'host-daemon/xmrig-orchestrator',
    'host-daemon/xmrig.service',
    'host-daemon/xmrig-orchestrator.service',
    'host-daemon/lib/installer/*.rb'
  ]

  files_to_transfer.each do |pattern|
    Dir.glob(pattern).each do |file|
      relative_path = file.sub('host-daemon/', '')
      remote_path = "#{@temp_dir}/#{relative_path}"

      # Create remote directory if needed
      remote_dir = File.dirname(remote_path)
      ssh("mkdir -p #{remote_dir}") if remote_dir != @temp_dir

      # Transfer file
      _, _, status = scp(file, remote_path)
      return false unless status.success?
    end
  end

  logger.info "   ✓ Installation package transferred"
  true
end
```

**Step 2: Execute Remote Installation**

```ruby
# lib/orchestrator_updater.rb - SSHExecutor class

def execute_installation(env_vars)
  return true if @dry_run

  # Build environment variable exports
  env_exports = env_vars.map { |k, v| "export #{k}=#{Shellwords.escape(v)}" }.join("\n")

  install_script = <<~BASH
    set -e

    # Set environment variables
    #{env_exports}

    # Navigate to installation directory
    cd #{@temp_dir}

    # Make installer executable
    chmod +x install

    # Run installer
    sudo -E ./install

    # Cleanup
    cd /
    rm -rf #{@temp_dir}

    # Verify services
    sudo systemctl is-active xmrig-orchestrator
  BASH

  stdout, stderr, status = ssh(install_script)

  {
    success: status.success?,
    output: stdout,
    error: stderr
  }
end
```

**Step 3: Environment Variable Propagation**

Environment variables must be passed from local machine to remote hosts:

```ruby
# lib/orchestrator_updater.rb - UpdateCoordinator class

def collect_environment_variables
  {
    'MONERO_WALLET' => ENV['MONERO_WALLET'],
    'WORKER_ID' => ENV['WORKER_ID'],
    'POOL_URL' => ENV.fetch('POOL_URL', 'pool.hashvault.pro:443'),
    'CPU_MAX_THREADS_HINT' => ENV.fetch('CPU_MAX_THREADS_HINT', '50')
  }.compact  # Remove nil values
end

def update_host(hostname)
  # ... existing code ...

  env_vars = collect_environment_variables

  # Validate required variables
  unless env_vars['MONERO_WALLET']
    puts "✗ #{hostname} ERROR: MONERO_WALLET not set"
    @results[:failed] << { host: hostname, reason: "MONERO_WALLET not set" }
    return
  end

  unless env_vars['WORKER_ID']
    # Use hostname as default worker ID
    env_vars['WORKER_ID'] = hostname
  end

  # Execute installation with environment
  result = executor.execute_installation(env_vars)

  # ... rest of update logic ...
end
```

### API Changes

**No Public API Changes**: These are internal scripts with no external API surface.

**CLI Changes**:
- `host-daemon/install` - Behavior change: always overwrites files (no visible CLI change)
- `bin/update-orchestrators-ssh` - Behavior change: transfers and runs full installer (no visible CLI change)

**Environment Variables** (existing, now properly propagated during updates):
- `MONERO_WALLET` (required)
- `WORKER_ID` (optional, defaults to hostname)
- `POOL_URL` (optional, defaults to pool.hashvault.pro:443)
- `CPU_MAX_THREADS_HINT` (optional, defaults to 50)

### Data Model Changes

**No Database Changes**: This project uses file-based configuration only.

**Configuration File Changes**:
- `/etc/xmrig/config.json` - Always regenerated from environment variables
- `/etc/systemd/system/xmrig.service` - Always overwritten from source
- `/etc/systemd/system/xmrig-orchestrator.service` - Always overwritten from source
- `/usr/local/bin/xmrig-orchestrator` - Always overwritten from source

---

## User Experience

### Local Installation

**Before** (with idempotency):
```bash
$ cd /path/to/zen-miner/host-daemon
$ ./install

[1/8] Checking prerequisites... ✓ Already completed
[2/8] Managing xmrig user... ✓ Already completed
[3/8] Configuring sudo access... ✓ Already completed
[4/8] Creating directories... ✓ Already completed
[5/8] Generating XMRig configuration... ✓ Already completed
[6/8] Installing orchestrator daemon... ✓ Already completed
[7/8] Installing systemd services... ✓ Already completed
[8/8] Configuring log rotation... ✓ Already completed
```

**After** (always execute):
```bash
$ cd /path/to/zen-miner/host-daemon
$ ./install

[1/8] Checking prerequisites...
   ✓ Ruby found: 3.2.0
   ✓ XMRig found: 6.21.0
[2/8] Managing xmrig user...
   ✓ User xmrig exists
[3/8] Configuring sudo access...
   ✓ Sudoers configuration updated
[4/8] Creating directories...
   ✓ Directories verified
[5/8] Generating XMRig configuration...
   ✓ Config overwritten: /etc/xmrig/config.json
[6/8] Installing orchestrator daemon...
   ✓ Orchestrator installed to /usr/local/bin/xmrig-orchestrator
[7/8] Installing systemd services...
   ✓ Service file copied: xmrig.service
   ✓ Service file copied: xmrig-orchestrator.service
   ✓ Systemd daemon reloaded
   ✓ Service enabled: xmrig.service
   ✓ Service enabled: xmrig-orchestrator.service
   ✓ Orchestrator restarted
   ✓ Services verified
[8/8] Configuring log rotation...
   ✓ Logrotate configured
```

### Remote Update Workflow

**Scenario**: Update wallet address and pool across all mining hosts

**Steps**:
1. Update `mise.toml` with new `MONERO_WALLET` and `POOL_URL`
2. Run update command:

```bash
$ export MONERO_WALLET="4ABC...new_wallet...xyz"
$ export POOL_URL="pool.hashvault.pro:443"
$ bin/update-orchestrators-ssh --yes

==========================================
XMRig Orchestrator Update (via SSH)
==========================================

Hosts to update:
  - mini-1
  - mini-2
  - mini-3

Source: /Users/user/zen-miner/host-daemon
Update method: Full installation via SSH

Running preflight checks...
  Checking source files... ✓
  Calculating checksums... ✓
  Checking SSH host keys... ✓

Deployment strategy: 3 parallel workers

========================================
Updating: mini-1
========================================
[14:23:45] Checking SSH connectivity... ✓
[14:23:46] Copying installation package... ✓
[14:23:47] Executing installation...
[1/8] Checking prerequisites... ✓
[2/8] Managing xmrig user... ✓
[3/8] Configuring sudo access... ✓
[4/8] Creating directories... ✓
[5/8] Generating XMRig configuration... ✓ Config overwritten
[6/8] Installing orchestrator daemon... ✓
[7/8] Installing systemd services... ✓ Services restarted
[8/8] Configuring log rotation... ✓

✓ mini-1 updated successfully (8.2s)

[Similar output for mini-2 and mini-3...]

==========================================
Update Summary
==========================================

Success: 3 host(s)
  ✓ mini-1
  ✓ mini-2
  ✓ mini-3

Total time: 24.5s
```

**What Changed**:
- All configuration files regenerated with new wallet/pool
- All systemd services restarted
- Mining continues with new configuration

---

## Testing Strategy

### Unit Tests

#### Test File Structure
```
test/
├── installer/
│   ├── orchestrator_test.rb          # UPDATED: Remove completion check tests
│   ├── config_generator_test.rb      # UPDATED: Add overwrite tests
│   ├── daemon_installer_test.rb      # UPDATED: Add overwrite tests
│   ├── systemd_installer_test.rb     # UPDATED: Add restart tests
│   └── ...
└── orchestrator_updater_test.rb      # UPDATED: Add installation package tests
```

#### Config Generator Tests

**Purpose**: Verify configuration always overwrites existing files

```ruby
# test/installer/config_generator_test.rb

class ConfigGeneratorTest < Minitest::Test
  def test_overwrites_existing_config
    # Purpose: Ensure config file is overwritten even if it exists
    # This can fail if file permissions prevent overwriting

    # Setup: Create existing config with old values
    create_fake_config(wallet: 'OLD_WALLET')

    # Execute: Run config generator with new values
    ENV['MONERO_WALLET'] = 'NEW_WALLET'
    result = ConfigGenerator.new(logger: logger).execute

    # Verify: Config contains new values
    assert result.success?
    config = JSON.parse(File.read('/etc/xmrig/config.json'))
    assert_equal 'NEW_WALLET', config['pools'][0]['user']
  end

  def test_config_generation_always_runs
    # Purpose: Verify config is regenerated every time, not skipped

    generator = ConfigGenerator.new(logger: logger)

    # Execute twice
    result1 = generator.execute
    result2 = generator.execute

    # Both should execute (not skip)
    assert result1.success?
    assert result2.success?

    # No "already completed" messages
    refute_includes logger.messages, /already completed/i
  end
end
```

#### Systemd Installer Tests

**Purpose**: Verify services are always restarted

```ruby
# test/installer/systemd_installer_test.rb

class SystemdInstallerTest < Minitest::Test
  def test_always_restarts_services
    # Purpose: Ensure services are restarted on every run
    # This can fail if systemd commands don't execute

    installer = SystemdInstaller.new(logger: logger)

    # Mock: Track systemd commands
    commands = []
    allow(installer).to receive(:run_command) do |*args|
      commands << args
      { success: true, stdout: '', stderr: '' }
    end

    # Execute
    installer.execute

    # Verify: restart commands were issued
    assert_includes commands, ['sudo', 'systemctl', 'restart', 'xmrig-orchestrator']
    assert_includes commands, ['sudo', 'systemctl', 'restart', 'xmrig']
  end

  def test_fails_if_orchestrator_doesnt_start
    # Purpose: Installation should fail if orchestrator can't start
    # This is a meaningful failure that reveals real issues

    installer = SystemdInstaller.new(logger: logger)

    # Mock: restart succeeds but service is not active
    allow(installer).to receive(:run_command) do |*args|
      if args.include?('is-active')
        { success: false, stdout: 'inactive', stderr: '' }
      else
        { success: true, stdout: '', stderr: '' }
      end
    end

    # Execute
    result = installer.execute

    # Verify: fails with helpful message
    assert result.failure?
    assert_match /failed to start/i, result.message
    assert_match /journalctl/i, result.message
  end
end
```

#### Orchestrator Tests

**Purpose**: Verify completion checks are removed

```ruby
# test/installer/orchestrator_test.rb

class OrchestratorTest < Minitest::Test
  def test_always_executes_all_steps
    # Purpose: Verify all steps execute even if files exist

    orchestrator = Orchestrator.new(logger: logger)

    # Setup: Create all files as if already installed
    setup_existing_installation

    # Track which steps executed
    executed_steps = []

    # Mock step execution
    orchestrator.stub(:instantiate_steps, mock_steps(executed_steps)) do
      result = orchestrator.execute
      assert result
    end

    # Verify: all 8 steps executed
    assert_equal 8, executed_steps.length
    assert_includes executed_steps, 'ConfigGenerator'
    assert_includes executed_steps, 'DaemonInstaller'
    assert_includes executed_steps, 'SystemdInstaller'
  end

  def test_no_completion_skip_messages
    # Purpose: Verify no "already completed" messages appear

    orchestrator = Orchestrator.new(logger: logger)
    orchestrator.execute

    # No skip messages
    refute_match /already completed/i, logger.to_s
    refute_match /skipped/i, logger.to_s
  end
end
```

### Integration Tests

#### Full Installation Test

```ruby
# test/integration/full_installation_test.rb

class FullInstallationTest < Minitest::Test
  def test_repeated_installation_overwrites_all_files
    # Purpose: Verify running installer twice overwrites everything

    # First installation with wallet A
    ENV['MONERO_WALLET'] = 'WALLET_A'
    ENV['WORKER_ID'] = 'worker-a'

    run_installer

    # Verify initial state
    config = read_config
    assert_equal 'WALLET_A', config['pools'][0]['user']
    assert_equal 'worker-a', config['pools'][0]['pass']

    # Second installation with wallet B
    ENV['MONERO_WALLET'] = 'WALLET_B'
    ENV['WORKER_ID'] = 'worker-b'

    run_installer

    # Verify overwritten state
    config = read_config
    assert_equal 'WALLET_B', config['pools'][0]['user']
    assert_equal 'worker-b', config['pools'][0]['pass']
  end
end
```

#### Update Script Test

```ruby
# test/integration/update_orchestrators_test.rb

class UpdateOrchestratorsTest < Minitest::Test
  def test_update_transfers_full_installer
    # Purpose: Verify update script transfers all necessary files

    updater = SSHExecutor.new('test-host')

    # Mock SCP to track transfers
    transferred_files = []
    allow(updater).to receive(:scp) do |source, dest|
      transferred_files << source
      [nil, nil, double(success?: true)]
    end

    # Execute
    updater.copy_installation_package

    # Verify: all installer files transferred
    assert_includes transferred_files, 'host-daemon/install'
    assert_includes transferred_files, 'host-daemon/xmrig-orchestrator'
    assert_includes transferred_files, 'host-daemon/xmrig.service'
    assert_includes transferred_files, 'host-daemon/xmrig-orchestrator.service'

    # Verify: all installer library files transferred
    installer_libs = transferred_files.select { |f| f.include?('lib/installer') }
    assert installer_libs.length >= 8, "Expected at least 8 installer library files"
  end

  def test_update_propagates_environment_variables
    # Purpose: Verify environment variables are passed to remote installer

    ENV['MONERO_WALLET'] = 'TEST_WALLET'
    ENV['POOL_URL'] = 'test.pool.com:3333'

    updater = SSHExecutor.new('test-host')

    # Mock SSH to capture command
    ssh_command = nil
    allow(updater).to receive(:ssh) do |cmd|
      ssh_command = cmd
      ['', '', double(success?: true)]
    end

    # Execute
    env_vars = {
      'MONERO_WALLET' => 'TEST_WALLET',
      'POOL_URL' => 'test.pool.com:3333'
    }
    updater.execute_installation(env_vars)

    # Verify: environment exports in command
    assert_match /export MONERO_WALLET=.*TEST_WALLET/, ssh_command
    assert_match /export POOL_URL=.*test\.pool\.com:3333/, ssh_command
  end
end
```

### E2E Tests

Not applicable - these are operational scripts for internal infrastructure deployment.

### Testing Documentation

Each test includes:
- **Purpose comment**: Explains why the test exists and what it validates
- **Meaningful assertions**: Tests can fail to reveal real issues
- **Edge case coverage**: Tests scenarios that could actually break

---

## Performance Considerations

### Impact Analysis

**Before (with idempotency)**:
- First installation: ~10-15 seconds (all steps execute)
- Subsequent installations: ~2-3 seconds (most steps skipped)

**After (always execute)**:
- Every installation: ~10-15 seconds (all steps execute)

**Trade-off**: Acceptable for mining rig operational workflow where:
- Installations are infrequent (initial setup + occasional updates)
- Correctness and predictability matter more than speed
- 10-second installation time is negligible compared to mining runtime

### Remote Update Performance

**Current**: Serial updates, ~5-10 seconds per host (binary only)

**New**: Parallel updates, ~15-20 seconds per host (full installation)

**Mitigation**: Already using concurrent-ruby with thread pool (orchestrator_updater.rb:458-480)
- Default: 10 parallel workers
- 10 hosts update in ~20 seconds vs. 200+ seconds serially

**Network Bandwidth**:
- Current: ~2MB per host (binary only)
- New: ~5MB per host (full package including Ruby scripts)
- Impact: Minimal for typical broadband connections

### Service Downtime

**Orchestrator Service**:
- Restart time: ~2 seconds
- Impact: Mining commands delayed during restart
- Mitigation: None needed - brief delay acceptable

**XMRig Service**:
- Restart time: ~5 seconds (includes XMRig startup)
- Impact: Mining paused during restart
- Mitigation: Acceptable for configuration updates

**Estimated Downtime**: ~7 seconds per host during update

---

## Security Considerations

### Security Improvements

1. **Config Validation Always Runs**: By removing idempotency, configuration validation (wallet format, pool whitelist) runs every time, reducing risk of stale invalid configs

2. **Service File Verification**: Systemd service files are always overwritten from source, preventing tampering

3. **No Stale State**: Eliminates risk of partial updates leaving system in inconsistent state

### Security Safeguards

**Existing (maintained)**:
- Wallet address format validation (config_generator.rb:75-78)
- Pool URL whitelist (config_generator.rb:14-20)
- Hostname validation for SSH (orchestrator_updater.rb:35-56)
- SSH host key verification (orchestrator_updater.rb:58-148)
- Sudo command restrictions via sudoers file

**No New Security Risks**: Simplification doesn't introduce new attack vectors

### File Permissions

All operations maintain secure permissions:
- Config files: root-owned (created via sudo)
- Systemd services: root-owned in `/etc/systemd/system`
- Orchestrator binary: root-owned in `/usr/local/bin`

---

## Documentation

### Files to Update

1. **README.md** - Update "Installation" section to clarify behavior:
   ```markdown
   ## Installation on Remote Hosts

   The installer always overwrites all files and restarts services when run.
   This ensures your configuration is fully up-to-date.

   To update configurations across all hosts:
   1. Update environment variables in mise.toml
   2. Run: bin/update-orchestrators-ssh --yes
   ```

2. **bin/update-orchestrators-ssh** - Update header comments:
   ```ruby
   # Updates XMRig orchestrator daemon on all hosts via direct SSH
   #
   # This script performs a FULL INSTALLATION on each host:
   # - Transfers installer package
   # - Regenerates configuration from environment variables
   # - Overwrites orchestrator binary and systemd services
   # - Restarts all services to apply changes
   #
   # Environment variables are propagated from local machine to remote hosts:
   # - MONERO_WALLET (required)
   # - WORKER_ID (optional, defaults to hostname)
   # - POOL_URL (optional, defaults to pool.hashvault.pro:443)
   # - CPU_MAX_THREADS_HINT (optional, defaults to 50)
   ```

3. **host-daemon/install** - Update header comments:
   ```ruby
   # XMRig Orchestrator Installation Script
   #
   # Installs orchestrator daemon and systemd services.
   # This script ALWAYS overwrites all files and restarts services.
   #
   # Prerequisites: Ruby and XMRig must be installed and in PATH
   #
   # Environment variables:
   # - MONERO_WALLET (required): Destination wallet for mining rewards
   # - WORKER_ID (optional): Worker identifier (defaults to hostname)
   # - POOL_URL (optional): Mining pool URL (defaults to pool.hashvault.pro:443)
   # - CPU_MAX_THREADS_HINT (optional): CPU thread limit percentage (defaults to 50)
   ```

### New Documentation

Create `docs/INSTALLATION.md` with detailed explanation:
- When to run the installer
- How environment variables are used
- What files are modified
- Service restart behavior
- Troubleshooting common issues

---

## Implementation Phases

### Phase 1: Installer Simplification (Core MVP)

**Scope**: Remove idempotency checks from installer

**Tasks**:

1. Modify BaseStep to remove `completed?` requirement
2. Update Orchestrator to remove completion checks
3. Remove `completed?` methods from all step classes:
   - ConfigGenerator
   - DaemonInstaller
   - SystemdInstaller
   - DirectoryManager
   - SudoConfigurator
   - UserManager
   - LogrotateConfigurator
4. **Fix XMRig path bug in DaemonInstaller**:
   - Change `XMRIG_SYMLINK = '/usr/local/bin/xmrig'` to `'/usr/bin/xmrig'`
   - Remove symlink creation logic (xmrig is already at correct path)
   - Simplify to just verify xmrig exists in PATH
5. **Fix XMRig path in orchestrator_updater.rb**:
   - Remove symlink creation code (lines 258-268)
   - Just verify xmrig is in PATH
6. Update SystemdInstaller to always restart services
7. Update ConfigGenerator to always overwrite config
8. Update unit tests to remove completion check tests
9. Add tests for overwrite behavior

**Acceptance Criteria**:

- Installer runs all steps every time
- No "already completed" messages in output
- Config files always overwritten
- Services always restarted
- XMRig path correctly references `/usr/bin/xmrig` (not `/usr/local/bin/xmrig`)
- No unnecessary symlink creation
- All tests pass

**Deliverables**:

- Modified installer code with correct XMRig paths
- Updated tests
- Updated header comments in install script

### Phase 2: Update Script Enhancement

**Scope**: Make update script transfer full installer and run it remotely

**Tasks**:
1. Modify SSHExecutor to transfer installation package
2. Add environment variable collection in UpdateCoordinator
3. Implement remote installation execution
4. Update SSH script to pass environment variables
5. Add integration tests for package transfer
6. Add integration tests for environment propagation
7. Test with actual remote hosts

**Acceptance Criteria**:
- Update script transfers all installer files
- Environment variables propagate to remote hosts
- Remote installation executes successfully
- All services restart on remote hosts
- Config files updated with new environment values

**Deliverables**:
- Modified orchestrator_updater.rb
- Integration tests
- Updated CLI help text

### Phase 3: Documentation and Polish

**Scope**: Update documentation and improve error messages

**Tasks**:
1. Update README.md installation section
2. Update script header comments
3. Create docs/INSTALLATION.md
4. Improve error messages for common failures
5. Add verbose logging option for debugging
6. Update CLAUDE.md with new behavior

**Acceptance Criteria**:
- All documentation accurate
- Error messages helpful and actionable
- Users can diagnose common issues

**Deliverables**:
- Updated documentation
- Improved error handling
- Final testing on production hosts

---

## Open Questions

### Q1: Should we preserve any idempotency for prerequisite checks?

**Question**: PrerequisiteChecker validates Ruby and XMRig exist. Should this step still support early-exit if prerequisites fail, or always continue and fail later?

**Options**:
A. Keep prerequisite failure as early-exit (current behavior)
B. Remove early-exit, let later steps fail naturally

**Recommendation**: Keep early-exit (Option A). Failing fast on missing prerequisites provides better error messages than cryptic failures in later steps.

**Decision Required**: Before Phase 1 implementation

### Q2: How should we handle hosts with different environment variable requirements?

**Question**: If different hosts need different configurations (e.g., different worker IDs), how should we support this?

**Options**:
A. Use hostname as worker ID automatically (one config fits all)
B. Support per-host environment variable overrides in deploy.yml
C. Run update script multiple times with different --host flags and different ENV values

**Current Behavior**: Option C (manual per-host updates)

**Recommendation**: Start with Option A for simplicity. Most mining rigs use hostname as worker ID. Revisit if per-host configs become necessary.

**Decision Required**: Before Phase 2 implementation

### Q3: Should update script support rollback?

**Question**: If an update fails, should we preserve the previous binary/config for rollback?

**Options**:
A. No rollback support (current behavior)
B. Backup previous files before overwriting
C. Full versioned deployments with rollback capability

**Recommendation**: Option A for now. Mining rig deployments are low-risk and can be manually fixed via SSH if needed. Adding rollback adds significant complexity.

**Decision Required**: Before Phase 2 implementation

### Q4: Should we add a --force flag to make overwrite behavior optional?

**Question**: Should we keep idempotency as default and require --force to overwrite, or always overwrite as the new default?

**Options**:
A. Always overwrite (no flag needed) - simpler, more predictable
B. Add --force flag to trigger overwrite - preserves backward compatibility

**Recommendation**: Option A (always overwrite). The whole point of this feature is simplification. Adding a flag adds complexity back in.

**Decision Required**: Before Phase 1 implementation (affects user experience)

---

## References

### Related Files

- `host-daemon/install` - Installation entry point
- `host-daemon/lib/installer/orchestrator.rb` - Installation orchestrator
- `host-daemon/lib/installer/*.rb` - Individual installation steps
- `lib/orchestrator_updater.rb` - Remote update script
- `bin/update-orchestrators-ssh` - Update script entry point

### External Documentation

- [Systemd Service Management](https://www.freedesktop.org/software/systemd/man/systemctl.html)
- [XMRig Configuration](https://xmrig.com/docs/miner/config)
- [Ruby Open3 Module](https://ruby-doc.org/stdlib-3.0.0/libdoc/open3/rdoc/Open3.html) - Used for SSH execution

### Design Decisions

- **Simplicity over optimization**: Accepting slower re-installation for operational predictability
- **All-or-nothing updates**: No partial updates to avoid inconsistent state
- **Parallel deployment**: Using concurrent-ruby for scalability across many hosts

### Architectural Patterns

- **Step Pattern**: Each installation task is a discrete step class (BaseStep)
- **Result Object**: Standardized success/failure results with data payloads
- **SSH Executor**: Encapsulates all SSH operations for a single host
- **Update Coordinator**: Orchestrates parallel updates across multiple hosts
