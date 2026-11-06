# DDK VPS Manager 2 - Multi-Protocol Suite & Web Panel (Port 9090)

> **Official Repository**: https://github.com/mrshahnawazyt/DDK-VPS-Manager  
> **Web Panel Dashboard**: `http://YOUR_VPS_IP:9090`  
> **Terminal Control Command**: `ddk` or `vps`  
> **Default Admin Account**: Username: `admin` | Port: `9090`

---

## ⚡ Quick One-Line VPS Auto-Installer

Run this single command on your fresh Linux VPS (Ubuntu 20/22/24, Debian 10/11/12, CentOS/AlmaLinux) as `root`:

### 🌐 Method 1: Public GitHub Repository (Recommended)
```bash
apt update && apt install -y curl && curl -fsSL https://raw.githubusercontent.com/mrshahnawazyt/DDK-VPS-Manager/main/install.sh -o install.sh && bash install.sh
```

### 🔐 Method 2: Private GitHub Repository (with Token)
```bash
export GH_TOKEN=YOUR_GITHUB_TOKEN GH_REPO=DDK-VPS-Manager GH_OWNER=mrshahnawazyt; apt update && apt install -y curl && curl -fsSL -H "Authorization: token $GH_TOKEN" https://raw.githubusercontent.com/$GH_OWNER/$GH_REPO/main/install.sh -o install.sh && bash install.sh
```

---

## 🌐 Supported Protocols & Listening Ports Reference

This suite installs and automatically configures a high-performance multiplexed proxy stack:

| Service / Protocol | Port(s) | Description |
| :--- | :--- | :--- |
| **OpenSSH** | `22` | Native Linux administrative shell |
| **Dropbear SSH** | `109, 447` | Lightweight high-speed SSH daemon |
| **SSH-WebSocket (WS-Proxy)** | `80, 443, 2082, 2083, 2084, 2085` | Cloudflare CDN-compatible WebSocket proxy for SSH |
| **VMess (WebSocket / gRPC)** | `8442, 2082` | High-security multi-client VMess proxy |
| **VLESS (XTLS Reality / WS)** | `8443, 8446` | Ultra-fast censorship-resistant VLESS Reality Vision |
| **Trojan (WS / gRPC)** | `8445, 443` | TLS-camouflaged Trojan protocol |
| **HAProxy Multiplexer** | `80, 443` | High-availability load balancer offloading HTTP/HTTPS traffic |
| **Nginx Web Server** | `8080, 8081` | SSL certificate termination and reverse proxy |
| **DDK Web Panel** | `9090` | Real-time web browser control dashboard (Python 3 daemon) |

---

## 🖥️ Web Panel Features (Port 9090)

- **Real-Time Live Dashboard**: Displays live gauges for CPU load, RAM utilization, Disk space, and Network traffic.
- **SSH Accounts Manager**: Create and manage SSH/Dropbear accounts with IP limits, data transfer quotas, and expiry timers.
- **Xray Multi-Protocol Manager**: Instant generation of VMess, VLESS, and Trojan accounts with 1-click subscription links and mobile QR codes.
- **Service Controller**: Restart, stop, or inspect logs for HAProxy, Nginx, Dropbear, Xray, and WS-Proxy.
- **Network Speedtest**: Run on-demand server latency and throughput benchmarks.
- **Anti-Bufferbloat Ping QoS**: Optimize network queues to prevent latency spikes during high bandwidth usage.
- **Telegram Bot Notifications**: Automated Telegram alerts for account expiration and server resource warnings.

---

## 🚀 Post-Installation Usage

1. **Open the Web Panel in your browser**:
   ```text
   http://YOUR_SERVER_IP:9090
   ```

2. **Open the Control Menu in your VPS terminal**:
   ```bash
   ddk
   # or
   vps
   ```

3. **Check Service Status**:
   ```bash
   systemctl status ddk-panel
   systemctl status xray
   systemctl status dropbear
   systemctl status haproxy
   ```
