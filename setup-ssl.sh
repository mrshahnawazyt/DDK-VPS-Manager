#!/usr/bin/env bash
# Configure Nginx and a Let's Encrypt certificate for DDK VPS Manager.
set -Eeuo pipefail

APP_DIR="/opt/ddk-vps-manager"
SITE_NAME="ddk-vps-manager"
SITE_FILE="/etc/nginx/sites-available/${SITE_NAME}"
ENABLED_FILE="/etc/nginx/sites-enabled/${SITE_NAME}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run: sudo ddk-vps-manager"
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Ubuntu Server is required."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This HTTPS helper supports Ubuntu Server only."
  exit 1
fi

read -r -p "Domain name already pointed to this VPS (example: panel.example.com): " DOMAIN
DOMAIN="${DOMAIN,,}"
if [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
  echo "Enter a valid domain name."
  exit 1
fi

read -r -p "Email for Let's Encrypt renewal notices: " EMAIL
if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "Enter a valid email address."
  exit 1
fi

DEFAULT_PORT="9090"
if [[ -f "$APP_DIR/data/ddk-vps-manager.sqlite3" ]]; then
  STORED_PORT="$(python3 - "$APP_DIR/data/ddk-vps-manager.sqlite3" <<'PY'
import sqlite3
import sys
try:
    db = sqlite3.connect(sys.argv[1])
    row = db.execute("SELECT value FROM settings WHERE key='port'").fetchone()
    print(row[0] if row else "9090")
except Exception:
    print("9090")
PY
)"
  [[ "$STORED_PORT" =~ ^[0-9]{2,5}$ ]] && DEFAULT_PORT="$STORED_PORT"
fi

read -r -p "Panel local port [${DEFAULT_PORT}]: " PANEL_PORT
PANEL_PORT="${PANEL_PORT:-$DEFAULT_PORT}"
if [[ ! "$PANEL_PORT" =~ ^[0-9]{2,5}$ ]] || (( PANEL_PORT < 1024 || PANEL_PORT > 65535 )); then
  echo "Choose a port from 1024 to 65535."
  exit 1
fi

echo "Installing Nginx and Certbot..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx

cat > "$SITE_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sfn "$SITE_FILE" "$ENABLED_FILE"
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "Requesting the HTTPS certificate. Port 80 must be reachable and DNS must point here."
certbot --nginx --non-interactive --agree-tos --redirect --email "$EMAIL" -d "$DOMAIN"

echo "HTTPS is ready: https://${DOMAIN}"
