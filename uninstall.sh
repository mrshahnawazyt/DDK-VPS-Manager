#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/ddk-vps-manager"
SERVICE="ddk-vps-manager"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
MENU_FILE="/usr/local/bin/ddk-vps-manager"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run with sudo or as root."
  exit 1
fi

echo "This permanently removes DDK VPS Manager files, its database, logs,"
echo "configuration, systemd service and the ddk-vps-manager menu command."
echo "It does not remove unrelated VPS applications, users or SSH access."
read -r -p "Type REMOVE DDK VPS MANAGER to continue: " confirmation

if [[ "$confirmation" != "REMOVE DDK VPS MANAGER" ]]; then
  echo "Uninstall cancelled."
  exit 0
fi

systemctl disable --now "$SERVICE" 2>/dev/null || true
rm -f "$SERVICE_FILE"
rm -f "$MENU_FILE"
rm -rf "$APP_DIR"
systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true

echo "DDK VPS Manager has been removed from this server."
