# P2Pool Monero Mining Setup Guide for Linux

A complete guide to setting up decentralized Monero mining with P2Pool on Linux.

## What is P2Pool?

P2Pool is a decentralized mining pool that combines the advantages of pool and solo mining. Key benefits:

- **0% fees** - no pool operator taking a cut
- **Trustless** - funds are never in custody, payouts go directly to your wallet
- **Decentralized** - no central server that can be shutdown or attacked
- **Permissionless** - no one can decide who can or can't mine

P2Pool uses a sidechain (with 10-second block times) to track shares. When a P2Pool miner finds a valid Monero block, all miners with shares in the PPLNS window get paid directly in the coinbase transaction.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Monero Main Chain                         │
│                    (block time: ~2 min)                      │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │ Valid blocks submitted
                              │
┌─────────────────────────────────────────────────────────────┐
│                    P2Pool Sidechain                          │
│                    (block time: 10 sec)                      │
│                                                              │
│  ┌──────┐    ┌──────┐    ┌──────┐    ┌──────┐              │
│  │Share │───▶│Share │───▶│Share │───▶│Share │  ...         │
│  │  1   │    │  2   │    │  3   │    │  4   │              │
│  └──────┘    └──────┘    └──────┘    └──────┘              │
│                                                              │
│         PPLNS Window: 2160 blocks (~6 hours)                │
└─────────────────────────────────────────────────────────────┘
                              ▲
          ┌───────────────────┼───────────────────┐
          │                   │                   │
    ┌─────┴─────┐       ┌─────┴─────┐       ┌─────┴─────┐
    │  P2Pool   │◄─────▶│  P2Pool   │◄─────▶│  P2Pool   │
    │   Node    │  p2p  │   Node    │  p2p  │   Node    │
    └─────┬─────┘       └─────┬─────┘       └─────┬─────┘
          │                   │                   │
    ┌─────┴─────┐       ┌─────┴─────┐       ┌─────┴─────┐
    │  monerod  │       │  monerod  │       │  monerod  │
    └───────────┘       └───────────┘       └───────────┘
          ▲                   ▲                   ▲
          │                   │                   │
    ┌─────┴─────┐       ┌─────┴─────┐       ┌─────┴─────┐
    │   XMRig   │       │   XMRig   │       │   XMRig   │
    └───────────┘       └───────────┘       └───────────┘
```

## Prerequisites

- Linux server (Ubuntu/Debian recommended)
- 50-70GB disk space (for pruned blockchain)
- A dedicated Monero wallet address (primary address starting with `4`, not a subaddress)
- Open firewall ports: 18080, 37889 (or 37888 for mini)

> **Important:** Create a new wallet specifically for P2Pool mining. Your wallet address is public on the P2Pool network.

---

## Option 1: Manual Installation

### Step 1: Install Monero Daemon

```bash
# Create directory structure
sudo mkdir -p /opt/monero
cd /opt/monero

# Download latest monerod (check getmonero.org for current version)
wget https://downloads.getmonero.org/cli/linux64
tar -xjf linux64

# Move binary to system path
sudo mv monero-x86_64-linux-gnu-*/monerod /usr/local/bin/
sudo mv monero-x86_64-linux-gnu-*/monero-wallet-cli /usr/local/bin/

# Verify installation
monerod --version
```

### Step 2: Install P2Pool

```bash
# Download latest release (check GitHub for current version)
cd /opt
wget https://github.com/SChernykh/p2pool/releases/latest/download/p2pool-v4.4-linux-x64.tar.gz
tar -xzf p2pool-v4.4-linux-x64.tar.gz

# Move binary to system path
sudo mv p2pool-v4.4-linux-x64/p2pool /usr/local/bin/

# Verify installation
p2pool --version
```

### Step 3: Install XMRig

```bash
# Download latest release
cd /opt
wget https://github.com/xmrig/xmrig/releases/latest/download/xmrig-6.21.0-linux-x64.tar.gz
tar -xzf xmrig-6.21.0-linux-x64.tar.gz

# Move binary to system path
sudo mv xmrig-6.21.0/xmrig /usr/local/bin/

# Verify installation
xmrig --version
```

### Step 4: Quick Start (Manual)

Run each command in a separate terminal:

**Terminal 1 - Start monerod:**
```bash
monerod --zmq-pub tcp://127.0.0.1:18083 \
        --out-peers 32 \
        --in-peers 64 \
        --prune-blockchain \
        --disable-dns-checkpoints \
        --enable-dns-blocklist
```

Wait for blockchain to sync (several hours on first run). You'll see "SYNCHRONIZED OK" when ready.

**Terminal 2 - Start P2Pool (after monerod syncs):**
```bash
# For hashrate < 100 KH/s, use mini sidechain
p2pool --host 127.0.0.1 --wallet YOUR_WALLET_ADDRESS --mini

# For hashrate > 100 KH/s, use main sidechain
p2pool --host 127.0.0.1 --wallet YOUR_WALLET_ADDRESS
```

Wait for P2Pool sidechain to sync. You'll see "SideChain new chain tip" when ready.

**Terminal 3 - Start XMRig:**
```bash
xmrig -o 127.0.0.1:3333
```

---

## Option 2: Docker Compose Installation

Create the directory and compose file:

```bash
mkdir -p ~/p2pool
cd ~/p2pool
nano docker-compose.yml
```

Paste this configuration:

```yaml
version: '3.8'

services:
  monerod:
    image: sethsimmons/simple-monerod:latest
    restart: unless-stopped
    volumes:
      - monero-data:/home/monero/.bitmonero
    ports:
      - "18080:18080"  # p2p
      - "18089:18089"  # restricted RPC
    command: >-
      --rpc-restricted-bind-ip=0.0.0.0
      --rpc-restricted-bind-port=18089
      --no-igd
      --no-zmq
      --zmq-pub=tcp://0.0.0.0:18083
      --out-peers=32
      --in-peers=64
      --prune-blockchain
      --enable-dns-blocklist
      --disable-dns-checkpoints

  p2pool:
    image: sethsimmons/p2pool:latest
    restart: unless-stopped
    depends_on:
      - monerod
    ports:
      - "3333:3333"    # stratum for miners
      - "37888:37888"  # p2pool-mini p2p
    volumes:
      - p2pool-data:/home/p2pool
    command: >-
      --wallet YOUR_WALLET_ADDRESS
      --stratum 0.0.0.0:3333
      --p2p 0.0.0.0:37888
      --host monerod
      --rpc-port 18089
      --mini

volumes:
  monero-data:
  p2pool-data:
```

Start the services:

```bash
docker compose up -d

# Watch logs
docker compose logs -f monerod
docker compose logs -f p2pool
```

---

## Production Setup with Systemd

### Step 1: Create System Users

```bash
# Create users with no login shell for security
sudo useradd -r -s /bin/false monero
sudo useradd -r -s /bin/false p2pool
sudo useradd -r -s /bin/false xmrig

# Create data directories
sudo mkdir -p /var/lib/monero
sudo mkdir -p /var/lib/p2pool

# Set ownership
sudo chown monero:monero /var/lib/monero
sudo chown p2pool:p2pool /var/lib/p2pool
```

### Step 2: Create monerod Service

```bash
sudo nano /etc/systemd/system/monerod.service
```

Paste this:

```ini
[Unit]
Description=Monero Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=monero
Group=monero
WorkingDirectory=/var/lib/monero

ExecStart=/usr/local/bin/monerod \
    --data-dir=/var/lib/monero \
    --log-file=/var/lib/monero/monerod.log \
    --log-level=0 \
    --non-interactive \
    --prune-blockchain \
    --zmq-pub=tcp://127.0.0.1:18083 \
    --out-peers=32 \
    --in-peers=64 \
    --disable-dns-checkpoints \
    --enable-dns-blocklist

Restart=always
RestartSec=30

# Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Step 3: Create P2Pool Service

```bash
sudo nano /etc/systemd/system/p2pool.service
```

Paste this (replace `YOUR_WALLET_ADDRESS`):

```ini
[Unit]
Description=P2Pool Monero Mining
After=monerod.service
Requires=monerod.service

[Service]
Type=simple
User=p2pool
Group=p2pool
WorkingDirectory=/var/lib/p2pool

ExecStart=/usr/local/bin/p2pool \
    --host 127.0.0.1 \
    --wallet YOUR_WALLET_ADDRESS \
    --mini \
    --loglevel 2 \
    --data-api /var/lib/p2pool

Restart=always
RestartSec=10

# Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Step 4: Create XMRig Service

```bash
sudo nano /etc/systemd/system/xmrig.service
```

Paste this:

```ini
[Unit]
Description=XMRig Miner
After=p2pool.service
Requires=p2pool.service

[Service]
Type=simple
User=xmrig
Group=xmrig
WorkingDirectory=/opt/xmrig

ExecStart=/usr/local/bin/xmrig \
    -o 127.0.0.1:3333 \
    --no-color \
    --randomx-1gb-pages

Restart=always
RestartSec=10

# Allow huge pages
AmbientCapabilities=CAP_SYS_ADMIN
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
```

### Step 5: Configure Huge Pages

For optimal XMRig performance:

```bash
# Enable huge pages system-wide
echo "vm.nr_hugepages=1280" | sudo tee /etc/sysctl.d/99-hugepages.conf
sudo sysctl -p /etc/sysctl.d/99-hugepages.conf

# Verify
cat /proc/meminfo | grep Huge
```

### Step 6: Enable and Start Services

```bash
# Reload systemd
sudo systemctl daemon-reload

# Enable on boot
sudo systemctl enable monerod
sudo systemctl enable p2pool
sudo systemctl enable xmrig

# Start monerod first (needs to sync)
sudo systemctl start monerod

# Check status and watch sync progress
sudo systemctl status monerod
sudo journalctl -u monerod -f
```

Once monerod is synced, start the other services:

```bash
sudo systemctl start p2pool
sudo systemctl start xmrig

# Check all services
sudo systemctl status monerod p2pool xmrig
```

---

## Firewall Configuration

```bash
# Allow Monero p2p
sudo ufw allow 18080/tcp

# Allow P2Pool p2p (main)
sudo ufw allow 37889/tcp

# Allow P2Pool p2p (mini)
sudo ufw allow 37888/tcp

# Allow stratum (only if mining from other machines)
sudo ufw allow 3333/tcp

# Enable firewall
sudo ufw enable
```

---

## Mini vs Main Sidechain

| Aspect | Main | Mini |
|--------|------|------|
| Difficulty | Higher | ~100x lower |
| Share frequency | Less often | More often |
| Best for | >100 KH/s | <100 KH/s |
| P2P Port | 37889 | 37888 |
| Flag | (default) | `--mini` |

Rewards over time are roughly equal between both sidechains. Mini just gives you more frequent (smaller) shares, which is better for lower hashrate miners.

---

## Monitoring

### Check Your Stats

- **Main sidechain:** https://p2pool.observer
- **Mini sidechain:** https://mini.p2pool.observer

Search for your wallet address to see shares found and estimated payouts.

### Useful Commands

```bash
# Check all services status
sudo systemctl status monerod p2pool xmrig

# View recent logs
sudo journalctl -u monerod -n 50
sudo journalctl -u p2pool -n 50
sudo journalctl -u xmrig -n 50

# Follow logs in real-time
sudo journalctl -u p2pool -f

# Stop mining but keep node running
sudo systemctl stop xmrig

# Restart after config changes
sudo systemctl restart p2pool

# Check monerod sync status
monerod status
```

### P2Pool Local API

If you enabled `--data-api`, you can check local stats:

```bash
# Pool stats
cat /var/lib/p2pool/stats

# Your miner stats
cat /var/lib/p2pool/local/miner
```

---

## Connecting Multiple Miners

You can connect multiple machines to a single P2Pool node:

```bash
# On remote mining machines, point XMRig to your P2Pool node
xmrig -o YOUR_P2POOL_NODE_IP:3333
```

Make sure port 3333 is open on the P2Pool machine's firewall.

---

## Troubleshooting

### monerod won't start
- Check disk space: `df -h`
- Check logs: `sudo journalctl -u monerod -n 100`
- Verify binary permissions: `ls -la /usr/local/bin/monerod`

### P2Pool can't connect to monerod
- Ensure monerod is fully synced
- Check monerod is running: `sudo systemctl status monerod`
- Verify ZMQ is enabled in monerod command

### No shares found
- Check XMRig is connected: look for "accepted" in logs
- Verify P2Pool is synced: look for "SideChain new chain tip"
- Be patient - shares take time, especially on mini with low hashrate

### Low hashrate
- Enable huge pages (see Step 5 above)
- Check CPU temperature (throttling?)
- Ensure no other heavy processes running

---

## Security Considerations

1. **Use a dedicated mining wallet** - addresses are public on P2Pool
2. **Run services as unprivileged users** - never run as root
3. **Keep software updated** - especially after Monero network upgrades
4. **Firewall everything** - only open required ports
5. **Monitor your node** - watch for unusual activity

---

## Useful Links

- P2Pool GitHub: https://github.com/SChernykh/p2pool
- P2Pool Observer: https://p2pool.observer
- Monero Downloads: https://getmonero.org/downloads
- XMRig GitHub: https://github.com/xmrig/xmrig
