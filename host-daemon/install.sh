#!/bin/bash
# XMRig Orchestrator Installation Script
# Installs XMRig, orchestrator daemon, and systemd services

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

# Default values
POOL_URL="${POOL_URL:-pool.hashvault.pro:443}"
CPU_MAX_THREADS_HINT="${CPU_MAX_THREADS_HINT:-50}"
XMRIG_VERSION="${XMRIG_VERSION:-6.21.0}"

echo "Configuration:"
echo "  Pool: $POOL_URL"
echo "  CPU threads hint: $CPU_MAX_THREADS_HINT%"
echo "  XMRig version: $XMRIG_VERSION"
echo ""

# Install dependencies
echo "[1/8] Installing dependencies..."
apt-get update -qq
apt-get install -y ruby sqlite3 curl wget tar

# Download and install XMRig
echo "[2/8] Downloading XMRig v${XMRIG_VERSION}..."
XMRIG_TARBALL="xmrig-${XMRIG_VERSION}-linux-x64.tar.gz"
XMRIG_URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/${XMRIG_TARBALL}"

wget -q "$XMRIG_URL" -O "/tmp/${XMRIG_TARBALL}"
tar -xzf "/tmp/${XMRIG_TARBALL}" -C /tmp
mv "/tmp/xmrig-${XMRIG_VERSION}/xmrig" /usr/local/bin/xmrig
chmod +x /usr/local/bin/xmrig
rm -rf "/tmp/xmrig-${XMRIG_VERSION}"* "/tmp/${XMRIG_TARBALL}"

echo "   ✓ XMRig installed to /usr/local/bin/xmrig"

# Create xmrig user
echo "[3/8] Creating xmrig system user..."
if id "xmrig" &>/dev/null; then
  echo "   ✓ User 'xmrig' already exists"
else
  useradd -r -s /bin/false xmrig
  echo "   ✓ User 'xmrig' created"
fi

# Create directories
echo "[4/8] Creating directories..."
mkdir -p /var/log/xmrig
mkdir -p /etc/xmrig
mkdir -p /mnt/rails-storage
chown xmrig:xmrig /var/log/xmrig
echo "   ✓ Directories created"

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
      "pass": "$(hostname)-production",
      "rig-id": "$(hostname)-production",
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
echo "  1. Ensure Rails database is mounted at /mnt/rails-storage"
echo "     (This should be handled by Kamal volumes config)"
echo ""
echo "  2. Start the orchestrator:"
echo "     sudo systemctl start xmrig-orchestrator"
echo ""
echo "  3. Check status:"
echo "     sudo systemctl status xmrig-orchestrator"
echo "     sudo journalctl -u xmrig-orchestrator -f"
echo ""
echo "  4. Issue start command from Rails:"
echo "     Xmrig::CommandService.start_mining('$(hostname)')"
echo ""
