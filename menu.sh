#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Main Dashboard
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# ==============================================================================

# Sanitize potential CRLF line-ending issues
sed -i 's/\r$//' "$0" 2>/dev/null || true

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

# Gather System Metrics
get_metrics() {
  IPV4=$(curl -s -4 icanhazip.com || echo "Unknown")
  UPTIME=$(uptime -p | sed 's/up //')
  CPU_MODEL=$(lscpu | grep "Model name" | sed -e 's/Model name:[[:space:]]*//' | head -1)
  [ -z "$CPU_MODEL" ] && CPU_MODEL="Virtual CPU"
  CPU_CORES=$(nproc)
  CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
  
  MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
  MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
  MEM_PCT=$(awk "BEGIN {printf "%.1f", ($MEM_USED/$MEM_TOTAL)*100}")
  
  DISK_INFO=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
  
  BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
  [ -z "$BBR_STATUS" ] && BBR_STATUS="inactive"
}

show_header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "=============================================================================="
  echo "       DDK VPS MANAGER 2 - CONTROL PANEL (ڈی ڈی کے بی پی ایس مینیجر)         "
  echo "       https://github.com/mrshahnawazyt/DDK-VPS-Manager                       "
  echo "=============================================================================="
  echo -e "${NC}"
  get_metrics
  echo -e "${WHITE} [●] Public IP   :${GREEN} $IPV4${NC}           ${WHITE}[●] Uptime : ${YELLOW}$UPTIME${NC}"
  echo -e "${WHITE} [●] CPU Model   :${CYAN} $CPU_MODEL ($CPU_CORES Cores - $CPU_USAGE%)${NC}"
  echo -e "${WHITE} [●] Memory/RAM  :${PURPLE} ${MEM_USED}MB / ${MEM_TOTAL}MB ($MEM_PCT%)${NC}"
  echo -e "${WHITE} [●] Disk Usage  :${BLUE} $DISK_INFO${NC}"
  echo -e "${WHITE} [●] TCP BBR     :${GREEN} $BBR_STATUS${NC}"
  echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
}

show_menu() {
  show_header
  echo -e "${BOLD}${YELLOW}  === SPEED & NETWORK OPTIMIZATION ===${NC}"
  echo -e "  ${GREEN}[1]${NC} Install & Enable TCP BBR Speed Accelerator"
  echo -e "  ${GREEN}[2]${NC} System Optimizer (Swap 4GB, sysctl buffers, Fast DNS)"
  echo -e ""
  echo -e "${BOLD}${YELLOW}  === VPN & PROXY PROTOCOLS ===${NC}"
  echo -e "  ${GREEN}[3]${NC} WireGuard VPN Server (Fast, Multi-Client, QR Code)"
  echo -e "  ${GREEN}[4]${NC} Xray / V2Ray / Shadowsocks Multi-Protocol Core"
  echo -e ""
  echo -e "${BOLD}${YELLOW}  === SECURITY & SERVER HARDENING ===${NC}"
  echo -e "  ${GREEN}[5]${NC} SSH Security (Change Port, Key-Only Auth, Fail2Ban)"
  echo -e "  ${GREEN}[6]${NC} Firewall & Ports Manager (UFW Protection)"
  echo -e ""
  echo -e "${BOLD}${YELLOW}  === UTILITIES & MAINTENANCE ===${NC}"
  echo -e "  ${GREEN}[7]${NC} Run Network Speedtest & Latency Benchmark"
  echo -e "  ${GREEN}[8]${NC} Full VPS Backup & Export Configs"
  echo -e "  ${GREEN}[9]${NC} Check / Update DDK VPS Manager 2"
  echo -e "  ${RED}[0]${NC} Exit to Shell"
  echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
}

while true; do
  show_menu
  read -p " Select an option [0-9]: " choice
  case "$choice" in
    1)
      if [ -f "$INSTALL_DIR/modules/bbr.sh" ]; then
        bash "$INSTALL_DIR/modules/bbr.sh"
      else
        echo -e "${RED}Module bbr.sh not found.${NC}"
      fi
      read -p "Press [Enter] to continue..."
      ;;
    2)
      if [ -f "$INSTALL_DIR/modules/system-optimizer.sh" ]; then
        bash "$INSTALL_DIR/modules/system-optimizer.sh"
      else
        echo -e "${RED}Module system-optimizer.sh not found.${NC}"
      fi
      read -p "Press [Enter] to continue..."
      ;;
    3)
      if [ -f "$INSTALL_DIR/modules/wireguard.sh" ]; then
        bash "$INSTALL_DIR/modules/wireguard.sh"
      else
        echo -e "${RED}Module wireguard.sh not found.${NC}"
      fi
      read -p "Press [Enter] to continue..."
      ;;
    4)
      if [ -f "$INSTALL_DIR/modules/xray-v2ray.sh" ]; then
        bash "$INSTALL_DIR/modules/xray-v2ray.sh"
      else
        echo -e "${RED}Module xray-v2ray.sh not found.${NC}"
      fi
      read -p "Press [Enter] to continue..."
      ;;
    5)
      if [ -f "$INSTALL_DIR/modules/ssh-security.sh" ]; then
        bash "$INSTALL_DIR/modules/ssh-security.sh"
      else
        echo -e "${RED}Module ssh-security.sh not found.${NC}"
      fi
      read -p "Press [Enter] to continue..."
      ;;
    6)
      echo -e "${CYAN}Configuring UFW Firewall...${NC}"
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow 22/tcp comment 'SSH'
      ufw allow 80/tcp comment 'HTTP'
      ufw allow 443/tcp comment 'HTTPS'
      ufw allow 51820/udp comment 'WireGuard'
      ufw --force enable
      echo -e "${GREEN}UFW Firewall active and configured.${NC}"
      ufw status verbose
      read -p "Press [Enter] to continue..."
      ;;
    7)
      echo -e "${CYAN}Running Network Speedtest...${NC}"
      if ! command -v speedtest-cli &>/dev/null; then
        apt-get install -y speedtest-cli >/dev/null 2>&1 || yum install -y speedtest-cli >/dev/null 2>&1 || true
      fi
      if command -v speedtest-cli &>/dev/null; then
        speedtest-cli --simple
      else
        curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 - --simple
      fi
      read -p "Press [Enter] to continue..."
      ;;
    8)
      if [ -f "$INSTALL_DIR/modules/backup.sh" ]; then
        bash "$INSTALL_DIR/modules/backup.sh"
      else
        echo -e "${RED}Module backup.sh not found.${NC}"
      fi
      read -p "Press [Enter] to continue..."
      ;;
    9)
      echo -e "${CYAN}Updating DDK VPS Manager 2...${NC}"
      curl -fsSL https://raw.githubusercontent.com/mrshahnawazyt/DDK-VPS-Manager/main/install.sh | bash
      read -p "Press [Enter] to continue..."
      ;;
    0)
      echo -e "${GREEN}Thank you for using DDK VPS Manager 2!${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid option! Please pick 0-9.${NC}"
      sleep 1
      ;;
  esac
done
