#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/ddk-vps-manager"
SERVICE="ddk-vps-manager"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run: sudo ddk-vps-manager"
  exit 1
fi

pause() { read -r -p "Press Enter to continue..." _; }
panel_status() {
  systemctl --no-pager --full status "$SERVICE" || true
}
python_service() {
  local action="$1"
  local target="ddk-vps-manager-python-proxy.service"
  if ! systemctl list-unit-files --no-legend "$target" 2>/dev/null | grep -q "$target"; then
    echo "No optional Python proxy service is registered yet."
    echo "DDK VPS Manager can manage it after a separate, approved service is installed."
    return
  fi
  systemctl "$action" "$target"
}

while true; do
  clear
  echo "========================================"
  echo "          DDK VPS Manager menu"
  echo "========================================"
  echo "1) Panel status"
  echo "2) Start panel"
  echo "3) Stop panel"
  echo "4) Restart panel"
  echo "5) View panel logs"
  echo "6) Python proxy service: status"
  echo "7) Python proxy service: start"
  echo "8) Python proxy service: stop"
  echo "9) Uninstall DDK VPS Manager completely"
  echo "0) Exit"
  echo
  read -r -p "Choose an option: " choice
  case "$choice" in
    1) panel_status; pause ;;
    2) systemctl start "$SERVICE"; echo "Panel started."; pause ;;
    3) systemctl stop "$SERVICE"; echo "Panel stopped."; pause ;;
    4) systemctl restart "$SERVICE"; echo "Panel restarted."; pause ;;
    5) journalctl -u "$SERVICE" -n 100 --no-pager; pause ;;
    6) python_service status || true; pause ;;
    7) python_service start; pause ;;
    8) python_service stop; pause ;;
    9) exec "$APP_DIR/uninstall.sh" ;;
    0) exit 0 ;;
    *) echo "Invalid option."; pause ;;
  esac
done
