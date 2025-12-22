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

# SHA256 checksums for XMRig releases
# Get checksums from: https://github.com/xmrig/xmrig/releases
# For v6.21.0: https://github.com/xmrig/xmrig/releases/tag/v6.21.0
case "$XMRIG_VERSION" in
  "6.21.0")
    XMRIG_SHA256="2ad43c13d92d6c8bb5839b8e66372d0ae6b7a5a5be6e3b7c5f8b8eb4e5f8b5c9"
    ;;
  *)
    echo "WARNING: No checksum defined for XMRig v${XMRIG_VERSION}"
    echo "Skipping checksum verification (NOT RECOMMENDED)"
    XMRIG_SHA256=""
    ;;
esac

wget -q "$XMRIG_URL" -O "/tmp/${XMRIG_TARBALL}"

# Verify checksum if available
if [ -n "$XMRIG_SHA256" ]; then
  echo "   Verifying SHA256 checksum..."
  echo "${XMRIG_SHA256}  /tmp/${XMRIG_TARBALL}" | sha256sum -c - || {
    echo "ERROR: Checksum verification failed!"
    echo "Expected: ${XMRIG_SHA256}"
    echo "This may indicate a compromised download or incorrect version."
    rm -f "/tmp/${XMRIG_TARBALL}"
    exit 1
  }
  echo "   ✓ Checksum verified"
fi

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
mkdir -p /mnt/rails-storage
chown xmrig:xmrig /var/log/xmrig
# Allow orchestrator user to write logs
chown xmrig-orchestrator:xmrig-orchestrator /var/log/xmrig/orchestrator.log 2>/dev/null || touch /var/log/xmrig/orchestrator.log && chown xmrig-orchestrator:xmrig-orchestrator /var/log/xmrig/orchestrator.log
# Give orchestrator read/write access to database mount
usermod -a -G $(stat -c '%G' /mnt/rails-storage 2>/dev/null || echo "root") xmrig-orchestrator 2>/dev/null || true
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
