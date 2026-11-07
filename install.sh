#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Next-Gen Multi-Protocol Suite & Web Panel (Port 9090)
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# Protocols: Dropbear SSH, Python WS-Proxy, Xray (VMess/VLESS/Trojan), HAProxy, Nginx
# License: MIT
# ==============================================================================

if [ -f "$0" ]; then
  sed -i 's/\r$//' "$0" 2>/dev/null || true
fi

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

INSTALL_DIR="/etc/ddk-vps"
BIN_PATH="/usr/local/bin/ddk"
REPO_OWNER="${GH_OWNER:-mrshahnawazyt}"
REPO_NAME="${GH_REPO:-DDK-VPS-Manager}"
BRANCH="${GH_BRANCH:-main}"

clear
echo -e "${CYAN}${BOLD}"
cat << "EOF"
  ____  ____  _  __ __     ______  ____    __  __                                   ____  
 |  _ \|  _ \| |/ / \ \   / /  _ \/ ___|  |  \/  | __ _ _ __   __ _  __ _  ___ _ __|___ \ 
 | | | | | | | ' /   \ \ / /| |_) \___ \  | |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__| __) |
 | |_| | |_| | . \    \ V / |  __/ ___) | | |  | | (_| | | | | (_| | (_| |  __/ |   / __/ 
 |____/|____/|_|\_\    \_/  |_|   |____/  |_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|  |_____|
                                                                    |___/                 
           --- Next-Gen Multi-Protocol Suite & Web Panel v7.0 ---
           Web Panel: http://YOUR_VPS_IP:9090
EOF
echo -e "${NC}"

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}[ERROR] This script must be run as root!${NC}"
  echo -e "${YELLOW}Please run: sudo bash $0${NC}"
  exit 1
fi

echo -e "${BLUE}[INFO]${NC} Checking operating system..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
  VER=$VERSION_ID
else
  echo -e "${RED}[ERROR] Cannot detect operating system!${NC}"
  exit 1
fi
echo -e "${GREEN}[OK]${NC} Detected OS: ${CYAN}$OS $VER${NC}"

IPV4=$(curl -s -4 icanhazip.com || curl -s -4 ifconfig.me || curl -s -4 ipinfo.io/ip || echo "127.0.0.1")
echo -e "${GREEN}[OK]${NC} Public IPv4: ${YELLOW}$IPV4${NC}"

# ==============================================================================
# INTERACTIVE DOMAIN CONFIGURATION STEP
# ==============================================================================
echo ""
echo -e "${YELLOW}==============================================================================${NC}"
echo -e "${CYAN}${BOLD}            STEP 1: DOMAIN & SSL CONFIGURATION                               ${NC}"
echo -e "${YELLOW}==============================================================================${NC}"
echo -e "${WHITE}To enable Let's Encrypt SSL, Xray Reality/VLESS, and the Web Panel,${NC}"
echo -e "${WHITE}please provide your pointed Domain or Subdomain (e.g. vps.example.com).${NC}"
echo -e "${WHITE}Ensure an 'A' record in Cloudflare / DNS points to: ${GREEN}$IPV4${NC}"
echo ""

read -p "Enter Domain / Subdomain (or press Enter for IP mode): " USER_DOMAIN

if [ -z "$USER_DOMAIN" ]; then
  echo -e "${YELLOW}[!] No domain specified. Proceeding in IP mode with Self-Signed SSL.${NC}"
  DOMAIN="$IPV4"
else
  echo -e "${BLUE}[INFO]${NC} Verifying DNS resolution for ${CYAN}$USER_DOMAIN${NC}..."
  RESOLVED_IP=$(ping -c 1 "$USER_DOMAIN" 2>/dev/null | sed -n 's/.*(\([0-9.]*\)).*/\1/p' | head -n 1 || getent ahostsv4 "$USER_DOMAIN" 2>/dev/null | awk '{print $1}' | head -n 1 || echo "")
  
  if [ "$RESOLVED_IP" == "$IPV4" ]; then
    echo -e "${GREEN}[SUCCESS]${NC} Domain ${CYAN}$USER_DOMAIN${NC} is successfully pointed to ${GREEN}$IPV4${NC}!"
    DOMAIN="$USER_DOMAIN"
  else
    echo -e "${YELLOW}[WARNING]${NC} Domain '$USER_DOMAIN' resolves to '${RED}$RESOLVED_IP${NC}' (Server IP is ${GREEN}$IPV4${NC})."
    echo -e "${WHITE}Tip: If using Cloudflare, set proxy status to 'DNS Only' (Grey Cloud).${NC}"
    read -p "Do you want to continue with this domain anyway? [y/N]: " FORCE_DOM
    if [[ "$FORCE_DOM" =~ ^[Yy]$ ]]; then
      DOMAIN="$USER_DOMAIN"
    else
      echo -e "${YELLOW}[!] Falling back to IP mode.${NC}"
      DOMAIN="$IPV4"
    fi
  fi
fi

mkdir -p "$INSTALL_DIR"
echo "$DOMAIN" > "$INSTALL_DIR/domain.conf"
echo -e "${GREEN}[OK]${NC} Configured domain: ${CYAN}$DOMAIN${NC}"

# ==============================================================================
# INSTALL PREREQUISITES & MULTI-PROTOCOL PACKAGES
# ==============================================================================
echo ""
echo -e "${BLUE}[INFO]${NC} Installing system packages (Dropbear, HAProxy, Nginx, Python3, Certbot, Socat)..."
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y > /dev/null 2>&1
  apt-get install -y curl wget jq tar net-tools htop dropbear haproxy nginx python3 python3-pip certbot iptables socat git ca-certificates openssl cron bc dnsutils > /dev/null 2>&1
elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
  yum update -y > /dev/null 2>&1
  yum install -y epel-release > /dev/null 2>&1 || true
  yum install -y curl wget jq tar dropbear haproxy nginx python3 certbot iptables socat git ca-certificates openssl cronie bind-utils > /dev/null 2>&1
fi
echo -e "${GREEN}[OK]${NC} System packages installed."

mkdir -p "$INSTALL_DIR/modules"
mkdir -p "$INSTALL_DIR/panel"
mkdir -p "$INSTALL_DIR/configs"
mkdir -p "$INSTALL_DIR/ssl"

# Auto-generate random secure admin password
ADMIN_PASS=$(openssl rand -hex 6 2>/dev/null || date +%s | tail -c 8)
cat << CREDS > "$INSTALL_DIR/panel/credentials.json"
{
  "username": "admin",
  "password": "$ADMIN_PASS",
  "role": "Super Admin",
  "domain": "$DOMAIN",
  "created_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
CREDS
chmod 600 "$INSTALL_DIR/panel/credentials.json"

# ==============================================================================
# SSL CERTIFICATE ISSUANCE (ACME.SH / ZERO-SSL / SELF-SIGNED)
# ==============================================================================
echo ""
echo -e "${BLUE}[INFO]${NC} Setting up SSL certificates..."
systemctl stop nginx haproxy 2>/dev/null || true

if [ "$DOMAIN" != "$IPV4" ]; then
  echo -e "${BLUE}[INFO]${NC} Requesting Let's Encrypt SSL certificate for ${CYAN}$DOMAIN${NC} via acme.sh..."
  curl -s https://get.acme.sh | sh -s email=admin@$DOMAIN >/dev/null 2>&1 || true
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force >/dev/null 2>&1 || true
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$INSTALL_DIR/ssl/ddk.crt" \
    --key-file "$INSTALL_DIR/ssl/ddk.key" >/dev/null 2>&1 || true
fi

if [ ! -f "$INSTALL_DIR/ssl/ddk.crt" ]; then
  echo -e "${YELLOW}[INFO]${NC} Generating high-grade 2048-bit SSL certificate..."
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$INSTALL_DIR/ssl/ddk.key" \
    -out "$INSTALL_DIR/ssl/ddk.crt" \
    -subj "/C=US/ST=Cloud/L=Server/O=DDK-VPS/CN=$DOMAIN" >/dev/null 2>&1 || true
fi

cat "$INSTALL_DIR/ssl/ddk.crt" "$INSTALL_DIR/ssl/ddk.key" > "$INSTALL_DIR/ssl/ddk.pem" 2>/dev/null || true
echo -e "${GREEN}[OK]${NC} SSL Certificate active at $INSTALL_DIR/ssl/ddk.crt"

# ==============================================================================
# DOWNLOAD REPOSITORY MODULES
# ==============================================================================
echo ""
echo -e "${BLUE}[INFO]${NC} Fetching DDK VPS Manager modules from GitHub..."
download_module() {
  local file_path="$1"
  local dest_path="$2"
  local success=false

  local urls=(
    "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/$file_path"
    "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/master/$file_path"
    "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/$file_path"
  )

  for url in "${urls[@]}"; do
    if [ -n "$GH_TOKEN" ]; then
      if curl -fsSL -H "Authorization: token $GH_TOKEN" "$url" -o "$dest_path" 2>/dev/null; then
        if [ -s "$dest_path" ]; then success=true; break; fi
      fi
    else
      if curl -fsSL "$url" -o "$dest_path" 2>/dev/null; then
        if [ -s "$dest_path" ]; then success=true; break; fi
      fi
    fi
  done

  sed -i 's/\r$//' "$dest_path" 2>/dev/null || true
  chmod +x "$dest_path" 2>/dev/null || true
}

download_module "menu.sh" "$INSTALL_DIR/menu.sh"
download_module "modules/ssh-ws.sh" "$INSTALL_DIR/modules/ssh-ws.sh"
download_module "modules/xray-all-protocols.sh" "$INSTALL_DIR/modules/xray-all-protocols.sh"
download_module "modules/panel-web-service.py" "$INSTALL_DIR/panel/web-service.py"
download_module "modules/bbr.sh" "$INSTALL_DIR/modules/bbr.sh"
download_module "modules/system-optimizer.sh" "$INSTALL_DIR/modules/system-optimizer.sh"
download_module "modules/backup.sh" "$INSTALL_DIR/modules/backup.sh"
download_module "uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod +x "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true
ln -sf "$INSTALL_DIR/uninstall.sh" /usr/local/bin/ddk-uninstall 2>/dev/null || true

# ==============================================================================
# EXECUTE PROTOCOL INSTALLATION & ACTIVATION
# ==============================================================================
echo ""
echo -e "${BLUE}[INFO]${NC} Activating Dropbear SSH & Python WebSocket Proxies..."
bash "$INSTALL_DIR/modules/ssh-ws.sh"

echo -e "${BLUE}[INFO]${NC} Activating Xray Multi-Protocol Suite (VMess, VLESS Reality, Trojan)..."
bash "$INSTALL_DIR/modules/xray-all-protocols.sh" "$DOMAIN"

echo -e "${BLUE}[INFO]${NC} Configuring HAProxy & Nginx Multi-Port Router..."
cat << 'HACONF' > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    tune.ssl.default-dh-param 2048

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms

frontend http_front
    bind *:80
    mode http
    acl is_ws hdr(Upgrade) -i websocket
    use_backend ws_proxy_back if is_ws
    default_backend panel_back

frontend https_front
    bind *:443 ssl crt /etc/ddk-vps/ssl/ddk.pem
    mode http
    acl is_vmess path_beg /vmess
    acl is_vless path_beg /vless
    acl is_trojan path_beg /trojan
    acl is_ws hdr(Upgrade) -i websocket
    use_backend xray_vmess if is_vmess
    use_backend xray_vless if is_vless
    use_backend xray_trojan if is_trojan
    use_backend ws_proxy_back if is_ws
    default_backend panel_back

backend ws_proxy_back
    mode http
    server wsp 127.0.0.1:2082

backend xray_vmess
    mode http
    server xvmess 127.0.0.1:8442

backend xray_vless
    mode http
    server xvless 127.0.0.1:8443

backend xray_trojan
    mode http
    server xtrojan 127.0.0.1:8445

backend panel_back
    mode http
    server webp 127.0.0.1:9090
HACONF

systemctl restart haproxy 2>/dev/null || true

echo -e "${BLUE}[INFO]${NC} Optimizing TCP BBR & System Buffers..."
bash "$INSTALL_DIR/modules/bbr.sh" >/dev/null 2>&1 || true
bash "$INSTALL_DIR/modules/system-optimizer.sh" >/dev/null 2>&1 || true

# Setup Systemd Web Panel Service (Port 9090)
cat << 'SYSTEMD' > /etc/systemd/system/ddk-panel.service
[Unit]
Description=DDK VPS Manager Web Panel (Port 9090)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/ddk-vps/panel
ExecStart=/usr/bin/python3 /etc/ddk-vps/panel/web-service.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable ddk-panel > /dev/null 2>&1 || true
systemctl restart ddk-panel 2>/dev/null || true

cat << 'LAUNCHER' > "$BIN_PATH"
#!/usr/bin/env bash
sed -i 's/\r$//' /etc/ddk-vps/menu.sh 2>/dev/null || true
exec bash /etc/ddk-vps/menu.sh "$@"
LAUNCHER
chmod +x "$BIN_PATH"
ln -sf "$BIN_PATH" /usr/local/bin/vps

# ==============================================================================
# COMPLETION SUMMARY BANNER WITH AUTO-GENERATED RANDOM PASSWORD
# ==============================================================================
clear
echo -e "${GREEN}${BOLD}"
echo "=============================================================================="
echo "          DDK VPS MANAGER 2 - INSTALLATION COMPLETED SUCCESSFULLY             "
echo "=============================================================================="
echo -e "${NC}"
echo -e "${WHITE} [●] Server Domain     : ${CYAN}https://$DOMAIN${NC}"
echo -e "${WHITE} [●] Server IPv4       : ${YELLOW}$IPV4${NC}"
if [ "$DOMAIN" != "$IPV4" ]; then
  echo -e "${WHITE} [●] Web Panel URL     : ${GREEN}https://$DOMAIN:9090${NC} (or http://$IPV4:9090)"
else
  echo -e "${WHITE} [●] Web Panel URL     : ${GREEN}http://$IPV4:9090${NC}"
fi
echo -e "${WHITE} [●] Default Admin User: ${CYAN}admin${NC}"
echo -e "${WHITE} [●] Auto-Generated PW : ${YELLOW}${BOLD}$ADMIN_PASS${NC}"
echo -e "${WHITE} [●] Credentials File  : ${PURPLE}/etc/ddk-vps/panel/credentials.json${NC}"
echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
echo -e "${BOLD}${YELLOW}  === ALL-IN-ONE ACTIVE PROTOCOLS & PORTS ===${NC}"
echo -e "${WHITE} [1] OpenSSH Direct    : ${CYAN}Port 22${NC}"
echo -e "${WHITE} [2] Dropbear SSH      : ${CYAN}Port 109, 447${NC}"
echo -e "${WHITE} [3] Python SSH-WS     : ${CYAN}Port 80, 443, 2082, 2083, 2084, 2085, 8880${NC}"
echo -e "${WHITE} [4] Xray VMess WS     : ${CYAN}Port 8442, 2082${NC} (Path: /vmess)"
echo -e "${WHITE} [5] Xray VLESS WS     : ${CYAN}Port 8443, 443${NC}  (Path: /vless)"
echo -e "${WHITE} [6] Xray VLESS Reality: ${CYAN}Port 8446${NC}      (Flow: xtls-rprx-vision)"
echo -e "${WHITE} [7] Xray Trojan WS    : ${CYAN}Port 8445, 443${NC}  (Path: /trojan)"
echo -e "${WHITE} [8] DDK Web Panel     : ${CYAN}Port 9090${NC}      (8-in-1 Cyber SPA)"
echo -e "${GREEN}[✓] To launch terminal menu anytime, type: ${YELLOW}ddk${GREEN} or ${YELLOW}menu${GREEN} or ${YELLOW}vps${NC}"
echo -e "${RED}[!] To completely uninstall script, run  : ${YELLOW}ddk-uninstall${NC}"
echo "=============================================================================="
echo ""
sleep 2

bash "$INSTALL_DIR/menu.sh"
