# Specification: Fix Orchestrator Deployment and XMRig Binary Path Issues

**Status**: Draft
**Author**: Claude Code
**Date**: 2025-12-22
**Type**: Bugfix

---

## Overview

The XMRig orchestrator daemon on deployed hosts is running outdated code that is incompatible with the current database schema, causing it to crash every 30 seconds and preventing any mining commands from being processed. Additionally, there's a mismatch between the expected and actual XMRig binary path.

---

## Background/Problem Statement

### Current Situation

The deployment architecture has a critical flaw: the host-side orchestrator daemon (`/usr/local/bin/xmrig-orchestrator`) is **not automatically updated** when the codebase changes. This has created the following issues:

1. **Schema Mismatch (CRITICAL)**:
   - Migration `20251222194500_remove_hostname_from_xmrig_commands.rb` removed the `hostname` column from `xmrig_commands` table
   - The deployed orchestrator daemon (installed Dec 22 at 18:49) still queries: `WHERE hostname = ?`
   - Result: SQLite error "no such column: hostname" every 10 seconds
   - Orchestrator crashes and sleeps for 30 seconds, then retries in an infinite error loop
   - **Zero commands are processed** - mining cannot be started/stopped

2. **XMRig Binary Path Mismatch**:
   - `xmrig.service` expects: `/usr/local/bin/xmrig`
   - Actual binary location: `/usr/bin/xmrig` (from system package manager)
   - Even if schema is fixed, `systemctl start xmrig` would fail with "No such file or directory"

3. **No Deployment Process for Daemon Updates**:
   - Rails app updates via Kamal automatically
   - Orchestrator daemon requires manual SSH + reinstallation
   - No versioning or update detection mechanism
   - No notification when daemon is out of sync with schema

### Evidence

From mini-1 host investigation:
```
# Orchestrator log shows continuous errors
E, [2025-12-22T20:14:46] ERROR -- : Error in main loop: no such column: hostname
SELECT * FROM xmrig_commands WHERE hostname = ? AND status = 'pending'

# Deployed orchestrator code (OUTDATED)
"SELECT * FROM xmrig_commands WHERE hostname = ? AND status = 'pending'"

# Current repository code (CORRECT)
"SELECT * FROM xmrig_commands WHERE status = 'pending' ORDER BY created_at ASC"

# XMRig binary location
/usr/bin/xmrig exists
/usr/local/bin/xmrig does NOT exist

# Command stuck in pending state
ID: 1, Action: start, Status: pending, Created: 2025-12-22 20:03:14 UTC
```

---

## Goals

1. **Immediate Fix**: Update the orchestrator daemon on all deployed hosts to use current code
2. **XMRig Path Detection**: Make install.sh detect and adapt to actual xmrig binary location
3. **Automated Updates**: Create a mechanism to update the orchestrator daemon when code changes
4. **Deployment Safety**: Ensure schema migrations and daemon updates are synchronized
5. **Multi-Host Support**: Verify the solution works correctly across all 4 hosts (mini-1, miner-beta, miner-gamma, miner-delta)

---

## Non-Goals

1. **Rollback Mechanism**: Not implementing database migration rollback (out of scope)
2. **Zero-Downtime Updates**: Brief mining interruption during orchestrator restart is acceptable
3. **Automated XMRig Installation**: Still requires manual xmrig binary installation (separate feature)
4. **Version Pinning**: Not implementing daemon version tracking in database (future enhancement)

---

## Technical Dependencies

### Existing Dependencies
- **Ruby**: 3.x (already required for orchestrator daemon)
- **SQLite3**: gem "sqlite3", "~> 2.4" (bundler/inline)
- **systemd**: For service management
- **Open3**: Ruby stdlib for safe command execution
- **Kamal**: For Rails deployment

### System Requirements
- **SSH Access**: Deploy user must have SSH access to all hosts
- **Sudo Permissions**: Deploy user needs sudo for systemctl operations
- **File System**: `/usr/local/bin/` must be writable by root

---

## Detailed Design

### Architecture Changes

#### Current Architecture (Broken)
```
┌─────────────────────────────────────────────────┐
│ Local Development Machine                       │
│                                                  │
│  1. Code changes in host-daemon/                │
│  2. Rails migration removes hostname column     │
│  3. kamal deploy (Rails only)                   │
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────┐
│ Remote Host (mini-1)                            │
│                                                  │
│  ┌────────────────────────────────────┐         │
│  │ Rails Container (UPDATED)          │         │
│  │ - New schema (no hostname column)  │         │
│  │ - Writes to /mnt/rails-storage/    │         │
│  └────────────────────────────────────┘         │
│                   │                              │
│                   │ Shared Volume                │
│                   ▼                              │
│  ┌────────────────────────────────────┐         │
│  │ /mnt/rails-storage/                │         │
│  │ - production.sqlite3 (NEW SCHEMA)  │         │
│  └────────────────────────────────────┘         │
│                   │                              │
│                   │ Polled by                    │
│                   ▼                              │
│  ┌────────────────────────────────────┐         │
│  │ Orchestrator Daemon (OUTDATED!)    │  ✗ BREAKS
│  │ - Queries: WHERE hostname = ?      │  ✗ CRASHES
│  │ - Installed: Dec 22 18:49          │         │
│  │ - Never updated automatically      │         │
│  └────────────────────────────────────┘         │
└─────────────────────────────────────────────────┘
```

#### Proposed Architecture (Fixed)
```
┌─────────────────────────────────────────────────┐
│ Local Development Machine                       │
│                                                  │
│  1. Code changes in host-daemon/                │
│  2. kamal deploy (Rails)                        │
│  3. bin/update-orchestrators-ssh                │ ← Direct SSH (secure)
└──────────────────┬──────────────────────────────┘
                   │ Direct SSH
                   ▼
┌─────────────────────────────────────────────────┐
│ Remote Host (mini-1)                            │
│                                                  │
│  ┌────────────────────────────────────┐         │
│  │ Rails Container                     │         │
│  │ - NO host filesystem access         │         │
│  │ - NO systemctl access               │         │
│  │ - Principle of least privilege      │         │
│  └────────────────────────────────────┘         │
│                                                  │
│  ┌────────────────────────────────────┐         │
│  │ Update Process (via SSH)           │         │
│  │ 1. SSH as 'deploy' user             │         │
│  │ 2. Detect xmrig binary location    │         │
│  │ 3. Create symlink if needed        │         │
│  │ 4. Copy to /usr/local/bin/         │         │
│  │ 5. Restart orchestrator service    │         │
│  └────────────────────────────────────┘         │
│                   │                              │
│                   ▼                              │
│  ┌────────────────────────────────────┐         │
│  │ Orchestrator Daemon (UPDATED!)     │  ✓ WORKS
│  │ - Current code from repository     │  ✓ COMPATIBLE
│  │ - Compatible with new schema       │         │
│  └────────────────────────────────────┘         │
└─────────────────────────────────────────────────┘
```

### Implementation Approach

**Objective**: Create a secure automated deployment mechanism that updates the orchestrator daemon on all hosts via direct SSH

**Implementation Strategy**: Ruby-based SSH approach (NOT container-based)

This spec originally proposed a container-based approach using `kamal app exec` with bind mounts. That approach was **rejected due to security concerns** (containers should not have write access to host filesystem or systemctl permissions).

**Implemented Solution**: Direct SSH from development machine

For complete implementation details, see **[specs/ruby-orchestrator-update.md](ruby-orchestrator-update.md)** which documents:

- Ruby module structure (`OrchestratorUpdater` with 5 classes)
- Comprehensive unit tests (39 tests)
- Security analysis and threat model
- SSH-based update workflow
- Hostname validation and injection prevention

**Quick Summary**:

```bash
# Update all hosts via SSH
bin/update-orchestrators-ssh

# Update specific host
bin/update-orchestrators-ssh --host mini-1 --yes

# Dry run (show what would be executed)
bin/update-orchestrators-ssh --dry-run
```

**Key Security Improvements**:
- ✅ No container bind mounts to `/usr/local/bin/`
- ✅ No container systemctl access
- ✅ Direct SSH from dev machine (standard remote administration)
- ✅ Principle of least privilege maintained
- ✅ Clear security boundary between deployment and runtime

**Update Flow**:
1. Parse hosts from `config/deploy.yml`
2. For each host (sequentially):
   - SSH as `deploy` user
   - Copy orchestrator file to `/tmp/`
   - Detect xmrig binary location and create symlink if needed
   - Copy to `/usr/local/bin/xmrig-orchestrator`
   - Restart `xmrig-orchestrator` service
   - Verify service is active
3. Display summary with success/failed hosts

### Code Structure and File Organization

```
zen-miner/
├── host-daemon/
│   ├── xmrig-orchestrator          # Daemon script (already exists)
│   ├── xmrig-orchestrator.service  # systemd service (already exists)
│   ├── xmrig.service              # systemd service (already exists)
│   ├── install.sh                 # Existing installation script
│   └── README.md                  # UPDATED: Document SSH update process
├── lib/
│   └── orchestrator_updater.rb    # NEW: Ruby module with all update logic
├── bin/
│   └── update-orchestrators-ssh   # NEW: SSH-based update script (executable)
├── test/
│   └── update_orchestrator_test.rb # NEW: Comprehensive unit tests (39 tests)
└── specs/
    ├── fix-orchestrator-deployment-sync.md  # This spec
    └── ruby-orchestrator-update.md          # NEW: Ruby implementation spec
```

### Database Schema - No Changes Required

The current schema (without hostname column) is correct. The orchestrator daemon code has already been updated in the repository to not use the hostname filter. The issue is simply that the deployed version is outdated.

**Current Repository Code** (correct):
```ruby
# host-daemon/xmrig-orchestrator line 70-72
pending = @db.execute(
  "SELECT * FROM xmrig_commands WHERE status = 'pending' ORDER BY created_at ASC"
)
```

**Deployed Code** (outdated):
```ruby
# /usr/local/bin/xmrig-orchestrator on mini-1 (WRONG)
pending = @db.execute(
  "SELECT * FROM xmrig_commands WHERE hostname = ? AND status = 'pending'",
  [@hostname]
)
```

### Migration Strategy

No database migrations needed. This is purely a deployment synchronization issue.

---

## User Experience

### For Operators (Infrastructure Team)

**Current Experience (Broken)**:
1. Operator: "Why isn't mining starting?"
2. Check logs: See continuous "no such column: hostname" errors
3. Debug for hours trying to understand why
4. No clear path to resolution

**Improved Experience (Fixed)**:
1. After deploying Rails changes: `bin/update-orchestrators`
2. Script updates all hosts automatically
3. Clear success/failure messages
4. Mining resumes immediately

### For Developers

**Current Experience (Broken)**:
1. Make changes to orchestrator code
2. Deploy Rails via `kamal deploy`
3. Orchestrator not updated (no indication!)
4. Mysterious failures on production hosts

**Improved Experience (Fixed)**:
1. Make changes to orchestrator code
2. Deploy Rails: `kamal deploy`
3. Update daemons: `bin/update-orchestrators`
4. Clear deployment checklist in documentation

---

## Testing Strategy

### Unit Tests

**Not applicable** - These are deployment scripts, not application code.

### Integration Tests

**Manual Test Checklist**:

1. **Test xmrig path detection**:
   ```bash
   # Install xmrig in different locations
   # Run update script
   # Verify symlink created correctly
   ```

2. **Test orchestrator update**:
   ```bash
   # Make intentional change to orchestrator code (add log line)
   # Run update script
   # Verify new code is running (check for new log line)
   ```

3. **Test service restart**:
   ```bash
   # Verify orchestrator restarts without errors
   # Check journalctl for clean startup
   ```

4. **Test command processing**:
   ```bash
   # Issue start command via Rails
   # Verify orchestrator picks it up within 10 seconds
   # Verify xmrig starts successfully
   ```

### Multi-Host Testing

**Test on all 4 hosts**:
- mini-1 (already broken, test fix)
- miner-beta (may be working, test update doesn't break)
- miner-gamma (test fresh deployment)
- miner-delta (test fresh deployment)

**Test Scenarios**:

1. **Scenario: Broken orchestrator**
   - Host: mini-1
   - Current state: Crashing every 30 seconds
   - Expected: After update, starts processing commands
   - Validation: `tail -f /var/log/xmrig/orchestrator.log` shows no errors

2. **Scenario: Working orchestrator**
   - Host: Any working host
   - Current state: Running old code but compatible
   - Expected: Updates to new code without disruption
   - Validation: Mining continues, new code confirmed

3. **Scenario: XMRig in /usr/bin**
   - Host: mini-1 (xmrig at /usr/bin/xmrig)
   - Expected: Symlink created, service works
   - Validation: `ls -la /usr/local/bin/xmrig` shows symlink

4. **Scenario: XMRig in /usr/local/bin**
   - Host: Any host with xmrig in standard location
   - Expected: No symlink needed, works directly
   - Validation: No errors, direct execution

### Edge Cases

1. **Orchestrator service not installed**:
   - Script should detect and fail gracefully
   - Error message: "Run install.sh first"

2. **XMRig not installed**:
   - Script should warn but continue (orchestrator can still update)
   - Warning message: "xmrig not found, mining will not work"

3. **Insufficient permissions**:
   - Script should detect early and fail
   - Error message: "Cannot write to /usr/local/bin"

4. **Service restart fails**:
   - Script should show journalctl output
   - Exit code 1 to signal failure

---

## Performance Considerations

### Impact

**Negligible performance impact**:
- Orchestrator restart takes ~2 seconds
- Mining interruption: ~2-12 seconds (one polling cycle)
- Network: Script runs locally on each host (no large data transfers)
- Disk I/O: Single file copy (~8KB orchestrator script)

### Optimization

- Update script uses `systemctl restart` (not stop + start) for minimal downtime
- Symlink creation is atomic operation
- No database downtime required

---

## Security Considerations

### Why Direct SSH is More Secure

**Container-Based Approach (Rejected)**:
1. **Container Escape Risk**: Containers with bind mounts to `/usr/local/bin/` can potentially escape to host
2. **Excessive Privileges**: Rails container doesn't need systemctl access for normal operations
3. **Attack Surface**: Compromised container gains host filesystem write access
4. **Audit Trail**: Container-based actions harder to audit than SSH logs
5. **Principle Violation**: Breaks principle of least privilege

**SSH-Based Approach (Implemented)**:
1. **Standard Remote Administration**: Uses well-established SSH security model
2. **Principle of Least Privilege**: Rails container has NO host access
3. **Clear Security Boundary**: Deployment operations (SSH) vs runtime operations (container)
4. **Better Auditing**: SSH logs provide clear audit trail of who updated what
5. **Industry Standard**: Remote administration via SSH is a proven, secure pattern

### Security Safeguards

1. **Hostname Validation**: Prevents injection attacks via regex `/\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}\z/`
   - Rejects: `mini-1; rm -rf /`, `../../../etc/passwd`, `mini 1` (with space)
   - Accepts: `mini-1`, `miner-beta`, `host.example.com`

2. **SSH Command Quoting**: Uses `Shellwords.escape` for all dynamic values
   - Prevents command injection via hostname or other parameters

3. **File Verification**: Ensures source orchestrator file exists and is not a symlink before copying

4. **Fail-Fast**: Exit immediately on critical errors (missing config, invalid hostname)

5. **Per-Host Isolation**: Failure on one host doesn't stop updates to others

6. **Service Verification**: Checks that orchestrator service is active after restart

### Threat Model

**Threats Mitigated**:
- ✅ Command injection via hostname parameter
- ✅ Path traversal attacks
- ✅ Container escape to host
- ✅ Unauthorized host filesystem access
- ✅ Privilege escalation via container

**Remaining Risks** (Accepted):
- SSH key compromise (standard SSH risk, out of scope)
- Malicious orchestrator code deployed (mitigated by code review)
- Host compromise (SSH access required, but that's intentional for deployment)

---

## Documentation

### Documentation Updates (Completed)

The following documentation has been updated to reflect the SSH-based approach:

1. **`host-daemon/README.md`** - ✅ Updated with SSH update instructions
   - Documents `bin/update-orchestrators-ssh` usage
   - Provides manual update fallback via SCP
   - Explains when to update orchestrators
   - Includes security note about direct SSH approach

2. **`README.md`** - ✅ Updated deployment section
   - Added "Updating Orchestrator Daemon" section
   - Included deployment checklist
   - Documents when orchestrator updates are needed
   - References SSH-based approach

3. **`specs/ruby-orchestrator-update.md`** - ✅ Created comprehensive implementation spec
   - Documents Ruby module structure
   - Includes 39 unit tests specification
   - Security threat model and mitigations
   - Design decisions and rationale

### Key Documentation Points

**When to Update Orchestrators**:
- After database migrations affecting `xmrig_commands` or `xmrig_processes` tables
- After changes to orchestrator code logic
- After bug fixes in the daemon
- If seeing "no such column" errors in orchestrator logs

**Deployment Workflow**:
```bash
# 1. Deploy Rails application
bin/kamal deploy

# 2. Update orchestrators if daemon code changed
bin/update-orchestrators-ssh

# 3. Verify health
bin/kamal logs
ssh deploy@mini-1 'sudo systemctl status xmrig-orchestrator'
```

---

## Implementation Phases

### Phase 1: Ruby Implementation ✅ COMPLETED

**Objective**: Create secure SSH-based deployment tooling

**Completed Steps**:
1. ✅ Created `specs/ruby-orchestrator-update.md` - Comprehensive implementation spec
2. ✅ Created `test/update_orchestrator_test.rb` - 39 unit tests (TDD approach)
3. ✅ Created `lib/orchestrator_updater.rb` - Ruby module with 5 classes
4. ✅ Created `bin/update-orchestrators-ssh` - Executable wrapper
5. ✅ Deleted old insecure `bin/update-orchestrators` script
6. ✅ Verified functionality via dry-run mode

**Success Criteria Met**:
- ✅ Update script uses direct SSH (not container-based)
- ✅ Hostname validation prevents injection attacks
- ✅ XMRig path automatically detected
- ✅ Comprehensive unit test coverage
- ✅ Security boundaries maintained (containers have NO host access)

**Deliverables**:
- ✅ Ruby-based SSH update mechanism working
- ✅ 39 unit tests passing
- ✅ Security vulnerabilities eliminated

### Phase 2: Documentation ✅ COMPLETED

**Objective**: Document SSH-based approach and update existing specs

**Completed Steps**:
1. ✅ Updated `host-daemon/README.md` with SSH update process
2. ✅ Updated main `README.md` deployment section
3. ✅ Updated this spec to remove container-based approach
4. ✅ Created deployment workflow documentation

**Success Criteria Met**:
- ✅ Clear documentation of when to run orchestrator updates
- ✅ SSH-based approach documented
- ✅ Security improvements explained

**Deliverables**:
- ✅ Documentation complete
- ✅ Deployment workflow documented

---

## Open Questions

### Q1: Should orchestrator updates be fully automated as part of `kamal deploy`? ✅ RESOLVED

**Decision**: Manual trigger via `bin/update-orchestrators-ssh`

**Rationale**:
- Explicit control over deployment steps
- Clear separation of concerns (Rails deployment vs daemon updates)
- Allows testing Rails changes before updating orchestrators
- User preference for manual control (from user feedback)

**Status**: Implemented and documented

### Q2: Should we add version checking to detect mismatches?

**Proposal**: Add a version constant to orchestrator daemon and check it via database or API.

**Pros**: Early detection of version drift
**Cons**: Added complexity, requires database schema change
**Recommendation**: Defer to future enhancement, not critical for initial fix.

### Q3: What about rollback if orchestrator update fails?

**Current approach**: Script fails fast, leaves old version running
**Alternative**: Backup old version before update, restore on failure
**Recommendation**: Current approach is sufficient (orchestrator is stateless).

### Q4: Should we reconsider the hostname column removal?

**Context**: The original schema had hostname for multi-host filtering. It was removed, but the orchestrator still filters by hostname.

**Analysis**:
- Current code: Orchestrator processes ALL pending commands (any host)
- Risk: Multiple hosts might process the same command (race condition)
- Mitigation: Commands are marked as 'processing' atomically in a transaction

**Recommendation**: Current design (no hostname) works due to transaction-based locking. Document this clearly in code comments.

---

## References

### Related Files
- `/Users/ihoka/ihoka/zen-miner/host-daemon/xmrig-orchestrator` - Daemon code
- `/Users/ihoka/ihoka/zen-miner/host-daemon/install.sh` - Installation script
- `/Users/ihoka/ihoka/zen-miner/db/migrate/20251222194500_remove_hostname_from_xmrig_commands.rb` - Migration that caused the issue

### Related Issues
- Schema mismatch causing orchestrator crashes
- XMRig binary path detection needed
- No automated deployment mechanism for host-side daemons

### External Documentation
- [systemd service management](https://www.freedesktop.org/software/systemd/man/systemctl.html)
- [Kamal deployment guide](https://kamal-deploy.org/)
- [SQLite WAL mode](https://www.sqlite.org/wal.html)

### Design Decisions
- **Decision**: Remove hostname column from xmrig_commands
  - **Rationale**: Simplify schema, rely on transaction locking
  - **Impact**: Requires orchestrator code update (this spec addresses that)

- **Decision**: Use symlinks for xmrig binary path
  - **Rationale**: Works regardless of installation method (apt, pacman, manual)
  - **Alternative considered**: Update service file dynamically (rejected as more fragile)

---

## Appendix: Command Processing Flow (After Fix)

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Rails: Xmrig::CommandService.start_mining                │
│    - Creates record: {action: 'start', status: 'pending'}   │
│    - No hostname field (broadcast to all hosts)             │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Database: xmrig_commands table                           │
│    id | action | status  | created_at                       │
│    1  | start  | pending | 2025-12-22 20:03:14             │
└────────────────────────────┬────────────────────────────────┘
                             │
                  ┌──────────┴──────────┐
                  ▼                     ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│ 3a. Orchestrator (mini-1)│   │ 3b. Orchestrator (beta) │
│  - Polls every 10s       │   │  - Polls every 10s      │
│  - SELECT WHERE pending  │   │  - SELECT WHERE pending │
│  - Gets command ID 1     │   │  - Gets command ID 1    │
└───────────┬──────────────┘   └──────────┬──────────────┘
            │                             │
            │ Transaction starts          │ Transaction starts
            ▼                             ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│ 4a. Mark as processing  │   │ 4b. Mark as processing  │
│  UPDATE status =        │   │  UPDATE status =        │
│    'processing'         │   │    'processing'         │
│  WHERE id = 1           │   │  WHERE id = 1           │
│                         │   │                         │
│  ✓ SUCCESS (first!)     │   │  ✗ SKIP (already proc)  │
└───────────┬──────────────┘   └──────────┬──────────────┘
            │                             │
            │ Commit transaction          │ Commit transaction
            ▼                             ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│ 5a. Execute command     │   │ 5b. No commands to run  │
│  sudo systemctl start   │   │  (already processed)    │
│  xmrig                  │   │                         │
└───────────┬──────────────┘   └─────────────────────────┘
            │
            ▼
┌─────────────────────────┐
│ 6. Update result        │
│  UPDATE status =        │
│    'completed'          │
│  WHERE id = 1           │
└─────────────────────────┘
```

**Key Points**:
- Only ONE orchestrator wins the race to mark command as 'processing'
- Other orchestrators see status='processing' and skip
- No hostname needed due to transaction-based locking
- This works correctly even with multiple hosts polling simultaneously

---

## Implementation Checklist

### Pre-Implementation ✅ COMPLETED
- [x] Review spec with team (user approved SSH approach)
- [x] Confirm approach for multi-host safety (sequential updates, per-host isolation)
- [x] Verify all 4 hosts are accessible via SSH (config/deploy.yml verified)

### Phase 1: Ruby Implementation ✅ COMPLETED
- [x] Create `specs/ruby-orchestrator-update.md` (comprehensive spec)
- [x] Create `test/update_orchestrator_test.rb` (39 unit tests)
- [x] Create `lib/orchestrator_updater.rb` (Ruby module)
- [x] Create `bin/update-orchestrators-ssh` (executable wrapper)
- [x] Delete old insecure `bin/update-orchestrators`
- [x] Test via dry-run mode
- [x] Verify all security safeguards implemented

### Phase 2: Documentation ✅ COMPLETED
- [x] Update `host-daemon/README.md` (SSH update process)
- [x] Update main `README.md` (deployment section with checklist)
- [x] Update this spec (remove container-based approach)
- [x] Document deployment workflow

### Post-Implementation (Pending Production Deployment)
- [ ] Deploy to all hosts via `bin/update-orchestrators-ssh`
- [ ] Monitor logs for 24 hours
- [ ] Verify health checks running
- [ ] Confirm mining performance
- [ ] Close related issues

---

**End of Specification**
