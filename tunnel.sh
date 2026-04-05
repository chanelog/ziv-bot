#!/bin/bash
# ================================================================
#   UDP ZiVPN - Professional Manager v3.0
#   Author  : ZiVPN Team | Updated : 2026
# ================================================================

BINARY_URL="https://github.com/fauzanihanipah/ziv-udp/releases/download/udp-zivpn/udp-zivpn-linux-amd64"
CONFIG_URL="https://raw.githubusercontent.com/fauzanihanipah/ziv-udp/main/config.json"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/udp-zivpn"
CERT_DIR="/etc/zivpn"
LOG_DIR="/var/log/udp-zivpn"
DATA_DIR="/var/lib/udp-zivpn"
BINARY="$INSTALL_DIR/udp-zivpn"
CONFIG_FILE="$CONFIG_DIR/config.json"
USERS_FILE="$DATA_DIR/users.json"
BOT_CONFIG="$DATA_DIR/bot.conf"
BOT_SCRIPT="$DATA_DIR/bot.py"
SERVICE_NAME="udp-zivpn"
BOT_SERVICE="udp-zivpn-bot"
VERSION="3.0.0"
PORTFW_CONFIG="$DATA_DIR/portfw.conf"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; P='\033[0;35m'
W='\033[1;37m'; D='\033[2;37m'; N='\033[0m'

# ================================================================
# HELPERS
# ================================================================
log()   { echo -e "${G}[✔]${N} $1"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"  >> "$LOG_DIR/tunnel.log" 2>/dev/null; }
warn()  { echo -e "${Y}[!]${N} $1"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1"  >> "$LOG_DIR/tunnel.log" 2>/dev/null; }
error() { echo -e "${R}[✘]${N} $1"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_DIR/tunnel.log" 2>/dev/null; }
info()  { echo -e "${C}[i]${N} $1"; }
press() { echo ""; echo -ne "  ${D}Tekan Enter untuk kembali...${N}"; read -r _; }
div()   { echo -e "  ${D}────────────────────────────────────────────────────────${N}"; }

check_root() { [[ $EUID -ne 0 ]] && error "Harus dijalankan sebagai root!" && exit 1; }

load_config() {
    [[ -f "$BOT_CONFIG" ]] && source "$BOT_CONFIG" 2>/dev/null
    UDP_PORT="${UDP_PORT:-5667}"
    VPS_NAME="${VPS_NAME:-VPS-1}"
    OBFS_PASS="${OBFS_PASS:-zivpn}"
    SERVER_IP=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "N/A")
}

init_dirs() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$CERT_DIR"
    [[ ! -f "$USERS_FILE" ]] && echo '{"users":[]}' > "$USERS_FILE"
    init_portfw_config
}

# ================================================================
# SETUP IPTABLES & UDP PORT FORWARDING
# ================================================================
setup_iptables_udp_forward() {
    local inp_port="${1:-5667}"
    
    info "Mengatur iptables & UDP port forwarding..."
    local IFACE
    IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    # Bersihkan rules lama
    while iptables -t nat -D PREROUTING \
        -i "$IFACE" -p udp --dport 6000:19999 \
        -j DNAT --to-destination :${inp_port} 2>/dev/null; do :; done
    
    # Tambah rules baru
    iptables -t nat -A PREROUTING \
        -i "$IFACE" -p udp --dport 6000:19999 \
        -j DNAT --to-destination :${inp_port}
    iptables -A FORWARD -p udp -d 127.0.0.1 --dport "${inp_port}" -j ACCEPT
    iptables -t nat -A POSTROUTING -s 127.0.0.1/32 -o "$IFACE" -j MASQUERADE
    
    # Simpan permanen
    netfilter-persistent save &>/dev/null
    log "IPTables: UDP 6000-19999 → ${inp_port} via $IFACE"
    
    # ── Firewall UFW ──────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        ufw allow 6000:19999/udp &>/dev/null
        ufw allow "${inp_port}/udp" &>/dev/null
        log "UFW: port 6000-19999/udp & ${inp_port}/udp dibuka"
    fi
    
    iptables -I INPUT -p udp --dport "${inp_port}" -j ACCEPT 2>/dev/null
}

# ================================================================
# ADVANCED CUSTOMIZABLE PORT FORWARDING
# ================================================================
init_portfw_config() {
    [[ ! -f "$PORTFW_CONFIG" ]] && cat > "$PORTFW_CONFIG" << 'EOF'
# UDP Port Forwarding Configuration
# Format: SOURCE_START:SOURCE_END|TARGET_PORT|NAME
# Example: 6000:9999|5667|Primary
# Multiple rules per line separated by semicolon

RULES=""
EOF
    chmod 600 "$PORTFW_CONFIG"
}

load_portfw_rules() {
    [[ -f "$PORTFW_CONFIG" ]] && source "$PORTFW_CONFIG" 2>/dev/null
}

save_portfw_rule() {
    local src_start="$1" src_end="$2" tgt_port="$3" name="$4"
    local rule_line="${src_start}:${src_end}|${tgt_port}|${name}"
    
    if [[ -z "$RULES" ]]; then
        RULES="$rule_line"
    else
        RULES="${RULES};${rule_line}"
    fi
    
    sed -i "s/^RULES=.*/RULES=\"$RULES\"/" "$PORTFW_CONFIG"
    log "Rule disimpan: $name ($src_start:$src_end → $tgt_port)"
}

apply_portfw_rule() {
    local src_start="$1" src_end="$2" tgt_port="$3" name="$4"
    
    local IFACE
    IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    info "Applying rule: $name ($src_start:$src_end → $tgt_port)"
    
    # PREROUTING DNAT
    iptables -t nat -A PREROUTING \
        -i "$IFACE" -p udp --dport ${src_start}:${src_end} \
        -j DNAT --to-destination :${tgt_port}
    
    # FORWARD
    iptables -A FORWARD -p udp -d 127.0.0.1 --dport ${tgt_port} -j ACCEPT
    
    # POSTROUTING
    iptables -t nat -A POSTROUTING -s 127.0.0.1/32 -o "$IFACE" -j MASQUERADE
    
    # INPUT
    iptables -I INPUT -p udp --dport ${tgt_port} -j ACCEPT 2>/dev/null
    
    # UFW
    if command -v ufw &>/dev/null; then
        ufw allow ${src_start}:${src_end}/udp &>/dev/null
        ufw allow ${tgt_port}/udp &>/dev/null
    fi
    
    log "Rule aktif: $name (${src_start}:${src_end} → ${tgt_port})"
}

list_portfw_rules() {
    load_portfw_rules
    banner
    echo -e "  ${W}DAFTAR PORT FORWARDING RULES${N}"
    div
    
    if [[ -z "$RULES" ]]; then
        echo -e "  ${Y}Belum ada rules yang dikonfigurasi${N}"
        div
        press
        return
    fi
    
    local counter=1
    IFS=';' read -ra RULE_ARRAY <<< "$RULES"
    
    echo -e "  ${W}#${N}  ${W}Source${N}          ${W}Target${N}      ${W}Name${N}"
    div
    
    for rule in "${RULE_ARRAY[@]}"; do
        IFS='|' read -r src_range tgt_port name <<< "$rule"
        printf "  %d.  %-15s → %-10s %s\n" "$counter" "$src_range" "$tgt_port" "$name"
        ((counter++))
    done
    
    div
    press
}

delete_portfw_rule() {
    load_portfw_rules
    
    if [[ -z "$RULES" ]]; then
        error "Tidak ada rules untuk dihapus!"
        press
        return
    fi
    
    banner
    echo -e "  ${W}HAPUS PORT FORWARDING RULE${N}"
    div
    
    local counter=1
    IFS=';' read -ra RULE_ARRAY <<< "$RULES"
    
    for rule in "${RULE_ARRAY[@]}"; do
        IFS='|' read -r src_range tgt_port name <<< "$rule"
        printf "  %d. %s (%s → %s)\n" "$counter" "$name" "$src_range" "$tgt_port"
        ((counter++))
    done
    
    div
    echo -ne "  Nomor rule yang dihapus [1-$((counter-1))]: "; read -r del_num
    
    if [[ ! "$del_num" =~ ^[0-9]+$ ]] || [[ $del_num -lt 1 || $del_num -gt $((counter-1)) ]]; then
        error "Nomor tidak valid!"
        press
        return
    fi
    
    local new_rules=""
    counter=1
    for rule in "${RULE_ARRAY[@]}"; do
        if [[ $counter -ne $del_num ]]; then
            if [[ -z "$new_rules" ]]; then
                new_rules="$rule"
            else
                new_rules="${new_rules};${rule}"
            fi
        fi
        ((counter++))
    done
    
    if [[ -z "$new_rules" ]]; then
        RULES=""
    else
        RULES="$new_rules"
    fi
    
    sed -i "s/^RULES=.*/RULES=\"$RULES\"/" "$PORTFW_CONFIG"
    log "Rule dihapus"
    echo -e "  ${G}Rule berhasil dihapus!${N}"
    press
}

apply_all_portfw_rules() {
    load_portfw_rules
    
    if [[ -z "$RULES" ]]; then
        warn "Tidak ada rules untuk diapply"
        return
    fi
    
    info "Mengapply semua port forwarding rules..."
    
    IFS=';' read -ra RULE_ARRAY <<< "$RULES"
    local success=0
    
    for rule in "${RULE_ARRAY[@]}"; do
        IFS='|' read -r src_range tgt_port name <<< "$rule"
        if [[ -n "$src_range" && -n "$tgt_port" ]]; then
            IFS=':' read -r src_start src_end <<< "$src_range"
            apply_portfw_rule "$src_start" "$src_end" "$tgt_port" "$name"
            ((success++))
        fi
    done
    
    netfilter-persistent save &>/dev/null
    log "Berhasil mengapply $success rules"
    info "Semua rules berhasil diapply!"
}

menu_add_portfw_rule() {
    banner
    echo -e "  ${W}TAMBAH PORT FORWARDING RULE${N}"
    div
    
    echo -ne "  Nama rule           : "; read -r rule_name
    [[ -z "$rule_name" ]] && error "Nama kosong!" && press && return
    
    echo -ne "  Port awal (6000)    : "; read -r src_start
    src_start=${src_start:-6000}
    [[ ! "$src_start" =~ ^[0-9]+$ ]] && error "Port tidak valid!" && press && return
    
    echo -ne "  Port akhir (9999)   : "; read -r src_end
    src_end=${src_end:-9999}
    [[ ! "$src_end" =~ ^[0-9]+$ ]] && error "Port tidak valid!" && press && return
    
    if [[ $src_start -gt $src_end ]]; then
        error "Port awal harus lebih kecil dari port akhir!"
        press
        return
    fi
    
    echo -ne "  Target port (5667)  : "; read -r tgt_port
    tgt_port=${tgt_port:-5667}
    [[ ! "$tgt_port" =~ ^[0-9]+$ || $tgt_port -lt 1024 || $tgt_port -gt 65535 ]] && \
        error "Target port tidak valid!" && press && return
    
    echo ""
    echo -e "  ${Y}Konfirmasi:${N}"
    echo -e "    Nama      : ${W}${rule_name}${N}"
    echo -e "    Source    : ${W}${src_start}:${src_end}${N}"
    echo -e "    Target    : ${W}${tgt_port}${N}"
    div
    
    echo -ne "  ${Y}Lanjutkan? [y/N]: ${N}"; read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Dibatalkan"
        press
        return
    fi
    
    save_portfw_rule "$src_start" "$src_end" "$tgt_port" "$rule_name"
    apply_portfw_rule "$src_start" "$src_end" "$tgt_port" "$rule_name"
    
    # Save iptables
    netfilter-persistent save &>/dev/null
    
    banner
    echo -e "  ${G}RULE BERHASIL DITAMBAHKAN!${N}"
    div
    echo -e "  Nama      : ${W}${rule_name}${N}"
    echo -e "  Source    : ${W}${src_start}:${src_end}${N}"
    echo -e "  Target    : ${W}${tgt_port}${N}"
    div
    press
}

# ================================================================
# BANNER
# ================================================================
banner() {
    clear
    load_config
    local tun_s bot_s
    tun_s=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
    bot_s=$(systemctl is-active "$BOT_SERVICE"  2>/dev/null)
    [[ "$tun_s" == "active" ]] && tun_c="${G}AKTIF${N}" || tun_c="${R}MATI${N}"
    [[ "$bot_s" == "active" ]] && bot_c="${G}AKTIF${N}" || bot_c="${R}MATI${N}"

    local now=$(date '+%Y-%m-%d %H:%M:%S')
    local total=$(jq '.users|length' "$USERS_FILE" 2>/dev/null || echo 0)
    local aktif=$(jq "[.users[]|select(.expire > \"$now\" and .active==true)]|length" "$USERS_FILE" 2>/dev/null || echo 0)
    local cpu=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{printf "%.0f", $2}')
    local ram=$(free -m | awk 'NR==2{printf "%d/%dMB",$3,$2}')

    echo -e "${C}"
    echo "  ════════════════════════════════════════════════════════"
    echo -e "         ${W}ZiVPN TUNNELING${C}  |  v${VERSION}"
    echo "  ════════════════════════════════════════════════════════"
    printf "   VPS  : %-20s IP   : %-20s\n" "$VPS_NAME" "$SERVER_IP"
    printf "   Port : %-20s OBFS : %-20s\n" "$UDP_PORT" "$OBFS_PASS"
    echo "  ────────────────────────────────────────────────────────"
    echo -e "   Tunnel: ${tun_c}${C}  Bot: ${bot_c}${C}  User: ${W}${aktif}/${total}${C}  CPU: ${W}${cpu}%${C}  RAM: ${W}${ram}${C}"
    echo -e "${N}"
}

# ================================================================
# MAIN MENU
# ================================================================
main_menu() {
    check_root; init_dirs
    while true; do
        banner
        echo -e "  ${W}USER MANAGEMENT${C} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo -e "   ${W}1${N}. Tambah User          ${W}2${N}. Hapus User"
        echo -e "   ${W}3${N}. Perpanjang User      ${W}4${N}. Daftar User"
        echo -e "   ${W}22${N}. Max Login Monitor"
        echo ""
        echo -e "  ${W}SERVICE${C} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo -e "   ${W}5${N}. Start Tunnel         ${W}6${N}. Stop Tunnel"
        echo -e "   ${W}7${N}. Restart Tunnel       ${W}8${N}. Status Lengkap"
        echo ""
        echo -e "  ${W}BOT TELEGRAM${C} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo -e "   ${W}9${N}. Setup Bot            ${W}10${N}. Start/Stop Bot"
        echo -e "   ${W}11${N}. Log Bot"
        echo ""
        echo -e "  ${W}BACKUP & RESTORE${C} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo -e "   ${W}12${N}. Backup → Telegram   ${W}13${N}. Restore dari Telegram"
        echo ""
        echo -e "  ${W}TOOLS${C} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo -e "   ${W}14${N}. Speed Test (Ookla)  ${W}15${N}. Ganti Port"
        echo -e "   ${W}16${N}. Log Tunnel          ${W}17${N}. Setup IPTables UDP"
        echo ""
        echo -e "  ${W}PORT FORWARDING${C} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo -e "   ${W}18${N}. Tambah Rule         ${W}19${N}. Lihat Rules"
        echo -e "   ${W}20${N}. Hapus Rule          ${W}21${N}. Reload Rules"
        echo ""
        echo -e "   ${W}0${N}. Keluar"
        echo -e "  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
        echo -ne "  ${W}Pilih [0-22]: ${N}"
        read -r choice

        case $choice in
            1)  menu_add_user ;;
            2)  menu_delete_user ;;
            3)  menu_renew_user ;;
            4)  menu_list_users ;;
            5)  systemctl start   "$SERVICE_NAME"; log "Tunnel distart";   sleep 1 ;;
            6)  systemctl stop    "$SERVICE_NAME"; warn "Tunnel distop";   sleep 1 ;;
            7)  systemctl restart "$SERVICE_NAME"; log "Tunnel direstart"; sleep 1 ;;
            8)  menu_full_status ;;
            9)  menu_bot_setup ;;
            10) menu_bot_control ;;
            11) menu_bot_log ;;
            12) menu_backup ;;
            13) menu_restore ;;
            14) menu_speedtest ;;
            15) menu_change_port ;;
            16) tail -100 "$LOG_DIR/tunnel.log" 2>/dev/null | less ;;
            17) menu_setup_iptables ;;
            18) menu_add_portfw_rule ;;
            19) list_portfw_rules ;;
            20) delete_portfw_rule ;;
            21) load_portfw_rules; apply_all_portfw_rules; log "Rules direload" ;;
            22) menu_maxlogin ;;
            0)  clear; echo -e "\n  ${G}Sampai jumpa!${N}\n"; exit 0 ;;
            *)  warn "Pilihan tidak valid!"; sleep 1 ;;
        esac
    done
}

# ================================================================
# USER MANAGEMENT
# ================================================================
menu_add_user() {
    banner
    echo -e "  ${W}TAMBAH USER BARU${N}"
    div
    echo -ne "  Username    : "; read -r username
    [[ -z "$username" ]] && warn "Username kosong!" && press && return
    if jq -e --arg u "$username" '.users[]|select(.username==$u)' "$USERS_FILE" &>/dev/null; then
        error "Username '$username' sudah digunakan!"; press; return
    fi
    echo -ne "  Password    : "; read -r password
    [[ -z "$password" ]] && warn "Password kosong!" && press && return
    echo -ne "  Durasi (hari) [30]: "; read -r dur
    dur=${dur:-30}
    [[ ! "$dur" =~ ^[0-9]+$ ]] && error "Durasi harus angka!" && press && return

    local exp=$(date -d "+${dur} days" '+%Y-%m-%d %H:%M:%S')
    local crd=$(date '+%Y-%m-%d %H:%M:%S')

    jq --arg u "$username" --arg p "$password" \
       --arg e "$exp" --arg c "$crd" --argjson d "$dur" \
       '.users += [{"username":$u,"password":$p,"expire":$e,"created":$c,"duration":$d,"active":true,"created_by":"admin"}]' \
       "$USERS_FILE" > /tmp/u.json && mv /tmp/u.json "$USERS_FILE"

    update_auth_config
    load_config

    banner
    echo -e "  ${G}AKUN BERHASIL DIBUAT${N}"
    div
    echo -e "  🌐  Server IP  : ${G}${SERVER_IP}${N}"
    echo -e "  🔌  Port UDP   : ${G}${UDP_PORT}${N}"
    echo -e "  🛡   OBFS       : ${C}${OBFS_PASS}${N}"
    div
    echo -e "  👤  Username   : ${Y}${username}${N}"
    echo -e "  🔑  Password   : ${Y}${password}${N}"
    echo -e "  📅  Dibuat     : ${W}${crd}${N}"
    echo -e "  ⏰  Expire     : ${R}${exp}${N}"
    echo -e "  📆  Durasi     : ${W}${dur} hari${N}"
    div
    echo -e "  ${D}Konfigurasi koneksi ZiVPN App:${N}"
    echo -e "  Server  : ${C}${SERVER_IP}${N}"
    echo -e "  Port    : ${C}${UDP_PORT}${N}"
    echo -e "  User    : ${C}${username}${N}"
    echo -e "  Pass    : ${C}${password}${N}"
    echo -e "  OBFS    : ${C}${OBFS_PASS}${N}"
    div
    log "User '$username' dibuat, expire: $exp"
    press
}

menu_delete_user() {
    banner
    echo -e "  ${W}HAPUS USER${N}"
    div; show_users_table; div
    echo -ne "  Username yang dihapus: "; read -r username
    [[ -z "$username" ]] && return
    if ! jq -e --arg u "$username" '.users[]|select(.username==$u)' "$USERS_FILE" &>/dev/null; then
        error "User tidak ditemukan!"; press; return
    fi
    echo -ne "  ${R}Yakin hapus '$username'? [y/N]: ${N}"; read -r c
    if [[ "$c" =~ ^[Yy]$ ]]; then
        jq --arg u "$username" 'del(.users[]|select(.username==$u))' \
            "$USERS_FILE" > /tmp/u.json && mv /tmp/u.json "$USERS_FILE"
        update_auth_config
        log "User '$username' dihapus"
        echo -e "  ${G}Berhasil dihapus!${N}"
    else
        info "Dibatalkan."
    fi
    press
}

menu_renew_user() {
    banner
    echo -e "  ${W}PERPANJANG USER${N}"
    div; show_users_table; div
    echo -ne "  Username: "; read -r username
    [[ -z "$username" ]] && return
    if ! jq -e --arg u "$username" '.users[]|select(.username==$u)' "$USERS_FILE" &>/dev/null; then
        error "User tidak ditemukan!"; press; return
    fi
    echo -ne "  Durasi tambahan (hari) [30]: "; read -r dur
    dur=${dur:-30}
    local new_exp=$(date -d "+${dur} days" '+%Y-%m-%d %H:%M:%S')
    jq --arg u "$username" --arg e "$new_exp" --argjson d "$dur" \
       '(.users[]|select(.username==$u)) |= .+{"expire":$e,"duration":$d,"active":true}' \
       "$USERS_FILE" > /tmp/u.json && mv /tmp/u.json "$USERS_FILE"
    update_auth_config
    load_config
    local pass=$(jq -r --arg u "$username" '.users[]|select(.username==$u)|.password' "$USERS_FILE")
    banner
    echo -e "  ${G}USER DIPERPANJANG${N}"
    div
    echo -e "  🌐  Server IP  : ${G}${SERVER_IP}${N}"
    echo -e "  🔌  Port       : ${G}${UDP_PORT}${N}"
    echo -e "  👤  Username   : ${Y}${username}${N}"
    echo -e "  🔑  Password   : ${Y}${pass}${N}"
    echo -e "  ⏰  Expire Baru: ${R}${new_exp}${N}"
    echo -e "  📆  Ditambah   : ${W}${dur} hari${N}"
    div
    log "User '$username' diperpanjang hingga $new_exp"
    press
}

menu_list_users() {
    banner
    echo -e "  ${W}DAFTAR USER${N}"
    div
    local now=$(date '+%Y-%m-%d %H:%M:%S')
    local total=$(jq '.users|length' "$USERS_FILE" 2>/dev/null || echo 0)
    local aktif=$(jq "[.users[]|select(.expire > \"$now\")]|length" "$USERS_FILE" 2>/dev/null || echo 0)
    echo -e "  Total: ${W}${total}${N}   Aktif: ${G}${aktif}${N}   Expired: ${R}$((total-aktif))${N}"
    div; show_users_table
    press
}

show_users_table() {
    local now=$(date '+%Y-%m-%d %H:%M:%S')
    printf "  ${C}%-18s %-16s %-22s %-12s${N}\n" "USERNAME" "PASSWORD" "EXPIRE" "STATUS"
    echo -e "  ${D}──────────────────────────────────────────────────────────────${N}"
    jq -r '.users[]|"\(.username)|\(.password)|\(.expire)"' "$USERS_FILE" 2>/dev/null | \
    while IFS='|' read -r u p e; do
        local days=$(( ( $(date -d "$e" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if [[ $days -gt 0 ]]; then
            printf "  ${G}%-18s${N} %-16s %-22s ${G}%s hari${N}\n" "$u" "$p" "$e" "$days"
        else
            printf "  ${R}%-18s${N} %-16s %-22s ${R}EXPIRED${N}\n" "$u" "$p" "$e"
        fi
    done
    echo ""
}

update_auth_config() {
    local arr
    arr=$(jq -r '[.users[]|select(.active==true)|.username+":"+.password]' "$USERS_FILE" 2>/dev/null || echo '[]')
    jq --argjson a "$arr" '.auth.config = $a' "$CONFIG_FILE" > /tmp/cfg.json && mv /tmp/cfg.json "$CONFIG_FILE"
    systemctl reload-or-restart "$SERVICE_NAME" 2>/dev/null
}

check_expired_users() {
    local now=$(date '+%Y-%m-%d %H:%M:%S')
    jq --arg now "$now" \
       '(.users[]|select(.expire < $now and .active==true)) |= .+{"active":false}' \
       "$USERS_FILE" > /tmp/u.json && mv /tmp/u.json "$USERS_FILE"
    update_auth_config
}

# ================================================================
# MAX LOGIN MONITOR & AUTO KILL
# ================================================================
check_max_login() {
    load_config
    local killed=0

    # Baca semua user aktif beserta max_login
    while IFS= read -r line; do
        local username=$(echo "$line" | jq -r '.username')
        local max_login=$(echo "$line" | jq -r '.max_login // 1')
        local password=$(echo "$line" | jq -r '.password')

        [[ -z "$username" || "$username" == "null" ]] && continue
        [[ "$max_login" -le 0 ]] && continue

        # Hitung koneksi aktif user ini via ss (cek established UDP/TCP)
        local conn_count
        conn_count=$(ss -tnp 2>/dev/null | grep -c "ESTABLISHED" || echo 0)

        # Cek via log ZiVPN - hitung koneksi aktif berdasarkan auth success
        local active_conns
        active_conns=$(grep "auth.*${username}.*success" "$LOG_DIR/tunnel.log" 2>/dev/null |             tail -100 | awk -v now="$(date -d "5 minutes ago" "+%Y-%m-%d %H:%M:%S")"             "\$0 >= now {count++} END {print count+0}")

        # Jika melebihi max_login, hapus dari config sementara lalu restart
        if [[ "$active_conns" -gt "$max_login" ]]; then
            warn "User $username: $active_conns koneksi (max: $max_login) - killing excess..."

            # Kill dengan cara restart service (semua koneksi putus, re-auth diperlukan)
            # Cara lebih precise: gunakan ss -K untuk kill specific connection
            local excess=$(( active_conns - max_login ))
            for i in $(seq 1 $excess); do
                # Kill koneksi terlama menggunakan ss -K
                ss -K "sport = :${UDP_PORT}" 2>/dev/null | head -1
            done

            log "Killed $excess koneksi berlebih untuk user $username"
            killed=$((killed + 1))
        fi
    done < <(jq -c ".users[] | select(.active==true)" "$USERS_FILE" 2>/dev/null)

    [[ $killed -gt 0 ]] && log "Max login check: $killed user diterminasi koneksi berlebihnya"
}

menu_maxlogin() {
    banner
    echo -e "  ${W}MAX LOGIN MONITOR${N}"; div
    echo -e "  ${D}Format user & max login saat ini:${N}"
    echo ""
    printf "  ${C}%-18s %-10s %-12s${N}
" "USERNAME" "MAX LOGIN" "STATUS"
    echo -e "  ${D}──────────────────────────────────────────${N}"
    jq -r ".users[] | [.username, (.max_login//1|tostring), (if .active then "Aktif" else "Nonaktif" end)] | @tsv"         "$USERS_FILE" 2>/dev/null |     while IFS=$'\t' read -r u ml st; do
        if [[ "$st" == "Aktif" ]]; then
            printf "  ${G}%-18s${N} %-10s ${G}%s${N}
" "$u" "$ml device" "$st"
        else
            printf "  ${R}%-18s${N} %-10s ${R}%s${N}
" "$u" "$ml device" "$st"
        fi
    done
    echo ""
    div
    echo -ne "  Set max login user (username jumlah, contoh: user1 2): "; read -r input
    if [[ -n "$input" ]]; then
        local uname=$(echo "$input" | awk "{print \$1}")
        local mlimit=$(echo "$input" | awk "{print \$2}")
        if [[ -n "$uname" && -n "$mlimit" ]]; then
            jq --arg u "$uname" --argjson ml "$mlimit"                "(.users[] | select(.username==\$u)) |= .+{"max_login":\$ml}"                "$USERS_FILE" > /tmp/u.json && mv /tmp/u.json "$USERS_FILE"
            log "Max login user '$uname' diset ke $mlimit"
            echo -e "  ${G}Max login '$uname' = $mlimit device${N}"
        fi
    fi
    press
}

# ================================================================
# STATUS LENGKAP
# ================================================================
menu_full_status() {
    banner
    echo -e "  ${W}STATUS LENGKAP SERVER${N}"; div; load_config
    echo -e "  VPS Name    : ${W}${VPS_NAME}${N}"
    echo -e "  IP Server   : ${W}${SERVER_IP}${N}"
    echo -e "  Port UDP    : ${W}${UDP_PORT}${N}"
    echo -e "  OBFS Pass   : ${W}${OBFS_PASS}${N}"; div
    echo -e "  Tunnel      : $(systemctl is-active "$SERVICE_NAME" &>/dev/null && echo "${G}● Berjalan${N}" || echo "${R}● Mati${N}")"
    echo -e "  Bot Telegram: $(systemctl is-active "$BOT_SERVICE"  &>/dev/null && echo "${G}● Berjalan${N}" || echo "${R}● Mati${N}")"; div
    echo -e "  CPU         : ${W}$(top -bn1 2>/dev/null | grep 'Cpu(s)' | awk '{printf "%.1f%%",$2}')${N}"
    echo -e "  RAM         : ${W}$(free -m | awk 'NR==2{printf "%dMB / %dMB (%.0f%%)",$3,$2,$3*100/$2}')${N}"
    echo -e "  Disk        : ${W}$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')${N}"
    echo -e "  Uptime      : ${W}$(uptime -p)${N}"; div
    press
}

# ================================================================
# BOT TELEGRAM SETUP
# ================================================================
menu_bot_setup() {
    banner
    echo -e "  ${W}SETUP BOT TELEGRAM${N}"; div
    load_config
    echo -e "  Token saat ini  : ${W}${TG_TOKEN:-(belum diset)}${N}"
    echo -e "  Owner ID        : ${W}${TG_OWNER_ID:-(belum diset)}${N}"
    echo -e "  Nama VPS        : ${W}${VPS_NAME}${N}"; div

    echo -ne "  Bot Token baru  (Enter=skip): "; read -r nt
    echo -ne "  Owner ID baru   (Enter=skip): "; read -r no
    echo -ne "  Nama VPS baru   (Enter=skip): "; read -r nv

    [[ -n "$nt" ]] && TG_TOKEN="$nt"
    [[ -n "$no" ]] && TG_OWNER_ID="$no"
    [[ -n "$nv" ]] && VPS_NAME="$nv"

    if [[ -z "$TG_TOKEN" || -z "$TG_OWNER_ID" ]]; then
        error "Token dan Owner ID wajib diisi!"; press; return
    fi

    info "Memvalidasi token ke Telegram..."
    local resp
    resp=$(curl -s --connect-timeout 10 "https://api.telegram.org/bot${TG_TOKEN}/getMe")
    if echo "$resp" | jq -e '.ok==true' &>/dev/null; then
        local bname=$(echo "$resp" | jq -r '.result.username')
        log "Token valid! Bot: @${bname}"
    else
        error "Token tidak valid! Response: $(echo "$resp" | jq -r '.description // "N/A"')"
        press; return
    fi

    cat > "$BOT_CONFIG" << EOF
TG_TOKEN="${TG_TOKEN}"
TG_OWNER_ID="${TG_OWNER_ID}"
VPS_NAME="${VPS_NAME}"
UDP_PORT="${UDP_PORT}"
OBFS_PASS="${OBFS_PASS}"
EOF
    chmod 600 "$BOT_CONFIG"
    log "Konfigurasi bot tersimpan"

    systemctl restart "$BOT_SERVICE" 2>/dev/null
    sleep 2
    if systemctl is-active --quiet "$BOT_SERVICE"; then
        log "Bot Telegram berhasil direstart"
        echo -e "  ${G}Bot berjalan! Ketik /start di Telegram.${N}"
    else
        warn "Bot gagal start, cek: journalctl -u udp-zivpn-bot -n 20"
    fi
    press
}

menu_bot_control() {
    banner
    echo -e "  ${W}BOT TELEGRAM CONTROL${N}"; div
    echo -e "  Status: $(systemctl is-active "$BOT_SERVICE" &>/dev/null && echo "${G}● Berjalan${N}" || echo "${R}● Mati${N}")"
    div
    echo -e "  ${W}1${N}. Start Bot   ${W}2${N}. Stop Bot   ${W}3${N}. Restart Bot   ${W}0${N}. Kembali"
    echo -ne "\n  Pilih: "; read -r c
    case $c in
        1) systemctl start   "$BOT_SERVICE"; log "Bot distart"    ;;
        2) systemctl stop    "$BOT_SERVICE"; warn "Bot distop"    ;;
        3) systemctl restart "$BOT_SERVICE"; log "Bot direstart"  ;;
    esac
    sleep 1
}

menu_bot_log() {
    echo -e "\n  ${C}Log Bot (Ctrl+C keluar):${N}\n"
    tail -f "$LOG_DIR/bot.log" 2>/dev/null || journalctl -u "$BOT_SERVICE" -f
}

# ================================================================
# BACKUP — buat & kirim ke Telegram
# ================================================================
menu_backup() {
    banner
    echo -e "  ${W}BACKUP & KIRIM KE TELEGRAM${N}"; div
    load_config

    if [[ -z "$TG_TOKEN" || -z "$TG_OWNER_ID" ]]; then
        error "Token/Owner ID belum diset! Buka menu Setup Bot (9) dulu."
        press; return
    fi

    info "Membuat backup..."
    local ts=$(date '+%Y%m%d_%H%M%S')
    local bname="backup_zivpn_${VPS_NAME}_${ts}"
    local bdir="/tmp/${bname}"
    local bfile="/tmp/${bname}.tar.gz"

    mkdir -p "$bdir"
    cp "$CONFIG_FILE"         "$bdir/config.json"  2>/dev/null || true
    cp "$USERS_FILE"          "$bdir/users.json"   2>/dev/null || true
    cp "$BOT_CONFIG"          "$bdir/bot.conf"     2>/dev/null || true
    cp "$CERT_DIR/zivpn.crt" "$bdir/zivpn.crt"   2>/dev/null || true
    cp "$CERT_DIR/zivpn.key" "$bdir/zivpn.key"   2>/dev/null || true

    cat > "$bdir/info.json" << EOF
{
  "vps_name":    "${VPS_NAME}",
  "server_ip":   "${SERVER_IP}",
  "udp_port":    "${UDP_PORT}",
  "backup_date": "$(date '+%Y-%m-%d %H:%M:%S')",
  "total_users": $(jq '.users|length' "$USERS_FILE" 2>/dev/null || echo 0),
  "version":     "${VERSION}"
}
EOF

    tar -czf "$bfile" -C "/tmp" "$bname" 2>/dev/null
    rm -rf "$bdir"

    if [[ ! -f "$bfile" ]]; then
        error "Gagal membuat file backup!"; press; return
    fi

    local fsize=$(du -sh "$bfile" | cut -f1)
    local nusers=$(jq '.users|length' "$USERS_FILE" 2>/dev/null || echo 0)
    local caption
    caption=$(printf "💾 *Backup ZiVPN*\n📅 %s\n🖥 VPS: %s\n🌐 IP: %s\n👥 Users: %s\n📦 Size: %s" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$VPS_NAME" "$SERVER_IP" "$nusers" "$fsize")

    info "Mengirim ke Telegram (${fsize})..."
    local resp
    resp=$(curl -s --connect-timeout 30 \
        -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
        -F "chat_id=${TG_OWNER_ID}" \
        -F "document=@${bfile};type=application/gzip" \
        -F "caption=${caption}" \
        -F "parse_mode=Markdown")

    rm -f "$bfile"

    if echo "$resp" | jq -e '.ok==true' &>/dev/null; then
        local fid=$(echo "$resp" | jq -r '.result.document.file_id')
        echo "$fid" > "$DATA_DIR/last_backup_id.txt"
        log "Backup berhasil dikirim!"
        echo ""
        echo -e "  ${G}✔ Backup berhasil dikirim ke Telegram!${N}"
        echo -e "  File ID: ${Y}${fid}${N}"
        echo -e "  Disimpan di: ${W}${DATA_DIR}/last_backup_id.txt${N}"
        echo -e "  ${D}(gunakan File ID ini untuk restore)${N}"
    else
        error "Gagal kirim ke Telegram!"
        error "$(echo "$resp" | jq -r '.description // "Unknown error"')"
        error "Pastikan token & owner ID benar, dan bot belum diblokir."
    fi
    press
}

# ================================================================
# RESTORE dari Telegram
# ================================================================
menu_restore() {
    banner
    echo -e "  ${W}RESTORE DARI TELEGRAM${N}"; div
    load_config

    if [[ -z "$TG_TOKEN" ]]; then
        error "Token Telegram belum diset!"; press; return
    fi

    if [[ -f "$DATA_DIR/last_backup_id.txt" ]]; then
        local last_id=$(cat "$DATA_DIR/last_backup_id.txt")
        echo -e "  Backup terakhir: ${Y}${last_id}${N}"
        echo -e "  ${D}(Enter untuk pakai ini, atau ketik File ID lain)${N}"
    fi

    echo ""
    echo -ne "  File ID backup: "; read -r fid
    [[ -z "$fid" && -f "$DATA_DIR/last_backup_id.txt" ]] && fid=$(cat "$DATA_DIR/last_backup_id.txt")
    [[ -z "$fid" ]] && error "File ID kosong!" && press && return

    info "Mengambil info file dari Telegram..."
    local finfo
    finfo=$(curl -s --connect-timeout 15 "https://api.telegram.org/bot${TG_TOKEN}/getFile?file_id=${fid}")

    if ! echo "$finfo" | jq -e '.ok==true' &>/dev/null; then
        error "File ID tidak valid / expired (max 20 hari setelah diupload)!"
        error "$(echo "$finfo" | jq -r '.description // "N/A"')"
        press; return
    fi

    local fpath=$(echo "$finfo" | jq -r '.result.file_path')
    local fsize=$(echo "$finfo" | jq -r '.result.file_size // 0')
    info "Mendownload backup (${fsize} bytes)..."

    local ts=$(date '+%Y%m%d_%H%M%S')
    local rfile="/tmp/restore_${ts}.tar.gz"
    curl -s --connect-timeout 30 -o "$rfile" \
        "https://api.telegram.org/file/bot${TG_TOKEN}/${fpath}"

    if [[ ! -f "$rfile" || ! -s "$rfile" ]]; then
        error "Gagal mendownload file backup!"; rm -f "$rfile"; press; return
    fi

    local rdir="/tmp/rst_${ts}"
    mkdir -p "$rdir"
    tar -xzf "$rfile" -C "$rdir" 2>/dev/null
    local sub=$(ls "$rdir" 2>/dev/null | head -1)
    local src="$rdir/$sub"

    if [[ ! -f "$src/config.json" ]]; then
        error "File backup tidak valid / rusak!"
        rm -rf "$rdir" "$rfile"; press; return
    fi

    # Tampilkan info
    echo ""
    if [[ -f "$src/info.json" ]]; then
        echo -e "  Info backup yang akan direstore:"
        echo -e "  VPS    : ${W}$(jq -r '.vps_name//"N/A"' "$src/info.json")${N}"
        echo -e "  Tanggal: ${W}$(jq -r '.backup_date//"N/A"' "$src/info.json")${N}"
        echo -e "  Users  : ${W}$(jq -r '.total_users//0' "$src/info.json")${N}"
        div
    fi

    echo -ne "  ${Y}Yakin restore? Data saat ini akan ditimpa! [y/N]: ${N}"; read -r c
    if [[ ! "$c" =~ ^[Yy]$ ]]; then
        info "Dibatalkan."; rm -rf "$rdir" "$rfile"; press; return
    fi

    # Backup existing dulu
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${ts}" 2>/dev/null
    cp "$USERS_FILE"  "${USERS_FILE}.bak.${ts}"  2>/dev/null

    cp "$src/config.json" "$CONFIG_FILE"
    cp "$src/users.json"  "$USERS_FILE"
    [[ -f "$src/zivpn.crt" ]] && cp "$src/zivpn.crt" "$CERT_DIR/zivpn.crt"
    [[ -f "$src/zivpn.key" ]] && cp "$src/zivpn.key" "$CERT_DIR/zivpn.key"

    systemctl restart "$SERVICE_NAME" 2>/dev/null
    rm -rf "$rdir" "$rfile"
    log "Restore berhasil!"
    echo -e "  ${G}✔ Restore berhasil! Service direstart.${N}"
    press
}

# ================================================================
# SETUP IPTABLES UDP FORWARDING
# ================================================================
menu_setup_iptables() {
    banner
    echo -e "  ${W}SETUP IPTABLES UDP FORWARDING${N}"; div
    load_config
    
    echo -e "  Port UDP saat ini: ${W}${UDP_PORT}${N}"
    echo ""
    echo -ne "  Gunakan port UDP saat ini? [Y/n]: "; read -r c
    
    local port_to_use="$UDP_PORT"
    if [[ "$c" =~ ^[Nn]$ ]]; then
        echo -ne "  Masukkan port UDP [1024-65535]: "; read -r port_to_use
        [[ ! "$port_to_use" =~ ^[0-9]+$ || $port_to_use -lt 1024 || $port_to_use -gt 65535 ]] && \
            error "Port tidak valid!" && press && return
    fi
    
    echo ""
    echo -ne "  ${Y}Lanjutkan setup iptables untuk port ${port_to_use}? [y/N]: ${N}"; read -r c
    if [[ ! "$c" =~ ^[Yy]$ ]]; then
        info "Dibatalkan."; press; return
    fi
    
    echo ""
    setup_iptables_udp_forward "$port_to_use"
    
    echo ""
    echo -e "  ${G}✔ Setup iptables UDP forwarding berhasil!${N}"
    echo -e "  ${D}Port range 6000-19999 akan forward ke port ${port_to_use}${N}"
    press
}

# ================================================================
# SPEED TEST
# ================================================================
menu_speedtest() {
    banner
    echo -e "  ${W}SPEED TEST (Ookla)${N}"; div

    # Coba install Ookla official
    if ! command -v speedtest &>/dev/null; then
        info "Menginstall Speedtest CLI Ookla..."
        curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash &>/dev/null
        apt-get install -y speedtest &>/dev/null
    fi

    echo ""
    if command -v speedtest &>/dev/null; then
        info "Menjalankan Ookla Speedtest..."
        echo ""
        speedtest --accept-license --accept-gdpr
    else
        warn "Ookla tidak tersedia, pakai speedtest-cli Python..."
        pip3 install speedtest-cli -q 2>/dev/null
        python3 << 'PY'
import sys
try:
    import speedtest
    print("  Mencari server terbaik...")
    s = speedtest.Speedtest(secure=True)
    s.get_best_server()
    srv = s.results.server
    print(f"  Server  : {srv.get('name','')}, {srv.get('country','')}")
    print(f"  Sponsor : {srv.get('sponsor','')}")
    print()
    print("  Testing download speed...")
    dl = s.download() / 1e6
    print("  Testing upload speed...")
    ul = s.upload()   / 1e6
    ping = s.results.ping
    print()
    print(f"  ✔ Download : {dl:.2f} Mbps")
    print(f"  ✔ Upload   : {ul:.2f} Mbps")
    print(f"  ✔ Ping     : {ping:.1f} ms")
except Exception as e:
    print(f"  Error: {e}", file=sys.stderr)
    sys.exit(1)
PY
        if [[ $? -ne 0 ]]; then
            error "Speedtest gagal! Cek koneksi internet."
        fi
    fi
    press
}

# ================================================================
# GANTI PORT
# ================================================================
menu_change_port() {
    banner
    echo -e "  ${W}GANTI PORT UDP${N}"; div
    load_config
    echo -e "  Port saat ini: ${W}${UDP_PORT}${N}"
    echo ""
    echo -ne "  Port baru [1024-65535]: "; read -r np
    [[ -z "$np" ]] && return
    [[ ! "$np" =~ ^[0-9]+$ || $np -lt 1024 || $np -gt 65535 ]] && \
        error "Port tidak valid!" && press && return

    jq --arg p ":${np}" '.listen = $p' "$CONFIG_FILE" > /tmp/cfg.json && mv /tmp/cfg.json "$CONFIG_FILE"
    sed -i "s/^UDP_PORT=.*/UDP_PORT=\"${np}\"/" "$BOT_CONFIG" 2>/dev/null
    ufw allow "${np}/udp"     2>/dev/null
    ufw delete allow "${UDP_PORT}/udp" 2>/dev/null
    systemctl restart "$SERVICE_NAME"
    log "Port diganti ke ${np}"
    echo -e "  ${G}Port berhasil diganti ke ${np}!${N}"
    press
}

# ================================================================
# CLI ENTRY
# ================================================================
case "${1:-menu}" in
    add_user)       check_root; init_dirs; load_config; menu_add_user ;;
    del_user)       check_root; init_dirs; load_config
                    jq --arg u "$2" 'del(.users[]|select(.username==$u))' \
                        "$USERS_FILE" > /tmp/u.json && mv /tmp/u.json "$USERS_FILE"
                    update_auth_config; log "User $2 dihapus" ;;
    check_expired)  check_root; init_dirs; load_config; check_expired_users ;;
    check_maxlogin) check_root; init_dirs; load_config; check_max_login ;;
    backup_telegram) check_root; init_dirs; load_config; menu_backup ;;
    status)         check_root; init_dirs; load_config; menu_full_status ;;
    update_auth)    check_root; load_config; update_auth_config ;;
    menu|"")        main_menu ;;
    *)              echo "Usage: $0 {menu|add_user|del_user|check_expired|backup_telegram|status|update_auth}" ;;
esac
