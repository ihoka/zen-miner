# Specification: Ruby-Based SSH Orchestrator Update Script

**Status**: Approved
**Author**: Claude Code
**Date**: 2025-12-23
**Type**: Security Enhancement + Infrastructure Improvement

---

## Overview

Implement a secure, testable Ruby script to update the XMRig orchestrator daemon on all deployed hosts via direct SSH from the development machine. This replaces the insecure container-based approach that grants containers write access to the host filesystem.

---

## Background/Problem Statement

### Current Situation

The existing orchestrator update mechanism (proposed in `specs/fix-orchestrator-deployment-sync.md`) uses a container-based approach with critical security flaws:

1. **Container Security Risk**:
   - Uses `kamal app exec` to run update scripts from within containers
   - Requires bind mounts giving containers write access to `/usr/local/bin/` on the host
   - Allows containers to execute `systemctl` commands on the host
   - **Violation**: Principle of least privilege - Rails container doesn't need these permissions

2. **Container Escape Vector**:
   - Compromised Rails container could escape to host via bind mount
   - Write access to `/usr/local/bin/` enables arbitrary code execution as root
   - Attack surface unnecessarily expanded

3. **Lack of Testability**:
   - Bash script implementation difficult to unit test
   - No automated test coverage for critical security functions (hostname validation, command injection prevention)
   - Manual testing only - error-prone

### Evidence

From security analysis:
```
Current Broken Flow:
Dev Machine → Kamal → Docker Container → Host Filesystem (via bind mount)
                         ↑ SECURITY RISK: Container has host write access

Required Secure Flow:
Dev Machine → SSH → Host (as deploy user) → sudo systemctl
               ↑ SECURE: Standard remote admin pattern
```

---

## Goals

1. **Security**: Eliminate container host-level access completely
2. **Testability**: 100% unit test coverage for all critical paths
3. **Maintainability**: Ruby implementation consistent with Rails project
4. **Reliability**: Handle SSH failures gracefully, continue on partial failure
5. **Auditability**: Clear SSH audit trail, better logging

---

## Non-Goals

1. **Parallel Execution**: Start with sequential updates (4 hosts × 5s = 20s is acceptable)
2. **Auto-Detection**: No automatic detection of orchestrator code changes
3. **Rollback**: No rollback mechanism for failed updates (orchestrator is stateless)
4. **Zero-Downtime**: Brief mining interruption during restart is acceptable

---

## Technical Dependencies

### Ruby Standard Library
- `yaml` - Parse `config/deploy.yml`
- `open3` - Execute SSH/SCP commands with output capture
- `optparse` - Command-line argument parsing
- `shellwords` - Secure shell quoting (prevent injection)

### External Dependencies
- **SSH access**: Deploy user must have SSH access to all hosts
- **Sudo permissions**: Deploy user needs sudo for systemctl operations (already configured via install.sh)
- **File system**: `/usr/local/bin/` must be writable by root via sudo

### Testing Dependencies
- **Minitest**: Rails default testing framework (already available)
- `minitest/mock`: Mocking SSH/SCP commands

---

## Detailed Design

### Architecture Overview

```
┌─────────────────────────────────────────────────┐
│ Local Development Machine                       │
│                                                  │
│  ┌────────────────────────────────────┐         │
│  │ bin/update-orchestrators-ssh       │         │
│  │ (Ruby script)                      │         │
│  │                                    │         │
│  │ 1. Load config/deploy.yml          │         │
│  │ 2. Validate hostnames              │         │
│  │ 3. For each host:                  │         │
│  │    - SSH connectivity check        │         │
│  │    - SCP orchestrator file         │         │
│  │    - SSH update commands           │         │
│  │    - Verify service restart        │         │
│  └────────────────────────────────────┘         │
│                   │                              │
│                   │ Direct SSH as deploy user    │
│                   ▼                              │
└──────────────────────────────────────────────────┘
                    │
    ┌───────────────┴───────────────┐
    │                               │
    ▼                               ▼
┌─────────────────────┐   ┌─────────────────────┐
│ Host: mini-1        │   │ Host: miner-beta    │
│                     │   │                     │
│ 1. Receive file     │   │ 1. Receive file     │
│ 2. Detect xmrig     │   │ 2. Detect xmrig     │
│ 3. Update binary    │   │ 3. Update binary    │
│ 4. Restart service  │   │ 4. Restart service  │
│ 5. Verify running   │   │ 5. Verify running   │
└─────────────────────┘   └─────────────────────┘
```

### Ruby Class Structure

```ruby
module OrchestratorUpdater
  # Parses config/deploy.yml and extracts hosts
  class Config
    def self.load_hosts
    end
  end

  # Validates hostname format (prevent injection)
  class HostValidator
    def self.valid?(hostname)
    end
  end

  # Handles SSH operations for a single host
  class SSHExecutor
    def initialize(hostname, dry_run: false, verbose: false)
    end

    def check_connectivity
    end

    def copy_orchestrator(source_path)
    end

    def update_orchestrator
    end

    def verify_service
    end

    private

    def ssh(command)
    end

    def scp(source, destination)
    end
  end

  # Orchestrates updates across all hosts
  class UpdateCoordinator
    def initialize(hosts, options = {})
    end

    def run
    end

    private

    def update_host(hostname)
    end

    def display_summary
    end
  end

  # Command-line interface
  class CLI
    def self.run(argv)
    end

    private

    def self.parse_options(argv)
    end

    def self.determine_hosts(options)
    end
  end
end
```

### Implementation Approach

**Test-Driven Development (TDD):**

1. **Write tests first** (`test/update_orchestrator_test.rb`)
2. **Implement classes** to make tests pass (`bin/update-orchestrators-ssh`)
3. **Refactor** as needed while maintaining test coverage

**Class Responsibilities:**

#### 1. Config Class

**Purpose**: Parse Kamal configuration and extract host list

**Methods**:
- `load_hosts` → Array of hostnames

**Behavior**:
- Read `config/deploy.yml`
- Parse YAML safely (YAML.load_file)
- Extract `servers.web.hosts` array
- Raise error if config missing or malformed
- Raise error if no hosts defined

**Error Cases**:
- Config file not found → `ConfigError`
- Invalid YAML syntax → `ConfigError`
- No hosts in config → `ConfigError`

#### 2. HostValidator Class

**Purpose**: Validate hostname format (prevent injection attacks)

**Methods**:
- `valid?(hostname)` → Boolean

**Validation Rules**:
- Must match regex: `^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$`
- Maximum length: 253 characters (DNS limit)
- No path traversal: `..` or `/`
- No special characters: spaces, quotes, semicolons

**Example Valid Hostnames**:
- `mini-1`
- `miner-beta`
- `host.example.com`

**Example Invalid Hostnames**:
- `mini-1; rm -rf /` (injection attempt)
- `../../../etc/passwd` (path traversal)
- `mini 1` (space)
- `mini'1` (quote)

#### 3. SSHExecutor Class

**Purpose**: Execute SSH/SCP operations for a single host

**Initialization**:
```ruby
def initialize(hostname, dry_run: false, verbose: false)
  @hostname = hostname
  @dry_run = dry_run
  @verbose = verbose
  @ssh_user = 'deploy'
  @temp_prefix = "/tmp/xmrig-orchestrator-#{Process.pid}"
end
```

**Public Methods**:

1. **check_connectivity** → Boolean
   - Test SSH connection with 5-second timeout
   - Command: `ssh -o ConnectTimeout=5 deploy@host 'echo ok'`
   - Returns true if connection successful

2. **copy_orchestrator(source_path)** → Boolean
   - Copy orchestrator file to host via SCP
   - Source: `host-daemon/xmrig-orchestrator`
   - Destination: `/tmp/xmrig-orchestrator-#{pid}`
   - Returns true if SCP successful

3. **update_orchestrator** → Hash
   - Execute update commands via SSH
   - Returns: `{ success: bool, output: string, error: string }`
   - Steps:
     1. Detect xmrig binary location
     2. Create symlink if needed
     3. Copy to /usr/local/bin/
     4. Set executable permissions
     5. Restart service
     6. Cleanup temp file

4. **verify_service** → Boolean
   - Check if orchestrator service is active
   - Command: `sudo systemctl is-active xmrig-orchestrator`
   - Returns true if active

**Private Methods**:

1. **ssh(command)** → [stdout, stderr, status]
   - Execute SSH command using Open3.capture3
   - Quote hostname using Shellwords.escape
   - Format: `ssh -o ConnectTimeout=5 deploy@#{hostname} '#{command}'`
   - In dry-run mode: Log command, don't execute

2. **scp(source, destination)** → [stdout, stderr, status]
   - Execute SCP command using Open3.capture3
   - Quote paths using Shellwords.escape
   - Format: `scp -q #{source} deploy@#{hostname}:#{destination}`
   - In dry-run mode: Log command, don't execute

**Remote Update Script** (executed via SSH):
```bash
set -e

# 1. Detect xmrig binary location
XMRIG_PATH=$(which xmrig 2>/dev/null || echo "")
if [ -n "$XMRIG_PATH" ] && [ "$XMRIG_PATH" != "/usr/local/bin/xmrig" ]; then
  echo "  ✓ XMRig detected at: $XMRIG_PATH"
  sudo ln -sf "$XMRIG_PATH" /usr/local/bin/xmrig
  echo "  ✓ Symlink created"
fi

# 2. Install orchestrator
sudo cp /tmp/xmrig-orchestrator-PID /usr/local/bin/xmrig-orchestrator
sudo chmod +x /usr/local/bin/xmrig-orchestrator
echo "  ✓ Orchestrator updated"

# 3. Restart service
sudo systemctl restart xmrig-orchestrator
sleep 2

# 4. Verify running
if sudo systemctl is-active --quiet xmrig-orchestrator; then
  echo "  ✓ Service verified"
else
  echo "  ✗ Service failed to start"
  sudo journalctl -u xmrig-orchestrator -n 10 --no-pager
  exit 1
fi

# 5. Cleanup
rm -f /tmp/xmrig-orchestrator-PID
```

#### 4. UpdateCoordinator Class

**Purpose**: Orchestrate updates across multiple hosts

**Initialization**:
```ruby
def initialize(hosts, options = {})
  @hosts = hosts
  @options = options
  @results = { success: [], failed: [] }
end
```

**Public Methods**:

1. **run** → Integer (exit code)
   - Pre-flight checks
   - Display update plan
   - Prompt for confirmation (unless --yes)
   - Update each host sequentially
   - Display summary
   - Return 0 (all success) or 1 (any failures)

**Private Methods**:

1. **update_host(hostname)** → Boolean
   - Create SSHExecutor for host
   - Execute update steps:
     1. Check SSH connectivity
     2. Copy orchestrator file
     3. Execute update commands
     4. Verify service running
   - Track success/failure
   - Return true if all steps successful

2. **display_summary**
   - Show successful hosts
   - Show failed hosts
   - Display retry commands for failures

**Error Handling**:
- Continue on per-host failure
- Track all failures
- Exit code 1 if ANY host failed

#### 5. CLI Class

**Purpose**: Command-line interface

**Public Methods**:

1. **run(argv)** → void
   - Parse command-line options
   - Determine hosts (from config or --host)
   - Create UpdateCoordinator
   - Execute coordinator.run
   - Exit with appropriate code

**Private Methods**:

1. **parse_options(argv)** → Hash
   - Options:
     - `--host HOSTNAME` - Update single host
     - `--yes` - Skip confirmation
     - `--dry-run` - Show commands without executing
     - `--verbose` - Show all SSH commands
   - Return options hash

2. **determine_hosts(options)** → Array
   - If `--host` specified: Return single-host array
   - Else: Load hosts from config via Config.load_hosts
   - Validate all hostnames
   - Return validated host array

### Code Structure and File Organization

```
zen-miner/
├── bin/
│   ├── update-orchestrators-ssh         # NEW: Ruby script (~300 lines)
│   └── update-orchestrators             # DELETE: Old bash script (security risk)
├── test/
│   └── update_orchestrator_test.rb      # NEW: Unit tests (~400 lines)
├── host-daemon/
│   ├── xmrig-orchestrator               # Source file to deploy
│   └── README.md                        # UPDATE: Document SSH update process
├── config/
│   └── deploy.yml                       # Read-only: Extract host list
├── specs/
│   ├── ruby-orchestrator-update.md      # NEW: This specification
│   └── fix-orchestrator-deployment-sync.md  # UPDATE: Reference Ruby approach
└── README.md                             # UPDATE: Add deployment section
```

### Security Considerations

#### Threat Model

**Attack Vectors Mitigated**:
1. **SSH Command Injection**: Hostname validation + Shellwords.escape
2. **Path Traversal**: Hostname validation rejects `../`
3. **Container Escape**: No container host access (eliminated entirely)

**Security Safeguards**:

1. **Hostname Validation** (HostValidator):
   ```ruby
   HOSTNAME_REGEX = /\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}\z/

   def self.valid?(hostname)
     return false if hostname.nil? || hostname.empty?
     return false unless hostname.match?(HOSTNAME_REGEX)
     return false if hostname.include?('..')
     true
   end
   ```

2. **SSH Command Quoting** (SSHExecutor):
   ```ruby
   require 'shellwords'

   def ssh(command)
     escaped_host = Shellwords.escape(@hostname)
     ssh_cmd = "ssh -o ConnectTimeout=5 #{@ssh_user}@#{escaped_host} '#{command}'"
     Open3.capture3(ssh_cmd)
   end
   ```

3. **File Verification**:
   ```ruby
   def verify_source_file(path)
     raise "Source file not found: #{path}" unless File.exist?(path)
     raise "Source file is a symlink: #{path}" if File.symlink?(path)
     raise "Source file not readable: #{path}" unless File.readable?(path)
   end
   ```

4. **Fail-Fast Approach**:
   - Exit immediately on critical errors (config missing, invalid hostname)
   - Continue on per-host errors (one host failure doesn't stop others)

#### Audit Trail

**SSH Logs** provide clear audit trail:
```
# /var/log/auth.log on each host
Dec 23 12:45:01 mini-1 sshd[12345]: Accepted publickey for deploy from DEV_IP
Dec 23 12:45:02 mini-1 sudo: deploy : TTY=pts/0 ; PWD=/home/deploy ; USER=root ; COMMAND=/bin/systemctl restart xmrig-orchestrator
```

**Script Output**:
```
[12:45:01] Updating mini-1...
[12:45:02]   ✓ SSH connection verified
[12:45:02]   ✓ Orchestrator copied to host
[12:45:03]   ✓ XMRig binary detected at /usr/bin/xmrig
[12:45:03]   ✓ Symlink created: /usr/local/bin/xmrig
[12:45:04]   ✓ Orchestrator installed to /usr/local/bin/
[12:45:04]   ✓ Service restarted
[12:45:06]   ✓ Service verification successful
```

---

## User Experience

### For Operators

**Typical Workflow**:

```bash
# Make changes to orchestrator code
vim host-daemon/xmrig-orchestrator

# Test locally
ruby host-daemon/xmrig-orchestrator --help

# Commit changes
git commit -am "Fix orchestrator bug"

# Deploy Rails app
kamal deploy

# Update orchestrators on all hosts
bin/update-orchestrators-ssh

# Output:
# ==========================================
# XMRig Orchestrator Update (via SSH)
# ==========================================
#
# Hosts to update:
#   - mini-1 (reachable via SSH)
#   - miner-beta (reachable via SSH)
#   - miner-gamma (reachable via SSH)
#   - miner-delta (reachable via SSH)
#
# Source: /Users/ihoka/ihoka/zen-miner/host-daemon/xmrig-orchestrator
# Update method: Direct SSH as deploy user
#
# Continue? [y/N]: y
#
# [12:45:01] Updating mini-1...
# [12:45:06] ✓ mini-1 updated successfully (5s)
#
# [12:45:06] Updating miner-beta...
# [12:45:11] ✓ miner-beta updated successfully (5s)
#
# [12:45:11] Updating miner-gamma...
# [12:45:16] ✓ miner-gamma updated successfully (5s)
#
# [12:45:16] Updating miner-delta...
# [12:45:21] ✓ miner-delta updated successfully (5s)
#
# ==========================================
# Update Summary
# ==========================================
# Success: 4 hosts
#   ✓ mini-1
#   ✓ miner-beta
#   ✓ miner-gamma
#   ✓ miner-delta
#
# Total time: 20s
```

**Command-Line Options**:

```bash
# Update specific host without confirmation
bin/update-orchestrators-ssh --host mini-1 --yes

# Dry run (show what would be executed)
bin/update-orchestrators-ssh --dry-run

# Verbose mode (show all SSH commands)
bin/update-orchestrators-ssh --verbose
```

### For Developers

**Running Tests**:

```bash
# Run all unit tests
ruby test/update_orchestrator_test.rb

# Or via Rails test runner
rails test test/update_orchestrator_test.rb

# With verbose output
ruby test/update_orchestrator_test.rb --verbose

# Expected output:
# Run options: --seed 12345
#
# # Running:
#
# ...................................
#
# Finished in 0.123456s, 123.45 runs/s, 123.45 assertions/s.
#
# 39 runs, 82 assertions, 0 failures, 0 errors, 0 skips
```

**Debugging**:

```bash
# Test SSH connectivity to a single host
ssh deploy@mini-1 'echo ok'

# Test SCP file transfer
scp host-daemon/xmrig-orchestrator deploy@mini-1:/tmp/test

# Test orchestrator service status
ssh deploy@mini-1 'sudo systemctl status xmrig-orchestrator'

# View recent orchestrator logs
ssh deploy@mini-1 'sudo journalctl -u xmrig-orchestrator -n 50'
```

---

## Testing Strategy

### Unit Tests (Priority)

**Test Coverage**: 100% of critical paths

**Test Classes**:

1. **ConfigTest** (4 tests)
   - Load hosts from valid config
   - Missing config file error
   - Empty config error
   - Invalid YAML error

2. **HostValidatorTest** (5 test groups)
   - Valid hostnames
   - Invalid hostnames (injection attempts)
   - Invalid hostnames (path traversal)
   - Invalid hostnames (special characters)
   - Invalid hostnames (length limits)

3. **SSHExecutorTest** (10 tests)
   - Check connectivity success
   - Check connectivity timeout
   - Check connectivity auth failure
   - Copy orchestrator success
   - Copy orchestrator failure
   - Update orchestrator success
   - Update orchestrator service restart failure
   - Verify service running
   - Verify service not running
   - Dry-run mode (no actual execution)

4. **UpdateCoordinatorTest** (6 tests)
   - Run all hosts success
   - Run partial failure
   - Run all hosts failure
   - Run continues after host failure
   - Display summary (success)
   - Display summary (failures)

5. **CLITest** (8 tests)
   - Parse options defaults
   - Parse options --host
   - Parse options --yes
   - Parse options --dry-run
   - Parse options --verbose
   - Determine hosts from config
   - Determine hosts from option
   - Run integration

**Total**: 39 unit tests

**Mocking Strategy**:

```ruby
# Mock Open3.capture3 to avoid actual SSH execution
def test_check_connectivity_success
  stdout, stderr, status = "ok\n", "", double_success_status

  Open3.stub :capture3, [stdout, stderr, status] do
    executor = SSHExecutor.new('test-host')
    assert executor.check_connectivity
  end
end

# Helper method to create mock status
def double_success_status
  status = Object.new
  status.define_singleton_method(:success?) { true }
  status.define_singleton_method(:exitstatus) { 0 }
  status
end
```

### Integration Tests (Manual)

**After unit tests pass**, perform manual integration testing:

1. **Dry-run mode**: Verify no actual execution
2. **Single host update**: Update mini-1 only
3. **Hostname validation**: Test injection attempts (should fail)
4. **SSH failure handling**: Test with unreachable host
5. **All hosts update**: Update all 4 hosts
6. **XMRig path detection**: Verify symlink creation

### Production Verification

**Success Criteria**:
- All 4 hosts updated successfully
- Orchestrator services running without errors
- No "no such column: hostname" errors in logs
- Mining commands processed correctly

---

## Performance Considerations

### Update Time Estimates

**Sequential Updates** (current implementation):
- Per-host time: ~5 seconds
  - SSH connectivity check: 0.5s
  - SCP file transfer: 0.5s
  - SSH update commands: 3s
  - Service verification: 1s
- Total time (4 hosts): ~20 seconds

**Acceptable** for 4 hosts. Parallel execution can be added later if needed.

### Network Efficiency

- Single SSH session per host (not multiple round-trips)
- SCP transfers small file (~8KB orchestrator script)
- No database downtime required

---

## Documentation

### Files to Create/Update

1. **`specs/ruby-orchestrator-update.md`** (this file)
   - Comprehensive specification
   - Architecture and design decisions
   - Security analysis

2. **`bin/update-orchestrators-ssh`** (executable Ruby script)
   - Header comments explaining usage
   - Example invocations
   - Exit codes

3. **`test/update_orchestrator_test.rb`** (unit tests)
   - Test each class comprehensively
   - Document test coverage

4. **`host-daemon/README.md`** - Add section:
   ```markdown
   ## Updating the Orchestrator Daemon

   From your local development machine:

   ```bash
   # Update all hosts
   bin/update-orchestrators-ssh

   # Update specific host
   bin/update-orchestrators-ssh --host mini-1 --yes
   ```

   ### When to Update

   Update the orchestrator after:
   - Database schema changes affecting `xmrig_commands` or `xmrig_processes`
   - Changes to orchestrator logic or command processing
   - Bug fixes in the daemon code
   ```

5. **`README.md`** - Add section:
   ```markdown
   ## Deployment

   ### Rails Application

   ```bash
   kamal deploy
   ```

   ### Orchestrator Daemon

   After making changes to `host-daemon/xmrig-orchestrator`:

   ```bash
   bin/update-orchestrators-ssh
   ```
   ```

6. **`specs/fix-orchestrator-deployment-sync.md`** - Update to reference Ruby approach

---

## Implementation Phases

### Phase 1: Test-Driven Development

**Objective**: Create comprehensive test suite before implementation

**Steps**:
1. Create `test/update_orchestrator_test.rb` with all test cases (failing)
2. Run tests to verify they fail appropriately
3. Implement classes one at a time to make tests pass:
   - HostValidator (simplest, no dependencies)
   - Config (depends on YAML)
   - SSHExecutor (depends on Open3, mocked in tests)
   - UpdateCoordinator (depends on SSHExecutor)
   - CLI (depends on all above)

**Success Criteria**:
- All 39 unit tests pass
- Test coverage includes all critical paths
- No actual SSH commands executed during tests (mocked)

### Phase 2: Integration Testing

**Objective**: Verify actual SSH operations work correctly

**Steps**:
1. Test dry-run mode on all hosts
2. Test single host update (mini-1)
3. Test hostname validation (should reject invalid inputs)
4. Test all hosts update

**Success Criteria**:
- Orchestrator updated successfully on all hosts
- Services restart without errors
- Mining commands processed correctly

### Phase 3: Documentation

**Objective**: Integrate into standard deployment workflow

**Steps**:
1. Update `host-daemon/README.md`
2. Update main `README.md`
3. Update `specs/fix-orchestrator-deployment-sync.md`
4. Delete old `bin/update-orchestrators` (insecure bash script)

**Success Criteria**:
- Team knows when to run update script
- Process documented clearly
- Security improvements documented

---

## Success Criteria

- [ ] Ruby script created: `bin/update-orchestrators-ssh` (~300 lines)
- [ ] Unit tests created: `test/update_orchestrator_test.rb` (~400 lines)
- [ ] All 39 unit tests pass
- [ ] Test coverage includes all critical paths
- [ ] Script successfully updates all 4 hosts in production
- [ ] Hostname validation prevents injection attacks
- [ ] SSH failures handled gracefully (continues to other hosts)
- [ ] Orchestrator service restarts verified
- [ ] XMRig binary path detection and symlinking works
- [ ] Spec file created: `specs/ruby-orchestrator-update.md`
- [ ] Documentation updated: README.md, host-daemon/README.md
- [ ] Old insecure approach deleted: `bin/update-orchestrators`

---

## Design Decisions (Finalized)

### D1: Remove existing script completely

**Decision**: Delete `bin/update-orchestrators` (the insecure container-based bash script)
**Rationale**: Clean break, no confusion, eliminates security risk
**Impact**: Only one update method going forward (secure SSH-based Ruby script)

### D2: No parallel execution

**Decision**: Sequential updates only (no `--parallel` flag)
**Rationale**: 4 hosts × 5s = 20s is acceptable, simpler to debug, more reliable
**Impact**: Slightly slower but more maintainable

### D3: Idempotent updates (always update)

**Decision**: Script always updates, never checks if update is needed
**Rationale**: Simpler logic, safer (always in sync), no version tracking complexity
**Impact**: Can run update script multiple times safely, always ensures latest code deployed
**Benefit**: Idempotent operation - running multiple times has same effect as running once

---

## References

### Related Files
- `/Users/ihoka/ihoka/zen-miner/host-daemon/xmrig-orchestrator` - Daemon source
- `/Users/ihoka/ihoka/zen-miner/config/deploy.yml` - Kamal config (host list)
- `/Users/ihoka/ihoka/zen-miner/specs/fix-orchestrator-deployment-sync.md` - Original spec

### Related Issues
- Container security risk (bind mount host access)
- Lack of testability in bash implementation
- Need for automated deployment mechanism

### Design Decisions

**Decision**: Use Ruby instead of Bash
**Rationale**: Testability, maintainability, consistency with Rails project
**Impact**: 100% unit test coverage possible, easier to maintain

**Decision**: Direct SSH instead of container-based
**Rationale**: Security (no container host access), better audit trail
**Impact**: Eliminates container escape vector, follows principle of least privilege

**Decision**: Test-Driven Development (TDD)
**Rationale**: Critical security code must be well-tested
**Impact**: Higher confidence in security safeguards, fewer bugs

**Decision**: Sequential updates (not parallel)
**Rationale**: Simpler, easier to debug, 20s is acceptable for 4 hosts
**Impact**: Slightly slower but more reliable

---

**End of Specification**
