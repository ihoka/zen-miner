# Zen Miner

An open source Rails application for orchestrating cryptocurrency mining rigs. Manage multiple XMRig miners from a centralized web interface with real-time monitoring and configuration management.

## Features

- **Multi-Rig Orchestration**: Manage multiple mining rigs from a single dashboard
- **Real-Time Monitoring**: WebSocket-powered live updates via Action Cable
- **XMRig Integration**: Full support for CPU, GPU, and hybrid mining configurations
- **Zero-Downtime Deployments**: Kamal-based container deployments across multiple servers
- **PWA-Ready**: Progressive Web App support for mobile access
- **Background Jobs**: Solid Queue for reliable job processing

## Tech Stack

- **Framework**: Ruby on Rails 8.1
- **Ruby Version**: 3.4.5
- **Database**: SQLite3 (with Solid Cache, Solid Queue, Solid Cable)
- **Frontend**: Hotwire (Turbo + Stimulus)
- **Asset Pipeline**: Propshaft with Import Maps
- **Deployment**: Kamal with Docker
- **Web Server**: Puma with Thruster

## Getting Started

### Prerequisites

- Ruby 3.4.5
- SQLite3
- XMRig (for mining operations)

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/zen-miner.git
   cd zen-miner
   ```

2. Install dependencies:
   ```bash
   bundle install
   ```

3. Setup the database:
   ```bash
   bin/rails db:setup
   ```

4. Start the development server:
   ```bash
   bin/dev
   ```

5. Visit `http://localhost:3000`

### Running Tests

```bash
# Run all tests
bin/rails test

# Run system tests
bin/rails test:system
```

## Configuration

### Mining Configurations

XMRig configuration files are stored in `configs/`:

| File | Purpose |
|------|---------|
| `configs/cpu.json` | CPU-only mining |
| `configs/gpu.json` | GPU mining (OpenCL/CUDA) |
| `configs/hybrid.json` | Combined CPU+GPU mining |

### Environment Variables

Configure via Rails credentials or environment variables:

| Variable | Description |
|----------|-------------|
| `RAILS_MASTER_KEY` | Rails encrypted credentials key |
| `MONERO_WALLET` | Destination wallet address |

## Deployment

Zen Miner uses [Kamal](https://kamal-deploy.org/) for container deployments.

### Quick Deploy

```bash
# First-time setup
bin/kamal setup

# Deploy latest changes
bin/kamal deploy

# View logs
bin/kamal logs

# Access Rails console
bin/kamal console
```

### Production Architecture

- Multi-server deployment behind Cloudflare
- Persistent SQLite storage via Docker volumes
- Health checks at `/up` endpoint
- Automatic SSL via Cloudflare

See `config/deploy.yml` for full configuration.

## Development

### Directory Structure

```
zen-miner/
├── app/                    # Application code
│   ├── controllers/        # Request handlers
│   ├── models/             # Database models
│   ├── views/              # HTML templates
│   ├── javascript/         # Stimulus controllers
│   └── jobs/               # Background jobs
├── config/                 # Configuration
│   ├── deploy.yml          # Kamal deployment
│   └── database.yml        # Database settings
├── configs/                # XMRig mining configs
├── db/                     # Database migrations
├── specs/                  # Feature specifications
└── test/                   # Test suite
```

### Code Quality

The project uses:
- **RuboCop** with Rails Omakase style
- **Brakeman** for security scanning
- **Bundler Audit** for dependency vulnerabilities

Run all checks:
```bash
bin/rubocop
bin/brakeman
bundle exec bundler-audit
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is open source. See the LICENSE file for details.

## Acknowledgments

- [XMRig](https://xmrig.com/) - High performance Monero miner
- [Kamal](https://kamal-deploy.org/) - Deploy web apps anywhere
- [Hotwire](https://hotwired.dev/) - HTML over the wire
