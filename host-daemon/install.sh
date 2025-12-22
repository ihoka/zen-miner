#!/bin/bash
# XMRig Orchestrator Installation Script
# Installs orchestrator daemon and systemd services
# Prerequisites: Ruby and XMRig must be installed and in PATH

set -e

echo "=========================================="
echo "XMRig Orchestrator Installation"
echo "=========================================="
echo "Installing on: $(hostname)"
echo ""

# Check for required environment variables
if [ -z "$MONERO_WALLET" ]; then
  echo "ERROR: MONERO_WALLET environment variable not set"
  echo "Please set it before running this script:"
  echo "  export MONERO_WALLET='your-wallet-address'"
  exit 1
fi

if [ -z "$WORKER_ID" ]; then
  echo "ERROR: WORKER_ID environment variable not set"
  echo "Please set it before running this script:"
  echo "  export WORKER_ID='your-worker-id'"
  exit 1
fi

# Validate Monero wallet address format
# Standard address: starts with 4, 95 chars
# Integrated address: starts with 4, 106 chars
# Subaddress: starts with 8, 95 chars
if [[ ! "$MONERO_WALLET" =~ ^[48][0-9A-Za-z]{94}$ ]] && [[ ! "$MONERO_WALLET" =~ ^4[0-9A-Za-z]{105}$ ]]; then
  echo "ERROR: Invalid Monero wallet address format"
  echo "Monero addresses must:"
  echo "  - Start with '4' (standard/integrated) or '8' (subaddress)"
  echo "  - Be 95 characters (standard/subaddress) or 106 characters (integrated)"
  echo "  - Contain only alphanumeric characters"
  echo ""
  echo "Your address: $MONERO_WALLET"
  echo "Length: ${#MONERO_WALLET}"
  exit 1
fi
echo "   ✓ Monero wallet address format validated"

# Default values
POOL_URL="${POOL_URL:-pool.hashvault.pro:443}"
CPU_MAX_THREADS_HINT="${CPU_MAX_THREADS_HINT:-50}"

echo "Configuration:"
echo "  Pool: $POOL_URL"
echo "  CPU threads hint: $CPU_MAX_THREADS_HINT%"
echo ""

# Verify required binaries are installed
echo "[1/8] Verifying prerequisites..."

if ! command -v ruby &> /dev/null; then
  echo "ERROR: Ruby not found in PATH"
  echo "Please install Ruby before running this script"
  exit 1
fi
echo "   ✓ Ruby found: $(ruby --version)"

# Install bundler system-wide (required for bundler/inline in daemon)
# Use --no-user-install to force system-wide installation
if ! gem list -i bundler >/dev/null 2>&1; then
  echo "   Installing bundler system-wide..."
  gem install bundler --no-document --no-user-install
else
  echo "   ✓ Bundler already installed"
fi

# Verify bundler is accessible
if ruby -e "require 'bundler/inline'" 2>/dev/null; then
  echo "   ✓ Bundler available for all users"
else
  echo "   ERROR: Bundler installation failed or not accessible"
  exit 1
fi

if ! command -v xmrig &> /dev/null; then
  echo "ERROR: XMRig not found in PATH"
  echo "Please install XMRig before running this script"
  exit 1
fi
echo "   ✓ XMRig found: $(xmrig --version | head -n1)"

# Install remaining dependencies
echo "[2/8] Installing system dependencies..."
if command -v pacman &> /dev/null; then
  # Arch Linux
  pacman -S --noconfirm --needed sqlite sudo
elif command -v apt-get &> /dev/null; then
  # Debian/Ubuntu
  apt-get update -qq
  apt-get install -y sqlite3 sudo
else
  echo "ERROR: Unsupported package manager. Please install sqlite3 and sudo manually."
  exit 1
fi

# Create xmrig user
echo "[3/8] Creating xmrig system user..."
if id "xmrig" &>/dev/null; then
  echo "   ✓ User 'xmrig' already exists"
else
  useradd -r -s /bin/false xmrig
  echo "   ✓ User 'xmrig' created"
fi

# Create xmrig-orchestrator user
echo "[3b/8] Creating xmrig-orchestrator system user..."
if id "xmrig-orchestrator" &>/dev/null; then
  echo "   ✓ User 'xmrig-orchestrator' already exists"
else
  useradd -r -s /bin/false xmrig-orchestrator
  echo "   ✓ User 'xmrig-orchestrator' created"
fi

# Configure sudo permissions for orchestrator (NOPASSWD for specific systemctl commands)
echo "[3c/8] Configuring sudo permissions for orchestrator..."
cat > /etc/sudoers.d/xmrig-orchestrator <<EOF
# Allow xmrig-orchestrator to manage xmrig service without password
xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl start xmrig
xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl stop xmrig
xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl restart xmrig
xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl is-active xmrig
xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl status xmrig
EOF
chmod 0440 /etc/sudoers.d/xmrig-orchestrator
echo "   ✓ Sudo permissions configured"

# Create directories
echo "[4/8] Creating directories..."
mkdir -p /var/log/xmrig
mkdir -p /etc/xmrig
mkdir -p /var/lib/xmrig-orchestrator/gems
chown xmrig:xmrig /var/log/xmrig
# Allow orchestrator user to write logs
chown xmrig-orchestrator:xmrig-orchestrator /var/log/xmrig/orchestrator.log 2>/dev/null || touch /var/log/xmrig/orchestrator.log && chown xmrig-orchestrator:xmrig-orchestrator /var/log/xmrig/orchestrator.log
# Give orchestrator ownership of its gem directory
chown -R xmrig-orchestrator:xmrig-orchestrator /var/lib/xmrig-orchestrator
echo "   ✓ Directories created"

# Set up Rails storage directory for database access
echo "[4b/8] Setting up Rails storage directory..."
mkdir -p /mnt/rails-storage
chmod 755 /mnt/rails-storage

# Create deploy group (used by Kamal for Docker volume access)
if ! getent group deploy >/dev/null; then
  groupadd deploy
  echo "   ✓ Created 'deploy' group"
else
  echo "   ✓ Group 'deploy' already exists"
fi

# Set ownership so both Docker (deploy user) and orchestrator can access
chown deploy:deploy /mnt/rails-storage

# Add xmrig-orchestrator to deploy group for database read access
usermod -a -G deploy xmrig-orchestrator
echo "   ✓ Rails storage directory configured (/mnt/rails-storage)"
echo "     - Owner: deploy:deploy"
echo "     - Permissions: 755"
echo "     - xmrig-orchestrator user added to deploy group"

# Generate XMRig config
echo "[5/8] Generating XMRig configuration..."
cat > /etc/xmrig/config.json <<EOF
{
  "autosave": true,
  "http": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 8080,
    "access-token": null,
    "restricted": true
  },
  "pools": [
    {
      "url": "${POOL_URL}",
      "user": "${MONERO_WALLET}",
      "pass": "${WORKER_ID}",
      "rig-id": "${WORKER_ID}",
      "tls": true,
      "keepalive": true
    }
  ],
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "priority": 1,
    "max-threads-hint": ${CPU_MAX_THREADS_HINT}
  },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "donate-level": 1
}
EOF
echo "   ✓ XMRig config written to /etc/xmrig/config.json"

# Install orchestrator daemon
echo "[6/8] Installing orchestrator daemon..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "${SCRIPT_DIR}/xmrig-orchestrator" /usr/local/bin/xmrig-orchestrator
chmod +x /usr/local/bin/xmrig-orchestrator
echo "   ✓ Orchestrator installed to /usr/local/bin/xmrig-orchestrator"

# Install systemd services
echo "[7/8] Installing systemd services..."
cp "${SCRIPT_DIR}/xmrig.service" /etc/systemd/system/xmrig.service
cp "${SCRIPT_DIR}/xmrig-orchestrator.service" /etc/systemd/system/xmrig-orchestrator.service
echo "   ✓ Service files copied to /etc/systemd/system/"

# Configure logrotate
echo "[8/8] Configuring log rotation..."
cat > /etc/logrotate.d/xmrig <<EOF
/var/log/xmrig/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 xmrig xmrig
}
EOF
echo "   ✓ Logrotate configured (7 day retention)"

# Reload systemd
systemctl daemon-reload

# Enable services (but don't start yet)
systemctl enable xmrig
systemctl enable xmrig-orchestrator

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "  1. Deploy Rails application via Kamal (from local machine):"
echo "     kamal deploy"
echo ""
echo "  2. Initialize database (first deploy only):"
echo "     kamal app exec 'bin/rails db:migrate'"
echo ""
echo "  3. Start the orchestrator on this host:"
echo "     sudo systemctl start xmrig-orchestrator"
echo ""
echo "  4. Check orchestrator status:"
echo "     sudo systemctl status xmrig-orchestrator"
echo "     sudo journalctl -u xmrig-orchestrator -f"
echo ""
echo "  5. Issue start command from Rails:"
echo "     Xmrig::CommandService.start_mining('${WORKER_ID}')"
echo ""
echo "Database location: /mnt/rails-storage/production.sqlite3"
echo "  (will be created by Rails on first deploy)"
echo ""
