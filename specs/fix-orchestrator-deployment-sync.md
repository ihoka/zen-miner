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
│  3. NEW: kamal app exec update-orchestrator.sh  │ ← New mechanism
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────┐
│ Remote Host (mini-1)                            │
│                                                  │
│  ┌────────────────────────────────────┐         │
│  │ Rails Container                     │         │
│  │ - Contains update-orchestrator.sh   │         │
│  │ - Can write to /usr/local/bin/      │         │
│  └────────────────────────────────────┘         │
│                   │                              │
│                   │ Executes on host             │
│                   ▼                              │
│  ┌────────────────────────────────────┐         │
│  │ Update Script (Host-side)          │         │
│  │ 1. Detect xmrig binary location    │         │
│  │ 2. Update orchestrator daemon      │         │
│  │ 3. Update xmrig.service path       │         │
│  │ 4. Restart orchestrator service    │         │
│  └────────────────────────────────────┘         │
│                   │                              │
│                   ▼                              │
│  ┌────────────────────────────────────┐         │
│  │ Orchestrator Daemon (CURRENT!)     │  ✓ WORKS
│  │ - Queries: WHERE status = 'pending'│  ✓ COMPATIBLE
│  │ - Auto-updated on deploy           │         │
│  └────────────────────────────────────┘         │
└─────────────────────────────────────────────────┘
```

### Implementation Approach

**Objective**: Create an automated deployment mechanism that updates the orchestrator daemon on all hosts

**Implementation Files**:

1. **`host-daemon/update-orchestrator.sh`** - Script to update orchestrator on current host
2. **`bin/update-orchestrators`** - Rails script to deploy update across all hosts
3. **Update to `install.sh`** - Add xmrig path detection

**File 1: `host-daemon/update-orchestrator.sh`**
```bash
#!/bin/bash
# Updates the orchestrator daemon on the current host
# Designed to be copied into Docker image and executed via kamal app exec

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Updating XMRig Orchestrator"
echo "=========================================="
echo "Host: $(hostname)"
echo ""

# Verify we're running with appropriate permissions
if [ ! -w /usr/local/bin ]; then
  echo "ERROR: Cannot write to /usr/local/bin"
  echo "This script must run as root or with appropriate sudo"
  exit 1
fi

# 1. Detect xmrig binary location
echo "[1/4] Detecting xmrig binary location..."
XMRIG_PATH=$(which xmrig 2>/dev/null || echo "")

if [ -z "$XMRIG_PATH" ]; then
  echo "   WARNING: xmrig not found in PATH"
  echo "   Mining will not work until xmrig is installed"
else
  echo "   ✓ Found xmrig at: $XMRIG_PATH"

  # Create symlink if needed
  if [ "$XMRIG_PATH" != "/usr/local/bin/xmrig" ] && [ -f "$XMRIG_PATH" ]; then
    echo "   Creating symlink: /usr/local/bin/xmrig -> $XMRIG_PATH"
    ln -sf "$XMRIG_PATH" /usr/local/bin/xmrig
    echo "   ✓ Symlink created"
  fi
fi

# 2. Update orchestrator daemon
echo "[2/4] Updating orchestrator daemon..."
if [ -f "${SCRIPT_DIR}/xmrig-orchestrator" ]; then
  cp "${SCRIPT_DIR}/xmrig-orchestrator" /usr/local/bin/xmrig-orchestrator
  chmod +x /usr/local/bin/xmrig-orchestrator
  echo "   ✓ Orchestrator updated"
else
  echo "   ERROR: xmrig-orchestrator not found in ${SCRIPT_DIR}"
  exit 1
fi

# 3. Verify orchestrator service exists
echo "[3/4] Verifying orchestrator service..."
if ! systemctl list-unit-files | grep -q xmrig-orchestrator.service; then
  echo "   ERROR: xmrig-orchestrator.service not found"
  echo "   Run install.sh first to install the orchestrator"
  exit 1
fi
echo "   ✓ Service file exists"

# 4. Restart service
echo "[4/4] Restarting orchestrator..."
systemctl restart xmrig-orchestrator

# Give it a moment to start
sleep 2

# Check status
if systemctl is-active --quiet xmrig-orchestrator; then
  echo "   ✓ Orchestrator is running"
else
  echo "   ✗ Orchestrator failed to start. Check logs:"
  echo "     journalctl -u xmrig-orchestrator -n 50"
  exit 1
fi

echo ""
echo "=========================================="
echo "Update Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  - Check logs: journalctl -u xmrig-orchestrator -f"
echo "  - Test command: Xmrig::CommandService.start_mining"
echo ""
```

**File 2: `bin/update-orchestrators`** - Rails script for mass update
```bash
#!/bin/bash
# Deploy orchestrator updates to all hosts
# Usage: bin/update-orchestrators

set -e

echo "=========================================="
echo "Deploying Orchestrator Updates"
echo "=========================================="
echo ""

# Get list of hosts from Kamal config
HOSTS=$(kamal config | grep -A 10 "hosts:" | grep "^  -" | awk '{print $2}')

if [ -z "$HOSTS" ]; then
  echo "ERROR: No hosts found in Kamal config"
  exit 1
fi

echo "Updating orchestrators on:"
for host in $HOSTS; do
  echo "  - $host"
done
echo ""

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted"
  exit 1
fi

# Deploy to each host via Kamal
for host in $HOSTS; do
  echo ""
  echo "===================="
  echo "Updating: $host"
  echo "===================="

  # Execute update script on host
  # Note: This runs in a container but the script has access to host via bind mounts
  kamal app exec --hosts "$host" 'bash /rails/host-daemon/update-orchestrator.sh' || {
    echo "✗ Failed to update $host"
    exit 1
  }

  echo "✓ $host updated successfully"
done

echo ""
echo "=========================================="
echo "All Orchestrators Updated!"
echo "=========================================="
```

**File 3: Update to `install.sh`** - Add xmrig detection
```bash
# Add after line 103 (after xmrig version check)

# Detect xmrig installation path
XMRIG_BINARY=$(which xmrig)
echo "   ✓ XMRig found at: $XMRIG_BINARY"

# Create symlink if xmrig is not in expected location
if [ "$XMRIG_BINARY" != "/usr/local/bin/xmrig" ]; then
  echo "   Creating symlink to standard location..."
  sudo ln -sf "$XMRIG_BINARY" /usr/local/bin/xmrig
  echo "   ✓ Symlink created: /usr/local/bin/xmrig -> $XMRIG_BINARY"
fi
```

### Code Structure and File Organization

```
zen-miner/
├── host-daemon/
│   ├── xmrig-orchestrator          # Daemon script (already exists)
│   ├── xmrig-orchestrator.service  # systemd service (already exists)
│   ├── xmrig.service              # systemd service (already exists)
│   ├── install.sh                 # UPDATED: Add xmrig path detection
│   ├── update-orchestrator.sh     # NEW: Update script for host
│   └── README.md                  # UPDATED: Document update process
├── bin/
│   └── update-orchestrators       # NEW: Deploy updates to all hosts
└── specs/
    └── fix-orchestrator-deployment-sync.md  # This spec
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

### Security Implications

1. **Script Execution Privileges**:
   - Update script requires root access to write `/usr/local/bin/`
   - Mitigated by: Script runs as root in Kamal exec context (already trusted)

2. **Symlink Creation**:
   - Creating symlink could theoretically be exploited if xmrig binary is malicious
   - Mitigated by: Script verifies xmrig exists before symlinking
   - Additional mitigation: Could add SHA256 checksum verification (future enhancement)

3. **Service Restart**:
   - Restarting orchestrator could allow command injection if daemon code is malicious
   - Mitigated by: Daemon code is reviewed and version-controlled

### Safeguards

1. **Fail-fast approach**: Script exits immediately on any error
2. **Verification steps**: Checks service status after restart
3. **Logging**: All actions logged to stdout for audit trail
4. **No network access**: Script doesn't download anything from internet

---

## Documentation

### Files to Create/Update

1. **`host-daemon/README.md`** - Add section:
   ```markdown
   ## Updating the Orchestrator Daemon

   When code changes are made to the orchestrator daemon, it must be manually updated on all hosts since it runs outside the Docker container.

   ### Automated Update (Recommended)

   From your local machine:
   ```bash
   # Update all hosts at once
   bin/update-orchestrators
   ```

   ### Manual Update (Single Host)

   SSH to the host and run:
   ```bash
   # Copy from repo
   scp host-daemon/xmrig-orchestrator deploy@mini-1:/tmp/

   # On the host
   sudo cp /tmp/xmrig-orchestrator /usr/local/bin/
   sudo chmod +x /usr/local/bin/xmrig-orchestrator
   sudo systemctl restart xmrig-orchestrator
   ```
   ```

2. **`README.md`** - Update deployment section:
   ```markdown
   ## Deployment

   ### Rails Application
   ```bash
   kamal deploy
   ```

   ### Host Orchestrator Daemon

   After making changes to `host-daemon/xmrig-orchestrator`:
   ```bash
   bin/update-orchestrators
   ```
   ```

3. **`docs/DEPLOYMENT.md`** - New comprehensive deployment guide

### Inline Documentation

All new scripts should include:
- Header comment explaining purpose
- Usage examples
- Prerequisites
- Expected behavior
- Error scenarios

---

## Implementation Phases

### Phase 1: Automated Update Mechanism

**Objective**: Create deployment tooling to update the orchestrator on all hosts

**Steps**:
1. Create `host-daemon/update-orchestrator.sh`
2. Create `bin/update-orchestrators`
3. Update `install.sh` with xmrig path detection
4. Test on one host (mini-1)
5. Deploy to all remaining hosts

**Success Criteria**:
- Update script works on all hosts
- XMRig path automatically detected
- Orchestrator updates without manual intervention
- All hosts operational after update

**Deliverables**:
- ✓ Automated update mechanism working
- ✓ All hosts updated and operational
- ✓ Mining commands processing successfully

### Phase 2: Documentation & Process Integration

**Objective**: Integrate into standard deployment workflow

**Steps**:
1. Update `host-daemon/README.md` with update process
2. Update main `README.md` deployment section
3. Create deployment runbook
4. Document when to run orchestrator updates

**Success Criteria**:
- Team knows when to run update-orchestrators
- Process documented clearly
- Future schema changes won't break orchestrator

**Deliverables**:
- ✓ Documentation complete
- ✓ Deployment runbook created

---

## Open Questions

### Q1: Should orchestrator updates be fully automated as part of `kamal deploy`?

**Options**:
1. **Manual trigger** (current proposal): Requires running `bin/update-orchestrators` separately
2. **Automatic with confirmation**: `kamal deploy` detects changes and prompts
3. **Fully automatic**: Always updates orchestrator on every deploy

**Recommendation**: Start with manual trigger (option 1) for safety, consider automation later based on stability.

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

### Pre-Implementation
- [ ] Review spec with team
- [ ] Confirm approach for multi-host safety
- [ ] Verify all 4 hosts are accessible via SSH

### Phase 1: Automated Updates
- [ ] Create `host-daemon/update-orchestrator.sh`
- [ ] Create `bin/update-orchestrators`
- [ ] Update `install.sh` with xmrig detection
- [ ] Test on single host (mini-1)
- [ ] Deploy to all hosts
- [ ] Verify all hosts operational

### Phase 2: Documentation
- [ ] Update `host-daemon/README.md`
- [ ] Update main `README.md`
- [ ] Create deployment runbook
- [ ] Add to development guide

### Post-Implementation
- [ ] Monitor logs for 24 hours
- [ ] Verify health checks running
- [ ] Confirm mining performance
- [ ] Close related issues

---

**End of Specification**
