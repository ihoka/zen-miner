# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed - BREAKING

#### Installer Always Executes All Steps

**⚠️ BREAKING CHANGE**: The installer and updater scripts now ALWAYS execute all installation steps and restart services on every run, regardless of whether components are already installed or configured.

**What Changed:**
- Removed idempotency checks (`completed?` method) from all installer steps
- Configuration files are now ALWAYS overwritten with current environment variables
- Services are now ALWAYS restarted after installation/update
- XMRig path validation simplified (removed symlink creation)

**Impact:**
- Installation/update runs will take longer as they cannot skip already-configured steps
- Configuration files will be regenerated on every run (ensure environment variables are always set correctly)
- Services will experience brief downtime during updates (restart is automatic)
- Existing configuration customizations will be lost if not represented in environment variables

**Migration Guide:**
- No code changes required for users
- Ensure all required environment variables are set before running install/update:
  - `MONERO_WALLET`: Your Monero wallet address
  - `WORKER_ID`: Unique identifier for this worker
  - `POOL_URL`: Mining pool URL (optional, defaults to pool.hashvault.pro:443)
  - `CPU_MAX_THREADS_HINT`: CPU thread hint (optional, defaults to 50)
- Any manual customizations to `/etc/xmrig/config.json` will be overwritten
- Services will restart automatically - expect brief mining downtime during updates

**Why This Change:**
- Simplifies installer logic by eliminating complex idempotency checks
- Ensures configuration always matches current environment variables
- Guarantees services are running with latest code after updates
- Reduces edge cases where partial installations could occur

**Related:**
- See [specs/feat-simplify-installer-updater.md](specs/feat-simplify-installer-updater.md) for detailed design
- Pull Request: #8

### Fixed

- **Security**: Fixed race condition in config file generation (TOCTOU vulnerability)
  - Now uses atomic write with process-specific temp file
  - Proper cleanup on failure
- **Security**: Fixed potential shell injection in orchestrator updater
  - Properly escapes temp file paths before shell interpolation
  - Uses `Shellwords.escape` for safe shell command construction
- **Bug**: Corrected XMRig binary path from `/usr/local/bin/xmrig` to `/usr/bin/xmrig`
  - Removed symlink creation logic
  - Now verifies XMRig exists in PATH and validates version

### Added

- Test coverage for "always execute" behavior
  - `test_always_overwrites_existing_config` in ConfigGeneratorTest
  - `test_always_restarts_services` in SystemdInstallerTest
- Comprehensive test purpose documentation following project testing philosophy

### Removed

- All `completed?` methods from installer step classes:
  - BaseStep
  - ConfigGenerator
  - DaemonInstaller
  - DirectoryManager
  - LogrotateConfigurator
  - PrerequisiteChecker
  - SudoConfigurator
  - SystemdInstaller
  - UserManager
- Idempotency check logic from Orchestrator
- XMRig symlink creation logic from DaemonInstaller
- Related tests for `completed?` functionality

## [Previous Releases]

This is the first CHANGELOG entry. Previous releases were not documented in this format.
