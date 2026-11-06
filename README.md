# DDK VPS Manager 2 - Multi-Protocol Suite & Web Panel (Port 9090)

> **Official Repository**: https://github.com/mrshahnawazyt/DDK-VPS-Manager  
> **Web Panel Dashboard**: `http://YOUR_VPS_IP:9090` (or `https://YOUR_DOMAIN:9090`)  
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

## 🛠️ Step-by-Step Installation Workflow

1. **System & Public IP Check**: The installer verifies OS compatibility and fetches your server's public IPv4.
2. **Interactive Domain Setup**:
   - The installer prompts: `Enter Domain / Subdomain (e.g. vps.example.com):`
   - It performs an automated DNS lookup verifying that your Domain points to the VPS IPv4.
3. **Automated SSL Certificate (acme.sh)**:
   - Automated issuance of Let's Encrypt ECC SSL certificates for your domain.
   - Installs certificate to `/etc/ddk-vps/ssl/ddk.crt` and generates combined PEM for HAProxy.
4. **All-in-One Multi-Protocol Setup**:
   - **OpenSSH** on port `22`.
   - **Dropbear SSH** on ports `109` and `447`.
   - **Python SSH-WebSocket Proxy** on ports `80`, `443`, `2082`, `2083`, `2084`, `2085`, `8880`.
   - **Xray Core Multi-Protocol**:
     - VMess WebSocket on port `8442` (Path: `/vmess`)
     - VLESS WebSocket on port `8443` (Path: `/vless`)
     - VLESS Reality Vision on port `8446` (`xtls-rprx-vision`)
     - Trojan WebSocket on port `8445` (Path: `/trojan`)
     - Trojan gRPC on port `8447` (`trojan-grpc`)
   - **HAProxy Multiplexer**: Multiplexes ports `80` and `443` to forward HTTP/WS traffic to Dropbear, Xray, and the Web Panel.
   - **TCP BBR Booster & 4GB Swap**: Activated for maximum network throughput.
5. **DDK Web Panel on Port 9090**:
   - Launches standalone Python 3 service with embedded cyber-dark dashboard (no directory listings).

---

## 🌐 Supported Protocols & Listening Ports Reference

| Service / Protocol | Port(s) | Description |
| :--- | :--- | :--- |
| **OpenSSH** | `22` | Native Linux administrative shell |
| **Dropbear SSH** | `109, 447` | Lightweight high-speed SSH daemon |
| **SSH-WebSocket (WS-Proxy)** | `80, 443, 2082, 2083, 2084, 2085, 8880` | Cloudflare CDN HTTP/HTTPS WebSocket tunneling for SSH |
| **VMess (WebSocket / gRPC)** | `8442, 2082` | Obfuscated VMess proxy with multi-client support |
| **VLESS (Reality XTLS / WS)** | `8443, 8446` | Ultra-fast censorship-resistant VLESS Reality Vision |
| **Trojan (WS / gRPC)** | `8445, 443, 8447` | TLS-camouflaged Trojan protocol |
| **HAProxy Multiplexer** | `80, 443` | High-availability load balancer offloading HTTP/HTTPS traffic |
| **Nginx Web Server** | `8080, 8081` | SSL certificate termination and reverse proxy |
| **DDK Web Panel** | `9090` | Real-time web browser control dashboard (Python 3 daemon) |

---

## 🚀 Post-Installation Usage

1. **Access Web Panel**:
   ```text
   http://YOUR_SERVER_IP:9090
   # or
   https://YOUR_DOMAIN:9090
   ```

2. **Access Terminal Menu**:
   ```bash
   ddk
   # or
   vps
   ```
