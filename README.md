# DDK VPS Manager 2 - Multi-Protocol Suite & Web Panel (Port 9090)

> **Official Repository**: https://github.com/mrshahnawazyt/DDK-VPS-Manager  
> **Web Panel Dashboard**: `https://YOUR_DOMAIN:9090` (or `http://YOUR_VPS_IP:9090`)  
> **Terminal Control Command**: `ddk` or `vps`  
> **Default Admin Account**: Username: `admin` | Password: Auto-generated random & printed at install

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

## 🛠️ Step-by-Step Installation Workflow

1. **System & Public IP Check**: Verifies OS compatibility and retrieves your server's public IPv4.
2. **Interactive Domain Setup**:
   - The installer prompts: `Enter Domain / Subdomain (e.g. vps.yourdomain.com):`
   - Executes automated DNS check verifying that the Domain points to your VPS IP.
3. **Automated SSL Certificate (acme.sh)**:
   - Standalone issuance of Let's Encrypt ECC SSL certificates for your domain.
   - Installs certificate to `/etc/ddk-vps/ssl/ddk.crt` and generates combined PEM for HAProxy.
4. **All-in-One Multi-Protocol Proxy Suite**:
   - **OpenSSH** on port `22`.
   - **Dropbear SSH** on ports `109` and `447`.
   - **Python SSH-WS Proxy** on ports `80`, `443`, `2082`, `2083`, `2084`, `2085`, `8880`.
   - **Xray Core Multi-Protocol**:
     - VMess WebSocket on port `8442` & `2082` (Path: `/vmess`)
     - VLESS WebSocket on port `8443` & `443` (Path: `/vless`)
     - VLESS Reality Vision on port `8446` (`flow: xtls-rprx-vision`)
     - Trojan WebSocket on port `8445` (Path: `/trojan`)
     - Trojan gRPC on port `8447` (`trojan-grpc`)
   - **HAProxy Multiplexer**: Multiplexes ports `80` and `443` to forward HTTP/WS traffic to Dropbear, Xray, and the Web Panel.
   - **TCP BBR & 4GB Swap**: Activated for maximum network throughput.
5. **DDK Web Panel on Port 9090**:
   - Auto-generates random secure password for user `admin`.
   - Saved to `/etc/ddk-vps/panel/credentials.json`.
   - Serves complete 8-tab cyber SPA on `https://YOUR_DOMAIN:9090` (or `http://YOUR_VPS_IP:9090`).

---

## 🌐 Supported Protocols & Listening Ports Reference

| Service / Protocol | Port(s) | Description |
| :--- | :--- | :--- |
| **OpenSSH** | `22` | Native Linux administrative shell |
| **Dropbear SSH** | `109, 447` | Lightweight high-speed SSH daemon |
| **SSH-WebSocket (WS-Proxy)** | `80, 443, 2082, 2083, 2084, 2085, 8880` | Cloudflare CDN HTTP/HTTPS WebSocket tunneling for SSH |
| **VMess (WebSocket / gRPC)** | `8442, 2082` | Advanced obfuscated VMess proxy with multi-client routing |
| **VLESS (Reality XTLS / WS)** | `8443, 8446` | High-speed censorship-resistant VLESS Reality Vision protocol |
| **Trojan (WS / gRPC)** | `8445, 443, 8447` | TLS-camouflaged anti-censorship Trojan protocol |
| **HAProxy Multiplexer** | `80, 443` | Multiplexes HTTP and HTTPS traffic between Dropbear, Nginx & Xray |
| **Nginx Web Server** | `8080, 8081` | Reverse proxy backend and SSL certificate termination |
| **DDK Web Panel** | `9090` | Real-time web browser control dashboard (Python 3 daemon) |

---

## 🖥️ Web Panel Tabs (Port 9090)

1. **Dashboard**: Live CPU, RAM, Disk, Network gauges, 9 active service badges.
2. **SSH Accounts**: List users, online status, IP limit, Add account modal, delete user.
3. **Xray (V2Ray)**: VMess, VLESS Reality, Trojan, 1-click subscription link copy and mobile QR modal.
4. **Running Services**: Status badges, Restart/Stop buttons for each service, and Restart All VPN services.
5. **VPS Stats & Speedtest**: Server hardware specs, live Speedtest runner with Ping, Down, Up benchmark.
6. **Telegram Bot**: API token & Admin Chat ID integration with automated alerts.
7. **Settings & SSL**: Domain configuration, Let's Encrypt renewal, and admin password changer.
8. **Panel Admins**: Admin accounts table and real-time Activity Audit Log.
