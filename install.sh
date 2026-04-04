#!/bin/bash
# ================================================================
#   UDP ZiVPN - Master Installer v3.0
#   Port default : 5667 (sesuai config.json resmi)
# ================================================================

BINARY_URL="https://github.com/fauzanihanipah/ziv-udp/releases/download/udp-zivpn/udp-zivpn-linux-amd64"
CONFIG_URL="https://raw.githubusercontent.com/fauzanihanipah/ziv-udp/main/config.json"

INSTALL_DIR="/usr/local/bin"
DATA_DIR="/var/lib/udp-zivpn"
CONFIG_DIR="/etc/udp-zivpn"
CERT_DIR="/etc/zivpn"
LOG_DIR="/var/log/udp-zivpn"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; D='\033[2;37m'; N='\033[0m'

log()   { echo -e "${G}[✔]${N} $1"; }
warn()  { echo -e "${Y}[!]${N} $1"; }
error() { echo -e "${R}[✘]${N} $1"; }
info()  { echo -e "${C}[i]${N} $1"; }
step()  { echo -e "\n${W}━━━ $1 ━━━${N}"; }
div()   { echo -e "${D}────────────────────────────────────────────────────────${N}"; }

[[ $EUID -ne 0 ]] && error "Harus dijalankan sebagai root!" && exit 1

clear
echo -e "${C}"
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │       UDP ZiVPN - Master Installer v3.0              │"
echo "  │    Multi-Region | Telegram Bot | Auto Sales | QRIS   │"
echo "  └──────────────────────────────────────────────────────┘"
echo -e "${N}"

# ================================================================
# STEP 1: DEPENDENCIES
# ================================================================
step "1. Instalasi Dependensi"

if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y curl wget jq screen unzip tar python3 python3-pip \
        net-tools openssl logrotate cron 2>/dev/null
elif command -v yum &>/dev/null; then
    yum install -y curl wget jq screen unzip tar python3 python3-pip \
        net-tools openssl cronie 2>/dev/null
fi

# Install Python packages
info "Menginstall Python packages..."
pip3 install --quiet --upgrade --break-system-packages \
    "python-telegram-bot==20.7" \
    requests speedtest-cli 2>/dev/null

log "Dependensi selesai"

# ================================================================
# STEP 2: DIREKTORI
# ================================================================
step "2. Setup Direktori"
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$CERT_DIR" "$LOG_DIR"
chmod 700 "$DATA_DIR" "$CONFIG_DIR" "$CERT_DIR"
chmod 755 "$LOG_DIR"

[[ ! -f "$DATA_DIR/users.json"     ]] && echo '{"users":[]}'     > "$DATA_DIR/users.json"
[[ ! -f "$DATA_DIR/resellers.json" ]] && echo '{"resellers":[]}' > "$DATA_DIR/resellers.json"
[[ ! -f "$DATA_DIR/orders.json"    ]] && echo '{"orders":[]}'    > "$DATA_DIR/orders.json"
[[ ! -f "$DATA_DIR/settings.json"  ]] && echo '{"vps_regions":{},"payment_timeout":30}' > "$DATA_DIR/settings.json"
log "Direktori siap"

# ================================================================
# STEP 3: DOWNLOAD BINARY
# ================================================================
step "3. Download Binary ZiVPN"
info "URL: $BINARY_URL"
wget -q --show-progress -O "$INSTALL_DIR/udp-zivpn" "$BINARY_URL"
if [[ $? -ne 0 ]]; then
    error "Gagal download binary!"; exit 1
fi
chmod +x "$INSTALL_DIR/udp-zivpn"
log "Binary terdownload: $("$INSTALL_DIR/udp-zivpn" --help 2>&1 | head -2 | tail -1)"

# ================================================================
# STEP 4: KONFIGURASI
# ================================================================
step "4. Konfigurasi Server"
div
echo -e "  Masukkan konfigurasi (Enter = pakai default):"
div

echo -ne "  UDP Port        [5667]  : "; read -r UDP_PORT;  UDP_PORT=${UDP_PORT:-5667}
echo -ne "  OBFS Password  [zivpn] : "; read -r OBFS_PASS; OBFS_PASS=${OBFS_PASS:-zivpn}
div
echo -e "  ${C}Konfigurasi Telegram Bot:${N}"
div
echo -ne "  Bot Token (dari @BotFather) : "; read -r TG_TOKEN
while [[ -z "$TG_TOKEN" ]]; do
    warn "Token tidak boleh kosong!"
    echo -ne "  Bot Token : "; read -r TG_TOKEN
done

echo -ne "  Owner ID  (dari @userinfobot): "; read -r TG_OWNER_ID
while [[ -z "$TG_OWNER_ID" ]]; do
    warn "Owner ID tidak boleh kosong!"
    echo -ne "  Owner ID  : "; read -r TG_OWNER_ID
done

echo -ne "  Nama VPS/Region   [VPS-1] : "; read -r VPS_NAME; VPS_NAME=${VPS_NAME:-VPS-1}

# ================================================================
# STEP 5: GENERATE SSL CERT
# ================================================================
step "5. Generate SSL Certificate"
openssl req -x509 -nodes \
    -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$CERT_DIR/zivpn.key" \
    -out    "$CERT_DIR/zivpn.crt" \
    -days 3650 -subj "/CN=zivpn" 2>/dev/null
log "SSL Certificate dibuat (10 tahun)"

# ================================================================
# STEP 6: CONFIG.JSON — Format ZiVPN v1.5.0
# ================================================================
step "6. Membuat Config ZiVPN"
cat > "$CONFIG_DIR/config.json" << EOF
{
    "listen": ":${UDP_PORT}",
    "cert": "${CERT_DIR}/zivpn.crt",
    "key": "${CERT_DIR}/zivpn.key",
    "obfs": "${OBFS_PASS}",
    "auth": {
        "mode": "passwords",
        "config": []
    }
}
EOF
log "config.json dibuat (port: ${UDP_PORT})"

# Simpan bot config
cat > "$DATA_DIR/bot.conf" << EOF
TG_TOKEN="${TG_TOKEN}"
TG_OWNER_ID="${TG_OWNER_ID}"
VPS_NAME="${VPS_NAME}"
UDP_PORT="${UDP_PORT}"
OBFS_PASS="${OBFS_PASS}"
EOF
chmod 600 "$DATA_DIR/bot.conf"
log "Bot config tersimpan"

# ================================================================
# STEP 7: INSTALL SCRIPTS
# ================================================================
step "7. Instalasi Scripts"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/tunnel.sh" "$INSTALL_DIR/udp-zivpn-manage"
chmod +x "$INSTALL_DIR/udp-zivpn-manage"

cp "$SCRIPT_DIR/bot.py" "$DATA_DIR/bot.py"
chmod +x "$DATA_DIR/bot.py"

# Symlinks
ln -sf "$INSTALL_DIR/udp-zivpn-manage" /usr/bin/tunnel   2>/dev/null
ln -sf "$INSTALL_DIR/udp-zivpn-manage" /usr/bin/vpnmanage 2>/dev/null
log "Scripts terinstall"

# ================================================================
# STEP 8: SYSTEMD SERVICES
# ================================================================
step "8. Setup Systemd Services"

cat > /etc/systemd/system/udp-zivpn.service << EOF
[Unit]
Description=UDP ZiVPN Tunnel Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/udp-zivpn server -c ${CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
StandardOutput=append:${LOG_DIR}/tunnel.log
StandardError=append:${LOG_DIR}/tunnel.log

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/udp-zivpn-bot.service << EOF
[Unit]
Description=UDP ZiVPN Telegram Bot
After=network.target udp-zivpn.service

[Service]
Type=simple
User=root
WorkingDirectory=${DATA_DIR}
ExecStart=/usr/bin/python3 ${DATA_DIR}/bot.py
Restart=on-failure
RestartSec=10s
StandardOutput=append:${LOG_DIR}/bot.log
StandardError=append:${LOG_DIR}/bot.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable udp-zivpn udp-zivpn-bot
log "Systemd services terdaftar"

# ================================================================
# STEP 9: LOGROTATE & CRON
# ================================================================
step "9. Setup Logrotate & Cron"

cat > /etc/logrotate.d/udp-zivpn << 'EOF'
/var/log/udp-zivpn/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF

(crontab -l 2>/dev/null | grep -v "udp-zivpn"; cat << 'CRON'
# UDP ZiVPN cek expired setiap jam
0 * * * * /usr/local/bin/udp-zivpn-manage check_expired >> /var/log/udp-zivpn/cron.log 2>&1
# UDP ZiVPN auto backup tiap hari jam 03:00
0 3 * * * /usr/local/bin/udp-zivpn-manage backup_telegram >> /var/log/udp-zivpn/cron.log 2>&1
CRON
) | crontab -
log "Logrotate & Cron dikonfigurasi"

# ================================================================
# STEP 10: FIREWALL
# ================================================================
step "10. Konfigurasi Firewall"
if command -v ufw &>/dev/null; then
    ufw allow "${UDP_PORT}/udp" 2>/dev/null
    ufw allow 22/tcp 2>/dev/null
    log "UFW: port ${UDP_PORT}/udp dibuka"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${UDP_PORT}/udp" 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    log "Firewalld: port ${UDP_PORT}/udp dibuka"
else
    iptables -A INPUT -p udp --dport "$UDP_PORT" -j ACCEPT 2>/dev/null
    log "iptables: port ${UDP_PORT}/udp dibuka"
fi

# ================================================================
# STEP 11: START SERVICES
# ================================================================
step "11. Menjalankan Services"

systemctl start udp-zivpn
sleep 2
if systemctl is-active --quiet udp-zivpn; then
    log "UDP ZiVPN Tunnel : ${G}BERJALAN${N}"
else
    warn "Tunnel gagal start. Cek: journalctl -u udp-zivpn -n 20"
fi

systemctl start udp-zivpn-bot
sleep 3
if systemctl is-active --quiet udp-zivpn-bot; then
    log "Telegram Bot     : ${G}BERJALAN${N}"
else
    warn "Bot gagal start. Cek: journalctl -u udp-zivpn-bot -n 20"
fi

# ================================================================
# SELESAI
# ================================================================
SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "N/A")

clear
echo -e "${G}"
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │           INSTALASI SELESAI!                         │"
echo "  └──────────────────────────────────────────────────────┘"
echo -e "${N}"
div
echo -e "  ${W}Info Server:${N}"
echo -e "  IP Server   : ${G}${SERVER_IP}${N}"
echo -e "  VPS Name    : ${G}${VPS_NAME}${N}"
echo -e "  UDP Port    : ${G}${UDP_PORT}${N}"
echo -e "  OBFS Pass   : ${G}${OBFS_PASS}${N}"
div
echo -e "  ${W}Status:${N}"
systemctl is-active --quiet udp-zivpn     && echo -e "  Tunnel    : ${G}● Berjalan${N}" || echo -e "  Tunnel    : ${R}● Mati${N}"
systemctl is-active --quiet udp-zivpn-bot && echo -e "  Bot TG    : ${G}● Berjalan${N}" || echo -e "  Bot TG    : ${R}● Mati${N}"
div
echo -e "  ${W}Perintah:${N}"
echo -e "  ${C}tunnel${N}           - Menu management VPS"
echo -e "  ${C}vpnmanage status${N} - Cek status server"
echo -e "  ${C}vpnmanage backup${N} - Backup & kirim Telegram"
div
echo -e "  ${Y}PENTING:${N}"
echo -e "  1. Buka Telegram → cari bot → ketik /start"
echo -e "  2. Upload foto QRIS di menu ⚙️ Pengaturan → Upload QRIS"
echo -e "  3. Untuk VPS ke-2: jalankan installer ini di VPS baru,"
echo -e "     lalu tambah region di bot Telegram (Owner only)"
div
