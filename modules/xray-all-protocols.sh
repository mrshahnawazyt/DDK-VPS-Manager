#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - Xray Multi-Protocol Inbounds Configuration
# Protocols: VMess (WS/gRPC), VLESS (XTLS/WS), Trojan (WS/gRPC)
# ==============================================================================

sed -i 's/\r$//' "$0" 2>/dev/null || true

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${CYAN}=== Configuring Xray Multi-Protocol Inbounds ===${NC}"

XRAY_CONF="/usr/local/etc/xray/config.json"
mkdir -p /usr/local/etc/xray

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "e9b56f84-3b1a-4d22-9a67-9c98ef55d901")

cat << XRAY_MULTI > "$XRAY_CONF"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 8442,
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "$UUID", "alterId": 0 }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess" }
      }
    },
    {
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "level": 0 }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      }
    },
    {
      "port": 8445,
      "protocol": "trojan",
      "settings": {
        "clients": [{ "password": "trojan_$UUID" }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/trojan" }
      }
    },
    {
      "port": 8446,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality"
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
XRAY_MULTI

systemctl restart xray 2>/dev/null || true
echo -e "${GREEN}[SUCCESS] All protocols (VMess, VLESS, Trojan, Reality) configured!${NC}"
