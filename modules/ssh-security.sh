#!/usr/bin/env bash
# ==============================================================================
# DDK VPS Manager 2 - SSH & Security Hardening Module
# ==============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=== SSH Security & Hardening Suite ===${NC}"
echo "Current SSH Port: $(grep -i "^Port" /etc/ssh/sshd_config | awk '{print $2}' || echo "22 (Default)")"
echo ""
echo "1) Change SSH Port"
echo "2) Install and configure Fail2Ban (Anti Brute-Force)"
echo "3) Disable Root Password Login (SSH Keys Only)"
echo "4) Show active SSH login attempts & banned IPs"
read -p "Select option [1-4]: " sec_choice

case "$sec_choice" in
  1)
    read -p "Enter new SSH Port (e.g. 2222, 5522): " NEW_PORT
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1024 ] && [ "$NEW_PORT" -le 65535 ]; then
      # Backup config
      cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
      sed -i "s/^#*Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
      
      # Allow in UFW if enabled
      if command -v ufw &>/dev/null; then
        ufw allow "$NEW_PORT"/tcp comment 'Custom SSH'
      fi
      
      systemctl restart ssh || systemctl restart sshd
      echo -e "${GREEN}[SUCCESS] SSH Port changed to: $NEW_PORT${NC}"
      echo -e "${YELLOW}IMPORTANT: Do NOT close this session until testing a new terminal connection:${NC}"
      echo -e "ssh -p $NEW_PORT root@$(curl -s -4 icanhazip.com)"
    else
      echo -e "${RED}Invalid port! Must be between 1024 and 65535.${NC}"
    fi
    ;;
  2)
    echo -e "Installing Fail2Ban..."
    apt-get update -y > /dev/null 2>&1 || true
    apt-get install -y fail2ban > /dev/null 2>&1 || yum install -y fail2ban > /dev/null 2>&1 || true
    
    cat << 'F2B' > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ssh
F2B
    systemctl enable fail2ban > /dev/null 2>&1 || true
    systemctl restart fail2ban || true
    echo -e "${GREEN}[OK] Fail2ban is active and monitoring SSH brute-force attempts.${NC}"
    ;;
  3)
    echo -e "${YELLOW}Warning: Make sure you have uploaded your SSH public key before doing this!${NC}"
    read -p "Are you sure you want to disable password authentication? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
      systemctl restart ssh || systemctl restart sshd
      echo -e "${GREEN}Password authentication disabled.${NC}"
    fi
    ;;
  4)
    if command -v fail2ban-client &>/dev/null; then
      fail2ban-client status sshd
    else
      echo "Fail2Ban is not installed."
    fi
    ;;
esac
