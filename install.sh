#!/bin/bash
# ============================================================
# UDP ZiVPN - Master Installer
# Jalankan script ini di VPS untuk setup lengkap
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

BINARY_URL="https://github.com/fauzanihanipah/ziv-udp/releases/download/udp-zivpn/udp-zivpn-linux-amd64"
CONFIG_URL="https://raw.githubusercontent.com/fauzanihanipah/ziv-udp/main/config.json"
INSTALL_DIR="/usr/local/bin"
DATA_DIR="/var/lib/udp-zivpn"
CONFIG_DIR="/etc/udp-zivpn"
LOG_DIR="/var/log/udp-zivpn"

clear
echo -e "${CYAN}"
cat << 'BANNER'
╔══════════════════════════════════════════════════════════════╗
║         UDP ZiVPN - Master Installer v2.0                    ║
║         Multi-Region Tunnel + Telegram Bot + Auto Shop       ║
╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✗] Harus dijalankan sebagai root!${NC}"
    exit 1
fi

# Detect OS
if [[ -f /etc/debian_version ]]; then
    PKG_MGR="apt-get"
    PKG_INSTALL="apt-get install -y"
elif [[ -f /etc/redhat-release ]]; then
    PKG_MGR="yum"
    PKG_INSTALL="yum install -y"
else
    echo -e "${RED}OS tidak didukung!${NC}"
    exit 1
fi

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }
step()  { echo -e "\n${WHITE}━━━ $1 ━━━${NC}"; }

# ============================================================
# STEP 1: UPDATE & DEPENDENCIES
# ============================================================
step "Menginstall Dependensi"

$PKG_INSTALL curl wget jq screen unzip tar gzip python3 python3-pip \
    iperf3 net-tools htop logrotate cron 2>/dev/null

# Install speedtest Ookla
if ! command -v speedtest &>/dev/null; then
    info "Menginstall Speedtest Ookla..."
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash 2>/dev/null
    $PKG_INSTALL speedtest 2>/dev/null || warn "Speedtest Ookla tidak bisa diinstall, akan menggunakan fallback"
fi

# Install Python packages
info "Menginstall Python packages untuk Telegram Bot..."
pip3 install --quiet \
    python-telegram-bot==20.7 \
    requests \
    speedtest-cli \
    qrcode[pil] \
    Pillow \
    pytz \
    aiohttp 2>/dev/null

log "Dependensi berhasil diinstall"

# ============================================================
# STEP 2: CREATE DIRECTORIES
# ============================================================
step "Membuat Direktori"

mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CONFIG_DIR/backup"
chmod 700 "$DATA_DIR" "$CONFIG_DIR"
chmod 755 "$LOG_DIR"

# Init files
[[ ! -f "$DATA_DIR/users.json" ]]    && echo '{"users":[]}' > "$DATA_DIR/users.json"
[[ ! -f "$DATA_DIR/resellers.json" ]] && echo '{"resellers":[]}' > "$DATA_DIR/resellers.json"
[[ ! -f "$DATA_DIR/orders.json" ]]   && echo '{"orders":[]}' > "$DATA_DIR/orders.json"
[[ ! -f "$DATA_DIR/settings.json" ]] && echo '{"qris_number":"","qris_name":"","payment_timeout":30,"auto_approve":false,"vps_regions":{}}' > "$DATA_DIR/settings.json"

log "Direktori siap"

# ============================================================
# STEP 3: DOWNLOAD BINARY
# ============================================================
step "Mendownload UDP ZiVPN Binary"

info "Mendownload dari: $BINARY_URL"
wget -q --show-progress -O "$INSTALL_DIR/udp-zivpn" "$BINARY_URL"

if [[ $? -ne 0 ]]; then
    error "Gagal mendownload binary!"
    exit 1
fi

chmod +x "$INSTALL_DIR/udp-zivpn"
log "Binary berhasil didownload"

# ============================================================
# STEP 4: KONFIGURASI
# ============================================================
step "Konfigurasi Awal"

echo ""
echo -e "${CYAN}Masukkan konfigurasi server:${NC}"
echo ""

read -p "  UDP Port (default: 36712): " UDP_PORT
UDP_PORT=${UDP_PORT:-36712}

read -p "  Password Obfuscation (default: zivpn2024): " OBFS_PASS
OBFS_PASS=${OBFS_PASS:-zivpn2024}

read -p "  Max Bandwidth Upload (Mbps, default: 100): " UP_BW
UP_BW=${UP_BW:-100}

read -p "  Max Bandwidth Download (Mbps, default: 100): " DOWN_BW
DOWN_BW=${DOWN_BW:-100}

echo ""
echo -e "${CYAN}Konfigurasi Telegram Bot:${NC}"
echo ""

read -p "  Telegram Bot Token: " TG_TOKEN
while [[ -z "$TG_TOKEN" ]]; do
    warn "Token tidak boleh kosong!"
    read -p "  Telegram Bot Token: " TG_TOKEN
done

read -p "  Telegram Owner ID (angka): " TG_OWNER_ID
while [[ -z "$TG_OWNER_ID" ]]; do
    warn "Owner ID tidak boleh kosong!"
    read -p "  Telegram Owner ID: " TG_OWNER_ID
done

read -p "  Nama VPS/Region ini (contoh: VPS-ID-1): " VPS_NAME
VPS_NAME=${VPS_NAME:-VPS-1}

# Buat config.json
info "Membuat config.json..."
cat > "$CONFIG_DIR/config.json" << EOF
{
    "listen": ":${UDP_PORT}",
    "obfs": {
        "type": "salamander",
        "salamander": {
            "password": "${OBFS_PASS}"
        }
    },
    "bandwidth": {
        "up": "${UP_BW} mbps",
        "down": "${DOWN_BW} mbps"
    },
    "ignoreClientBandwidth": false,
    "speedTest": true,
    "disableUDP": false,
    "udpIdleTimeout": "60s",
    "auth": {
        "type": "userpass",
        "userpass": {}
    },
    "resolver": {
        "type": "udp",
        "udp": {
            "addr": "8.8.8.8:53",
            "timeout": "4s"
        }
    },
    "acl": {
        "inline": [
            "direct(all)"
        ]
    },
    "masquerade": {
        "type": "proxy",
        "proxy": {
            "url": "https://www.bing.com/",
            "rewriteHost": true
        }
    },
    "quic": {
        "initStreamReceiveWindow": 8388608,
        "maxStreamReceiveWindow": 8388608,
        "initConnReceiveWindow": 20971520,
        "maxConnReceiveWindow": 20971520,
        "maxIdleTimeout": "30s",
        "maxIncomingStreams": 1024,
        "disablePathMTUDiscovery": false
    }
}
EOF

# Simpan bot config
cat > "$DATA_DIR/bot.conf" << EOF
TG_TOKEN="${TG_TOKEN}"
TG_OWNER_ID="${TG_OWNER_ID}"
VPS_NAME="${VPS_NAME}"
UDP_PORT="${UDP_PORT}"
OBFS_PASS="${OBFS_PASS}"
EOF
chmod 600 "$DATA_DIR/bot.conf"

log "Konfigurasi tersimpan"

# ============================================================
# STEP 5: INSTALL SCRIPTS
# ============================================================
step "Menginstall Management Scripts"

# Copy tunnel management script
cp "$(dirname "$0")/tunnel.sh" "$INSTALL_DIR/udp-zivpn-manage"
chmod +x "$INSTALL_DIR/udp-zivpn-manage"

# Copy bot.py
cp "$(dirname "$0")/bot.py" "$DATA_DIR/bot.py"
chmod +x "$DATA_DIR/bot.py"

# Buat symlink untuk easy access
ln -sf "$INSTALL_DIR/udp-zivpn-manage" /usr/bin/vpnmanage
ln -sf "$INSTALL_DIR/udp-zivpn-manage" /usr/bin/tunnel

log "Scripts terinstall"

# ============================================================
# STEP 6: SETUP SYSTEMD SERVICES
# ============================================================
step "Setup Systemd Services"

# Service UDP ZiVPN Tunnel
cat > /etc/systemd/system/udp-zivpn.service << EOF
[Unit]
Description=UDP ZiVPN Tunnel Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/udp-zivpn server -c /etc/udp-zivpn/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
StandardOutput=append:/var/log/udp-zivpn/tunnel.log
StandardError=append:/var/log/udp-zivpn/tunnel.log

[Install]
WantedBy=multi-user.target
EOF

# Service Telegram Bot
cat > /etc/systemd/system/udp-zivpn-bot.service << EOF
[Unit]
Description=UDP ZiVPN Telegram Bot
After=network.target udp-zivpn.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${DATA_DIR}
ExecStart=/usr/bin/python3 ${DATA_DIR}/bot.py
Restart=on-failure
RestartSec=10s
StandardOutput=append:/var/log/udp-zivpn/bot.log
StandardError=append:/var/log/udp-zivpn/bot.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable udp-zivpn udp-zivpn-bot

log "Systemd services terdaftar"

# ============================================================
# STEP 7: SETUP LOGROTATE
# ============================================================
cat > /etc/logrotate.d/udp-zivpn << 'EOF'
/var/log/udp-zivpn/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    postrotate
        systemctl reload udp-zivpn 2>/dev/null || true
    endscript
}
EOF

# ============================================================
# STEP 8: SETUP CRON JOBS
# ============================================================
step "Setup Cron Jobs"

(crontab -l 2>/dev/null | grep -v "udp-zivpn"; cat << 'CRON'
# UDP ZiVPN - Cek expired users setiap jam
0 * * * * /usr/local/bin/udp-zivpn-manage check_expired >> /var/log/udp-zivpn/cron.log 2>&1
# UDP ZiVPN - Auto backup ke Telegram setiap hari jam 3 pagi  
0 3 * * * /usr/local/bin/udp-zivpn-manage backup_telegram >> /var/log/udp-zivpn/cron.log 2>&1
# UDP ZiVPN - Restart service mingguan (Minggu jam 4 pagi)
0 4 * * 0 systemctl restart udp-zivpn >> /var/log/udp-zivpn/cron.log 2>&1
CRON
) | crontab -

log "Cron jobs dikonfigurasi"

# ============================================================
# STEP 9: FIREWALL
# ============================================================
step "Konfigurasi Firewall"

if command -v ufw &>/dev/null; then
    ufw allow "$UDP_PORT/udp" 2>/dev/null
    ufw allow 22/tcp 2>/dev/null
    info "UFW: Port $UDP_PORT/udp dibuka"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${UDP_PORT}/udp" 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    info "Firewalld: Port $UDP_PORT/udp dibuka"
else
    # iptables langsung
    iptables -A INPUT -p udp --dport "$UDP_PORT" -j ACCEPT 2>/dev/null
    info "iptables: Port $UDP_PORT/udp dibuka"
fi

log "Firewall dikonfigurasi"

# ============================================================
# STEP 10: START SERVICES
# ============================================================
step "Menjalankan Services"

systemctl start udp-zivpn
sleep 2

if systemctl is-active --quiet udp-zivpn; then
    log "UDP ZiVPN Tunnel: ${GREEN}BERJALAN${NC}"
else
    warn "UDP ZiVPN Tunnel gagal dimulai. Cek log: journalctl -u udp-zivpn"
fi

systemctl start udp-zivpn-bot
sleep 2

if systemctl is-active --quiet udp-zivpn-bot; then
    log "Telegram Bot: ${GREEN}BERJALAN${NC}"
else
    warn "Telegram Bot gagal dimulai. Cek log: journalctl -u udp-zivpn-bot"
fi

# ============================================================
# SELESAI
# ============================================================
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "Tidak diketahui")

echo ""
echo -e "${CYAN}"
cat << 'DONE'
╔══════════════════════════════════════════════════════════════╗
║                  INSTALASI SELESAI!                          ║
╚══════════════════════════════════════════════════════════════╝
DONE
echo -e "${NC}"

echo -e "${WHITE}Info Server:${NC}"
echo -e "  IP Server    : ${GREEN}${SERVER_IP}${NC}"
echo -e "  VPS Name     : ${GREEN}${VPS_NAME}${NC}"
echo -e "  UDP Port     : ${GREEN}${UDP_PORT}${NC}"
echo -e "  OBFS Pass    : ${GREEN}${OBFS_PASS}${NC}"
echo ""
echo -e "${WHITE}Services:${NC}"
echo -e "  UDP Tunnel   : ${GREEN}Aktif${NC}"
echo -e "  Telegram Bot : ${GREEN}Aktif${NC}"
echo ""
echo -e "${WHITE}Perintah berguna:${NC}"
echo -e "  ${CYAN}tunnel${NC}              - Buka menu management"
echo -e "  ${CYAN}vpnmanage status${NC}    - Cek status"
echo -e "  ${CYAN}vpnmanage backup${NC}    - Backup & kirim ke Telegram"
echo -e "  ${CYAN}vpnmanage speedtest${NC} - Speed test Ookla"
echo ""
echo -e "${WHITE}Log files:${NC}"
echo -e "  ${CYAN}tail -f /var/log/udp-zivpn/tunnel.log${NC}"
echo -e "  ${CYAN}tail -f /var/log/udp-zivpn/bot.log${NC}"
echo ""
echo -e "${YELLOW}PENTING: Buka Telegram dan ketik /start ke bot Anda!${NC}"
echo -e "${YELLOW}Untuk menambah VPS region, gunakan menu bot Telegram (Owner only)${NC}"
echo ""
