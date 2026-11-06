# DDK VPS Manager 2 (ڈی ڈی کے بی پی ایس مینیجر ۲)

> **Next-Generation Automated VPS Management Suite & Auto Script for Linux (Ubuntu / Debian / CentOS / AlmaLinux)**
> **Official Repository**: https://github.com/mrshahnawazyt/DDK-VPS-Manager

---

## ⚡ Quick One-Line Installation (فوری انسٹالیشن کمانڈ)

Run this single command on your fresh Linux VPS as `root`:

### 🌐 Method 1: Clean Public Repository (Recommended - بغیر ٹوکن کے):
If your repository is Public on GitHub, run this simple command:
```bash
apt update && apt install -y curl && curl -fsSL https://raw.githubusercontent.com/mrshahnawazyt/DDK-VPS-Manager/main/install.sh -o install.sh && bash install.sh
```

### 🔐 Method 2: Private GitHub Repository (with Token - پرائیویٹ ریپو):
If your repository is Private, run with your GitHub Personal Access Token:
```bash
export GH_TOKEN=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 GH_REPO=DDK-VPS-Manager GH_OWNER=mrshahnawazyt; apt update && apt install -y curl && curl -fsSL -H "Authorization: token $GH_TOKEN" https://raw.githubusercontent.com/$GH_OWNER/$GH_REPO/main/install.sh -o install.sh && bash install.sh
```

---

## 🚀 How to Open Control Menu After Installation
Whenever you log into your VPS terminal, just type:
```bash
ddk
# or
vps
```

---

## 🛠️ Key Features (خصوصیات)

- ⚡ **TCP BBR Speed Booster**: One-click Google BBR + FQ congestion control activation.
- 🛡️ **WireGuard VPN Multi-User**: Instant server deployment + QR codes for mobile connection.
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

## 🛡️ Error Prevention Built-in

This script has automatic error-recovery built-in:
1. **CRLF Windows Line Ending Fix**: Automatically strips carriage returns so Windows uploads never trigger `$'': command not found`.
2. **Fail-Safe Fallback**: If sub-modules cannot be downloaded from GitHub, `install.sh` extracts built-in self-contained module scripts directly.
3. **Dual-Branch Support**: Works seamlessly on both `main` and `master` branches.
