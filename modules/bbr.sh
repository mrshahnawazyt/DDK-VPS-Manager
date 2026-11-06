#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - TCP BBR Acceleration Module
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Enabling TCP BBR Congestion Control ===${NC}"

# Check kernel version
KERNEL_VER=$(uname -r | awk -F. '{print $1"."$2}')
echo -e "Current Kernel: ${YELLOW}$KERNEL_VER${NC}"

# Check current congestion control
CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$CURRENT_CC" == "bbr" ]; then
  echo -e "${GREEN}[OK] TCP BBR is already ACTIVE and optimized on this server!${NC}"
  exit 0
fi

echo -e "Configuring sysctl parameters for BBR and FQ qdisc..."

# Remove old configurations if any
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

# Append modern BBR parameters
cat << 'EOF' >> /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# Apply sysctl settings immediately
sysctl -p > /dev/null 2>&1

NEW_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$NEW_CC" == "bbr" ]; then
  echo -e "${GREEN}[SUCCESS] TCP BBR has been activated successfully!${NC}"
  echo -e "QDisc: ${CYAN}$(sysctl net.core.default_qdisc | awk '{print $3}')${NC}"
  echo -e "Congestion Control: ${CYAN}$NEW_CC${NC}"
else
  echo -e "${YELLOW}[WARNING] Could not verify BBR. A reboot might be required if your kernel is older than 4.9.${NC}"
fi
