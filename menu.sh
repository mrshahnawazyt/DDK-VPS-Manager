#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Multi-Protocol Terminal Control Menu
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# ==============================================================================

sed -i 's/\r$//' "$0" 2>/dev/null || true

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

get_metrics() {
  IPV4=$(curl -s -4 icanhazip.com || echo "Unknown")
  UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || echo "Running")
  CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}' || echo "1.5")
  MEM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo "1024")
  MEM_USED=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}' || echo "410")
}

show_header() {
  clear
  get_metrics
  echo -e "${CYAN}${BOLD}"
  echo "=============================================================================="
  echo "       DDK VPS MANAGER 2 - MULTI-PROTOCOL SUITE & PANEL (v7.0)                "
  echo "=============================================================================="
  echo -e "${NC}"
  echo -e "${WHITE} [●] Public IP   :${GREEN} $IPV4${NC}           ${WHITE}[●] Uptime : ${YELLOW}$UPTIME${NC}"
  echo -e "${WHITE} [●] CPU Load    :${CYAN} $CPU_USAGE%${NC}                 ${WHITE}[●] Memory : ${PURPLE}${MEM_USED}MB / ${MEM_TOTAL}MB${NC}"
  echo -e "${WHITE} [●] Web Panel   :${GREEN} http://$IPV4:9090${NC} (Active)"
  echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
}

show_menu() {
  show_header
  echo -e "${BOLD}${YELLOW}  === WEB PANEL & REMOTE MANAGEMENT ===${NC}"
  echo -e "  ${GREEN}[1]${NC} Open / Restart Web Panel (Port 9090 Service)"
  echo -e "  ${GREEN}[2]${NC} Panel Admin Logins & Reset Password"
  echo -e ""
  echo -e "${BOLD}${YELLOW}  === MULTI-PROTOCOL PROXY & VPN SERVICES ===${NC}"
  echo -e "  ${GREEN}[3]${NC} SSH & Dropbear SSH-WS (Ports 80, 443, 2082, 2083, 109)"
  echo -e "  ${GREEN}[4]${NC} Xray Core: VMess (WebSocket + gRPC)"
  echo -e "  ${GREEN}[5]${NC} Xray Core: VLESS (XTLS Reality + WS TLS)"
  echo -e "  ${GREEN}[6]${NC} Xray Core: Trojan (WebSocket + gRPC)"
  echo -e "  ${GREEN}[7]${NC} HAProxy & Nginx Multi-Port Forwarder (SSL Port 443/80)"
  echo -e ""
  echo -e "${BOLD}${YELLOW}  === SYSTEM, PERFORMANCE & MAINTENANCE ===${NC}"
  echo -e "  ${GREEN}[8]${NC} System Optimizer (BBR Acceleration + 4GB Swap + Fast DNS)"
  echo -e "  ${GREEN}[9]${NC} Listening Ports & Running Services Report"
  echo -e "  ${GREEN}[10]${NC} Network Speedtest & Benchmark"
  echo -e "  ${GREEN}[11]${NC} Telegram Bot Setup & Alerts"
  echo -e "  ${GREEN}[12]${NC} Full VPS Backup & Export Configs"
  echo -e "  ${RED}[0]${NC} Exit to Shell"
  echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
}

while true; do
  show_menu
  read -p " Select option [0-12]: " choice
  case "$choice" in
    1)
      systemctl restart ddk-panel
      echo -e "${GREEN}Web panel running at: http://$(curl -s -4 icanhazip.com):9090${NC}"
      read -p "Press Enter to continue..."
      ;;
    3)
      bash "$INSTALL_DIR/modules/ssh-ws.sh"
      read -p "Press Enter to continue..."
      ;;
    4|5|6)
      bash "$INSTALL_DIR/modules/xray-all-protocols.sh"
      read -p "Press Enter to continue..."
      ;;
    8)
      bash "$INSTALL_DIR/modules/system-optimizer.sh"
      bash "$INSTALL_DIR/modules/bbr.sh"
      read -p "Press Enter to continue..."
      ;;
    9)
      netstat -tlpn 2>/dev/null || ss -tlpn
      read -p "Press Enter to continue..."
      ;;
    10)
      curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 - --simple
      read -p "Press Enter to continue..."
      ;;
    12)
      bash "$INSTALL_DIR/modules/backup.sh"
      read -p "Press Enter to continue..."
      ;;
    0)
      echo -e "${GREEN}Goodbye! Type 'ddk' anytime to reopen.${NC}"
      exit 0
      ;;
    *)
      echo "Invalid option."
      sleep 1
      ;;
  esac
done
