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
