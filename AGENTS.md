# AGENTS.md

This file provides guidance to AI coding assistants working in this repository.

**Note:** CLAUDE.md, .clinerules, .cursorrules, .windsurfrules, .replit.md, GEMINI.md, .github/copilot-instructions.md, and .idx/airules.md are symlinks to AGENTS.md.

## Project Overview

Zen Miner is an open source Rails 8.1 application for orchestrating cryptocurrency mining rigs. It provides a centralized web interface to manage multiple XMRig miners with real-time monitoring.

| Attribute | Value |
|-----------|-------|
| **Framework** | Ruby on Rails 8.1.1 |
| **Ruby Version** | 3.4.5 |
| **Database** | SQLite3 |
| **Frontend** | Hotwire (Turbo + Stimulus) |
| **Asset Pipeline** | Propshaft + Import Maps |
| **Background Jobs** | Solid Queue |
| **Caching** | Solid Cache |
| **WebSockets** | Solid Cable |
| **Deployment** | Kamal with Docker |

## Build & Commands

### Development

```bash
bin/dev                    # Start development server (Puma + assets)
bin/rails server           # Start Rails server only
bin/rails console          # Interactive Rails console
bin/rails test             # Run unit/integration tests
bin/rails test:system      # Run system tests (Capybara + Selenium)
```

### Code Quality

```bash
bin/rubocop                # Run RuboCop linter
bin/rubocop -A             # Auto-fix RuboCop issues
bin/brakeman               # Security vulnerability scan
bundle exec bundler-audit  # Gem vulnerability check
```

### Deployment (Kamal)

```bash
bin/kamal setup            # Bootstrap new server
bin/kamal deploy           # Deploy latest code
bin/kamal rollback         # Rollback to previous version
bin/kamal logs             # View container logs
bin/kamal console          # Access Rails console in production
bin/kamal shell            # SSH into container
```

### Database

```bash
bin/rails db:migrate       # Run pending migrations
bin/rails db:seed          # Load seed data
bin/rails db:reset         # Drop, create, migrate, seed
```

## Directory Structure

```
zen-miner/
├── app/
│   ├── controllers/       # Request handlers
│   ├── models/            # ActiveRecord models
│   ├── views/             # ERB templates
│   ├── javascript/        # Stimulus controllers
│   │   └── controllers/   # JS controller files
│   ├── jobs/              # Solid Queue background jobs
│   ├── helpers/           # View helpers
│   └── assets/            # CSS and images
├── config/
│   ├── deploy.yml         # Kamal deployment configuration
│   ├── database.yml       # Database settings
│   ├── routes.rb          # URL routing
│   ├── queue.yml          # Solid Queue configuration
│   ├── cache.yml          # Solid Cache configuration
│   ├── cable.yml          # Action Cable configuration
│   └── recurring.yml      # Scheduled job definitions
├── configs/               # XMRig mining configurations
│   ├── cpu.json           # CPU mining config
│   ├── gpu.json           # GPU mining config
│   └── hybrid.json        # Hybrid CPU+GPU config
├── db/
│   ├── migrate/           # Database migrations
│   ├── schema.rb          # Current schema
│   └── seeds.rb           # Seed data
├── specs/                 # Feature specification documents
├── test/                  # Test suite
│   ├── models/            # Model tests
│   ├── controllers/       # Controller tests
│   ├── system/            # System/integration tests
│   └── fixtures/          # Test fixtures
├── .github/workflows/     # GitHub Actions CI/CD
├── .kamal/                # Kamal hooks and secrets
├── Dockerfile             # Production container build
└── Gemfile                # Ruby dependencies
```

## Code Style

### Ruby

- Follow [Rails Omakase](https://github.com/rails/rubocop-rails-omakase) style
- Run `bin/rubocop` before committing
- Use `bin/rubocop -A` to auto-fix issues

### Key Conventions

- **Models**: Use ActiveRecord conventions, add validations and associations
- **Controllers**: Keep thin, delegate to models/services
- **Views**: Use ERB templates with Turbo Frames for dynamic updates
- **JavaScript**: Stimulus controllers only, no jQuery or vanilla JS sprawl
- **Jobs**: Inherit from `ApplicationJob`, use Solid Queue

### Naming

| Type | Convention | Example |
|------|------------|---------|
| Models | Singular, PascalCase | `MiningRig` |
| Controllers | Plural, PascalCase | `MiningRigsController` |
| Database tables | Plural, snake_case | `mining_rigs` |
| Routes | RESTful, plural | `/mining_rigs/:id` |
| Stimulus controllers | Kebab-case | `mining-status_controller.js` |

## Testing

### Test Framework

- **Rails Test Unit** for unit/integration tests
- **Capybara + Selenium** for system tests
- **Fixtures** for test data

### Running Tests

```bash
bin/rails test                        # All unit/integration tests
bin/rails test test/models/           # Model tests only
bin/rails test:system                 # System tests (browser)
bin/rails test test/models/mining_rig_test.rb:15  # Specific line
```

### Test Conventions

- One assertion per test when possible
- Use fixtures over factories
- System tests for critical user flows
- Name tests descriptively: `test "mining rig validates presence of name"`

## Security

### Sensitive Data

- **Never commit**: Wallet addresses, API keys, credentials
- **Use Rails credentials**: `bin/rails credentials:edit`
- **Environment variables**: For deployment configuration
- **Secrets management**: 1Password/Bitwarden integration via `.kamal/secrets`

### Security Scanning

- **Brakeman**: Runs on every PR via GitHub Actions
- **Bundler Audit**: Checks gem vulnerabilities
- **Importmap Audit**: Checks JavaScript dependencies

## Deployment Architecture

### Production Setup

- **Servers**: Multi-server deployment (configured in `config/deploy.yml`)
- **Proxy**: Cloudflare for SSL termination and CDN
- **Container**: Docker with multi-stage build
- **Storage**: Persistent Docker volumes for SQLite databases
- **Health Check**: `/up` endpoint for load balancer

### Database Strategy

SQLite with multiple databases:
- `production.sqlite3` - Application data
- `production_cache.sqlite3` - Solid Cache
- `production_queue.sqlite3` - Solid Queue
- `production_cable.sqlite3` - Action Cable

### CI/CD Pipeline

GitHub Actions workflow (`.github/workflows/ci.yml`):
1. **scan_ruby**: Brakeman + Bundler Audit
2. **scan_js**: Importmap audit
3. **lint**: RuboCop
4. **test**: Rails tests
5. **system-test**: Browser tests

## Agent Delegation

### Recommended Agents

| Agent | Use Case |
|-------|----------|
| `rails-expert` | Rails patterns, ActiveRecord, routing |
| `devops-expert` | Kamal deployment, Docker, infrastructure |
| `testing-expert` | Test structure, coverage, debugging |
| `git-expert` | Version control, branching, PRs |
| `documentation-expert` | README, guides, inline docs |
| `typescript-expert` | Stimulus controllers (if TypeScript added) |

### Key Principles

1. **Rails conventions**: Follow Rails Way, don't fight the framework
2. **Minimal changes**: Make focused changes, avoid scope creep
3. **Test coverage**: Add tests for new functionality
4. **Security first**: Review changes affecting auth, payments, or credentials
5. **Performance**: Consider N+1 queries, use `includes` for associations

### Parallel Execution

Execute in parallel when possible:
- Multiple file reads
- Independent search operations
- Non-dependent test runs

Sequential only when:
- Migration depends on previous migration
- Test setup required before test run
- Deploy depends on test passing

## Common Tasks

### Adding a New Model

```bash
bin/rails generate model MiningRig name:string status:integer ip_address:string
bin/rails db:migrate
```

### Adding a Stimulus Controller

```bash
bin/rails generate stimulus mining_status
```

Creates `app/javascript/controllers/mining_status_controller.js`

### Adding a Background Job

```bash
bin/rails generate job UpdateMiningStats
```

Creates `app/jobs/update_mining_stats_job.rb`

### Creating a Migration

```bash
bin/rails generate migration AddHashrateToMiningRigs hashrate:decimal
bin/rails db:migrate
```

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Assets not loading | Run `bin/rails assets:precompile` |
| Database locked | Check for zombie processes, restart server |
| Kamal deploy fails | Check `bin/kamal logs` and `.kamal/secrets` |
| Tests failing in CI | Ensure fixtures are consistent |

### Logs

- Development: `log/development.log`
- Test: `log/test.log`
- Production: `bin/kamal logs`
