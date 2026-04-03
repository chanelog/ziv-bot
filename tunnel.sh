#!/bin/bash
# ============================================================
# UDP ZiVPN Tunnel Manager
# Full-featured tunnel management with backup/restore
# ============================================================

BINARY_URL="https://github.com/fauzanihanipah/ziv-udp/releases/download/udp-zivpn/udp-zivpn-linux-amd64"
CONFIG_URL="https://raw.githubusercontent.com/fauzanihanipah/ziv-udp/main/config.json"

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/udp-zivpn"
LOG_DIR="/var/log/udp-zivpn"
DATA_DIR="/var/lib/udp-zivpn"
BINARY="$INSTALL_DIR/udp-zivpn"
CONFIG_FILE="$CONFIG_DIR/config.json"
USERS_FILE="$DATA_DIR/users.json"
SERVICE_NAME="udp-zivpn"
BOT_CONFIG="$DATA_DIR/bot.conf"
VERSION="2.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          UDP ZiVPN Tunnel Manager v${VERSION}              ║"
    echo "║         Multi-Region VPN Tunnel Management               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log() {
    echo -e "${GREEN}[✓]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_DIR/tunnel.log"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$LOG_DIR/tunnel.log"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_DIR/tunnel.log"
}

info() {
    echo -e "${BLUE}[i]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Script harus dijalankan sebagai root!"
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "wget" "jq" "python3" "pip3" "screen" "iperf3")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Menginstall dependensi yang kurang: ${missing[*]}"
        apt-get update -qq
        apt-get install -y "${missing[@]}" 2>/dev/null || yum install -y "${missing[@]}" 2>/dev/null
    fi
}

init_dirs() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$CONFIG_DIR/backup"
    
    # Init users.json jika belum ada
    if [[ ! -f "$USERS_FILE" ]]; then
        echo '{"users":[]}' > "$USERS_FILE"
    fi
}

# ============================================================
# INSTALLATION
# ============================================================
install_tunnel() {
    banner
    log "Memulai instalasi UDP ZiVPN..."
    
    check_root
    check_dependencies
    init_dirs
    
    # Download binary
    log "Mendownload binary UDP ZiVPN..."
    wget -q --show-progress -O "$BINARY" "$BINARY_URL"
    chmod +x "$BINARY"
    
    # Download config
    log "Mendownload konfigurasi default..."
    wget -q -O "$CONFIG_FILE" "$CONFIG_URL"
    
    # Setup systemd service
    log "Membuat systemd service..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service << 'EOF'
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

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    
    # Setup logrotate
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
    
    # Install Python bot dependencies
    log "Menginstall dependensi Telegram bot..."
    pip3 install python-telegram-bot requests speedtest-cli qrcode pillow pytz aiohttp asyncio 2>/dev/null
    
    log "Instalasi selesai!"
    
    # Konfigurasi awal
    configure_initial
}

configure_initial() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${WHITE}  Konfigurasi Awal UDP ZiVPN               ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    
    read -p "Masukkan Port UDP (default: 36712): " UDP_PORT
    UDP_PORT=${UDP_PORT:-36712}
    
    read -p "Masukkan Password Obfuscation (default: zivpn2024): " OBFS_PASS
    OBFS_PASS=${OBFS_PASS:-zivpn2024}
    
    read -p "Masukkan Max Upload Bandwidth (Mbps, default: 100): " UP_BW
    UP_BW=${UP_BW:-100}
    
    read -p "Masukkan Max Download Bandwidth (Mbps, default: 100): " DOWN_BW
    DOWN_BW=${DOWN_BW:-100}
    
    read -p "Masukkan Telegram Bot Token: " TG_TOKEN
    read -p "Masukkan Telegram Owner ID: " TG_OWNER_ID
    read -p "Masukkan nama VPS/Region ini (contoh: VPS-SG-1): " VPS_NAME
    
    # Buat config.json
    cat > "$CONFIG_FILE" << EOF
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
        "tcp": {
            "addr": "8.8.8.8:53",
            "timeout": "4s"
        },
        "udp": {
            "addr": "8.8.8.8:53",
            "timeout": "4s"
        }
    },
    "acl": {
        "inline": [
            "reject(geoip:cn)",
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
    cat > "$BOT_CONFIG" << EOF
TG_TOKEN="${TG_TOKEN}"
TG_OWNER_ID="${TG_OWNER_ID}"
VPS_NAME="${VPS_NAME}"
UDP_PORT="${UDP_PORT}"
OBFS_PASS="${OBFS_PASS}"
EOF
    
    # Mulai service
    systemctl start "$SERVICE_NAME"
    
    log "Konfigurasi tersimpan!"
    log "Service UDP ZiVPN dimulai di port ${UDP_PORT}"
    
    # Setup dan jalankan bot
    setup_telegram_bot
    
    echo ""
    echo -e "${GREEN}Instalasi dan konfigurasi selesai!${NC}"
    echo -e "${YELLOW}Jalankan: bash tunnel.sh untuk membuka menu${NC}"
}

# ============================================================
# SERVICE MANAGEMENT
# ============================================================
start_service() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "Service sudah berjalan"
    else
        systemctl start "$SERVICE_NAME"
        log "Service UDP ZiVPN dimulai"
    fi
}

stop_service() {
    systemctl stop "$SERVICE_NAME"
    log "Service UDP ZiVPN dihentikan"
}

restart_service() {
    systemctl restart "$SERVICE_NAME"
    log "Service UDP ZiVPN direstart"
}

status_service() {
    echo ""
    echo -e "${CYAN}═══════════════════════════ STATUS SERVICE ═══════════════════════════${NC}"
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "Status UDP ZiVPN : ${GREEN}● BERJALAN${NC}"
    else
        echo -e "Status UDP ZiVPN : ${RED}● BERHENTI${NC}"
    fi
    
    source "$BOT_CONFIG" 2>/dev/null
    echo -e "VPS Name         : ${WHITE}${VPS_NAME:-Unknown}${NC}"
    echo -e "UDP Port         : ${WHITE}${UDP_PORT:-36712}${NC}"
    echo -e "Server IP        : ${WHITE}$(curl -s4 ifconfig.me 2>/dev/null || echo 'N/A')${NC}"
    
    # Hitung user aktif
    local total_users=$(jq '.users | length' "$USERS_FILE" 2>/dev/null || echo 0)
    local active_users=$(jq '[.users[] | select(.active == true)] | length' "$USERS_FILE" 2>/dev/null || echo 0)
    local expired_users=$(jq '[.users[] | select(.active == false)] | length' "$USERS_FILE" 2>/dev/null || echo 0)
    
    echo -e "Total User       : ${WHITE}${total_users}${NC}"
    echo -e "User Aktif       : ${GREEN}${active_users}${NC}"
    echo -e "User Expired     : ${RED}${expired_users}${NC}"
    
    echo ""
    echo -e "${CYAN}═══════════════════════════ RESOURCE USAGE ══════════════════════════${NC}"
    echo -e "CPU Usage        : ${WHITE}$(top -bn1 | grep load | awk '{printf "%.1f%%", $(NF-2)}')${NC}"
    echo -e "RAM Usage        : ${WHITE}$(free -m | awk 'NR==2{printf "%s/%sMB (%.1f%%)", $3,$2,$3*100/$2}')${NC}"
    echo -e "Disk Usage       : ${WHITE}$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')${NC}"
    echo -e "Uptime           : ${WHITE}$(uptime -p)${NC}"
    echo ""
}

# ============================================================
# USER MANAGEMENT
# ============================================================
add_user() {
    local username="$1"
    local password="$2"
    local duration="$3"  # dalam hari
    local created_by="${4:-admin}"
    
    if [[ -z "$username" || -z "$password" ]]; then
        read -p "Username: " username
        read -p "Password: " password
        read -p "Durasi (hari): " duration
    fi
    
    duration=${duration:-30}
    
    # Cek apakah user sudah ada
    local exists=$(jq --arg u "$username" '.users[] | select(.username == $u)' "$USERS_FILE" 2>/dev/null)
    if [[ -n "$exists" ]]; then
        error "User '$username' sudah ada!"
        return 1
    fi
    
    local expire_date=$(date -d "+${duration} days" '+%Y-%m-%d %H:%M:%S')
    local created_date=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Tambahkan ke users.json
    jq --arg u "$username" \
       --arg p "$password" \
       --arg e "$expire_date" \
       --arg c "$created_date" \
       --arg b "$created_by" \
       --argjson d "$duration" \
       '.users += [{
           "username": $u,
           "password": $p,
           "expire": $e,
           "created": $c,
           "created_by": $b,
           "duration": $d,
           "active": true,
           "bytes_sent": 0,
           "bytes_recv": 0
       }]' "$USERS_FILE" > /tmp/users_tmp.json && mv /tmp/users_tmp.json "$USERS_FILE"
    
    # Update config.json untuk auth
    update_auth_config
    
    log "User '$username' berhasil dibuat, expire: $expire_date"
    
    # Return info untuk bot
    echo "$username|$password|$expire_date|$duration"
}

delete_user() {
    local username="$1"
    
    if [[ -z "$username" ]]; then
        read -p "Username yang akan dihapus: " username
    fi
    
    jq --arg u "$username" 'del(.users[] | select(.username == $u))' "$USERS_FILE" > /tmp/users_tmp.json && mv /tmp/users_tmp.json "$USERS_FILE"
    
    update_auth_config
    log "User '$username' dihapus"
}

renew_user() {
    local username="$1"
    local duration="$2"
    
    if [[ -z "$username" ]]; then
        read -p "Username: " username
        read -p "Durasi perpanjangan (hari): " duration
    fi
    
    duration=${duration:-30}
    local new_expire=$(date -d "+${duration} days" '+%Y-%m-%d %H:%M:%S')
    
    jq --arg u "$username" --arg e "$new_expire" --argjson d "$duration" \
       '(.users[] | select(.username == $u)) |= . + {"expire": $e, "duration": $d, "active": true}' \
       "$USERS_FILE" > /tmp/users_tmp.json && mv /tmp/users_tmp.json "$USERS_FILE"
    
    update_auth_config
    log "User '$username' diperpanjang hingga $new_expire"
    echo "$new_expire"
}

list_users() {
    echo ""
    echo -e "${CYAN}══════════════════════════ DAFTAR USER ══════════════════════════════${NC}"
    printf "%-20s %-15s %-22s %-10s\n" "USERNAME" "STATUS" "EXPIRE" "CREATOR"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────${NC}"
    
    jq -r '.users[] | "\(.username)|\(.active)|\(.expire)|\(.created_by)"' "$USERS_FILE" 2>/dev/null | while IFS='|' read -r uname active expire creator; do
        local now=$(date +%s)
        local exp=$(date -d "$expire" +%s 2>/dev/null || echo 0)
        
        if [[ "$active" == "true" && $exp -gt $now ]]; then
            status="${GREEN}AKTIF${NC}"
        else
            status="${RED}EXPIRED${NC}"
        fi
        
        printf "%-20s " "$uname"
        echo -e "${status}"
        printf "%45s %-22s %-10s\n" "" "$expire" "$creator"
    done
    echo ""
}

check_expired_users() {
    local now=$(date '+%Y-%m-%d %H:%M:%S')
    
    jq --arg now "$now" \
       '(.users[] | select(.expire < $now and .active == true)) |= . + {"active": false}' \
       "$USERS_FILE" > /tmp/users_tmp.json && mv /tmp/users_tmp.json "$USERS_FILE"
    
    update_auth_config
}

update_auth_config() {
    # Baca semua user aktif dan update config
    local userpass=$(jq -r '.users[] | select(.active == true) | "\(.username): \"\(.password)\""' "$USERS_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    
    # Update auth section di config.json
    local auth_json=$(jq -r '.users[] | select(.active == true) | {(.username): .password}' "$USERS_FILE" 2>/dev/null | jq -s 'add // {}')
    
    jq --argjson auth "$auth_json" '.auth.userpass = $auth' "$CONFIG_FILE" > /tmp/config_tmp.json && mv /tmp/config_tmp.json "$CONFIG_FILE"
    
    # Restart service untuk apply config baru
    systemctl reload-or-restart "$SERVICE_NAME" 2>/dev/null
}

# ============================================================
# BACKUP & RESTORE
# ============================================================
backup_config() {
    local backup_name="backup_$(date '+%Y%m%d_%H%M%S')"
    local backup_dir="/tmp/${backup_name}"
    local backup_file="${backup_dir}.tar.gz"
    
    mkdir -p "$backup_dir"
    
    # Copy semua file penting
    cp "$CONFIG_FILE" "$backup_dir/config.json"
    cp "$USERS_FILE" "$backup_dir/users.json"
    cp "$BOT_CONFIG" "$backup_dir/bot.conf" 2>/dev/null
    
    # Tambahkan metadata
    cat > "$backup_dir/metadata.json" << EOF
{
    "backup_date": "$(date '+%Y-%m-%d %H:%M:%S')",
    "vps_name": "$(source $BOT_CONFIG 2>/dev/null && echo $VPS_NAME)",
    "server_ip": "$(curl -s4 ifconfig.me 2>/dev/null)",
    "total_users": $(jq '.users | length' "$USERS_FILE" 2>/dev/null || echo 0),
    "version": "${VERSION}"
}
EOF
    
    # Compress backup
    tar -czf "$backup_file" -C "/tmp" "$backup_name"
    rm -rf "$backup_dir"
    
    log "Backup dibuat: $backup_file"
    echo "$backup_file"
}

send_backup_telegram() {
    source "$BOT_CONFIG" 2>/dev/null
    
    if [[ -z "$TG_TOKEN" || -z "$TG_OWNER_ID" ]]; then
        error "Konfigurasi Telegram tidak ditemukan!"
        return 1
    fi
    
    local backup_file=$(backup_config)
    
    log "Mengirim backup ke Telegram..."
    
    # Kirim file ke Telegram
    local response=$(curl -s -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
        -F "chat_id=${TG_OWNER_ID}" \
        -F "document=@${backup_file}" \
        -F "caption=🔒 *Backup UDP ZiVPN*%0A📅 $(date '+%Y-%m-%d %H:%M:%S')%0A🖥 VPS: ${VPS_NAME}" \
        -F "parse_mode=Markdown")
    
    if echo "$response" | jq -e '.ok == true' &>/dev/null; then
        log "Backup berhasil dikirim ke Telegram!"
        # Simpan file_id untuk restore
        local file_id=$(echo "$response" | jq -r '.result.document.file_id')
        echo "$file_id" > "$DATA_DIR/last_backup_file_id.txt"
        log "File ID backup: $file_id"
    else
        error "Gagal mengirim backup ke Telegram"
        error "Response: $response"
    fi
    
    rm -f "$backup_file"
}

restore_from_telegram() {
    source "$BOT_CONFIG" 2>/dev/null
    
    if [[ -z "$TG_TOKEN" || -z "$TG_OWNER_ID" ]]; then
        error "Konfigurasi Telegram tidak ditemukan!"
        return 1
    fi
    
    local file_id="$1"
    
    if [[ -z "$file_id" ]]; then
        if [[ -f "$DATA_DIR/last_backup_file_id.txt" ]]; then
            file_id=$(cat "$DATA_DIR/last_backup_file_id.txt")
            info "Menggunakan file_id terakhir: $file_id"
        else
            read -p "Masukkan File ID backup dari Telegram: " file_id
        fi
    fi
    
    log "Mengambil backup dari Telegram..."
    
    # Dapatkan URL file
    local file_info=$(curl -s "https://api.telegram.org/bot${TG_TOKEN}/getFile?file_id=${file_id}")
    local file_path=$(echo "$file_info" | jq -r '.result.file_path')
    
    if [[ "$file_path" == "null" || -z "$file_path" ]]; then
        error "File ID tidak valid atau file sudah expired!"
        return 1
    fi
    
    # Download file
    local restore_file="/tmp/restore_$(date '+%Y%m%d_%H%M%S').tar.gz"
    wget -q "https://api.telegram.org/file/bot${TG_TOKEN}/${file_path}" -O "$restore_file"
    
    if [[ ! -f "$restore_file" ]]; then
        error "Gagal mendownload backup!"
        return 1
    fi
    
    # Extract dan restore
    local restore_dir="/tmp/restore_$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$restore_dir"
    tar -xzf "$restore_file" -C "$restore_dir"
    
    # Cari file-file backup
    local backup_subdir=$(ls "$restore_dir" | head -1)
    
    if [[ -f "$restore_dir/$backup_subdir/config.json" ]]; then
        # Backup config yang ada dulu
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
        cp "$USERS_FILE" "${USERS_FILE}.bak"
        
        # Restore
        cp "$restore_dir/$backup_subdir/config.json" "$CONFIG_FILE"
        cp "$restore_dir/$backup_subdir/users.json" "$USERS_FILE"
        
        log "Backup berhasil direstore!"
        
        # Restart service
        systemctl restart "$SERVICE_NAME"
        log "Service direstart dengan konfigurasi baru"
    else
        error "File backup tidak valid!"
    fi
    
    rm -rf "$restore_dir" "$restore_file"
}

# ============================================================
# SPEED TEST
# ============================================================
run_speedtest() {
    echo ""
    echo -e "${CYAN}═══════════════════════════ SPEED TEST ══════════════════════════════${NC}"
    echo -e "${YELLOW}Menjalankan speed test via Ookla...${NC}"
    echo ""
    
    # Install speedtest-cli jika belum ada
    if ! command -v speedtest-cli &>/dev/null; then
        pip3 install speedtest-cli 2>/dev/null
    fi
    
    # Gunakan official speedtest CLI
    if ! command -v speedtest &>/dev/null; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash 2>/dev/null
        apt-get install -y speedtest 2>/dev/null
    fi
    
    # Jalankan speedtest
    if command -v speedtest &>/dev/null; then
        speedtest --accept-license --accept-gdpr
    elif command -v speedtest-cli &>/dev/null; then
        speedtest-cli --simple
    else
        error "Speedtest tidak tersedia"
        # Fallback: iperf3 test
        echo -e "${YELLOW}Menggunakan iperf3 sebagai fallback...${NC}"
        iperf3 -c iperf.he.net -t 10 2>/dev/null || echo "Iperf3 test gagal"
    fi
    
    echo ""
}

# ============================================================
# AUTO CRON JOBS
# ============================================================
setup_cron() {
    # Hapus cron lama
    crontab -l 2>/dev/null | grep -v "udp-zivpn" | crontab -
    
    # Tambahkan cron baru
    (crontab -l 2>/dev/null; cat << 'CRON'
# UDP ZiVPN - Cek expired users setiap jam
0 * * * * /usr/local/bin/udp-zivpn-manage check_expired
# UDP ZiVPN - Auto backup setiap hari jam 3 pagi
0 3 * * * /usr/local/bin/udp-zivpn-manage backup_telegram
# UDP ZiVPN - Restart service setiap Minggu
0 4 * * 0 systemctl restart udp-zivpn
CRON
    ) | crontab -
    
    log "Cron jobs berhasil dikonfigurasi"
}

# ============================================================
# MENU UTAMA
# ============================================================
main_menu() {
    while true; do
        banner
        status_service
        
        echo -e "${CYAN}═══════════════════════════ MENU UTAMA ══════════════════════════════${NC}"
        echo -e "${WHITE}[1]${NC}  Tambah User"
        echo -e "${WHITE}[2]${NC}  Hapus User"
        echo -e "${WHITE}[3]${NC}  Perpanjang User"
        echo -e "${WHITE}[4]${NC}  Daftar User"
        echo -e "${WHITE}[5]${NC}  ─────────────────────────────────"
        echo -e "${WHITE}[6]${NC}  Start Service"
        echo -e "${WHITE}[7]${NC}  Stop Service"
        echo -e "${WHITE}[8]${NC}  Restart Service"
        echo -e "${WHITE}[9]${NC}  ─────────────────────────────────"
        echo -e "${WHITE}[10]${NC} Backup & Kirim ke Telegram"
        echo -e "${WHITE}[11]${NC} Restore dari Telegram"
        echo -e "${WHITE}[12]${NC} ─────────────────────────────────"
        echo -e "${WHITE}[13]${NC} Speed Test (Ookla)"
        echo -e "${WHITE}[14]${NC} Lihat Log"
        echo -e "${WHITE}[15]${NC} Setup/Restart Bot Telegram"
        echo -e "${WHITE}[16]${NC} ─────────────────────────────────"
        echo -e "${WHITE}[0]${NC}  Keluar"
        echo -e "${CYAN}═════════════════════════════════════════════════════════════════════${NC}"
        
        read -p "Pilih menu: " choice
        
        case $choice in
            1) add_user ;;
            2) delete_user ;;
            3) renew_user ;;
            4) list_users ;;
            6) start_service ;;
            7) stop_service ;;
            8) restart_service ;;
            10) send_backup_telegram ;;
            11) restore_from_telegram ;;
            13) run_speedtest ;;
            14) tail -50 "$LOG_DIR/tunnel.log" | less ;;
            15) setup_telegram_bot && start_telegram_bot ;;
            0) exit 0 ;;
            *) warn "Pilihan tidak valid" ;;
        esac
        
        read -p "Tekan Enter untuk melanjutkan..."
    done
}

setup_telegram_bot() {
    source "$BOT_CONFIG" 2>/dev/null
    
    # Tulis bot script ke file
    cat > "$DATA_DIR/bot.py" << 'PYEOF'
# Bot Telegram - Di-generate oleh tunnel.sh
# File terpisah: /var/lib/udp-zivpn/bot.py
PYEOF
    
    # Salin bot.py dari template
    cp /home/claude/udp-zivpn/bot.py "$DATA_DIR/bot.py" 2>/dev/null || true
    log "Bot Telegram dikonfigurasi di $DATA_DIR/bot.py"
}

start_telegram_bot() {
    source "$BOT_CONFIG" 2>/dev/null
    
    # Hentikan bot yang ada
    pkill -f "python3 $DATA_DIR/bot.py" 2>/dev/null
    
    # Jalankan bot di background dengan screen
    screen -dmS tg-bot python3 "$DATA_DIR/bot.py" \
        --token "$TG_TOKEN" \
        --owner "$TG_OWNER_ID" \
        --vps-name "$VPS_NAME"
    
    log "Bot Telegram dijalankan di screen session 'tg-bot'"
}

# ============================================================
# CLI INTERFACE
# ============================================================
case "$1" in
    install) install_tunnel ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    status) status_service ;;
    add_user) add_user "$2" "$3" "$4" "$5" ;;
    del_user) delete_user "$2" ;;
    renew_user) renew_user "$2" "$3" ;;
    list_users) list_users ;;
    backup) send_backup_telegram ;;
    restore) restore_from_telegram "$2" ;;
    speedtest) run_speedtest ;;
    check_expired) check_expired_users ;;
    backup_telegram) send_backup_telegram ;;
    setup_cron) setup_cron ;;
    menu|"") main_menu ;;
    *) echo "Usage: $0 {install|start|stop|restart|status|add_user|del_user|renew_user|list_users|backup|restore|speedtest|menu}" ;;
esac
