#!/bin/bash
# ============================================================
# UDP ZiVPN Tunnel Manager (DIPERBAIKI)
# Full-featured tunnel management with backup/restore
# ============================================================

BINARY_URL="https://github.com/fauzanihanipah/ziv-udp/releases/download/udp-zivpn/udp-zivpn-linux-amd64"

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/udp-zivpn"
LOG_DIR="/var/log/udp-zivpn"
DATA_DIR="/var/lib/udp-zivpn"
BINARY="$INSTALL_DIR/udp-zivpn"
CONFIG_FILE="$CONFIG_DIR/config.json"
USERS_FILE="$DATA_DIR/users.json"
SERVICE_NAME="udp-zivpn"
BOT_CONFIG="$DATA_DIR/bot.conf"
VERSION="2.0.1-FIXED"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║      UDP ZiVPN Tunnel Manager v${VERSION}           ║"
    echo "║     Multi-Region VPN Tunnel Management                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log() {
    echo -e "${GREEN}[✓]${NC} $1"
    [[ -d "$LOG_DIR" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_DIR/tunnel.log" 2>/dev/null
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
    [[ -d "$LOG_DIR" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$LOG_DIR/tunnel.log" 2>/dev/null
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    [[ -d "$LOG_DIR" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_DIR/tunnel.log" 2>/dev/null
}

info() {
    echo -e "${BLUE}[i]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Script harus dijalankan sebagai root!"
        echo "Gunakan: sudo bash $0"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$CONFIG_DIR/backup" 2>/dev/null
    chmod 700 "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null
}

ensure_json_exists() {
    [[ ! -f "$USERS_FILE" ]] && echo '{"users":[]}' > "$USERS_FILE"
}

# ============================================================
# STATUS CHECK
# ============================================================

status_check() {
    banner
    echo -e "${CYAN}━━━ Status Tunnel ━━━${NC}\n"

    # Check tunnel service
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  Service Tunnel      : ${GREEN}✓ BERJALAN${NC}"
    else
        echo -e "  Service Tunnel      : ${RED}✗ MATI${NC}"
    fi

    # Check bot service
    if systemctl is-active --quiet "${SERVICE_NAME}-bot" 2>/dev/null; then
        echo -e "  Service Bot         : ${GREEN}✓ BERJALAN${NC}"
    else
        echo -e "  Service Bot         : ${RED}✗ MATI${NC}"
    fi

    # Check config
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "  Config Tunnel       : ${GREEN}✓ ADA${NC}"
        UDP_PORT=$(jq -r '.listen' "$CONFIG_FILE" 2>/dev/null | cut -d: -f2)
        [[ -n "$UDP_PORT" ]] && echo -e "  Port UDP            : ${GREEN}$UDP_PORT${NC}"
    else
        echo -e "  Config Tunnel       : ${RED}✗ TIDAK ADA${NC}"
    fi

    # Check binary
    if [[ -x "$BINARY" ]]; then
        echo -e "  Binary Tunnel       : ${GREEN}✓ OK${NC}"
    else
        echo -e "  Binary Tunnel       : ${RED}✗ TIDAK EXECUTABLE${NC}"
    fi

    # Check bot config
    if [[ -f "$BOT_CONFIG" ]]; then
        echo -e "  Bot Config          : ${GREEN}✓ ADA${NC}"
        TG_TOKEN=$(grep "TG_TOKEN=" "$BOT_CONFIG" 2>/dev/null | cut -d'=' -f2 | cut -d'"' -f2)
        [[ -n "$TG_TOKEN" ]] && echo -e "  Bot Token           : ${GREEN}Valid${NC}" || echo -e "  Bot Token           : ${RED}Kosong${NC}"
    else
        echo -e "  Bot Config          : ${RED}✗ TIDAK ADA${NC}"
    fi

    # Check network port
    if command -v netstat &>/dev/null; then
        LISTENING_PORT=$(netstat -tulpn 2>/dev/null | grep "udp.*36712\|udp.*$(echo $UDP_PORT)" | wc -l)
        if [[ $LISTENING_PORT -gt 0 ]]; then
            echo -e "  Port Listening      : ${GREEN}✓ YES${NC}"
        else
            echo -e "  Port Listening      : ${YELLOW}? Belum setup${NC}"
        fi
    fi

    echo ""
}

# ============================================================
# SERVICE MANAGEMENT
# ============================================================

start_tunnel() {
    log "Menjalankan tunnel..."
    systemctl start "$SERVICE_NAME" 2>/dev/null
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "Tunnel berhasil dijalankan"
    else
        error "Tunnel gagal dijalankan"
        warn "Cek: journalctl -u $SERVICE_NAME -n 20"
    fi
}

stop_tunnel() {
    log "Menghentikan tunnel..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    sleep 1
    log "Tunnel dihentikan"
}

restart_tunnel() {
    log "Me-restart tunnel..."
    systemctl restart "$SERVICE_NAME" 2>/dev/null
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "Tunnel berhasil di-restart"
    else
        error "Tunnel gagal di-restart"
    fi
}

start_bot() {
    log "Menjalankan Telegram bot..."
    systemctl start "${SERVICE_NAME}-bot" 2>/dev/null
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}-bot"; then
        log "Bot berhasil dijalankan"
    else
        error "Bot gagal dijalankan"
        warn "Cek: journalctl -u ${SERVICE_NAME}-bot -n 20"
    fi
}

stop_bot() {
    log "Menghentikan bot..."
    systemctl stop "${SERVICE_NAME}-bot" 2>/dev/null
    sleep 1
    log "Bot dihentikan"
}

restart_bot() {
    log "Me-restart bot..."
    systemctl restart "${SERVICE_NAME}-bot" 2>/dev/null
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}-bot"; then
        log "Bot berhasil di-restart"
    else
        error "Bot gagal di-restart"
    fi
}

# ============================================================
# BACKUP & RESTORE
# ============================================================

backup_data() {
    banner
    echo -e "${CYAN}━━━ Backup Data ━━━${NC}\n"

    BACKUP_FILE="$CONFIG_DIR/backup/backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p "$CONFIG_DIR/backup"

    log "Membuat backup ke: $BACKUP_FILE"
    tar -czf "$BACKUP_FILE" \
        "$CONFIG_FILE" \
        "$USERS_FILE" \
        "$DATA_DIR/settings.json" \
        "$DATA_DIR/bot.conf" 2>/dev/null

    if [[ -f "$BACKUP_FILE" ]]; then
        SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        log "Backup berhasil dibuat ($SIZE)"
        echo -e "  Lokasi: ${GREEN}$BACKUP_FILE${NC}"
    else
        error "Backup gagal"
    fi
    echo ""
}

list_backups() {
    banner
    echo -e "${CYAN}━━━ Daftar Backup ━━━${NC}\n"

    if [[ -d "$CONFIG_DIR/backup" ]]; then
        ls -lh "$CONFIG_DIR/backup"/backup-*.tar.gz 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
    else
        warn "Belum ada backup"
    fi
    echo ""
}

# ============================================================
# USER MANAGEMENT
# ============================================================

add_user() {
    banner
    echo -e "${CYAN}━━━ Tambah User Baru ━━━${NC}\n"

    read -p "  Username: " USERNAME
    [[ -z "$USERNAME" ]] && error "Username tidak boleh kosong" && return 1

    read -sp "  Password: " PASSWORD
    echo ""
    [[ -z "$PASSWORD" ]] && error "Password tidak boleh kosong" && return 1

    # Update config.json auth
    if [[ -f "$CONFIG_FILE" ]]; then
        HASHED_PASS=$(echo -n "$PASSWORD" | sha256sum | cut -d' ' -f1)
        jq ".auth.userpass[\"$USERNAME\"] = \"$HASHED_PASS\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" 2>/dev/null
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        systemctl restart "$SERVICE_NAME" 2>/dev/null
        log "User '$USERNAME' berhasil ditambahkan"
    else
        error "Config.json tidak ditemukan"
    fi
    echo ""
}

list_users() {
    banner
    echo -e "${CYAN}━━━ Daftar User ━━━${NC}\n"

    if [[ -f "$CONFIG_FILE" ]]; then
        USERS=$(jq '.auth.userpass | keys[]' "$CONFIG_FILE" 2>/dev/null)
        if [[ -n "$USERS" ]]; then
            echo "$USERS" | while read user; do
                echo "  - $user"
            done
        else
            warn "Belum ada user"
        fi
    else
        error "Config.json tidak ditemukan"
    fi
    echo ""
}

# ============================================================
# SPEED TEST
# ============================================================

speedtest() {
    banner
    echo -e "${CYAN}━━━ Speed Test Ookla ━━━${NC}\n"

    if ! command -v speedtest &>/dev/null; then
        warn "speedtest-cli belum diinstall"
        info "Menginstall..."
        pip3 install --quiet speedtest-cli 2>/dev/null
    fi

    if command -v speedtest &>/dev/null; then
        log "Menjalankan speed test... (ini bisa memakan waktu 1-2 menit)"
        speedtest --simple
    else
        error "speedtest-cli gagal diinstall"
    fi
    echo ""
}

# ============================================================
# LOG VIEWER
# ============================================================

view_log_tunnel() {
    banner
    echo -e "${CYAN}━━━ Log Tunnel (real-time) ━━━${NC}\n"
    echo "Tekan CTRL+C untuk keluar"
    echo ""
    tail -f "$LOG_DIR/tunnel.log" 2>/dev/null || warn "Log tunnel tidak ditemukan"
}

view_log_bot() {
    banner
    echo -e "${CYAN}━━━ Log Bot Telegram (real-time) ━━━${NC}\n"
    echo "Tekan CTRL+C untuk keluar"
    echo ""
    tail -f "$LOG_DIR/bot.log" 2>/dev/null || warn "Log bot tidak ditemukan"
}

view_log_cron() {
    banner
    echo -e "${CYAN}━━━ Log Cron Jobs ━━━${NC}\n"
    tail -n 30 "$LOG_DIR/cron.log" 2>/dev/null || warn "Log cron tidak ditemukan"
    echo ""
}

# ============================================================
# CONFIGURATION
# ============================================================

show_config() {
    banner
    echo -e "${CYAN}━━━ Konfigurasi Tunnel ━━━${NC}\n"

    if [[ -f "$CONFIG_FILE" ]]; then
        jq '.' "$CONFIG_FILE" 2>/dev/null || cat "$CONFIG_FILE"
    else
        error "Config.json tidak ditemukan"
    fi
    echo ""
}

show_bot_config() {
    banner
    echo -e "${CYAN}━━━ Konfigurasi Bot ━━━${NC}\n"

    if [[ -f "$BOT_CONFIG" ]]; then
        cat "$BOT_CONFIG" | while read line; do
            KEY=$(echo "$line" | cut -d'=' -f1)
            VALUE=$(echo "$line" | cut -d'=' -f2- | cut -d'"' -f2)
            if [[ "$KEY" == "TG_TOKEN" ]] && [[ ${#VALUE} -gt 10 ]]; then
                VALUE="${VALUE:0:10}...${VALUE: -10}"
            fi
            echo "  $KEY = $VALUE"
        done
    else
        error "Bot config tidak ditemukan"
    fi
    echo ""
}

# ============================================================
# INTERACTIVE MENU
# ============================================================

show_menu() {
    banner
    echo -e "${CYAN}Pilih menu:${NC}\n"
    echo "  ${GREEN}1${NC}. Status Tunnel & Bot"
    echo "  ${GREEN}2${NC}. Start/Stop/Restart Services"
    echo "  ${GREEN}3${NC}. Kelola User"
    echo "  ${GREEN}4${NC}. Backup & Restore"
    echo "  ${GREEN}5${NC}. Speed Test"
    echo "  ${GREEN}6${NC}. Lihat Log"
    echo "  ${GREEN}7${NC}. Konfigurasi"
    echo "  ${GREEN}0${NC}. Exit"
    echo ""
    read -p "  Pilihan: " MENU
}

menu_service_control() {
    banner
    echo -e "${CYAN}━━━ Kontrol Service ━━━${NC}\n"
    echo "  ${GREEN}1${NC}. Start Tunnel"
    echo "  ${GREEN}2${NC}. Stop Tunnel"
    echo "  ${GREEN}3${NC}. Restart Tunnel"
    echo "  ${GREEN}4${NC}. Start Bot"
    echo "  ${GREEN}5${NC}. Stop Bot"
    echo "  ${GREEN}6${NC}. Restart Bot"
    echo "  ${GREEN}7${NC}. Restart Semua"
    echo "  ${GREEN}0${NC}. Back"
    echo ""
    read -p "  Pilihan: " CHOICE

    case $CHOICE in
        1) start_tunnel ;;
        2) stop_tunnel ;;
        3) restart_tunnel ;;
        4) start_bot ;;
        5) stop_bot ;;
        6) restart_bot ;;
        7) restart_tunnel && restart_bot ;;
        0) return ;;
        *) error "Pilihan tidak valid" ;;
    esac
    read -p "Press Enter to continue..." && menu_service_control
}

menu_user_management() {
    banner
    echo -e "${CYAN}━━━ Kelola User ━━━${NC}\n"
    echo "  ${GREEN}1${NC}. Tambah User Baru"
    echo "  ${GREEN}2${NC}. Daftar User"
    echo "  ${GREEN}3${NC}. Hapus User"
    echo "  ${GREEN}0${NC}. Back"
    echo ""
    read -p "  Pilihan: " CHOICE

    case $CHOICE in
        1) add_user ;;
        2) list_users ;;
        3) banner; echo "Feature coming soon"; sleep 1 ;;
        0) return ;;
        *) error "Pilihan tidak valid" ;;
    esac
    read -p "Press Enter to continue..." && menu_user_management
}

menu_backup() {
    banner
    echo -e "${CYAN}━━━ Backup & Restore ━━━${NC}\n"
    echo "  ${GREEN}1${NC}. Backup Data Sekarang"
    echo "  ${GREEN}2${NC}. Lihat Daftar Backup"
    echo "  ${GREEN}0${NC}. Back"
    echo ""
    read -p "  Pilihan: " CHOICE

    case $CHOICE in
        1) backup_data ;;
        2) list_backups ;;
        0) return ;;
        *) error "Pilihan tidak valid" ;;
    esac
    read -p "Press Enter to continue..." && menu_backup
}

menu_logs() {
    banner
    echo -e "${CYAN}━━━ Lihat Log ━━━${NC}\n"
    echo "  ${GREEN}1${NC}. Log Tunnel (Real-time)"
    echo "  ${GREEN}2${NC}. Log Bot (Real-time)"
    echo "  ${GREEN}3${NC}. Log Cron Jobs"
    echo "  ${GREEN}0${NC}. Back"
    echo ""
    read -p "  Pilihan: " CHOICE

    case $CHOICE in
        1) view_log_tunnel ;;
        2) view_log_bot ;;
        3) view_log_cron ;;
        0) return ;;
        *) error "Pilihan tidak valid" ;;
    esac
    read -p "Press Enter to continue..." && menu_logs
}

menu_config() {
    banner
    echo -e "${CYAN}━━━ Konfigurasi ━━━${NC}\n"
    echo "  ${GREEN}1${NC}. Lihat Tunnel Config"
    echo "  ${GREEN}2${NC}. Lihat Bot Config"
    echo "  ${GREEN}3${NC}. Edit Tunnel Config"
    echo "  ${GREEN}0${NC}. Back"
    echo ""
    read -p "  Pilihan: " CHOICE

    case $CHOICE in
        1) show_config; read -p "Press Enter..." ;;
        2) show_bot_config; read -p "Press Enter..." ;;
        3) nano "$CONFIG_FILE" ;;
        0) return ;;
        *) error "Pilihan tidak valid" ;;
    esac
}

# ============================================================
# COMMAND LINE ARGUMENTS
# ============================================================

case "${1:-}" in
    status)
        check_root
        ensure_dirs
        status_check
        ;;
    start)
        check_root
        start_tunnel
        ;;
    stop)
        check_root
        stop_tunnel
        ;;
    restart)
        check_root
        restart_tunnel
        ;;
    backup)
        check_root
        ensure_dirs
        backup_data
        ;;
    speedtest)
        check_root
        speedtest
        ;;
    add_user)
        check_root
        ensure_dirs
        add_user
        ;;
    list_users)
        check_root
        ensure_dirs
        list_users
        ;;
    *)
        check_root
        ensure_dirs
        
        # Interactive mode
        while true; do
            show_menu
            case $MENU in
                1) status_check; read -p "Press Enter..." ;;
                2) menu_service_control ;;
                3) menu_user_management ;;
                4) menu_backup ;;
                5) speedtest; read -p "Press Enter..." ;;
                6) menu_logs ;;
                7) menu_config ;;
                0) log "Goodbye!"; exit 0 ;;
                *) error "Pilihan tidak valid"; sleep 1 ;;
            esac
        done
        ;;
esac
