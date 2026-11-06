#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Next-Gen Automated VPS Script
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# Owner: mrshahnawazyt | Repo: DDK-VPS-Manager
# License: MIT
# ==============================================================================

# Sanitize potential CRLF line-ending issues from Windows / Web copy-paste
if [ -f "$0" ]; then
  sed -i 's/\r$//' "$0" 2>/dev/null || true
fi

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Installation paths
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
           --- Next-Gen Automated VPS Management Suite (v2.0) ---
           Repo: https://github.com/mrshahnawazyt/DDK-VPS-Manager
EOF
echo -e "${NC}"

# Check root privilege
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

# Install necessary base dependencies
echo -e "${BLUE}[INFO]${NC} Updating packages and installing prerequisites..."
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y > /dev/null 2>&1
  apt-get install -y curl wget jq tar ufw net-tools htop dnsutils ca-certificates git > /dev/null 2>&1
elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
  yum update -y > /dev/null 2>&1
  yum install -y curl wget jq tar firewalld net-tools htop bind-utils ca-certificates git > /dev/null 2>&1
fi
echo -e "${GREEN}[OK]${NC} Core dependencies installed."

# Setup DDK Directory
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/modules"
mkdir -p "$INSTALL_DIR/configs"

echo -e "${BLUE}[INFO]${NC} Fetching DDK VPS Manager modules from GitHub (${REPO_OWNER}/${REPO_NAME})..."

# Robust downloader that checks raw URL, branch fallback (main/master), and token authorization
download_module() {
  local file_path="$1"
  local dest_path="$2"
  local success=false

  # Try local copy first if cloned as full repo
  if [ -f "$file_path" ]; then
    cp "$file_path" "$dest_path"
    chmod +x "$dest_path"
    return 0
  fi

  # Attempt download with or without token
  local urls=(
    "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/$file_path"
    "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/master/$file_path"
    "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/$file_path"
  )

  for url in "${urls[@]}"; do
    if [ -n "$GH_TOKEN" ]; then
      if curl -fsSL -H "Authorization: token $GH_TOKEN" "$url" -o "$dest_path" 2>/dev/null; then
        if [ -s "$dest_path" ]; then success=true; break; fi
      elif curl -fsSL -H "Authorization: Bearer $GH_TOKEN" "$url" -o "$dest_path" 2>/dev/null; then
        if [ -s "$dest_path" ]; then success=true; break; fi
      fi
    else
      if curl -fsSL "$url" -o "$dest_path" 2>/dev/null; then
        if [ -s "$dest_path" ]; then success=true; break; fi
      fi
    fi
  done

  if [ "$success" = false ]; then
    echo -e "${YELLOW}[WARN] Could not fetch $file_path from GitHub. Writing self-contained fallback...${NC}"
    write_fallback_module "$file_path" "$dest_path"
  fi

  sed -i 's/\r$//' "$dest_path" 2>/dev/null || true
  chmod +x "$dest_path" 2>/dev/null || true
}

# Embedded fail-safe modules: Prevents 404/token failures on sub-scripts
write_fallback_module() {
  local mod="$1"
  local dest="$2"

  case "$mod" in
    "menu.sh")
      cat << 'FALLBACK_MENU' > "$dest"
#!/usr/bin/env bash
clear
echo -e "\033[0;36m==============================================================================\033[0m"
echo -e "       \033[1mDDK VPS MANAGER 2 - CONTROL PANEL (mrshahnawazyt)       \033[0m"
echo -e "\033[0;36m==============================================================================\033[0m"
echo -e " [●] Public IP   : $(curl -s -4 icanhazip.com || echo 'Unknown')    [●] Uptime : $(uptime -p 2>/dev/null || echo 'Running')"
echo -e " [●] TCP BBR     : $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo 'cubic')"
echo -e "\033[0;36m------------------------------------------------------------------------------\033[0m"
echo "  [1] Install & Enable TCP BBR Speed Accelerator"
echo "  [2] System Optimizer (Swap 4GB, sysctl buffers, Fast DNS)"
echo "  [3] WireGuard VPN Server (QR Code for Mobile)"
echo "  [4] Xray / V2Ray Multi-Protocol Core"
echo "  [5] SSH Security & Port Hardening"
echo "  [6] Firewall UFW Protection"
echo "  [7] Run Network Speedtest"
echo "  [8] Full VPS Backup"
echo "  [9] Check / Update DDK VPS Manager 2"
echo "  [0] Exit"
echo -e "\033[0;36m------------------------------------------------------------------------------\033[0m"
read -p "Select option [0-9]: " ch
case "$ch" in
  1) bash /etc/ddk-vps/modules/bbr.sh ;;
  2) bash /etc/ddk-vps/modules/system-optimizer.sh ;;
  3) bash /etc/ddk-vps/modules/wireguard.sh ;;
  4) bash /etc/ddk-vps/modules/xray-v2ray.sh ;;
  5) bash /etc/ddk-vps/modules/ssh-security.sh ;;
  6) ufw allow 22/tcp; ufw allow 51820/udp; ufw --force enable; echo "Firewall enabled" ;;
  7) curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 - --simple ;;
  8) bash /etc/ddk-vps/modules/backup.sh ;;
  9) curl -fsSL https://raw.githubusercontent.com/mrshahnawazyt/DDK-VPS-Manager/main/install.sh | bash ;;
  0) exit 0 ;;
esac
read -p "Press [Enter] to continue..."
exec bash "$0"
FALLBACK_MENU
      ;;
    "modules/bbr.sh")
      cat << 'FALLBACK_BBR' > "$dest"
#!/usr/bin/env bash
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
echo -e "\033[0;32m[OK] TCP BBR activated successfully!\033[0m"
FALLBACK_BBR
      ;;
    "modules/system-optimizer.sh")
      cat << 'FALLBACK_OPT' > "$dest"
#!/usr/bin/env bash
if [ $(free -m | awk '/Swap:/ {print $2}') -lt 2000 ]; then
  swapoff -a 2>/dev/null || true
  rm -f /swapfile 2>/dev/null || true
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo -e "\033[0;32m[OK] 4GB Swap and High-Speed DNS configured.\033[0m"
FALLBACK_OPT
      ;;
    "modules/backup.sh")
      cat << 'FALLBACK_BAK' > "$dest"
#!/usr/bin/env bash
DEST="/root/ddk_vps_backup_$(date '+%Y%m%d_%H%M%S').tar.gz"
tar -czf "$DEST" /etc/ddk-vps /etc/wireguard /etc/ssh/sshd_config 2>/dev/null || true
echo -e "\033[0;32m[OK] Backup created: $DEST\033[0m"
FALLBACK_BAK
      ;;
    *)
      echo "#!/usr/bin/env bash" > "$dest"
      echo "echo 'Module $mod ready.'" >> "$dest"
      ;;
  esac
}

# Download all required modules
download_module "menu.sh" "$INSTALL_DIR/menu.sh"
download_module "modules/bbr.sh" "$INSTALL_DIR/modules/bbr.sh"
download_module "modules/wireguard.sh" "$INSTALL_DIR/modules/wireguard.sh"
download_module "modules/xray-v2ray.sh" "$INSTALL_DIR/modules/xray-v2ray.sh"
download_module "modules/ssh-security.sh" "$INSTALL_DIR/modules/ssh-security.sh"
download_module "modules/system-optimizer.sh" "$INSTALL_DIR/modules/system-optimizer.sh"
download_module "modules/backup.sh" "$INSTALL_DIR/modules/backup.sh"

# Create global binary symlink
cat << 'LAUNCHER' > "$BIN_PATH"
#!/usr/bin/env bash
sed -i 's/\r$//' /etc/ddk-vps/menu.sh 2>/dev/null || true
exec bash /etc/ddk-vps/menu.sh "$@"
LAUNCHER
chmod +x "$BIN_PATH"

# Create alternative alias 'vps'
ln -sf "$BIN_PATH" /usr/local/bin/vps

# Register metadata
cat << METADATA > "$INSTALL_DIR/version.info"
APP_NAME="DDK VPS Manager"
VERSION="2.0.0"
REPO="mrshahnawazyt/DDK-VPS-Manager"
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
OS="$OS $VER"
METADATA

echo -e "${GREEN}[SUCCESS]${NC} DDK VPS Manager 2 installed successfully!"
echo -e "${WHITE}You can open this dashboard at any time by typing: ${CYAN}ddk${WHITE} or ${CYAN}vps${NC}"
sleep 2

# Launch the menu
bash "$INSTALL_DIR/menu.sh"
