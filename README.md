# DDK VPS Manager 2 (ڈی ڈی کے بی پی ایس مینیجر ۲)

> **Next-Generation Automated VPS Management Suite & Auto Script for Linux (Ubuntu / Debian / CentOS / AlmaLinux)**

---

## ⚡ Quick One-Line Installation (فوری انسٹالیشن کمانڈ)

Run this single command on your fresh Linux VPS as `root`:

### 🔐 For Private GitHub Repository (with Token):
```bash
export GH_TOKEN=YOUR_GITHUB_TOKEN GH_REPO=ddk-vps-manager-2 GH_OWNER=YOUR_USERNAME; apt update && apt install -y curl && curl -fsSL -H "Authorization: token $GH_TOKEN" https://raw.githubusercontent.com/$GH_OWNER/$GH_REPO/main/install.sh -o install.sh && bash install.sh
```

### 🌐 For Public GitHub Repository:
```bash
apt update && apt install -y curl && curl -fsSL https://raw.githubusercontent.com/testn5165-collab/ddk-vps-manager-2/main/install.sh -o install.sh && bash install.sh
```

Once installed, just type:
```bash
ddk
# or
vps
```

---

## 🚀 Key Features (خصوصیات)

- ⚡ **TCP BBR Speed Booster**: One-click Google BBR + FQ congestion control activation.
- 🛡️ **WireGuard VPN Multi-User**: Instant server deployment + QR codes for mobile.
- 🌐 **Xray / V2Ray / Shadowsocks**: High-speed anti-censorship proxy protocols.
- 🔒 **SSH Security Hardening**: Port alteration, Fail2Ban brute-force defender, root login toggle.
- 🚀 **System Performance Optimizer**: 4GB Swapfile, ultra-low latency Cloudflare DNS, sysctl kernel buffer tuning.
- 🔥 **UFW Firewall Manager**: Pre-configured safe port rules.
- 📦 **One-Click Backup**: Tarball export of keys and configurations.
- 📊 **Real-time Live Metrics**: Instant CPU, RAM, Disk, Public IP and Uptime overview.

---

## 💻 Supported Operating Systems

- **Ubuntu**: 20.04 LTS, 22.04 LTS, 24.04 LTS
- **Debian**: 10 (Buster), 11 (Bullseye), 12 (Bookworm)
- **CentOS / AlmaLinux / Rocky Linux**: 8, 9

---

## 🛡️ Security Note

Keep your GitHub Personal Access Token (`GH_TOKEN`) secure. Do not share tokens with admin or write permissions publicly. Use fine-grained tokens with read-only repository permissions for production server deployments.
