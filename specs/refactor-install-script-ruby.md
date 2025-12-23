# Specification: Refactor install.sh to Modular Ruby Installer

## Overview

Replace the 312-line `host-daemon/install.sh` bash script with a highly modular, testable Ruby installer following the bundler/inline pattern established by `xmrig-orchestrator`.

### Goals

1. **Modularity**: One class per installation step, independently testable
2. **Idempotency**: Safe to run multiple times, skips completed steps
3. **Testability**: Full unit and integration test coverage using Minitest
4. **Standalone**: Uses bundler/inline, no Rails dependency
5. **Replace install.sh**: Complete replacement, remove bash version

### User Requirements

- Standalone Ruby script using bundler/inline pattern
- Highly modular with separate classes per step
- Maximum testability with unit tests for each component
- Idempotent - safe to run multiple times
- Keep simple - no dry-run or rollback initially

---

## Architecture

### File Structure

```
host-daemon/
├── install                          # Main installer (executable)
├── lib/installer/                   # Installer modules
│   ├── result.rb                    # Result object for step tracking
│   ├── base_step.rb                 # Base class for all steps
│   ├── orchestrator.rb              # Main orchestrator
│   ├── prerequisite_checker.rb      # Step 1: Prerequisites
│   ├── user_manager.rb              # Step 2-3: Users
│   ├── sudo_configurator.rb         # Step 3c: Sudo config
│   ├── directory_manager.rb         # Step 4: Directories
│   ├── config_generator.rb          # Step 5: XMRig config
│   ├── daemon_installer.rb          # Step 6: Daemon
│   ├── systemd_installer.rb         # Step 7: Services
│   └── logrotate_configurator.rb    # Step 8: Logrotate
└── xmrig-orchestrator               # Existing (unchanged)

test/installer/
├── test_helper.rb                   # Test utilities
├── prerequisite_checker_test.rb
├── user_manager_test.rb
├── sudo_configurator_test.rb
├── directory_manager_test.rb
├── config_generator_test.rb
├── daemon_installer_test.rb
├── systemd_installer_test.rb
├── logrotate_configurator_test.rb
├── orchestrator_test.rb
└── integration_test.rb              # Full flow test
```

### Core Design Patterns

**1. Result Object Pattern**
- Each step returns `Result.success(message, data: {})` or `Result.failure(message, data: {})`
- Provides consistent interface for success/failure tracking
- Includes optional data payload for context

**2. Base Step Class**
- All steps inherit from `BaseStep`
- Required methods: `execute` (returns Result), `completed?` (returns boolean)
- Helper methods: `run_command`, `command_exists?`, `user_exists?`, `file_exists?`
- Automatic step description generation

**3. Orchestrator Pattern**
- Sequences steps in defined order
- Checks `completed?` before executing each step (idempotency)
- Stops on first failure
- Logs progress with numbered steps

---

## Module Specifications

### 1. Result Object (`lib/installer/result.rb`)

```ruby
module Installer
  class Result
    attr_reader :success, :message, :data

    def initialize(success:, message:, data: {})
      @success = success
      @message = message
      @data = data
    end

    def success? = @success
    def failure? = !@success

    def self.success(message, data: {})
      new(success: true, message: message, data: data)
    end

    def self.failure(message, data: {})
      new(success: false, message: message, data: data)
    end
  end
end
```

### 2. Base Step (`lib/installer/base_step.rb`)

**Responsibilities:**
- Provide common interface for all steps
- Helper methods for system commands
- Automatic description generation

**Interface:**
```ruby
module Installer
  class BaseStep
    attr_reader :logger, :options

    def initialize(logger:, **options)
      @logger = logger
      @options = options
    end

    def execute
      raise NotImplementedError
    end

    def completed?
      false
    end

    def description
      self.class.name.split('::').last.gsub(/([A-Z])/, ' \1').strip
    end

    protected

    def run_command(*cmd)
      # Use Open3.capture3 for shell injection safety
    end

    def command_exists?(command)
      system("which #{command} > /dev/null 2>&1")
    end

    def user_exists?(username)
      system("id #{username} > /dev/null 2>&1")
    end

    def file_exists?(path)
      File.exist?(path)
    end
  end
end
```

### 3. PrerequisiteChecker (`lib/installer/prerequisite_checker.rb`)

**Responsibilities:**
- Verify sudo access
- Check required commands (sudo, ruby, xmrig)
- Check bundler availability (install if needed)
- Validate environment variables (MONERO_WALLET, WORKER_ID)
- Validate Monero wallet format

**Constants:**
```ruby
REQUIRED_COMMANDS = %w[sudo ruby xmrig]
REQUIRED_ENV_VARS = %w[MONERO_WALLET WORKER_ID]
MONERO_WALLET_REGEX = /^[48][0-9A-Za-z]{94}$|^4[0-9A-Za-z]{105}$/
```

**Idempotency:** Always runs checks (completed? returns false)

### 4. UserManager (`lib/installer/user_manager.rb`)

**Responsibilities:**
- Create system users: `xmrig`, `xmrig-orchestrator`
- Create `deploy` group if needed
- Add `xmrig-orchestrator` to `deploy` group

**Constants:**
```ruby
USERS = [
  { name: 'xmrig', description: 'XMRig service user' },
  { name: 'xmrig-orchestrator', description: 'Orchestrator service user' }
]
```

**Idempotency:** Checks if users exist and are in correct groups

### 5. SudoConfigurator (`lib/installer/sudo_configurator.rb`)

**Responsibilities:**
- Create `/etc/sudoers.d/xmrig-orchestrator`
- Configure NOPASSWD for systemctl commands
- Validate sudoers syntax with `visudo -c`

**Constants:**
```ruby
SUDOERS_FILE = '/etc/sudoers.d/xmrig-orchestrator'
SUDOERS_CONTENT = <<~SUDOERS
  # Allow xmrig-orchestrator to manage xmrig service without password
  xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl start xmrig
  xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl stop xmrig
  xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl restart xmrig
  xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl is-active xmrig
  xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl status xmrig
SUDOERS
```

**Idempotency:** Checks if file exists with correct permissions (0440)

### 6. DirectoryManager (`lib/installer/directory_manager.rb`)

**Responsibilities:**
- Create required directories with correct ownership/permissions
- Create required files (log files)

**Constants:**
```ruby
DIRECTORIES = [
  { path: '/var/log/xmrig', owner: 'xmrig', group: 'xmrig', mode: '0755' },
  { path: '/etc/xmrig', owner: 'root', group: 'root', mode: '0755' },
  { path: '/var/lib/xmrig-orchestrator/gems', owner: 'xmrig-orchestrator', group: 'xmrig-orchestrator', mode: '0755' },
  { path: '/mnt/rails-storage', owner: '1000', group: 'deploy', mode: '0775' }
]

FILES = [
  { path: '/var/log/xmrig/orchestrator.log', owner: 'xmrig-orchestrator', group: 'xmrig-orchestrator', mode: '0644' }
]
```

**Idempotency:** Checks if directories and files exist

### 7. ConfigGenerator (`lib/installer/config_generator.rb`)

**Responsibilities:**
- Generate `/etc/xmrig/config.json` from environment variables
- Support optional POOL_URL and CPU_MAX_THREADS_HINT

**Environment Variables:**
```ruby
MONERO_WALLET (required)
WORKER_ID (required)
POOL_URL (optional, default: pool.hashvault.pro:443)
CPU_MAX_THREADS_HINT (optional, default: 50)
```

**Config Structure:**
```json
{
  "autosave": true,
  "http": { "enabled": true, "host": "127.0.0.1", "port": 8080 },
  "pools": [{ "url": "...", "user": "WALLET", "pass": "WORKER_ID", "tls": true }],
  "cpu": { "enabled": true, "max-threads-hint": 50 },
  "donate-level": 1
}
```

**Idempotency:** Checks if config file exists

### 8. DaemonInstaller (`lib/installer/daemon_installer.rb`)

**Responsibilities:**
- Detect XMRig binary location
- Create symlink `/usr/local/bin/xmrig` if needed
- Install orchestrator daemon to `/usr/local/bin/xmrig-orchestrator`
- Make daemon executable

**Constants:**
```ruby
DAEMON_SOURCE = 'xmrig-orchestrator'
DAEMON_DEST = '/usr/local/bin/xmrig-orchestrator'
XMRIG_SYMLINK = '/usr/local/bin/xmrig'
```

**Idempotency:** Checks if daemon exists and is executable

### 9. SystemdInstaller (`lib/installer/systemd_installer.rb`)

**Responsibilities:**
- Copy service files to `/etc/systemd/system/`
- Run `systemctl daemon-reload`
- Enable services (auto-start on boot)
- Restart orchestrator if already running

**Constants:**
```ruby
SERVICES = [
  { name: 'xmrig.service', source: 'xmrig.service' },
  { name: 'xmrig-orchestrator.service', source: 'xmrig-orchestrator.service' }
]

SYSTEMD_DIR = '/etc/systemd/system'
```

**Idempotency:** Checks if service files exist

### 10. LogrotateConfigurator (`lib/installer/logrotate_configurator.rb`)

**Responsibilities:**
- Create `/etc/logrotate.d/xmrig`
- Configure daily rotation with 7-day retention

**Constants:**
```ruby
LOGROTATE_FILE = '/etc/logrotate.d/xmrig'
LOGROTATE_CONFIG = <<~LOGROTATE
  /var/log/xmrig/*.log {
      daily
      rotate 7
      compress
      missingok
      notifempty
      create 0640 xmrig xmrig
  }
LOGROTATE
```

**Idempotency:** Checks if logrotate file exists

### 11. Orchestrator (`lib/installer/orchestrator.rb`)

**Responsibilities:**
- Sequence all installation steps
- Check idempotency (skip completed steps)
- Stop on first failure
- Log progress
- Display next steps after completion

**Step Order:**
```ruby
STEPS = [
  PrerequisiteChecker,
  UserManager,
  SudoConfigurator,
  DirectoryManager,
  ConfigGenerator,
  DaemonInstaller,
  SystemdInstaller,
  LogrotateConfigurator
]
```

**Execution Flow:**
1. For each step:
   - Check if `completed?` → skip if true
   - Call `execute`
   - Store result
   - If failure, log error and return false
2. If all steps succeed, display next steps

---

## Testing Strategy

### Testing Framework

**Minitest** (Rails default, not RSpec)
- Assertion-based testing
- Parallel test execution
- Fixtures support

### Test Organization

```
test/installer/
├── test_helper.rb               # Mocking utilities
├── *_test.rb                    # Unit tests (one per module)
└── integration_test.rb          # Full installation flow
```

### Test Helper (`test/installer/test_helper.rb`)

**Provides:**
- Module loading and setup
- Mock utilities for system commands
- Temporary directory management
- Environment variable helpers

**Key Utilities:**
```ruby
module InstallerTestHelpers
  def mock_command(cmd_pattern, stdout: "", stderr: "", success: true)
    # Mock Open3.capture3
  end

  def mock_system(result)
    # Mock system() calls
  end

  def mock_file_exists(paths)
    # Mock File.exist?
  end

  def with_env(vars)
    # Temporarily set environment variables
  end
end
```

### Unit Test Pattern

**Example: `test/installer/prerequisite_checker_test.rb`**

Test cases:
1. `test_execute_success_when_all_prerequisites_met` - Happy path
2. `test_execute_fails_without_monero_wallet` - Missing env var
3. `test_validate_monero_wallet_rejects_invalid_format` - Validation
4. `test_validate_monero_wallet_accepts_standard_address` - Valid formats
5. `test_completed_always_returns_false` - Idempotency check

**Testing approach:**
- Mock all system calls (sudo, command checks, etc.)
- Test validation logic independently
- Verify error messages are helpful
- Test idempotency logic

### Integration Test Pattern

**Example: `test/installer/integration_test.rb`**

Test cases:
1. `test_full_installation_flow_with_mocks` - End-to-end success
2. `test_installation_stops_on_first_failure` - Error handling
3. `test_idempotency_skips_completed_steps` - Skip logic

**Testing approach:**
- Mock all steps to avoid actual system changes
- Verify orchestration logic (step order, error handling)
- Test result aggregation

### Test Coverage Requirements

- **Unit tests**: Each module must have 100% method coverage
- **Integration tests**: Full flow and error scenarios
- **Validation**: All environment variable checks
- **Idempotency**: Every `completed?` method tested

---

## Implementation Checklist

### Phase 1: Core Infrastructure
- [ ] Create `host-daemon/lib/installer/` directory
- [ ] Implement `Result` class
- [ ] Implement `BaseStep` class
- [ ] Implement `Orchestrator` class
- [ ] Create main `host-daemon/install` entry point
- [ ] Write test helper with mocking utilities

### Phase 2: Installation Steps (in order)
- [ ] Implement `PrerequisiteChecker` + tests
- [ ] Implement `UserManager` + tests
- [ ] Implement `SudoConfigurator` + tests
- [ ] Implement `DirectoryManager` + tests
- [ ] Implement `ConfigGenerator` + tests
- [ ] Implement `DaemonInstaller` + tests
- [ ] Implement `SystemdInstaller` + tests
- [ ] Implement `LogrotateConfigurator` + tests

### Phase 3: Integration & Testing
- [ ] Write integration tests
- [ ] Test on development VM (full installation)
- [ ] Create validation script (`verify-installation.rb`)
- [ ] Compare results with install.sh on test host

### Phase 4: Migration
- [ ] Deploy to 1 test host, monitor 48 hours
- [ ] Deploy to 25% of hosts if successful
- [ ] Deploy to remaining hosts
- [ ] Remove `install.sh` after 2 weeks of production use
- [ ] Update documentation

### Phase 5: Documentation
- [ ] Update `host-daemon/README.md`
- [ ] Add installation troubleshooting guide
- [ ] Document testing approach
- [ ] Add examples of running installer

---

## Critical Files to Create/Modify

### New Files (24 total)

**Installer Code (12 files):**
1. `host-daemon/install` - Main entry point
2. `host-daemon/lib/installer/result.rb`
3. `host-daemon/lib/installer/base_step.rb`
4. `host-daemon/lib/installer/orchestrator.rb`
5. `host-daemon/lib/installer/prerequisite_checker.rb`
6. `host-daemon/lib/installer/user_manager.rb`
7. `host-daemon/lib/installer/sudo_configurator.rb`
8. `host-daemon/lib/installer/directory_manager.rb`
9. `host-daemon/lib/installer/config_generator.rb`
10. `host-daemon/lib/installer/daemon_installer.rb`
11. `host-daemon/lib/installer/systemd_installer.rb`
12. `host-daemon/lib/installer/logrotate_configurator.rb`

**Test Files (11 files):**
13. `test/installer/test_helper.rb`
14. `test/installer/prerequisite_checker_test.rb`
15. `test/installer/user_manager_test.rb`
16. `test/installer/sudo_configurator_test.rb`
17. `test/installer/directory_manager_test.rb`
18. `test/installer/config_generator_test.rb`
19. `test/installer/daemon_installer_test.rb`
20. `test/installer/systemd_installer_test.rb`
21. `test/installer/logrotate_configurator_test.rb`
22. `test/installer/orchestrator_test.rb`
23. `test/installer/integration_test.rb`

**Utilities (1 file):**
24. `host-daemon/verify-installation.rb` - Post-install validation

### Files to Remove (after testing)
- `host-daemon/install.sh` (replaced by `host-daemon/install`)

### Files Unchanged
- `host-daemon/xmrig-orchestrator` - No changes
- `host-daemon/xmrig.service` - No changes
- `host-daemon/xmrig-orchestrator.service` - No changes
- `host-daemon/config.json.template` - No changes

---

## Success Criteria

### Functionality
- ✅ All installation steps complete successfully on fresh host
- ✅ Idempotent - can run multiple times without errors
- ✅ Creates identical system state as install.sh
- ✅ XMRig and orchestrator services start correctly
- ✅ Database access works (Rails container → /mnt/rails-storage)

### Testing
- ✅ 100% unit test coverage for all modules
- ✅ Integration tests pass
- ✅ All tests run in CI/CD pipeline
- ✅ No external dependencies beyond Ruby stdlib

### Quality
- ✅ Clear error messages for all failure modes
- ✅ Helpful logging during installation
- ✅ Code follows Ruby conventions
- ✅ Consistent with xmrig-orchestrator patterns

### Production
- ✅ Successfully deployed to all production hosts
- ✅ No regression in mining operations
- ✅ install.sh removed from repository
- ✅ Documentation updated

---

## Error Handling

### Validation Errors
- Missing environment variables → Clear message listing missing vars
- Invalid Monero wallet → Format requirements explanation
- Missing prerequisites → Installation instructions

### System Errors
- Permission denied → Suggest checking sudo access
- User already exists → Skip (idempotent)
- Service installation fails → Suggest checking systemd

### Recovery Strategy
- All steps are idempotent
- Failed state is safe - fix issue and re-run
- No rollback needed - partial installation is recoverable

---

## Future Enhancements

**Not in initial scope but documented for later:**
1. `--dry-run` flag to preview changes
2. `--rollback` to undo installation
3. Update mode to detect and update existing installation
4. Parallel multi-host deployment
5. Configuration validation before applying
6. Built-in health check post-installation

---

## Migration Validation

### Comparison Checklist

After running Ruby installer, verify identical state to install.sh:

```bash
# Users
id xmrig && id xmrig-orchestrator

# Groups
groups xmrig-orchestrator | grep -q deploy

# Directories
ls -ld /var/log/xmrig /etc/xmrig /var/lib/xmrig-orchestrator /mnt/rails-storage

# Files
test -f /etc/xmrig/config.json
test -f /usr/local/bin/xmrig-orchestrator
test -f /etc/systemd/system/xmrig.service
test -f /etc/systemd/system/xmrig-orchestrator.service
test -f /etc/sudoers.d/xmrig-orchestrator
test -f /etc/logrotate.d/xmrig

# Services
systemctl is-enabled xmrig
systemctl is-enabled xmrig-orchestrator

# Permissions
stat -c "%a" /etc/sudoers.d/xmrig-orchestrator | grep -q 440
stat -c "%a" /mnt/rails-storage | grep -q 775
```

### Validation Script

Run `host-daemon/verify-installation.rb` to check all components.

---

## Dependencies

**Runtime Dependencies:**
- Ruby (already required for orchestrator)
- Bundler (installed by PrerequisiteChecker if missing)
- No additional gems required (stdlib only)

**System Requirements:**
- Systemd (for service management)
- Sudo access
- XMRig binary in PATH

**Development Dependencies:**
- Minitest (included with Ruby)
- No additional test gems

---

## Notes

1. **Consistency**: Follow xmrig-orchestrator pattern (bundler/inline, no Rails)
2. **Security**: Use Open3.capture3 with array form to prevent shell injection
3. **Logging**: INFO level for progress, ERROR for failures, WARN for non-fatal issues
4. **Constants**: Define all magic strings/paths as constants at top of each module
5. **Testing**: Mock all system calls to enable testing without root access
6. **Documentation**: Each class should have clear docstring explaining purpose
