#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Next-Gen Automated VPS Script
# Repository: DDK VPS Manager 2
# License: MIT
# ==============================================================================

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
REPO_OWNER="${GH_OWNER:-testn5165-collab}"
REPO_NAME="${GH_REPO:-ddk-vps-manager-2}"
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

echo -e "${BLUE}[INFO]${NC} Fetching DDK VPS Manager 2 modules from GitHub..."

AUTH_HEADER=""
if [ -n "$GH_TOKEN" ]; then
  AUTH_HEADER="Authorization: token $GH_TOKEN"
fi

download_file() {
  local file_path="$1"
  local dest_path="$2"
  local url="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH/$file_path"
  
  if [ -n "$AUTH_HEADER" ]; then
    curl -fsSL -H "$AUTH_HEADER" "$url" -o "$dest_path" || cp "$file_path" "$dest_path" 2>/dev/null || true
  else
    curl -fsSL "$url" -o "$dest_path" || cp "$file_path" "$dest_path" 2>/dev/null || true
  fi
}

# Download modules
download_file "menu.sh" "$INSTALL_DIR/menu.sh"
download_file "modules/bbr.sh" "$INSTALL_DIR/modules/bbr.sh"
download_file "modules/wireguard.sh" "$INSTALL_DIR/modules/wireguard.sh"
download_file "modules/xray-v2ray.sh" "$INSTALL_DIR/modules/xray-v2ray.sh"
download_file "modules/ssh-security.sh" "$INSTALL_DIR/modules/ssh-security.sh"
download_file "modules/system-optimizer.sh" "$INSTALL_DIR/modules/system-optimizer.sh"
download_file "modules/backup.sh" "$INSTALL_DIR/modules/backup.sh"

# Make executable
chmod +x "$INSTALL_DIR"/menu.sh "$INSTALL_DIR"/modules/*.sh 2>/dev/null || true

# Create global binary symlink
cat << 'LAUNCHER' > "$BIN_PATH"
#!/usr/bin/env bash
exec bash /etc/ddk-vps/menu.sh "$@"
LAUNCHER
chmod +x "$BIN_PATH"

# Create alternative alias 'vps'
ln -sf "$BIN_PATH" /usr/local/bin/vps

# Register metadata
cat << METADATA > "$INSTALL_DIR/version.info"
APP_NAME="DDK VPS Manager"
VERSION="2.0.0"
INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
OS="$OS $VER"
METADATA

echo -e "${GREEN}[SUCCESS]${NC} DDK VPS Manager 2 installed successfully!"
echo -e "${WHITE}You can open this dashboard at any time by typing: ${CYAN}ddk${WHITE} or ${CYAN}vps${NC}"
sleep 2

# Launch the menu
bash "$INSTALL_DIR/menu.sh"
