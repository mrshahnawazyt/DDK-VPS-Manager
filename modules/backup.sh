#!/usr/bin/env bash
DEST_PATH="/root/ddk_vps_backup_$(date '+%Y%m%d_%H%M%S').tar.gz"
tar -czf "$DEST_PATH" /etc/ddk-vps /usr/local/etc/xray /etc/dropbear 2>/dev/null || true
echo -e "\033[0;32m[SUCCESS] Backup created at: $DEST_PATH\033[0m"
