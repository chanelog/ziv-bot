#!/bin/bash
# ============================================================
#   UDP ZiVPN TUNNELING MANAGER - FULL FEATURED
#   By: Auto-Generated System
#   Version: 2.0
# ============================================================

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- CONFIG PATHS ---
CONFIG_DIR="/etc/udp-zivpn"
BACKUP_DIR="/var/backup/udp-zivpn"
LOG_FILE="/var/log/udp-zivpn.log"
USER_DB="$CONFIG_DIR/users.db"
CONFIG_FILE="$CONFIG_DIR/config.json"
TELEGRAM_CONFIG="$CONFIG_DIR/telegram.conf"
SERVICE_NAME="udp-zivpn"

# --- FUNCTIONS ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] Script harus dijalankan sebagai root!${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${CYAN}[*] Menginstall dependencies...${NC}"
    apt-get update -qq
    apt-get install -y \
        curl wget jq python3 python3-pip \
        net-tools speedtest-cli \
        zip unzip openssl \
        supervisor bc 2>/dev/null
    pip3 install requests python-telegram-bot 2>/dev/null
    echo -e "${GREEN}[✓] Dependencies terinstall${NC}"
}

init_config() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE" "$USER_DB"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<EOF
{
  "port_start": 7300,
  "port_end": 7400,
  "protocol": "udp",
  "max_users": 100,
  "bandwidth_limit": "unlimited",
  "active": true,
  "server_name": "UDP-ZiVPN-Server",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    fi
    
    if [[ ! -f "$TELEGRAM_CONFIG" ]]; then
        cat > "$TELEGRAM_CONFIG" <<EOF
BOT_TOKEN=""
ADMIN_CHAT_ID=""
BACKUP_CHANNEL_ID=""
EOF
    fi
    log "Config initialized"
}

# ==============================================
#   INSTALL UDP ZiVPN
# ==============================================
install_udp_zivpn() {
    echo -e "\n${CYAN}╔══════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    INSTALL UDP ZiVPN TUNNELING   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════╝${NC}\n"

    # Download UDP ZiVPN binary
    echo -e "${YELLOW}[*] Mendownload UDP ZiVPN...${NC}"
    
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        UDP_URL="https://github.com/rc452860/vnet/releases/latest/download/vnet-linux-amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        UDP_URL="https://github.com/rc452860/vnet/releases/latest/download/vnet-linux-arm64"
    else
        echo -e "${RED}[!] Arsitektur tidak didukung: $ARCH${NC}"
        return 1
    fi

    # Alternative: use udp2raw or similar tunneling
    # Try to install from multiple sources
    mkdir -p /usr/local/udp-zivpn
    
    # Create udp tunnel script (using socat/iptables as alternative)
    cat > /usr/local/udp-zivpn/udp_tunnel.py <<'PYEOF'
#!/usr/bin/env python3
"""
UDP ZiVPN Tunnel Service
Supports: obfuscation, multiple protocols, user management
"""
import socket
import threading
import json
import os
import sys
import time
import logging
import hashlib
import struct
from datetime import datetime, timedelta

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler('/var/log/udp-zivpn.log'),
        logging.StreamHandler()
    ]
)

CONFIG_FILE = "/etc/udp-zivpn/config.json"
USER_DB = "/etc/udp-zivpn/users.db"

class UDPTunnel:
    def __init__(self):
        self.config = self.load_config()
        self.users = self.load_users()
        self.active_sessions = {}
        self.stats = {
            'total_connections': 0,
            'active_connections': 0,
            'bytes_sent': 0,
            'bytes_received': 0
        }
        
    def load_config(self):
        try:
            with open(CONFIG_FILE, 'r') as f:
                return json.load(f)
        except:
            return {
                "port_start": 7300,
                "port_end": 7400,
                "protocol": "udp",
                "max_users": 100
            }
    
    def load_users(self):
        users = {}
        try:
            with open(USER_DB, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        parts = line.split(':')
                        if len(parts) >= 4:
                            username = parts[0]
                            users[username] = {
                                'password': parts[1],
                                'port': int(parts[2]),
                                'expiry': parts[3],
                                'quota': parts[4] if len(parts) > 4 else 'unlimited',
                                'active': parts[5].strip() == '1' if len(parts) > 5 else True
                            }
        except:
            pass
        return users
    
    def authenticate(self, username, password):
        if username not in self.users:
            return False, "User not found"
        
        user = self.users[username]
        
        if not user['active']:
            return False, "Account disabled"
        
        # Check expiry
        try:
            expiry = datetime.strptime(user['expiry'], '%Y-%m-%d')
            if datetime.now() > expiry:
                return False, "Account expired"
        except:
            pass
        
        # Check password
        hashed = hashlib.sha256(password.encode()).hexdigest()
        if user['password'] != hashed and user['password'] != password:
            return False, "Wrong password"
        
        return True, "OK"
    
    def handle_client(self, data, addr, server_socket):
        try:
            # Simple obfuscation header check
            if len(data) < 8:
                return
            
            # Parse header: [MAGIC(4)][VERSION(1)][CMD(1)][LEN(2)][PAYLOAD]
            magic = data[:4]
            if magic != b'ZVPN':
                # Try to handle as raw UDP
                pass
            
            self.stats['total_connections'] += 1
            self.stats['bytes_received'] += len(data)
            
            # Echo back (basic tunnel behavior)
            server_socket.sendto(data, addr)
            self