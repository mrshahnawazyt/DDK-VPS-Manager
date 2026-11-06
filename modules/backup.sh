#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Backup & Export Suite
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# ==============================================================================

sed -i 's/\r$//' "$0" 2>/dev/null || true

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

BACKUP_NAME="ddk_vps_backup_$(date '+%Y%m%d_%H%M%S').tar.gz"
DEST_PATH="/root/$BACKUP_NAME"

echo -e "${CYAN}Creating compressed backup of /etc/ddk-vps and network configs...${NC}"

tar -czf "$DEST_PATH" \
  /etc/ddk-vps \
  /etc/wireguard \
  /usr/local/etc/xray \
  /etc/ssh/sshd_config \
  2>/dev/null || true

echo -e "${GREEN}[SUCCESS] Backup archive created successfully!${NC}"
echo -e "File location: ${CYAN}$DEST_PATH${NC}"
echo -e "Size: $(du -h "$DEST_PATH" 2>/dev/null | awk '{print $1}')"
