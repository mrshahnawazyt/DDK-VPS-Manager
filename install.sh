#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Next-Gen Multi-Protocol Suite & Web Panel (Port 9090)
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# Protocols: SSH, Dropbear, SSH-WS, HAProxy, VMess, VLESS, Trojan, WireGuard
# License: MIT
# ==============================================================================

# Sanitize potential CRLF line-ending issues
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

INSTALL_DIR="/etc/ddk-vps"
BIN_PATH="/usr/local/bin/ddk"
REPO_OWNER="${GH_OWNER:-mrshahnawazyt}"
REPO_NAME="${GH_REPO:-DDK-VPS-Manager}"
BRANCH="${GH_BRANCH:-main}"

clear
echo -e "${CYAN}"
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

# Install all multi-protocol dependencies
echo -e "${BLUE}[INFO]${NC} Installing multi-protocol core stack (HAProxy, Nginx, Dropbear, Python3, Certbot)..."
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y > /dev/null 2>&1
  apt-get install -y curl wget jq tar ufw net-tools htop dropbear haproxy nginx python3 python3-pip certbot iptables socat git ca-certificates > /dev/null 2>&1
elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
  yum update -y > /dev/null 2>&1
  yum install -y epel-release > /dev/null 2>&1 || true
  yum install -y curl wget jq tar dropbear haproxy nginx python3 certbot iptables socat git ca-certificates > /dev/null 2>&1
fi
echo -e "${GREEN}[OK]${NC} Multi-protocol packages installed."

# Setup Directories
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/modules"
mkdir -p "$INSTALL_DIR/panel"
mkdir -p "$INSTALL_DIR/configs"

echo -e "${BLUE}[INFO]${NC} Installing Xray Core (VMess, VLESS, Trojan, Shadowsocks)..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh 2>/dev/null)" @ install > /dev/null 2>&1 || true

# Download or extract modules
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

# Setup Global Binaries
cat << 'LAUNCHER' > "$BIN_PATH"
#!/usr/bin/env bash
sed -i 's/\r$//' /etc/ddk-vps/menu.sh 2>/dev/null || true
exec bash /etc/ddk-vps/menu.sh "$@"
LAUNCHER
chmod +x "$BIN_PATH"
ln -sf "$BIN_PATH" /usr/local/bin/vps

IPV4=$(curl -s -4 icanhazip.com || echo "YOUR_VPS_IP")
echo -e "${GREEN}[SUCCESS]${NC} Multi-Protocol VPS Suite Installed!"
echo -e "${WHITE}Web Panel running at: ${CYAN}http://$IPV4:9090${NC}"
echo -e "${WHITE}Terminal Dashboard command: ${YELLOW}ddk${WHITE} or ${YELLOW}vps${NC}"
sleep 2

bash "$INSTALL_DIR/menu.sh"
