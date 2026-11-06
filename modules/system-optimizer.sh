#!/usr/bin/env bash
CURRENT_SWAP=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}' || echo "0")
if [ "${CURRENT_SWAP:-0}" -lt 2000 ]; then
  swapoff -a 2>/dev/null || true
  rm -f /swapfile 2>/dev/null || true
  fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo -e "\033[0;32m[OK] 4GB Swap and DNS configured.\033[0m"
