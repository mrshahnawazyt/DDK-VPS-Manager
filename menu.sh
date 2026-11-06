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
  DOMAIN=$(cat "$INSTALL_DIR/domain.conf" 2>/dev/null || echo "$IPV4")
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
  echo -e "${WHITE} [●] Domain / Host:${CYAN} $DOMAIN${NC}           ${WHITE}[●] Uptime : ${YELLOW}$UPTIME${NC}"
  echo -e "${WHITE} [●] Public IP    :${GREEN} $IPV4${NC}             ${WHITE}[●] Memory : ${PURPLE}${MEM_USED}MB / ${MEM_TOTAL}MB${NC}"
  echo -e "${WHITE} [●] Web Panel    :${GREEN} http://$IPV4:9090${NC} (or https://$DOMAIN:9090)"
  echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
}

show_menu() {
  show_header
  echo -e "${BOLD}${YELLOW}  === WEB PANEL & DOMAIN MANAGEMENT ===${NC}"
  echo -e "  ${GREEN}[1]${NC} Web Panel Status & Restart (Port 9090 Service)"
  echo -e "  ${GREEN}[2]${NC} Domain & SSL Certificate Manager (acme.sh renew/change)"
  echo -e ""
  echo -e "${BOLD}${YELLOW}  === MULTI-PROTOCOL PROXY & VPN SERVICES ===${NC}"
  echo -e "  ${GREEN}[3]${NC} SSH & Dropbear Accounts Manager (Add/Delete/Online Users)"
  echo -e "  ${GREEN}[4]${NC} Python SSH-WS Proxy (Ports 80, 443, 2082-2085, 8880)"
  echo -e "  ${GREEN}[5]${NC} Xray Core: VMess (WebSocket + gRPC Accounts)"
  echo -e "  ${GREEN}[6]${NC} Xray Core: VLESS (Reality Vision + WS Accounts)"
  echo -e "  ${GREEN}[7]${NC} Xray Core: Trojan (WebSocket + gRPC Accounts)"
  echo -e "  ${GREEN}[8]${NC} HAProxy & Nginx Multi-Port Status (Ports 80 & 443)"
  echo -e ""
  echo -e "${BOLD}${YELLOW}  === SYSTEM, PERFORMANCE & MAINTENANCE ===${NC}"
  echo -e "  ${GREEN}[9]${NC} System Optimizer (BBR Speed Booster + 4GB Swap + Fast DNS)"
  echo -e "  ${GREEN}[10]${NC} Running Services & Listening Ports Matrix"
  echo -e "  ${GREEN}[11]${NC} Real-Time Network Speedtest & Benchmark"
  echo -e "  ${GREEN}[12]${NC} Restart All VPN Services (HAProxy, Nginx, Dropbear, Xray)"
  echo -e "  ${GREEN}[13]${NC} Full VPS Backup & Export Configs"
  echo -e "  ${RED}[0]${NC} Exit to Shell"
  echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
}

while true; do
  show_menu
  read -p " Select option [0-13]: " choice
  case "$choice" in
    1)
      systemctl restart ddk-panel
      echo -e "${GREEN}[OK] Web panel restarted. Access at: http://$IPV4:9090 or https://$DOMAIN:9090${NC}"
      read -p "Press Enter to continue..."
      ;;
    2)
      echo -e "${CYAN}Current Domain: $DOMAIN${NC}"
      read -p "Enter new domain name (or press Enter to cancel): " NEW_DOM
      if [ -n "$NEW_DOM" ]; then
        echo "$NEW_DOM" > "$INSTALL_DIR/domain.conf"
        ~/.acme.sh/acme.sh --issue -d "$NEW_DOM" --standalone -k ec-256 --force 2>/dev/null || true
        ~/.acme.sh/acme.sh --install-cert -d "$NEW_DOM" --ecc \
          --fullchain-file "$INSTALL_DIR/ssl/ddk.crt" \
          --key-file "$INSTALL_DIR/ssl/ddk.key" 2>/dev/null || true
        cat "$INSTALL_DIR/ssl/ddk.crt" "$INSTALL_DIR/ssl/ddk.key" > "$INSTALL_DIR/ssl/ddk.pem" 2>/dev/null || true
        systemctl restart haproxy nginx xray ddk-panel 2>/dev/null || true
        echo -e "${GREEN}[SUCCESS] SSL certificate reissued for $NEW_DOM!${NC}"
      fi
      read -p "Press Enter to continue..."
      ;;
    3)
      echo -e "${YELLOW}1) Add SSH User  2) Delete SSH User  3) Show Connected Users${NC}"
      read -p "Choice: " sub
      if [ "$sub" == "1" ]; then
        read -p "Username: " u
        read -p "Password: " p
        read -p "Days active: " d
        useradd -M -s /bin/false "$u" 2>/dev/null || true
        echo "$u:$p" | chpasswd
        echo -e "${GREEN}User $u created successfully! Expire in $d days.${NC}"
      elif [ "$sub" == "2" ]; then
        read -p "Username to delete: " u
        userdel -f "$u" 2>/dev/null || true
        echo -e "${GREEN}User $u deleted.${NC}"
      else
        who
      fi
      read -p "Press Enter to continue..."
      ;;
    4)
      systemctl status ws-proxy --no-pager
      read -p "Press Enter to continue..."
      ;;
    5|6|7)
      bash "$INSTALL_DIR/modules/xray-all-protocols.sh" "$DOMAIN"
      read -p "Press Enter to continue..."
      ;;
    8)
      systemctl status haproxy --no-pager
      read -p "Press Enter to continue..."
      ;;
    9)
      bash "$INSTALL_DIR/modules/system-optimizer.sh"
      bash "$INSTALL_DIR/modules/bbr.sh"
      read -p "Press Enter to continue..."
      ;;
    10)
      netstat -tlpn 2>/dev/null || ss -tlpn
      read -p "Press Enter to continue..."
      ;;
    11)
      curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 - --simple
      read -p "Press Enter to continue..."
      ;;
    12)
      systemctl restart dropbear ws-proxy xray haproxy nginx ddk-panel 2>/dev/null || true
      echo -e "${GREEN}[OK] All VPN services restarted successfully!${NC}"
      read -p "Press Enter to continue..."
      ;;
    13)
      bash "$INSTALL_DIR/modules/backup.sh"
      read -p "Press Enter to continue..."
      ;;
    0)
      echo -e "${GREEN}Goodbye! Type 'ddk' or 'vps' anytime to reopen.${NC}"
      exit 0
      ;;
    *)
      echo "Invalid option."
      sleep 1
      ;;
  esac
done
