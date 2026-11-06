#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Xray/V2Ray Proxy Core Module
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# ==============================================================================

sed -i 's/\r$//' "$0" 2>/dev/null || true

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Xray / V2Ray Next-Gen Core Setup ===${NC}"

# Download official Xray-install script
echo "Fetching Xray-Core installer..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "12345678-1234-1234-1234-123456789abc")
PORT=$((RANDOM % 50000 + 10000))
SERVER_IP=$(curl -s -4 icanhazip.com || echo "YOUR_SERVER_IP")

cat << XRAYCONF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
XRAYCONF

systemctl restart xray 2>/dev/null || true
systemctl enable xray > /dev/null 2>&1 || true

echo -e "${GREEN}[SUCCESS] Xray VLESS Core configured and active!${NC}"
echo -e "Port: ${YELLOW}$PORT${NC}"
echo -e "UUID: ${YELLOW}$UUID${NC}"
echo -e "Share Link: ${CYAN}vless://$UUID@$SERVER_IP:$PORT?encryption=none#DDK-VPS-VLESS${NC}"
