# AGENTS.md
This file provides guidance to AI coding assistants working in this repository.

**Note:** CLAUDE.md, .clinerules, .cursorrules, .windsurfrules, .replit.md, GEMINI.md, .github/copilot-instructions.md, and .idx/airules.md are symlinks to AGENTS.md in this project.

# ZenCash Mining Rig

A cryptocurrency mining configuration repository for Monero mining using XMRig. This is an operational/deployment configuration project, not a software development project.

## Project Overview

- **Purpose**: Configure and run Monero mining operations via XMRig
- **Task Runner**: Mise (Rust-based task/environment manager)
- **Mining Pool**: HashVault Pro (pool.hashvault.pro:443)
- **Dependencies**: XMRig must be installed and available in PATH

## Build & Commands

This project uses [Mise](https://mise.jdx.dev/) for task management.

### Available Tasks

| Command | Description |
|---------|-------------|
| `mise run mine` | Start CPU mining (default) |
| `mise run mine:cpu` | Start CPU-only mining |
| `mise run mine:gpu` | Start GPU-only mining (OpenCL/CUDA) |
| `mise run mine:hybrid` | Start hybrid CPU+GPU mining |

### Mining Task Details

All mining tasks use XMRig JSON configuration files from the `configs/` directory:
- Pool: `pool.hashvault.pro:443`
- TLS: Enabled with fingerprint verification
- Donate level: 1%

### Configuration Profiles

| Config | File | Use Case |
|--------|------|----------|
| CPU | `configs/cpu.json` | Standard CPU mining |
| GPU | `configs/gpu.json` | GPU mining via OpenCL/CUDA |
| Hybrid | `configs/hybrid.json` | Combined CPU+GPU mining |

### Prerequisites

1. **Install Mise**: Follow [Mise installation guide](https://mise.jdx.dev/getting-started.html)
2. **Install XMRig**: Ensure `xmrig` binary is available in PATH
3. **Verify configuration**: Check `mise.toml` for current settings

## Configuration

### Environment Variables

The following environment variable is configured in `mise.toml`:

| Variable | Description |
|----------|-------------|
| `MONERO_WALLET` | Destination wallet address for mining rewards |

### Configuration Files

| File | Purpose |
|------|---------|
| `mise.toml` | Task definitions and environment variables |
| `configs/cpu.json` | XMRig CPU mining configuration |
| `configs/gpu.json` | XMRig GPU mining configuration |
| `configs/hybrid.json` | XMRig hybrid CPU+GPU configuration |
| `.claude/settings.local.json` | Claude Code local settings (not committed) |

## Code Style

- **Configuration format**: TOML for Mise configuration
- **Documentation**: Markdown format
- **Repository structure**: Minimal, focused on operational configuration

## Security

### Sensitive Data Handling

- **Wallet addresses**: Stored in `mise.toml` - review before committing changes
- **Pool fingerprints**: TLS fingerprint verification is enabled for secure connections
- **No secrets in code**: Avoid committing private keys or sensitive credentials

### Best Practices

- Review changes to `mise.toml` carefully before committing
- Verify pool TLS fingerprints from official sources
- Keep XMRig updated to the latest stable version

## Directory Structure & File Organization

```
xmrig/
├── AGENTS.md           # AI assistant guidance (this file)
├── CLAUDE.md           # Symlink to AGENTS.md
├── README.md           # Project documentation
├── mise.toml           # Mise task configuration
├── configs/            # XMRig configuration files
│   ├── cpu.json        # CPU mining config
│   ├── gpu.json        # GPU mining config
│   └── hybrid.json     # Hybrid CPU+GPU config
├── reports/            # Project reports and documentation
│   └── README.md       # Reports directory guide
├── .github/
│   └── copilot-instructions.md  # Symlink to AGENTS.md
├── .idx/
│   └── airules.md      # Symlink to AGENTS.md
└── .claude/
    └── settings.local.json  # Local Claude settings (gitignored)
```

### Reports Directory

ALL project reports and documentation should be saved to the `reports/` directory:

**Report Types:**
- Configuration changes: `CONFIG_CHANGE_[DATE].md`
- Performance logs: `MINING_PERFORMANCE_[DATE].md`
- Setup documentation: `SETUP_GUIDE_[TOPIC].md`

### Temporary Files & Debugging

For any temporary files or debugging:
- Create a `/temp` folder (gitignored)
- Use for logs, test outputs, debugging scripts
- Clean up regularly

### Example `.gitignore` patterns

```
# Temporary files
/temp/
temp/
*.log

# Claude settings (local only)
.claude/settings.local.json

# Don't ignore reports
!reports/
!reports/**
```

## Testing

This is a configuration repository without automated tests. Validation is done through:

1. **Syntax validation**: Ensure `mise.toml` has valid TOML syntax and `configs/*.json` files have valid JSON
2. **Dry run**: Review XMRig output before extended mining sessions
3. **Pool connectivity**: Verify connection to mining pool

## Agent Delegation & Tool Execution

### Available Agents

For this repository, the following agents are most relevant:

| Agent | Use Case |
|-------|----------|
| `devops-expert` | Infrastructure and deployment questions |
| `documentation-expert` | Documentation improvements |
| `git-expert` | Version control operations |

### Key Principles

- **Minimal changes**: This is a configuration repo - avoid unnecessary modifications
- **Security focus**: Review all changes involving wallet addresses or pool settings
- **Documentation**: Update README.md when configuration changes

### Parallel Tool Execution

When performing multiple operations, execute them in parallel when possible:
- Multiple file reads
- Independent searches
- Non-dependent validations

**Sequential only when:** One operation's output is required for the next operation's input.
