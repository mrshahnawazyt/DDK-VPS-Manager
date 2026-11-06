#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - WireGuard VPN Multi-Client Setup
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# ==============================================================================

sed -i 's/\r$//' "$0" 2>/dev/null || true

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

WG_DIR="/etc/wireguard"
WG_PORT=51820
SERVER_IP=$(curl -s -4 icanhazip.com || echo "YOUR_SERVER_IP")

echo -e "${CYAN}=== WireGuard VPN Quick Setup ===${NC}"

# Install WireGuard & qrencode
if ! command -v wg &>/dev/null; then
  echo -e "Installing WireGuard & tools..."
  apt-get update -y > /dev/null 2>&1 || true
  apt-get install -y wireguard wireguard-tools qrencode iptables resolvconf > /dev/null 2>&1 || true
fi

mkdir -p "$WG_DIR"
cd "$WG_DIR"

if [ ! -f "$WG_DIR/wg0.conf" ]; then
  echo -e "Generating WireGuard Server Keys..."
  wg genkey | tee server_private.key | wg pubkey > server_public.key
  chmod 600 server_private.key

  SERVER_PRIV=$(cat server_private.key)
  SERVER_PUB=$(cat server_public.key)

  # Find default network interface
  NET_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
  [ -z "$NET_IF" ] && NET_IF="eth0"

  cat << WGCONF > "$WG_DIR/wg0.conf"
[Interface]
Address = 10.66.66.1/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV
SaveConfig = false
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $NET_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $NET_IF -j MASQUERADE

WGCONF

  # Enable IP forwarding
  echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard-forward.conf
  sysctl --system > /dev/null 2>&1

  # Enable systemd service
  systemctl enable wg-quick@wg0 > /dev/null 2>&1 || true
  systemctl start wg-quick@wg0 || true
  echo -e "${GREEN}[OK] WireGuard Server initialized.${NC}"
fi

# Add Client Option
echo -e "\n${YELLOW}Add New Client Configuration:${NC}"
read -p "Enter Client Name (e.g. phone, laptop): " CLIENT_NAME
[ -z "$CLIENT_NAME" ] && CLIENT_NAME="client1"

CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
CLIENT_IP="10.66.66.$((RANDOM % 200 + 10))"

# Append peer to server
cat << PEER >> "$WG_DIR/wg0.conf"

# Client: $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = $CLIENT_IP/32
PEER

# Apply without disconnecting
wg addconf wg0 <(echo -e "[Peer]\nPublicKey = $CLIENT_PUB\nAllowedIPs = $CLIENT_IP/32") 2>/dev/null || systemctl restart wg-quick@wg0

# Generate Client .conf
CLIENT_CONF="$WG_DIR/$CLIENT_NAME.conf"
SERVER_PUB=$(cat "$WG_DIR/server_public.key")

cat << CLIENT > "$CLIENT_CONF"
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $CLIENT_IP/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CLIENT

echo -e "${GREEN}[SUCCESS] Client configuration created at: $CLIENT_CONF${NC}"
echo -e "${CYAN}Scan QR Code with WireGuard App (iOS/Android):${NC}"
qrencode -t ansiutf8 < "$CLIENT_CONF" || true
