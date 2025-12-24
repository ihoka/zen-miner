# Multiplatform Dynamic WORKER_ID Generation

## Status
Draft

## Authors
- Claude Code Assistant
- Date: 2025-12-16

## Overview

Implement cross-platform dynamic generation of `WORKER_ID` based on the system hostname. The worker ID is used to identify mining rigs in pool dashboards and must work consistently across Windows, macOS, and Linux while producing valid worker names that conform to mining pool requirements.

## Background/Problem Statement

### Current State
The `WORKER_ID` is currently hardcoded as `"MacBookPro"` in `mise.toml` (line 8). This creates several issues:

1. **Manual Updates Required**: Each machine running this configuration requires manual modification of the worker ID
2. **Configuration Drift**: When deploying to multiple machines, it's easy to forget to update the worker ID, leading to all machines reporting as the same worker
3. **Pool Dashboard Confusion**: Without unique worker IDs, pool statistics aggregate all machines into one, making it impossible to monitor individual rig performance

### Historical Context
A previous implementation (commit `8cd6d2a`) attempted dynamic hostname detection using mise's `_.source` shell scripting feature. This was later simplified to a static value (commit `f2b838b`), possibly due to:
- Complexity of cross-platform shell compatibility
- Mise's `_.source` behavior differences across platforms
- Need for more robust sanitization of hostnames

### Core Problem
Mining operators need automatic, unique identification of each mining rig without manual configuration per machine, while ensuring the generated worker IDs are valid for mining pool protocols.

## Goals

- Automatically detect and use the system hostname as the worker ID
- Support all three major platforms: Windows, macOS, and Linux
- Sanitize hostnames to produce valid worker names (alphanumeric, hyphens, underscores only)
- Provide a sensible fallback when hostname detection fails
- Maintain backward compatibility with existing mining tasks
- Keep the solution simple and maintainable within mise.toml

## Non-Goals

- Custom worker ID prefixes or suffixes (can be added later)
- Persistent worker ID storage across hostname changes
- GUI or interactive configuration
- Support for exotic platforms (BSD, embedded systems)
- Worker ID registration or validation against pool APIs

## Technical Dependencies

### Required
- **Mise** (v2024.x or later): Task runner with environment variable templating
  - Documentation: https://mise.jdx.dev/
  - Feature used: `_.source` for shell script execution in environment setup
- **XMRig** (v6.x): Mining software accepting `-p` parameter for worker identification

### Platform-Specific Dependencies
| Platform | Hostname Source | Fallback |
|----------|-----------------|----------|
| Linux | `$HOSTNAME` env var, `hostname` command | `hostname -s` |
| macOS | `$HOSTNAME` env var, `hostname` command | `scutil --get ComputerName` |
| Windows (Git Bash/WSL) | `$COMPUTERNAME` env var | `hostname` command |

### Character Validation
Mining pools typically accept worker names matching: `^[a-zA-Z0-9_-]+$`
- Maximum length: 32 characters (pool-dependent, HashVault allows up to 64)
- No spaces, special characters, or Unicode

## Detailed Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      mise.toml                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  [env]                                               │    │
│  │  _.source = """                                      │    │
│  │    ┌──────────────────────────────────────────────┐ │    │
│  │    │  1. Detect platform                          │ │    │
│  │    │  2. Get hostname (platform-specific)         │ │    │
│  │    │  3. Sanitize (remove invalid chars)          │ │    │
│  │    │  4. Truncate (max 32 chars)                  │ │    │
│  │    │  5. Export WORKER_ID                         │ │    │
│  │    └──────────────────────────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────┘    │
│                            │                                 │
│                            ▼                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  [tasks."mine:cpu"]                                  │    │
│  │  xmrig -o $POOL_URL -u $MONERO_WALLET -p $WORKER_ID │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Implementation Approach

The solution uses mise's `_.source` directive to execute a POSIX-compliant shell script that:

1. **Detects the hostname** using a platform-aware cascade:
   - First checks `$HOSTNAME` (set on most Linux/macOS systems)
   - Then checks `$COMPUTERNAME` (set on Windows)
   - Falls back to the `hostname` command
   - Ultimate fallback: generates a unique ID based on timestamp

2. **Sanitizes the hostname** to ensure pool compatibility:
   - Removes all characters except `a-z`, `A-Z`, `0-9`, `_`, `-`
   - Truncates to 32 characters maximum
   - Converts empty results to a fallback value

3. **Exports as environment variable** for use in mining tasks

### Code Structure and Implementation

**File: `mise.toml`**

```toml
[tools]

[env]
XMRIG_PATH = "/Users/ihoka/crypto/xmrig-6.24.0"
_.path = { path = ["{{env.XMRIG_PATH}}"], tools = true }
MONERO_WALLET = "41y5Qg2H7YgK42nnsRUpuTLTC5th9GhwRgzqgPaVk5V4bpGd22W8XVc8Tz31dK8mLjQo67BW7HQUGRZPCEEkANyMRUYVxcb"
POOL_URL = "pool.hashvault.pro:443"

# Dynamic WORKER_ID generation - Cross-platform hostname detection
_.source = """
# Detect hostname across platforms (Linux, macOS, Windows/WSL/Git Bash)
get_hostname() {
    # Try environment variables first (fastest)
    if [ -n "${HOSTNAME:-}" ]; then
        printf '%s' "$HOSTNAME"
        return
    fi

    if [ -n "${COMPUTERNAME:-}" ]; then
        printf '%s' "$COMPUTERNAME"
        return
    fi

    # Try hostname command
    if command -v hostname >/dev/null 2>&1; then
        hostname 2>/dev/null && return
    fi

    # macOS fallback using scutil
    if command -v scutil >/dev/null 2>&1; then
        scutil --get ComputerName 2>/dev/null && return
    fi

    # Ultimate fallback: generate unique ID
    printf 'worker-%s' "$(date +%s | tail -c 6)"
}

# Get and sanitize hostname
RAW_HOSTNAME=$(get_hostname)

# Sanitize: keep only alphanumeric, underscore, hyphen
# Then truncate to 32 characters for pool compatibility
WORKER_ID=$(printf '%s' "$RAW_HOSTNAME" | tr -cd 'a-zA-Z0-9_-' | cut -c1-32)

# Handle empty result after sanitization
if [ -z "$WORKER_ID" ]; then
    WORKER_ID="worker-$(date +%s | tail -c 6)"
fi

export WORKER_ID
"""

[tasks."mine:cpu"]
run = [
    "{{env.XMRIG_PATH}}/xmrig -o {{env.POOL_URL}} -u {{env.MONERO_WALLET}} -p {{env.WORKER_ID}}",
]
description = "Start CPU-only mining"

[tasks."mine:gpu"]
run = [
    "{{env.XMRIG_PATH}}/xmrig --config configs/gpu.json -o {{env.POOL_URL}} -u {{env.MONERO_WALLET}} -p {{env.WORKER_ID}}",
]
description = "Start GPU-only mining (OpenCL/CUDA)"

[tasks."mine:hybrid"]
run = [
    "{{env.XMRIG_PATH}}/xmrig --config configs/hybrid.json -o {{env.POOL_URL}} -u {{env.MONERO_WALLET}} -p {{env.WORKER_ID}}",
]
description = "Start hybrid CPU+GPU mining"
```

### Platform-Specific Behavior

| Platform | Detection Method | Example Hostname | Sanitized Output |
|----------|-----------------|------------------|------------------|
| Linux | `$HOSTNAME` | `ubuntu-server-01` | `ubuntu-server-01` |
| macOS | `$HOSTNAME` | `Johns-MacBook-Pro.local` | `Johns-MacBook-Prolocal` |
| Windows (Git Bash) | `$COMPUTERNAME` | `DESKTOP-ABC123` | `DESKTOP-ABC123` |
| Windows (WSL) | `$HOSTNAME` | `DESKTOP-ABC123` | `DESKTOP-ABC123` |
| Docker Container | `hostname` cmd | `a1b2c3d4e5f6` | `a1b2c3d4e5f6` |

### Edge Cases Handled

1. **Hostname with special characters**: `my.server@home!` → `myserverhome`
2. **Hostname with spaces** (rare): `My Computer` → `MyComputer`
3. **Very long hostname**: Truncated to 32 characters
4. **Empty hostname after sanitization**: Falls back to `worker-XXXXXX`
5. **Unicode hostname**: All non-ASCII characters stripped
6. **Hostname is just dots/special chars**: Falls back to generated ID

### API Changes

No API changes. The `WORKER_ID` environment variable interface remains the same; only its value source changes from static to dynamic.

### Data Model Changes

None. This is a runtime configuration change only.

## User Experience

### Before (Current)
```bash
$ mise run mine:cpu
# Always reports as "MacBookPro" regardless of actual machine
```

### After (Proposed)
```bash
# On a machine named "mining-rig-01"
$ mise run mine:cpu
# Reports as "mining-rig-01" to the pool

# On a machine named "GPU-Server-2"
$ mise run mine:cpu
# Reports as "GPU-Server-2" to the pool
```

### Verification
Users can verify their worker ID before mining:
```bash
$ mise env | grep WORKER_ID
WORKER_ID=mining-rig-01
```

## Testing Strategy

### Unit Tests (Manual Verification)

Since this is a configuration-only change with no application code, testing is performed manually:

**Test 1: Basic Hostname Detection**
- Purpose: Verify hostname is correctly detected on the current platform
- Command: `mise env | grep WORKER_ID`
- Expected: Output shows sanitized hostname

**Test 2: Sanitization Validation**
- Purpose: Ensure special characters are properly removed
- Setup: Temporarily set `HOSTNAME="test.host@name!123"`
- Command: `HOSTNAME="test.host@name!123" mise env | grep WORKER_ID`
- Expected: `WORKER_ID=testhostname123`

**Test 3: Length Truncation**
- Purpose: Verify long hostnames are truncated to 32 characters
- Setup: `HOSTNAME="this-is-a-very-long-hostname-that-exceeds-32-chars"`
- Expected: `WORKER_ID=this-is-a-very-long-hostname-th`

**Test 4: Fallback on Empty**
- Purpose: Verify fallback when hostname results in empty string
- Setup: `HOSTNAME="..."`
- Expected: `WORKER_ID=worker-XXXXXX` (timestamp-based)

### Integration Tests

**Test 5: XMRig Connection**
- Purpose: Verify XMRig accepts the dynamically generated worker ID
- Command: `mise run mine:cpu` (let run for 30 seconds)
- Expected: XMRig connects successfully, pool dashboard shows correct worker name

### Cross-Platform Tests

| Platform | Test Environment | Validation Method |
|----------|------------------|-------------------|
| Linux | Ubuntu 22.04 | `mise env \| grep WORKER_ID` |
| macOS | macOS 14 (Sonoma) | `mise env \| grep WORKER_ID` |
| Windows | Git Bash on Win11 | `mise env \| grep WORKER_ID` |
| Windows | WSL2 Ubuntu | `mise env \| grep WORKER_ID` |

### Edge Case Tests

**Test 6: No hostname command available**
- Purpose: Verify scutil fallback works on macOS
- Method: Unset HOSTNAME, verify scutil is used

**Test 7: Docker container**
- Purpose: Verify short container IDs work correctly
- Method: Run mise in a Docker container

## Performance Considerations

### Impact
- **Startup Time**: Negligible (< 10ms for hostname detection)
- **Memory**: No additional memory usage
- **Runtime**: Zero impact - hostname detection occurs once at environment setup

### Optimizations
- Environment variables (`$HOSTNAME`, `$COMPUTERNAME`) are checked first as they're fastest
- Shell command execution only occurs if env vars are unset
- No network calls or file I/O required

## Security Considerations

### Hostname Exposure
- Worker IDs are visible to pool operators and may appear in public pool statistics
- Users with sensitive hostnames should set a custom `HOSTNAME` env var before running
- The sanitization process removes potentially exploitable characters

### Input Sanitization
- All hostname input is sanitized before use
- Only alphanumeric characters, hyphens, and underscores are allowed
- This prevents injection attacks through hostname manipulation

### Recommendations
- For privacy-conscious users, document how to override: `HOSTNAME=anonymous mise run mine:cpu`
- Consider adding a `WORKER_ID_OVERRIDE` env var for explicit customization

## Documentation

### Required Updates

1. **AGENTS.md / README.md**
   - Add section explaining dynamic WORKER_ID generation
   - Document override mechanism
   - Update environment variables table

2. **Example override documentation**:
   ```markdown
   ### Customizing Worker ID

   The worker ID is automatically generated from your hostname. To override:

   ```bash
   # One-time override
   HOSTNAME=my-custom-name mise run mine:cpu

   # Or set in your shell profile
   export HOSTNAME=mining-rig-01
   ```
   ```

## Implementation Phases

### Phase 1: Core Implementation (MVP)
- Implement the `_.source` script in `mise.toml`
- Test on macOS (primary development platform)
- Verify XMRig connects with dynamic worker ID
- Update documentation

### Phase 2: Cross-Platform Validation
- Test on Linux (Ubuntu/Debian)
- Test on Windows (Git Bash)
- Test on Windows (WSL2)
- Document any platform-specific quirks

### Phase 3: Enhancements (Optional)
- Add `WORKER_ID_PREFIX` env var for fleet identification (e.g., `dc1-` prefix)
- Add `WORKER_ID_OVERRIDE` for explicit customization
- Consider logging the generated worker ID on startup

## Open Questions

1. **Should we restore the GPU and hybrid mining tasks?**
   - The previous dynamic implementation included `mine:gpu` and `mine:hybrid` tasks
   - Current static implementation only has `mine:cpu`
   - Recommendation: Restore them for completeness

2. **Maximum worker ID length?**
   - Currently set to 32 characters
   - HashVault supports up to 64
   - Should we increase the limit?

3. **Override mechanism preference?**
   - Option A: Use `HOSTNAME` env var override
   - Option B: Add dedicated `WORKER_ID_OVERRIDE` env var
   - Option C: Both (WORKER_ID_OVERRIDE takes precedence)

4. **Logging/debugging?**
   - Should the script echo the detected worker ID for debugging?
   - Could add `echo "Worker ID: $WORKER_ID" >&2` for visibility

## References

- **Mise Documentation**: https://mise.jdx.dev/configuration.html#env
- **Mise _.source Feature**: https://mise.jdx.dev/configuration.html#env-source
- **XMRig Configuration**: https://xmrig.com/docs/miner/config
- **HashVault Pool**: https://monero.hashvault.pro/
- **Previous Implementation**: Commit `8cd6d2a` in this repository
- **POSIX Shell Specification**: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html

## Appendix: Alternative Approaches Considered

### Alternative 1: External Script File
Create a separate `scripts/get-worker-id.sh` and source it:
```toml
_.source = "source ./scripts/get-worker-id.sh"
```
- **Pros**: Cleaner mise.toml, easier to test script in isolation
- **Cons**: Additional file to maintain, more complex deployment

### Alternative 2: Mise Plugin
Create a custom mise plugin for worker ID management.
- **Pros**: Reusable across projects, cleaner interface
- **Cons**: Overkill for this use case, maintenance overhead

### Alternative 3: Pre-execution Hook
Use XMRig's API to set worker name at runtime.
- **Pros**: Most flexible
- **Cons**: Requires additional tooling, complexity

**Decision**: Inline `_.source` script was chosen for simplicity and self-contained deployment.
