#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="DDK VPS Manager"
APP_DIR="/opt/ddk-vps-manager"
SERVICE_NAME="ddk-vps-manager"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
MENU_FILE="/usr/local/bin/menu"
LEGACY_MENU_FILE="/usr/local/bin/ddk-vps-manager"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run this installer with sudo or as root."
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "This installer requires a supported Ubuntu release."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "DDK VPS Manager currently supports Ubuntu Server 20.04 or newer."
  exit 1
fi

UBUNTU_MAJOR="${VERSION_ID%%.*}"
if [[ ! "$UBUNTU_MAJOR" =~ ^[0-9]+$ ]] || (( UBUNTU_MAJOR < 20 )); then
  echo "Ubuntu ${VERSION_ID:-unknown} is not supported. Use Ubuntu 20.04 or newer."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "This release requires a Linux system with systemd."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing Python 3..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3
  else
    echo "Python 3 is required and could not be installed automatically."
    exit 1
  fi
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SOURCE_DIR/src/app.py" ]] || { echo "src/app.py was not found next to the installer."; exit 1; }

read -r -p "Panel domain or VPS IP: " PANEL_DOMAIN
PANEL_DOMAIN="${PANEL_DOMAIN//[[:space:]]/}"
[[ -n "$PANEL_DOMAIN" ]] || { echo "A domain or IP is required."; exit 1; }

PANEL_PORT="9090"
ADMIN_USER="admin"

if command -v openssl >/dev/null 2>&1; then
  ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-22)"
else
  ADMIN_PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
)"
fi

EXISTING_INSTALL=0
if [[ -d "$APP_DIR" ]]; then
  EXISTING_INSTALL=1
  read -r -p "Existing DDK VPS Manager installation found. Replace it? [y/N]: " REPLACE
  [[ "$REPLACE" =~ ^[Yy]$ ]] || { echo "Installation cancelled."; exit 0; }
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
fi

if [[ -e "$MENU_FILE" || -L "$MENU_FILE" ]]; then
  if [[ ! -L "$MENU_FILE" ]] || [[ "$(readlink -f "$MENU_FILE")" != "$APP_DIR/menu.sh" ]]; then
    echo "Cannot install the menu command because $MENU_FILE already belongs to another program."
    echo "Rename or remove that command first, then run this installer again."
    exit 1
  fi
fi

install -d -m 700 "$APP_DIR" "$APP_DIR/data" "$APP_DIR/logs"
install -m 700 "$SOURCE_DIR/src/app.py" "$APP_DIR/app.py"
install -m 700 "$SOURCE_DIR/menu.sh" "$APP_DIR/menu.sh"
install -m 700 "$SOURCE_DIR/uninstall.sh" "$APP_DIR/uninstall.sh"
install -m 700 "$SOURCE_DIR/setup-ssl.sh" "$APP_DIR/setup-ssl.sh"
install -m 644 "$SOURCE_DIR/systemd/ddk-vps-manager.service" "$SERVICE_FILE"

ln -sfn "$APP_DIR/menu.sh" "$MENU_FILE"
if [[ -L "$LEGACY_MENU_FILE" ]] && [[ "$(readlink -f "$LEGACY_MENU_FILE")" == "$APP_DIR/menu.sh" ]]; then
  rm -f "$LEGACY_MENU_FILE"
fi

DDK_VPS_MANAGER_HOME="$APP_DIR" python3 "$APP_DIR/app.py" --initialize \
  --admin-user "$ADMIN_USER" \
  --admin-password "$ADMIN_PASSWORD" \
  --domain "$PANEL_DOMAIN" \
  --port "$PANEL_PORT"

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo
echo "${APP_NAME} installed successfully."
echo "Supported Ubuntu detected: ${VERSION_ID}"
echo "Panel URL: http://${PANEL_DOMAIN}:${PANEL_PORT}"
if (( EXISTING_INSTALL == 0 )); then
  echo "Username: ${ADMIN_USER}"
  echo "Password: ${ADMIN_PASSWORD}"
  echo
  echo "Save this password now; it is not printed again."
else
  echo "Existing admin login and password were kept unchanged."
fi
echo "Manage the installation later by typing: menu"
