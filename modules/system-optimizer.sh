#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - System Optimizer Module
# Repository: https://github.com/mrshahnawazyt/DDK-VPS-Manager
# ==============================================================================

sed -i 's/\r$//' "$0" 2>/dev/null || true

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== VPS Performance Optimizer ===${NC}"

# 1. Swapfile creation if missing or < 2GB
CURRENT_SWAP=$(free -m | awk '/Swap:/ {print $2}')
if [ "$CURRENT_SWAP" -lt 2000 ]; then
  echo -e "Configuring 4GB High-Speed Swapfile..."
  swapoff -a 2>/dev/null || true
  rm -f /swapfile 2>/dev/null || true
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  
  if ! grep -q "/swapfile" /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
  echo -e "${GREEN}[OK] 4GB Swapfile configured and mounted.${NC}"
else
  echo -e "${GREEN}[OK] Swapfile already sufficient: ${CURRENT_SWAP}MB${NC}"
fi

# 2. Kernel and TCP tuning
echo -e "Applying High-Performance sysctl parameters..."
cat << 'SYSCTL' > /etc/sysctl.d/99-ddk-optimizations.conf
# File descriptors & limits
fs.file-max = 1000000
fs.inotify.max_user_instances = 8192

# Virtual Memory
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# TCP Buffers
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 65535

# TCP Memory
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
SYSCTL

sysctl --system > /dev/null 2>&1

# 3. Increase Limits
cat << 'LIMITS' >> /etc/security/limits.conf
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
LIMITS

# 4. Ultra-Fast DNS
echo -e "Setting fast Cloudflare and Google DNS..."
cat << 'RESOLV' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV

echo -e "${GREEN}[SUCCESS] System optimization completed successfully!${NC}"
