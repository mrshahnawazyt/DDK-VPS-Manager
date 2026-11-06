#!/usr/bin/env bash
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
echo -e "\033[0;32m[OK] TCP BBR activated successfully!\033[0m"
