#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Complete Uninstallation Script
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

clear
echo -e "${RED}${BOLD}"
echo "=============================================================================="
echo "          DDK VPS MANAGER 2 - COMPLETE UNINSTALLATION WIZARD                  "
echo "=============================================================================="
echo -e "${NC}"
echo -e "${YELLOW}WARNING:${NC} This will completely remove DDK VPS Manager from this system."
echo -e "The following components will be stopped and removed:"
echo -e "  • Web Panel (Port 9090 Service & Credentials)"
echo -e "  • Python WebSocket Proxy (Ports 2082-2085, 8880)"
echo -e "  • HAProxy & Nginx custom proxy configurations"
echo -e "  • Dropbear multi-port SSH listener"
echo -e "  • Xray Core Multi-Protocol Suite"
echo -e "  • System optimization scripts & /etc/ddk-vps directory"
echo -e "  • CLI shortcuts (/usr/local/bin/menu, /usr/local/bin/ddk, /usr/local/bin/vps)"
echo -e "${RED}==============================================================================${NC}"
echo ""
read -p "Are you sure you want to completely uninstall DDK VPS Manager? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
  echo -e "${CYAN}[INFO] Uninstallation aborted. Your system was not modified.${NC}"
  exit 0
fi

echo ""
echo -e "${YELLOW}[1/5] Stopping all DDK VPS Manager services...${NC}"
systemctl stop ddk-panel 2>/dev/null || true
systemctl stop ws-proxy 2>/dev/null || true
systemctl stop xray 2>/dev/null || true
systemctl stop haproxy 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop dropbear 2>/dev/null || true

echo -e "${YELLOW}[2/5] Disabling and removing systemd services...${NC}"
systemctl disable ddk-panel 2>/dev/null || true
systemctl disable ws-proxy 2>/dev/null || true
rm -f /etc/systemd/system/ddk-panel.service
rm -f /etc/systemd/system/ws-proxy.service
systemctl daemon-reload 2>/dev/null || true

echo -e "${YELLOW}[3/5] Cleaning binaries and CLI shortcuts...${NC}"
rm -f /usr/local/bin/menu
rm -f /usr/local/bin/ddk
rm -f /usr/local/bin/vps
rm -f /usr/local/bin/ddk-uninstall
rm -f /usr/local/bin/ws-proxy.py

echo -e "${YELLOW}[4/5] Restoring standard OpenSSH port 22...${NC}"
sed -i 's/^Port .*/Port 22/' /etc/ssh/sshd_config 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

echo -e "${YELLOW}[5/5] Removing installation directory /etc/ddk-vps...${NC}"
rm -rf /etc/ddk-vps /var/log/ddk-vps

echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}  [SUCCESS] DDK VPS Manager has been completely uninstalled from your VPS!    ${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${CYAN}Standard OpenSSH is active on Port 22.${NC}"
echo ""
