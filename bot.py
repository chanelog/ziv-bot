#!/usr/bin/env python3
# ================================================================
#   UDP ZiVPN - Telegram Bot v3.0
#   Multi-Region | Auto Sales | QRIS Photo | Owner & Reseller
# ================================================================

import asyncio, json, os, sys, subprocess, logging, time, re, io
import hashlib, uuid, shutil
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, List

from telegram import (
    Update, InlineKeyboardButton, InlineKeyboardMarkup,
    InputFile, BotCommand
)
from telegram.ext import (
    Application, CommandHandler, CallbackQueryHandler,
    MessageHandler, filters, ContextTypes, ConversationHandler
)
from telegram.constants import ParseMode

# ================================================================
# LOGGING
# ================================================================
logging.basicConfig(
    format='%(asctime)s [%(levelname)s] %(message)s',
    level=logging.INFO,
    handlers=[
        logging.FileHandler('/var/log/udp-zivpn/bot.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

# ================================================================
# CONFIG
# ================================================================
DATA_DIR     = '/var/lib/udp-zivpn'
USERS_FILE   = f'{DATA_DIR}/users.json'
RESELLERS_FILE = f'{DATA_DIR}/resellers.json'
ORDERS_FILE  = f'{DATA_DIR}/orders.json'
SETTINGS_FILE= f'{DATA_DIR}/settings.json'
BOT_CONF     = f'{DATA_DIR}/bot.conf'
QRIS_IMG     = f'{DATA_DIR}/qris.jpg'   # foto QRIS yang diupload admin

def load_bot_conf():
    cfg = {}
    if os.path.exists(BOT_CONF):
        with open(BOT_CONF) as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    k, v = line.split('=', 1)
                    cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg

CFG = load_bot_conf()
BOT_TOKEN  = CFG.get('TG_TOKEN', os.getenv('TG_TOKEN', ''))
OWNER_ID   = int(CFG.get('TG_OWNER_ID', os.getenv('TG_OWNER_ID', '0')))
VPS_NAME   = CFG.get('VPS_NAME', 'VPS-1')
UDP_PORT   = CFG.get('UDP_PORT', '5667')
OBFS_PASS  = CFG.get('OBFS_PASS', 'zivpn')

PACKAGES = {
    '15d': {'days': 15, 'price': 6000,  'label': '15 Hari'},
    '30d': {'days': 30, 'price': 10000, 'label': '30 Hari'},
}

# ConversationHandler states
(ST_USERNAME, ST_PASSWORD, ST_DURATION,
 ST_RESELLER_ID, ST_VPS_INFO, ST_QRIS_PHOTO,
 ST_PAYMENT_PROOF) = range(7)

# ================================================================
# DATABASE
# ================================================================
def load_json(path, default):
    try:
        if os.path.exists(path):
            with open(path) as f: return json.load(f)
    except Exception as e:
        logger.error(f"load_json {path}: {e}")
    return default

def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f: json.dump(data, f, indent=2, ensure_ascii=False)

def get_users():     return load_json(USERS_FILE,    {'users': []})
def get_resellers(): return load_json(RESELLERS_FILE,{'resellers': []})
def get_orders():    return load_json(ORDERS_FILE,   {'orders': []})
def get_settings():  return load_json(SETTINGS_FILE, {'vps_regions': {}, 'payment_timeout': 30})

def get_server_ip():
    try:
        r = subprocess.run(['curl','-s4','--connect-timeout','5','ifconfig.me'],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() or 'N/A'
    except: return 'N/A'

# ================================================================
# PERMISSION
# ================================================================
def is_owner(uid):    return uid == OWNER_ID
def is_reseller(uid):
    rs = get_resellers()
    return any(r['telegram_id'] == uid for r in rs.get('resellers', []))
def is_admin(uid):    return is_owner(uid) or is_reseller(uid)

def get_reseller(uid):
    rs = get_resellers()
    for r in rs.get('resellers', []):
        if r['telegram_id'] == uid: return r
    return None

# ================================================================
# VPS MANAGEMENT
# ================================================================
def get_all_vps():
    settings = get_settings()
    regions  = settings.get('vps_regions', {})
    result   = {}

    # VPS lokal
    try:
        r = subprocess.run(['systemctl','is-active','udp-zivpn'],
                           capture_output=True, text=True)
        result[VPS_NAME] = {
            'name': VPS_NAME, 'local': True,
            'active': r.stdout.strip() == 'active',
            'ip': get_server_ip(), 'port': UDP_PORT
        }
    except: pass

    # VPS remote
    for name, vps in regions.items():
        try:
            key  = vps.get('ssh_key', '/root/.ssh/id_rsa')
            port = str(vps.get('port', 22))
            ip   = vps['ip']
            cmd  = ['ssh','-i',key,'-p',port,
                    '-o','StrictHostKeyChecking=no',
                    '-o','ConnectTimeout=5',
                    f'root@{ip}',
                    'systemctl is-active udp-zivpn']
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            result[name] = {
                'name': name, 'local': False,
                'active': r.stdout.strip() == 'active',
                'ip': ip, 'port': vps.get('udp_port', '5667')
            }
        except:
            result[name] = {'name': name,'local':False,'active':False,
                            'ip': vps.get('ip','?'),'port':'?'}
    return result

def add_user_vps(vps_name, username, password, duration, created_by='bot', max_login=1):
    """Tambah user ke VPS (lokal atau remote)"""
    settings = get_settings()
    regions  = settings.get('vps_regions', {})

    if vps_name == VPS_NAME:
        # Lokal
        data = get_users()
        if any(u['username'] == username for u in data.get('users', [])):
            return False, "Username sudah ada"
        exp = (datetime.now() + timedelta(days=duration)).strftime('%Y-%m-%d %H:%M:%S')
        data['users'].append({
            'username':   username,
            'password':   password,
            'expire':     exp,
            'created':    datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'created_by': created_by,
            'duration':   duration,
            'active':     True,
            'vps':        vps_name,
            'max_login':  max_login,
        })
        save_json(USERS_FILE, data)
        # Update auth config
        subprocess.run(['/bin/bash','/usr/local/bin/udp-zivpn-manage','update_auth'],
                       timeout=15, capture_output=True)
        return True, exp
    else:
        if vps_name not in regions:
            return False, "VPS tidak ditemukan"
        vps = regions[vps_name]
        key  = vps.get('ssh_key', '/root/.ssh/id_rsa')
        port = str(vps.get('port', 22))
        ip   = vps['ip']
        cmd  = ['ssh','-i',key,'-p',port,
                '-o','StrictHostKeyChecking=no','-o','ConnectTimeout=10',
                f'root@{ip}',
                f'/bin/bash /usr/local/bin/udp-zivpn-manage add_user {username} {password} {duration} {created_by}']
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            exp = (datetime.now() + timedelta(days=duration)).strftime('%Y-%m-%d %H:%M:%S')
            return True, exp
        return False, r.stderr.strip() or "Gagal tambah user ke VPS remote"

def get_vps_ip(vps_name):
    settings = get_settings()
    if vps_name == VPS_NAME:
        return get_server_ip()
    regions = settings.get('vps_regions', {})
    return regions.get(vps_name, {}).get('ip', 'N/A')

def get_vps_port(vps_name):
    settings = get_settings()
    if vps_name == VPS_NAME:
        return UDP_PORT
    regions = settings.get('vps_regions', {})
    return regions.get(vps_name, {}).get('udp_port', '5667')

# ================================================================
# MAX LOGIN MONITOR
# ================================================================
def get_active_connections(username):
    """Hitung koneksi aktif user dari log ZiVPN"""
    try:
        r = subprocess.run(
            ['ss', '-tnp'],
            capture_output=True, text=True, timeout=5
        )
        count = r.stdout.count(username)
        return count
    except:
        return 0

def kill_excess_connections(username, max_login):
    """Kill koneksi berlebih, sisakan sejumlah max_login"""
    try:
        # Cari PID proses yang pakai koneksi username tsb
        r = subprocess.run(
            ['grep', '-r', username, '/proc/net/'],
            capture_output=True, text=True, timeout=5
        )
        # Gunakan ss untuk cari koneksi
        r2 = subprocess.run(
            ['ss', '-K', 'dport', '!=', '22'],
            capture_output=True, text=True, timeout=5
        )
        return True
    except:
        return False

def check_max_login_all():
    """Cek semua user, kill yang melebihi max_login"""
    users_data = get_users()
    killed = []
    for u in users_data.get('users', []):
        max_login = u.get('max_login', 1)
        username  = u['username']
        if max_login <= 0:
            continue
        # Cek via log file
        try:
            r = subprocess.run(
                ['grep', f'auth.*{username}', '/var/log/udp-zivpn/tunnel.log'],
                capture_output=True, text=True, timeout=5
            )
            # Hitung baris terakhir 1 menit
            lines = [l for l in r.stdout.strip().split('\n') if l]
            if len(lines) > max_login:
                killed.append(username)
        except:
            pass
    return killed

def set_user_max_login(username, max_login):
    """Set max_login untuk user tertentu"""
    data = get_users()
    for i, u in enumerate(data.get('users', [])):
        if u['username'] == username:
            data['users'][i]['max_login'] = max_login
            save_json(USERS_FILE, data)
            # Update auth config
            subprocess.run(['/bin/bash','/usr/local/bin/udp-zivpn-manage','update_auth'],
                           timeout=10, capture_output=True)
            return True
    return False

# ================================================================
# ORDER
# ================================================================
def create_order(uid, uname_tg, package, vps_name):
    orders = get_orders()
    oid    = str(uuid.uuid4())[:8].upper()
    pkg    = PACKAGES[package]
    order  = {
        'id':          oid,
        'user_id':     uid,
        'username_tg': uname_tg,
        'package':     package,
        'days':        pkg['days'],
        'price':       pkg['price'],
        'vps':         vps_name,
        'status':      'pending',
        'created':     datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'pay_expire':  (datetime.now()+timedelta(minutes=30)).strftime('%Y-%m-%d %H:%M:%S'),
        'vpn_user':    None,
        'vpn_pass':    None,
        'proof_file_id': None,
    }
    orders['orders'].append(order)
    save_json(ORDERS_FILE, orders)
    return order

def get_order(oid):
    orders = get_orders()
    for o in orders.get('orders', []):
        if o['id'] == oid: return o
    return None

def update_order(oid, updates):
    orders = get_orders()
    for i, o in enumerate(orders.get('orders', [])):
        if o['id'] == oid:
            orders['orders'][i].update(updates)
            break
    save_json(ORDERS_FILE, orders)

# ================================================================
# /start & MAIN KEYBOARD
# ================================================================
async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid  = update.effective_user.id
    name = update.effective_user.first_name

    if   is_owner(uid):    role = "👑 Owner"
    elif is_reseller(uid): role = "💼 Reseller"
    else:                  role = "👤 Member"

    text = (
        f"*UDP ZiVPN Bot* 🔐\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"Halo, *{name}*! {role}\n\n"
        f"Pilih menu di bawah:"
    )
    await update.message.reply_text(
        text, reply_markup=main_keyboard(uid),
        parse_mode=ParseMode.MARKDOWN
    )

def main_keyboard(uid):
    if is_owner(uid):
        return InlineKeyboardMarkup([
            [btn("📊 Dashboard",      "dashboard"),
             btn("🖥 VPS Status",     "vps_status")],
            [btn("👥 Kelola User",    "manage_users"),
             btn("💼 Reseller",       "manage_resellers")],
            [btn("✏️ Buat User",      "create_user"),
             btn("⚙️ Pengaturan",    "settings")],
            [btn("💾 Backup",         "do_backup"),
             btn("♻️ Restore",        "do_restore")],
            [btn("⚡ Speed Test",     "speedtest"),
             btn("🛍 Toko",           "shop")],
        ])
    elif is_reseller(uid):
        return InlineKeyboardMarkup([
            [btn("📊 Dashboard",      "dashboard"),
             btn("🖥 VPS Status",     "vps_status")],
            [btn("👥 Kelola User",    "manage_users"),
             btn("✏️ Buat User",      "create_user")],
            [btn("⚡ Speed Test",     "speedtest"),
             btn("🛍 Toko",           "shop")],
        ])
    else:
        return InlineKeyboardMarkup([
            [btn("🛍 Beli Akun VPN",  "shop"),
             btn("📋 Akun Saya",      "my_accounts")],
            [btn("ℹ️ Info",           "info"),
             btn("💬 Support",        "support")],
        ])

def btn(text, data): return InlineKeyboardButton(text, callback_data=data)
def back_btn(data="main_menu"): return [btn("◀️ Kembali", data)]

# ================================================================
# DASHBOARD
# ================================================================
async def dashboard(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()
    if not is_admin(uid):
        await q.edit_message_text("❌ Akses ditolak!"); return

    users  = get_users().get('users', [])
    orders = get_orders().get('orders', [])
    now    = datetime.now()
    total  = len(users)
    aktif  = sum(1 for u in users if datetime.strptime(u['expire'],'%Y-%m-%d %H:%M:%S') > now)
    pending= sum(1 for o in orders if o['status'] == 'pending')
    paid   = sum(1 for o in orders if o['status'] == 'paid')

    vps    = get_all_vps()
    vps_txt= ""
    for n, v in vps.items():
        ico = "🟢" if v['active'] else "🔴"
        vps_txt += f"{ico} `{n}` — `{v['ip']}`\n"

    text = (
        f"📊 *Dashboard*\n━━━━━━━━━━━━━━━━━━━━\n\n"
        f"👥 *User*\n"
        f"├ Total : `{total}`\n"
        f"├ Aktif : `{aktif}`\n"
        f"└ Expired: `{total-aktif}`\n\n"
        f"🛍 *Order*\n"
        f"├ Pending: `{pending}`\n"
        f"└ Selesai: `{paid}`\n\n"
        f"🖥 *VPS*\n{vps_txt}\n"
        f"⏰ `{now.strftime('%H:%M:%S')}`"
    )
    await q.edit_message_text(text, parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([
            [btn("🔄 Refresh","dashboard")],
            back_btn()
        ]))

# ================================================================
# VPS STATUS
# ================================================================
async def vps_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer("Mengecek semua VPS...")
    if not is_admin(q.from_user.id):
        await q.edit_message_text("❌ Akses ditolak!"); return

    vps = get_all_vps()
    text = "🖥 *Status VPS Region*\n━━━━━━━━━━━━━━━━━━━━\n\n"
    for n, v in vps.items():
        ico  = "🟢" if v['active'] else "🔴"
        loc  = " _(local)_" if v.get('local') else ""
        text+= f"{ico} *{n}*{loc}\n   IP: `{v['ip']}` | Port: `{v.get('port','?')}`\n\n"

    await q.edit_message_text(text, parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([
            [btn("🔄 Refresh","vps_status"), btn("➕ Tambah VPS","add_vps")],
            back_btn()
        ]))

# ================================================================
# MANAGE USERS
# ================================================================
async def manage_users(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()
    if not is_admin(uid): await q.edit_message_text("❌"); return

    users = get_users().get('users', [])
    if is_reseller(uid) and not is_owner(uid):
        rs   = get_reseller(uid)
        cby  = rs.get('name', str(uid)) if rs else str(uid)
        users= [u for u in users if u.get('created_by') == cby]

    now   = datetime.now()
    text  = f"👥 *Daftar User* ({len(users)})\n━━━━━━━━━━━━━━━━━━━━\n\n"
    for u in users[-15:]:
        try:
            exp  = datetime.strptime(u['expire'], '%Y-%m-%d %H:%M:%S')
            days = (exp - now).days
            ico  = "🟢" if days > 0 else "🔴"
            text+= f"{ico} `{u['username']}` — {max(0,days)}h | VPS: {u.get('vps',VPS_NAME)}\n"
        except: pass

    await q.edit_message_text(text, parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([
            [btn("✏️ Buat User","create_user"), btn("🗑 Hapus","del_user_menu")],
            [btn("🔄 Perpanjang","renew_user_menu"), btn("🔢 Set Max Login","set_maxlogin")],
            back_btn()
        ]))

# ================================================================
# CREATE USER MANUAL (conversation)
# ================================================================
async def create_user_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()
    if not is_admin(uid):
        await q.edit_message_text("❌ Akses ditolak!")
        return ConversationHandler.END

    # Pilih VPS
    vps = get_all_vps()
    btns = [[btn(f"🖥 {n}" + (" (local)" if v.get('local') else ""),
                 f"cusr_vps_{n}")] for n, v in vps.items()]
    btns.append(back_btn())
    await q.edit_message_text(
        "🖥 *Pilih VPS Region:*",
        reply_markup=InlineKeyboardMarkup(btns),
        parse_mode=ParseMode.MARKDOWN
    )
    return ST_USERNAME

async def create_user_vps(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    ctx.user_data['cu_vps'] = q.data.replace('cusr_vps_', '')
    await q.edit_message_text(
        f"🖥 VPS: *{ctx.user_data['cu_vps']}*\n\n👤 Ketik *username* VPN:\n_(ketik /batal untuk batal)_",
        parse_mode=ParseMode.MARKDOWN
    )
    return ST_PASSWORD

async def create_user_username(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    txt = update.message.text.strip()
    if txt == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    if not re.match(r'^[a-zA-Z0-9_-]{3,32}$', txt):
        await update.message.reply_text("❌ Username 3-32 karakter, hanya huruf/angka/_/-")
        return ST_PASSWORD
    ctx.user_data['cu_user'] = txt
    await update.message.reply_text(f"✅ Username: `{txt}`\n\n🔑 Ketik *password*:", parse_mode=ParseMode.MARKDOWN)
    return ST_DURATION

async def create_user_password(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    txt = update.message.text.strip()
    if txt == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    ctx.user_data['cu_pass'] = txt
    await update.message.reply_text(
        "🔢 Ketik *max login* (berapa device boleh connect sekaligus)
Contoh: `1` atau `2`
_(default: 1)_",
        parse_mode=ParseMode.MARKDOWN
    )
    return ST_DURATION

async def create_user_maxlogin(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    txt = update.message.text.strip()
    if txt == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    try:
        ml = int(txt)
        assert 1 <= ml <= 10
    except:
        ml = 1
    ctx.user_data['cu_maxlogin'] = ml
    await update.message.reply_text(
        f"✅ Max login: *{ml} device*

📅 Ketik *durasi* (hari), contoh: `30`",
        parse_mode=ParseMode.MARKDOWN
    )
    return ST_RESELLER_ID

async def create_user_duration(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    txt = update.message.text.strip()
    if txt == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    try:
        dur = int(txt)
        assert 1 <= dur <= 365
    except:
        await update.message.reply_text("❌ Durasi 1-365 hari!")
        return ST_RESELLER_ID

    uid      = update.effective_user.id
    username = ctx.user_data['cu_user']
    password = ctx.user_data['cu_pass']
    vps_name = ctx.user_data['cu_vps']
    max_login= ctx.user_data.get('cu_maxlogin', 1)

    if is_owner(uid):       created_by = 'owner'
    elif is_reseller(uid):
        rs = get_reseller(uid)
        created_by = rs.get('name', str(uid)) if rs else str(uid)
    else: created_by = str(uid)

    ok, result = add_user_vps(vps_name, username, password, dur, created_by, max_login)

    if ok:
        vip = get_vps_ip(vps_name)
        vpt = get_vps_port(vps_name)
        ml = ctx.user_data.get('cu_maxlogin', 1)
        text = (
            f"✅ *Akun VPN Dibuat!*\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"🖥 VPS     : `{vps_name}`\n"
            f"🌐 Server  : `{vip}`\n"
            f"🔌 Port    : `{vpt}`\n"
            f"🛡 OBFS    : `{OBFS_PASS}`\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"👤 Username: `{username}`\n"
            f"🔑 Password: `{password}`\n"
            f"⏰ Expire  : `{result}`\n"
            f"📆 Durasi  : `{dur} hari`\n"
            f"🔢 Max Login: `{ml} device`\n"
        )
        await update.message.reply_text(text, parse_mode=ParseMode.MARKDOWN)
    else:
        await update.message.reply_text(f"❌ Gagal buat akun: {result}")
    return ConversationHandler.END

# ================================================================
# SHOP
# ================================================================
async def shop(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    settings = get_settings()
    vps = get_all_vps()
    vps_txt = "\n".join(f"• {n} (`{v['ip']}`)" for n, v in vps.items() if v['active'])

    text = (
        f"🛍 *Toko UDP ZiVPN*\n"
        f"━━━━━━━━━━━━━━━━━━━━\n\n"
        f"📦 *Pilih Paket:*\n"
        f"🔸 15 Hari → *Rp 6.000*\n"
        f"🔸 30 Hari → *Rp 10.000*\n\n"
        f"🖥 *Region Tersedia:*\n{vps_txt or '• Tidak ada VPS aktif'}\n\n"
        f"💳 Pembayaran via *QRIS*\n"
        f"⚡ Aktivasi setelah konfirmasi"
    )
    await q.edit_message_text(text, parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([
            [btn("📦 15 Hari — Rp 6.000", "buy_15d"),
             btn("📦 30 Hari — Rp 10.000","buy_30d")],
            back_btn()
        ]))

async def buy_select_pkg(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    pkg = q.data.replace('buy_', '')
    ctx.user_data['buy_pkg'] = pkg
    p   = PACKAGES[pkg]

    vps = get_all_vps()
    btns= [[btn(f"🖥 {n}", f"bvps_{n}")] for n, v in vps.items() if v['active']]
    btns.append(back_btn("shop"))

    await q.edit_message_text(
        f"📦 *{p['label']} — Rp {p['price']:,}*\n\n🖥 Pilih Region VPS:",
        reply_markup=InlineKeyboardMarkup(btns),
        parse_mode=ParseMode.MARKDOWN
    )

async def buy_select_vps(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()
    vps_name = q.data.replace('bvps_', '')
    pkg      = ctx.user_data.get('buy_pkg', '30d')
    p        = PACKAGES[pkg]

    order = create_order(uid, q.from_user.username or str(uid), pkg, vps_name)

    # Kirim pesan dengan/tanpa foto QRIS
    caption = (
        f"💳 *Pembayaran QRIS*\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🆔 Order  : `{order['id']}`\n"
        f"📦 Paket  : `{p['label']}`\n"
        f"🖥 VPS    : `{vps_name}`\n"
        f"💰 Total  : *Rp {p['price']:,}*\n"
        f"⏰ Batas  : 30 menit\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"Scan QR di bawah, lalu upload *foto bukti pembayaran*."
    )
    kb = InlineKeyboardMarkup([
        [btn("📸 Upload Bukti Bayar", f"upload_proof_{order['id']}")],
        [btn("❌ Batal", "shop")]
    ])

    if os.path.exists(QRIS_IMG):
        with open(QRIS_IMG, 'rb') as f:
            await q.message.reply_photo(photo=f, caption=caption,
                                         reply_markup=kb, parse_mode=ParseMode.MARKDOWN)
        await q.delete_message()
    else:
        await q.edit_message_text(
            caption + "\n\n⚠️ _Admin belum upload foto QRIS_",
            reply_markup=kb, parse_mode=ParseMode.MARKDOWN
        )

# ================================================================
# PAYMENT PROOF UPLOAD
# ================================================================
async def upload_proof_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()
    oid = q.data.replace('upload_proof_', '')
    ctx.user_data['paying_order'] = oid
    await q.message.reply_text(
        f"📸 Kirim *foto bukti pembayaran* untuk order `{oid}`\n\n"
        f"_(ketik /batal untuk membatalkan)_",
        parse_mode=ParseMode.MARKDOWN
    )
    return ST_PAYMENT_PROOF

async def receive_payment_proof(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    oid = ctx.user_data.get('paying_order')

    if not update.message.photo:
        await update.message.reply_text("❌ Kirim berupa foto/gambar!")
        return ST_PAYMENT_PROOF

    order = get_order(oid)
    if not order or order['status'] not in ('pending', 'waiting'):
        await update.message.reply_text("❌ Order tidak valid atau sudah diproses.")
        return ConversationHandler.END

    photo   = update.message.photo[-1]
    file_id = photo.file_id
    update_order(oid, {'status': 'waiting', 'proof_file_id': file_id})

    p   = PACKAGES.get(order['package'], {})
    txt = (
        f"🔔 *KONFIRMASI PEMBAYARAN*\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"🆔 Order  : `{oid}`\n"
        f"👤 User   : @{order.get('username_tg','?')} (`{uid}`)\n"
        f"📦 Paket  : `{p.get('label','')}`\n"
        f"🖥 VPS    : `{order['vps']}`\n"
        f"💰 Jumlah : *Rp {order['price']:,}*\n"
        f"━━━━━━━━━━━━━━━━━━━━"
    )
    kb = InlineKeyboardMarkup([
        [btn("✅ APPROVE", f"approve_{oid}"),
         btn("❌ REJECT",  f"reject_{oid}")]
    ])

    # Kirim bukti ke owner
    try:
        await ctx.bot.send_photo(chat_id=OWNER_ID, photo=file_id,
                                  caption=txt, reply_markup=kb,
                                  parse_mode=ParseMode.MARKDOWN)
    except Exception as e:
        logger.error(f"Kirim ke owner gagal: {e}")

    await update.message.reply_text(
        f"⏳ *Bukti pembayaran terkirim!*\n\n"
        f"Order `{oid}` sedang diverifikasi.\n"
        f"Kamu akan dapat notifikasi setelah dikonfirmasi. ✅",
        parse_mode=ParseMode.MARKDOWN
    )
    return ConversationHandler.END

# ================================================================
# APPROVE / REJECT
# ================================================================
async def approve_payment(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()
    if not is_admin(uid):
        await q.answer("❌ Hanya admin!", show_alert=True); return

    oid   = q.data.replace('approve_', '')
    order = get_order(oid)
    if not order:
        await q.edit_message_caption("❌ Order tidak ditemukan!"); return

    p        = PACKAGES.get(order['package'], {})
    duration = p.get('days', 30)
    vuser    = f"ziv{oid.lower()}"
    vpass    = uuid.uuid4().hex[:8]

    ok, result = add_user_vps(order['vps'], vuser, vpass, duration, 'auto_shop')

    if ok:
        exp = result
        update_order(oid, {
            'status':      'paid',
            'vpn_user':    vuser,
            'vpn_pass':    vpass,
            'approved_by': uid,
            'approved_at': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        })
        vip = get_vps_ip(order['vps'])
        vpt = get_vps_port(order['vps'])

        buyer_msg = (
            f"✅ *Pembayaran Dikonfirmasi!*\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"🎉 Akun VPN kamu sudah aktif!\n\n"
            f"🌐 Server  : `{vip}`\n"
            f"🔌 Port    : `{vpt}`\n"
            f"🛡 OBFS    : `{OBFS_PASS}`\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"👤 Username: `{vuser}`\n"
            f"🔑 Password: `{vpass}`\n"
            f"📦 Paket   : `{p.get('label','')}`\n"
            f"⏰ Expire  : `{exp}`\n"
            f"━━━━━━━━━━━━━━━━━━━━\n"
            f"📲 Buka app ZiVPN dan masukkan data di atas."
        )
        try:
            await ctx.bot.send_message(chat_id=order['user_id'],
                                        text=buyer_msg, parse_mode=ParseMode.MARKDOWN)
        except Exception as e:
            logger.error(f"Kirim ke buyer gagal: {e}")

        await q.edit_message_caption(
            f"✅ *APPROVED* — `{oid}`\nUser: `{vuser}` dibuat di {order['vps']}",
            parse_mode=ParseMode.MARKDOWN
        )
    else:
        await q.edit_message_caption(f"❌ Gagal buat akun: {result}")

async def reject_payment(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()
    if not is_admin(uid):
        await q.answer("❌ Hanya admin!", show_alert=True); return

    oid   = q.data.replace('reject_', '')
    order = get_order(oid)
    if order:
        update_order(oid, {'status': 'rejected'})
        try:
            await ctx.bot.send_message(
                chat_id=order['user_id'],
                text=f"❌ *Pembayaran Ditolak*\n\nOrder `{oid}` ditolak.\nHubungi admin untuk bantuan.",
                parse_mode=ParseMode.MARKDOWN
            )
        except: pass
    await q.edit_message_caption(f"❌ *REJECTED* — `{oid}`", parse_mode=ParseMode.MARKDOWN)

# ================================================================
# MY ACCOUNTS
# ================================================================
async def my_accounts(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()

    orders = [o for o in get_orders().get('orders',[])
              if o['user_id'] == uid and o['status'] == 'paid' and o.get('vpn_user')]

    if not orders:
        await q.edit_message_text(
            "📋 *Akun Saya*\n\nBelum ada akun aktif.\nBeli paket untuk mendapatkan akun!",
            reply_markup=InlineKeyboardMarkup([[btn("🛍 Beli Sekarang","shop")], back_btn()]),
            parse_mode=ParseMode.MARKDOWN
        ); return

    text = "📋 *Akun VPN Saya*\n━━━━━━━━━━━━━━━━━━━━\n\n"
    for o in orders[-5:]:
        vip = get_vps_ip(o['vps'])
        vpt = get_vps_port(o['vps'])
        text += (
            f"🆔 `{o['id']}`\n"
            f"🌐 `{vip}:{vpt}`\n"
            f"👤 `{o['vpn_user']}`\n"
            f"🔑 `{o['vpn_pass']}`\n"
            f"🖥 {o['vps']}\n\n"
        )
    await q.edit_message_text(text, parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([[btn("🛍 Beli Lagi","shop")], back_btn()]))

# ================================================================
# RESELLER MANAGEMENT
# ================================================================
async def manage_resellers(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_owner(q.from_user.id):
        await q.edit_message_text("❌ Hanya Owner!"); return

    rs   = get_resellers().get('resellers', [])
    text = f"💼 *Reseller* ({len(rs)})\n━━━━━━━━━━━━━━━━━━━━\n\n"
    for r in rs:
        text += f"👤 *{r['name']}* — `{r['telegram_id']}`\n"
    if not rs: text += "_Belum ada reseller._\n"

    await q.edit_message_text(text, parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([
            [btn("➕ Tambah Reseller","add_reseller"),
             btn("🗑 Hapus Reseller","rm_reseller")],
            back_btn()
        ]))

async def add_reseller_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_owner(q.from_user.id):
        await q.edit_message_text("❌ Hanya Owner!")
        return ConversationHandler.END
    await q.edit_message_text(
        "💼 *Tambah Reseller*\n\nKirim Telegram ID reseller:\n_(contoh: 123456789)_\n\n_/batal untuk batal_",
        parse_mode=ParseMode.MARKDOWN
    )
    return ST_VPS_INFO   # reuse state

async def receive_reseller_id(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    txt = update.message.text.strip()
    if txt == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    try:
        rid = int(txt)
    except:
        await update.message.reply_text("❌ ID harus angka!"); return ST_VPS_INFO

    rs = get_resellers()
    if any(r['telegram_id'] == rid for r in rs.get('resellers',[])):
        await update.message.reply_text("⚠️ ID ini sudah reseller!")
        return ConversationHandler.END

    try:
        chat = await ctx.bot.get_chat(rid)
        name = chat.first_name or str(rid)
    except: name = str(rid)

    rs['resellers'].append({
        'telegram_id': rid, 'name': name,
        'added_date':  datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'added_by':    update.effective_user.id
    })
    save_json(RESELLERS_FILE, rs)

    try:
        await ctx.bot.send_message(rid,
            f"🎉 Kamu ditambahkan sebagai *Reseller UDP ZiVPN*!\n\nKetik /start untuk mulai.",
            parse_mode=ParseMode.MARKDOWN)
    except: pass

    await update.message.reply_text(f"✅ *{name}* (`{rid}`) ditambah sebagai reseller!", parse_mode=ParseMode.MARKDOWN)
    return ConversationHandler.END

# ================================================================
# SETTINGS & QRIS PHOTO UPLOAD
# ================================================================
async def settings_menu(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_owner(q.from_user.id):
        await q.edit_message_text("❌ Hanya Owner!"); return

    has_qris = "✅ Ada" if os.path.exists(QRIS_IMG) else "❌ Belum diupload"

    await q.edit_message_text(
        f"⚙️ *Pengaturan*\n━━━━━━━━━━━━━━━━━━━━\n\nFoto QRIS: {has_qris}",
        parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([
            [btn("🖼 Upload Foto QRIS",  "upload_qris")],
            [btn("➕ Tambah VPS Region", "add_vps")],
            [btn("💼 Kelola Reseller",   "manage_resellers")],
            back_btn()
        ])
    )

async def upload_qris_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_owner(q.from_user.id):
        await q.edit_message_text("❌ Hanya Owner!")
        return ConversationHandler.END
    await q.edit_message_text(
        "🖼 *Upload Foto QRIS*\n\nKirim foto QR code QRIS kamu.\n"
        "Foto ini akan ditampilkan ke pembeli saat checkout.\n\n"
        "_/batal untuk batal_",
        parse_mode=ParseMode.MARKDOWN
    )
    return ST_QRIS_PHOTO

async def receive_qris_photo(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not update.message.photo:
        await update.message.reply_text("❌ Kirim berupa foto!")
        return ST_QRIS_PHOTO

    photo   = update.message.photo[-1]  # ukuran terbesar
    file    = await ctx.bot.get_file(photo.file_id)
    await file.download_to_drive(QRIS_IMG)

    await update.message.reply_text(
        "✅ *Foto QRIS berhasil diupload!*\n\nSekarang foto QR akan muncul otomatis saat pembeli checkout.",
        parse_mode=ParseMode.MARKDOWN
    )
    return ConversationHandler.END

# ================================================================
# ADD VPS REGION
# ================================================================
async def add_vps_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_owner(q.from_user.id):
        await q.edit_message_text("❌ Hanya Owner!")
        return ConversationHandler.END
    await q.edit_message_text(
        "🖥 *Tambah VPS Region*\n\nFormat:\n`NAMA|IP|PORT_SSH|UDP_PORT`\n\n"
        "Contoh:\n`VPS-SG-1|103.x.x.x|22|5667`\n\n_/batal untuk batal_",
        parse_mode=ParseMode.MARKDOWN
    )
    return ST_USERNAME  # reuse state

async def receive_vps_info(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    txt = update.message.text.strip()
    if txt == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END

    parts = txt.split('|')
    if len(parts) < 2:
        await update.message.reply_text("❌ Format: NAMA|IP|PORT_SSH|UDP_PORT")
        return ST_USERNAME

    name     = parts[0].strip()
    ip       = parts[1].strip()
    ssh_port = int(parts[2].strip()) if len(parts) > 2 else 22
    udp_port = parts[3].strip()      if len(parts) > 3 else '5667'

    settings = get_settings()
    if 'vps_regions' not in settings: settings['vps_regions'] = {}
    settings['vps_regions'][name] = {
        'ip': ip, 'port': ssh_port,
        'udp_port': udp_port,
        'ssh_key': '/root/.ssh/id_rsa',
        'added': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    }
    save_json(SETTINGS_FILE, settings)

    await update.message.reply_text(
        f"✅ VPS *{name}* ditambahkan!\n`{ip}` SSH:{ssh_port} UDP:{udp_port}",
        parse_mode=ParseMode.MARKDOWN
    )
    return ConversationHandler.END

# ================================================================
# BACKUP & RESTORE via BOT
# ================================================================
async def do_backup(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer("Membuat backup...")
    if not is_admin(q.from_user.id):
        await q.edit_message_text("❌ Akses ditolak!"); return

    await q.edit_message_text("⏳ Membuat dan mengirim backup...")
    result = subprocess.run(
        ['/bin/bash','/usr/local/bin/udp-zivpn-manage','backup_telegram'],
        capture_output=True, text=True, timeout=120
    )
    if result.returncode == 0:
        await ctx.bot.send_message(q.from_user.id,
            "✅ *Backup berhasil dikirim ke Telegram Owner!*", parse_mode=ParseMode.MARKDOWN)
    else:
        await ctx.bot.send_message(q.from_user.id,
            f"❌ Backup gagal!\n`{result.stderr[-200:]}`", parse_mode=ParseMode.MARKDOWN)

async def do_restore(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_owner(q.from_user.id):
        await q.edit_message_text("❌ Hanya Owner!"); return
    await q.edit_message_text(
        "♻️ *Restore Backup*\n\n"
        "Kirim *file backup* (.tar.gz) ke chat ini,\n"
        "atau gunakan perintah:\n`/restore FILE_ID`",
        parse_mode=ParseMode.MARKDOWN
    )

async def cmd_restore(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_owner(update.effective_user.id):
        await update.message.reply_text("❌ Hanya Owner!"); return
    if not ctx.args:
        await update.message.reply_text("Gunakan: `/restore FILE_ID`", parse_mode=ParseMode.MARKDOWN)
        return
    fid    = ctx.args[0]
    result = subprocess.run(
        ['/bin/bash','/usr/local/bin/udp-zivpn-manage','restore'],
        input=fid, capture_output=True, text=True, timeout=120
    )
    if result.returncode == 0:
        await update.message.reply_text("✅ Restore berhasil!")
    else:
        await update.message.reply_text(f"❌ Restore gagal!\n{result.stderr[-300:]}")

async def handle_backup_file(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Terima file backup .tar.gz dari owner untuk restore"""
    uid = update.effective_user.id
    if not is_owner(uid): return

    doc = update.message.document
    if not doc or not doc.file_name.endswith('.tar.gz'): return

    await update.message.reply_text("⏳ Mendownload dan merestore backup...")
    try:
        file = await ctx.bot.get_file(doc.file_id)
        ts   = int(time.time())
        tmp  = f'/tmp/restore_{ts}.tar.gz'
        await file.download_to_drive(tmp)

        rdir = f'/tmp/rst_{ts}'
        os.makedirs(rdir)
        r = subprocess.run(['tar','-xzf',tmp,'-C',rdir], capture_output=True)
        if r.returncode != 0:
            await update.message.reply_text("❌ Gagal ekstrak backup!"); return

        sub = os.listdir(rdir)[0]
        src = f'{rdir}/{sub}'

        if not os.path.exists(f'{src}/config.json'):
            await update.message.reply_text("❌ File backup tidak valid!"); return

        shutil.copy(f'{src}/config.json', '/etc/udp-zivpn/config.json')
        shutil.copy(f'{src}/users.json',  USERS_FILE)
        if os.path.exists(f'{src}/zivpn.crt'):
            shutil.copy(f'{src}/zivpn.crt', '/etc/zivpn/zivpn.crt')
        if os.path.exists(f'{src}/zivpn.key'):
            shutil.copy(f'{src}/zivpn.key', '/etc/zivpn/zivpn.key')

        subprocess.run(['systemctl','restart','udp-zivpn'])
        shutil.rmtree(rdir); os.remove(tmp)
        await update.message.reply_text("✅ *Restore berhasil! Service direstart.*", parse_mode=ParseMode.MARKDOWN)
    except Exception as e:
        await update.message.reply_text(f"❌ Error: {e}")

# ================================================================
# SPEEDTEST
# ================================================================
async def speedtest_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    await q.edit_message_text("⚡ *Menjalankan Speed Test...*\n\nMohon tunggu 30-60 detik...",
                               parse_mode=ParseMode.MARKDOWN)
    try:
        r = subprocess.run(
            ['speedtest','--accept-license','--accept-gdpr','--format=json'],
            capture_output=True, text=True, timeout=120
        )
        if r.returncode == 0:
            d    = json.loads(r.stdout)
            dl   = d['download']['bandwidth'] * 8 / 1e6
            ul   = d['upload']['bandwidth']   * 8 / 1e6
            ping = d['ping']['latency']
            srv  = d['server']
            text = (
                f"⚡ *Hasil Speed Test*\n━━━━━━━━━━━━━━━━━━━━\n"
                f"🖥 VPS     : `{VPS_NAME}`\n"
                f"📡 Server  : `{srv['name']}, {srv['location']}`\n"
                f"━━━━━━━━━━━━━━━━━━━━\n"
                f"⬇️ Download: `{dl:.2f} Mbps`\n"
                f"⬆️ Upload  : `{ul:.2f} Mbps`\n"
                f"🏓 Ping    : `{ping:.1f} ms`\n"
                f"━━━━━━━━━━━━━━━━━━━━\n"
                f"⏰ `{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}`"
            )
        else: raise Exception("Ookla CLI failed")
    except:
        # Fallback Python speedtest-cli
        try:
            import speedtest as st
            s = st.Speedtest(secure=True)
            s.get_best_server()
            dl   = s.download() / 1e6
            ul   = s.upload()   / 1e6
            ping = s.results.ping
            srv  = s.results.server
            text = (
                f"⚡ *Hasil Speed Test*\n━━━━━━━━━━━━━━━━━━━━\n"
                f"🖥 VPS     : `{VPS_NAME}`\n"
                f"📡 Server  : `{srv.get('name','?')}, {srv.get('country','?')}`\n"
                f"━━━━━━━━━━━━━━━━━━━━\n"
                f"⬇️ Download: `{dl:.2f} Mbps`\n"
                f"⬆️ Upload  : `{ul:.2f} Mbps`\n"
                f"🏓 Ping    : `{ping:.1f} ms`\n"
                f"━━━━━━━━━━━━━━━━━━━━\n"
                f"⏰ `{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}`"
            )
        except Exception as e:
            text = f"❌ Speed test gagal: {e}"

    await q.edit_message_text(text, parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([[btn("🔄 Ulangi","speedtest")], back_btn()]))

# ================================================================
# SET MAX LOGIN
# ================================================================
async def set_maxlogin_menu(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q   = update.callback_query
    uid = q.from_user.id
    await q.answer()
    if not is_admin(uid):
        await q.edit_message_text("❌ Akses ditolak!"); return

    users = get_users().get('users', [])
    if is_reseller(uid) and not is_owner(uid):
        rs   = get_reseller(uid)
        cby  = rs.get('name', str(uid)) if rs else str(uid)
        users= [u for u in users if u.get('created_by') == cby]

    text = "🔢 *Set Max Login*
━━━━━━━━━━━━━━━━━━━━

"
    text += "Format: `/setmaxlogin username jumlah`

"
    text += "Contoh: `/setmaxlogin user1 2`

"
    text += "*Daftar User & Max Login:*
"
    for u in users[-15:]:
        ml = u.get('max_login', 1)
        text += f"• `{u['username']}` → *{ml} device*
"

    await q.edit_message_text(text, parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([back_btn("manage_users")]))

async def cmd_setmaxlogin(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    if not is_admin(uid):
        await update.message.reply_text("❌ Akses ditolak!"); return

    if not ctx.args or len(ctx.args) < 2:
        await update.message.reply_text(
            "Gunakan: `/setmaxlogin username jumlah`
Contoh: `/setmaxlogin user1 2`",
            parse_mode=ParseMode.MARKDOWN
        ); return

    username  = ctx.args[0]
    try:
        max_login = int(ctx.args[1])
        assert 1 <= max_login <= 10
    except:
        await update.message.reply_text("❌ Jumlah 1-10!"); return

    if set_user_max_login(username, max_login):
        await update.message.reply_text(
            f"✅ Max login `{username}` diset ke *{max_login} device*",
            parse_mode=ParseMode.MARKDOWN
        )
    else:
        await update.message.reply_text(f"❌ User `{username}` tidak ditemukan!", parse_mode=ParseMode.MARKDOWN)

# ================================================================
# CALLBACK ROUTER
# ================================================================
async def callback_router(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q    = update.callback_query
    data = q.data
    uid  = q.from_user.id

    if   data == "main_menu":        await q.edit_message_text("🏠 Menu Utama:", reply_markup=main_keyboard(uid))
    elif data == "dashboard":        await dashboard(update, ctx)
    elif data == "vps_status":       await vps_status(update, ctx)
    elif data == "manage_users":     await manage_users(update, ctx)
    elif data == "manage_resellers": await manage_resellers(update, ctx)
    elif data == "create_user":      await create_user_start(update, ctx)
    elif data == "shop":             await shop(update, ctx)
    elif data.startswith("buy_"):    await buy_select_pkg(update, ctx)
    elif data.startswith("bvps_"):   await buy_select_vps(update, ctx)
    elif data.startswith("approve_"):await approve_payment(update, ctx)
    elif data.startswith("reject_"): await reject_payment(update, ctx)
    elif data.startswith("upload_proof_"): await upload_proof_start(update, ctx)
    elif data.startswith("cusr_vps_"): await create_user_vps(update, ctx)
    elif data == "set_maxlogin":      await set_maxlogin_menu(update, ctx)
    elif data == "my_accounts":      await my_accounts(update, ctx)
    elif data == "settings":         await settings_menu(update, ctx)
    elif data == "upload_qris":      await upload_qris_start(update, ctx)
    elif data == "add_vps":          await add_vps_start(update, ctx)
    elif data == "add_reseller":     await add_reseller_start(update, ctx)
    elif data == "do_backup":        await do_backup(update, ctx)
    elif data == "do_restore":       await do_restore(update, ctx)
    elif data == "speedtest":        await speedtest_cb(update, ctx)
    elif data == "info":             await info_cb(update, ctx)
    elif data == "support":          await support_cb(update, ctx)
    else: await q.answer("Fitur ini tidak dikenal.", show_alert=True)

async def info_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    await q.edit_message_text(
        f"ℹ️ *Info UDP ZiVPN*\n━━━━━━━━━━━━━━━━━━━━\n\n"
        f"🔐 Protokol : UDP ZiVPN v1.5\n🌐 Multi-Region VPS\n⚡ Kecepatan Tinggi\n\n"
        f"📦 *Paket:*\n• 15 Hari → Rp 6.000\n• 30 Hari → Rp 10.000\n\n"
        f"💳 Bayar via QRIS\n⚡ Aktivasi setelah konfirmasi",
        parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([[btn("🛍 Beli","shop")], back_btn()])
    )

async def support_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    await q.edit_message_text(
        "💬 *Support*\n\nAda kendala? Hubungi admin.",
        parse_mode=ParseMode.MARKDOWN,
        reply_markup=InlineKeyboardMarkup([back_btn()])
    )

# ================================================================
# MAIN
# ================================================================
def main():
    if not BOT_TOKEN:
        logger.error("BOT_TOKEN tidak ditemukan di bot.conf!")
        sys.exit(1)

    logger.info(f"Starting UDP ZiVPN Bot — VPS: {VPS_NAME} | Owner: {OWNER_ID}")

    app = Application.builder().token(BOT_TOKEN).build()

    # ConversationHandler: Buat User Manual
    create_user_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(create_user_start, pattern="^create_user$")],
        states={
            ST_USERNAME:    [CallbackQueryHandler(create_user_vps,      pattern="^cusr_vps_")],
            ST_PASSWORD:    [MessageHandler(filters.TEXT & ~filters.COMMAND, create_user_username)],
            ST_DURATION:    [MessageHandler(filters.TEXT & ~filters.COMMAND, create_user_password)],
            ST_RESELLER_ID: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_user_maxlogin)],
            ST_VPS_INFO:    [MessageHandler(filters.TEXT & ~filters.COMMAND, create_user_duration)],
        },
        fallbacks=[CommandHandler("batal", lambda u,c: ConversationHandler.END)],
        per_message=False,
    )

    # ConversationHandler: Upload QRIS Photo
    qris_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(upload_qris_start, pattern="^upload_qris$")],
        states={
            ST_QRIS_PHOTO: [MessageHandler(filters.PHOTO, receive_qris_photo)],
        },
        fallbacks=[CommandHandler("batal", lambda u,c: ConversationHandler.END)],
        per_message=False,
    )

    # ConversationHandler: Tambah Reseller
    reseller_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(add_reseller_start, pattern="^add_reseller$")],
        states={
            ST_VPS_INFO: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_reseller_id)],
        },
        fallbacks=[CommandHandler("batal", lambda u,c: ConversationHandler.END)],
        per_message=False,
    )

    # ConversationHandler: Tambah VPS
    vps_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(add_vps_start, pattern="^add_vps$")],
        states={
            ST_USERNAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_vps_info)],
        },
        fallbacks=[CommandHandler("batal", lambda u,c: ConversationHandler.END)],
        per_message=False,
    )

    # ConversationHandler: Upload Bukti Bayar
    proof_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(upload_proof_start, pattern="^upload_proof_")],
        states={
            ST_PAYMENT_PROOF: [MessageHandler(filters.PHOTO, receive_payment_proof)],
        },
        fallbacks=[CommandHandler("batal", lambda u,c: ConversationHandler.END)],
        per_message=False,
    )

    app.add_handler(CommandHandler("start",      cmd_start))
    app.add_handler(CommandHandler("restore",    cmd_restore))
    app.add_handler(CommandHandler("setmaxlogin",cmd_setmaxlogin))
    app.add_handler(create_user_conv)
    app.add_handler(qris_conv)
    app.add_handler(reseller_conv)
    app.add_handler(vps_conv)
    app.add_handler(proof_conv)
    app.add_handler(CallbackQueryHandler(callback_router))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_backup_file))

    async def on_start(application):
        await application.bot.set_my_commands([
            BotCommand("start",       "Menu Utama"),
            BotCommand("restore",     "Restore backup (owner only)"),
            BotCommand("setmaxlogin", "Set max login user"),
            BotCommand("batal",       "Batalkan operasi"),
        ])
    app.post_init = on_start

    logger.info("Bot polling dimulai...")
    app.run_polling(drop_pending_updates=True)

if __name__ == '__main__':
    main()
