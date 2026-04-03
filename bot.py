#!/usr/bin/env python3
# ============================================================
# UDP ZiVPN - Telegram Bot Multi-Region
# Auto Sales, Payment QRIS, User Management
# ============================================================

import asyncio
import json
import os
import sys
import subprocess
import logging
import time
import re
import qrcode
import io
import hashlib
import uuid
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
import requests

# ============================================================
# KONFIGURASI
# ============================================================
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO,
    handlers=[
        logging.FileHandler('/var/log/udp-zivpn/bot.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Load konfigurasi dari file
def load_config():
    config = {}
    bot_conf = '/var/lib/udp-zivpn/bot.conf'
    if os.path.exists(bot_conf):
        with open(bot_conf) as f:
            for line in f:
                line = line.strip()
                if '=' in line:
                    k, v = line.split('=', 1)
                    config[k.strip()] = v.strip().strip('"')
    return config

CONFIG = load_config()
BOT_TOKEN = CONFIG.get('TG_TOKEN', os.getenv('TG_TOKEN', ''))
OWNER_ID = int(CONFIG.get('TG_OWNER_ID', os.getenv('TG_OWNER_ID', '0')))
VPS_NAME = CONFIG.get('VPS_NAME', 'VPS-1')
DATA_DIR = '/var/lib/udp-zivpn'
USERS_FILE = f'{DATA_DIR}/users.json'
RESELLERS_FILE = f'{DATA_DIR}/resellers.json'
ORDERS_FILE = f'{DATA_DIR}/orders.json'
SETTINGS_FILE = f'{DATA_DIR}/settings.json'

# Harga paket
PACKAGES = {
    '15days': {'days': 15, 'price': 6000, 'label': '15 Hari'},
    '30days': {'days': 30, 'price': 10000, 'label': '30 Hari'},
}

# Multi-VPS regions
VPS_REGIONS = {}

# State untuk conversation handler
(WAITING_USERNAME, WAITING_PASSWORD, WAITING_DURATION,
 WAITING_PAYMENT, WAITING_VPS_ADD, WAITING_RESELLER_ADD,
 WAITING_QRIS_INFO) = range(7)

# ============================================================
# DATABASE HELPERS
# ============================================================
def load_json(filepath, default=None):
    if default is None:
        default = {}
    try:
        if os.path.exists(filepath):
            with open(filepath) as f:
                return json.load(f)
    except:
        pass
    return default

def save_json(filepath, data):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def load_users():
    return load_json(USERS_FILE, {'users': []})

def save_users(data):
    save_json(USERS_FILE, data)

def load_resellers():
    return load_json(RESELLERS_FILE, {'resellers': []})

def save_resellers(data):
    save_json(RESELLERS_FILE, data)

def load_orders():
    return load_json(ORDERS_FILE, {'orders': []})

def save_orders(data):
    save_json(ORDERS_FILE, data)

def load_settings():
    return load_json(SETTINGS_FILE, {
        'qris_number': '',
        'qris_name': '',
        'payment_timeout': 30,
        'auto_approve': False,
        'vps_regions': {}
    })

def save_settings(data):
    save_json(SETTINGS_FILE, data)

# ============================================================
# PERMISSION CHECKS
# ============================================================
def is_owner(user_id: int) -> bool:
    return user_id == OWNER_ID

def is_reseller(user_id: int) -> bool:
    resellers = load_resellers()
    return any(r['telegram_id'] == user_id for r in resellers.get('resellers', []))

def is_admin(user_id: int) -> bool:
    return is_owner(user_id) or is_reseller(user_id)

def get_reseller_info(user_id: int) -> Optional[Dict]:
    resellers = load_resellers()
    for r in resellers.get('resellers', []):
        if r['telegram_id'] == user_id:
            return r
    return None

# ============================================================
# VPS MANAGEMENT
# ============================================================
def execute_on_vps(vps_name: str, command: str, args: list = None) -> Dict:
    """Eksekusi command di VPS tertentu atau lokal"""
    settings = load_settings()
    regions = settings.get('vps_regions', {})
    
    if vps_name == 'local' or vps_name == VPS_NAME:
        # Eksekusi lokal
        result = subprocess.run(
            ['/bin/bash', '/usr/local/bin/udp-zivpn-manage', command] + (args or []),
            capture_output=True, text=True, timeout=30
        )
        return {
            'success': result.returncode == 0,
            'output': result.stdout,
            'error': result.stderr
        }
    elif vps_name in regions:
        # Eksekusi via SSH ke VPS lain
        vps = regions[vps_name]
        ssh_cmd = f"ssh -i {vps.get('ssh_key', '/root/.ssh/id_rsa')} -p {vps.get('port', 22)} -o StrictHostKeyChecking=no root@{vps['ip']} '/bin/bash /usr/local/bin/udp-zivpn-manage {command} {\" \".join(args or [])}'"
        result = subprocess.run(ssh_cmd, shell=True, capture_output=True, text=True, timeout=30)
        return {
            'success': result.returncode == 0,
            'output': result.stdout,
            'error': result.stderr
        }
    else:
        return {'success': False, 'output': '', 'error': f'VPS {vps_name} tidak ditemukan'}

def get_all_vps_status() -> Dict:
    settings = load_settings()
    regions = settings.get('vps_regions', {})
    status = {}
    
    # Status VPS lokal
    result = subprocess.run(['systemctl', 'is-active', 'udp-zivpn'], capture_output=True, text=True)
    status[VPS_NAME] = {
        'name': VPS_NAME,
        'active': result.stdout.strip() == 'active',
        'ip': subprocess.run(['curl', '-s4', 'ifconfig.me'], capture_output=True, text=True).stdout.strip(),
        'local': True
    }
    
    # Status VPS remote
    for name, vps in regions.items():
        try:
            ssh_cmd = f"ssh -i {vps.get('ssh_key', '/root/.ssh/id_rsa')} -p {vps.get('port', 22)} -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@{vps['ip']} 'systemctl is-active udp-zivpn'"
            result = subprocess.run(ssh_cmd, shell=True, capture_output=True, text=True, timeout=10)
            status[name] = {
                'name': name,
                'active': result.stdout.strip() == 'active',
                'ip': vps['ip'],
                'local': False
            }
        except:
            status[name] = {
                'name': name,
                'active': False,
                'ip': vps.get('ip', 'Unknown'),
                'local': False
            }
    
    return status

def add_user_to_vps(vps_name: str, username: str, password: str, duration: int, created_by: str = 'bot') -> bool:
    """Tambah user ke VPS tertentu"""
    if vps_name == VPS_NAME:
        # Lokal
        users_data = load_users()
        expire_date = (datetime.now() + timedelta(days=duration)).strftime('%Y-%m-%d %H:%M:%S')
        
        # Cek duplikat
        if any(u['username'] == username for u in users_data.get('users', [])):
            return False
        
        users_data['users'].append({
            'username': username,
            'password': password,
            'expire': expire_date,
            'created': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'created_by': created_by,
            'duration': duration,
            'active': True,
            'vps': vps_name,
            'bytes_sent': 0,
            'bytes_recv': 0
        })
        save_users(users_data)
        
        # Update auth config
        subprocess.run(['/bin/bash', '/usr/local/bin/udp-zivpn-manage', 'update_auth'], timeout=10)
        return True
    else:
        result = execute_on_vps(vps_name, 'add_user', [username, password, str(duration), created_by])
        return result['success']

# ============================================================
# ORDER & PAYMENT SYSTEM
# ============================================================
def create_order(user_id: int, username_tg: str, package: str, vps_name: str) -> Dict:
    orders = load_orders()
    order_id = str(uuid.uuid4())[:8].upper()
    package_info = PACKAGES.get(package, {})
    
    order = {
        'id': order_id,
        'user_id': user_id,
        'username_tg': username_tg,
        'package': package,
        'days': package_info.get('days', 30),
        'price': package_info.get('price', 0),
        'vps': vps_name,
        'status': 'pending',
        'created': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'expire_payment': (datetime.now() + timedelta(minutes=30)).strftime('%Y-%m-%d %H:%M:%S'),
        'vpn_username': None,
        'vpn_password': None,
    }
    
    orders['orders'].append(order)
    save_orders(orders)
    return order

def get_order(order_id: str) -> Optional[Dict]:
    orders = load_orders()
    for order in orders.get('orders', []):
        if order['id'] == order_id:
            return order
    return None

def update_order(order_id: str, updates: Dict):
    orders = load_orders()
    for i, order in enumerate(orders.get('orders', [])):
        if order['id'] == order_id:
            orders['orders'][i].update(updates)
            break
    save_orders(orders)

def generate_qris_image(amount: int, order_id: str) -> bytes:
    """Generate QR Code untuk QRIS payment"""
    settings = load_settings()
    qris_number = settings.get('qris_number', '')
    qris_name = settings.get('qris_name', 'UDP ZiVPN')
    
    # Format QRIS dinamis (format standar QRIS Indonesia)
    qris_data = f"00020101021226620014ID.CO.BRI.WWW0118{qris_number}0303UMI51440014ID.CO.QRIS.WWW0215ID10201900990760303UMI520454995802ID5912{qris_name[:12]}6013Jakarta Pusat610551160624{order_id}630493AB"
    
    # Jika tidak ada QRIS number, buat QR dummy
    if not qris_number:
        qris_data = f"ORDER:{order_id}|AMOUNT:{amount}|PAY TO: {qris_name}"
    
    # Generate QR Code
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )
    qr.add_data(qris_data)
    qr.make(fit=True)
    
    img = qr.make_image(fill_color="black", back_color="white")
    
    # Convert ke bytes
    img_bytes = io.BytesIO()
    img.save(img_bytes, format='PNG')
    img_bytes.seek(0)
    return img_bytes.getvalue()

# ============================================================
# HANDLERS - START & MENU
# ============================================================
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    user_id = user.id
    
    if is_owner(user_id):
        role = "👑 Owner"
    elif is_reseller(user_id):
        role = "💼 Reseller"
    else:
        role = "👤 Member"
    
    text = (
        f"🔐 *UDP ZiVPN Bot*\n"
        f"━━━━━━━━━━━━━━━━━━━━\n"
        f"Halo {user.first_name}! {role}\n\n"
        f"🖥 *Multi-Region VPN Tunnel*\n"
        f"📡 Powered by ZiVPN Protocol\n\n"
        f"Pilih menu di bawah ini:"
    )
    
    keyboard = get_main_keyboard(user_id)
    await update.message.reply_text(text, reply_markup=keyboard, parse_mode=ParseMode.MARKDOWN)

def get_main_keyboard(user_id: int) -> InlineKeyboardMarkup:
    buttons = []
    
    if is_owner(user_id):
        buttons = [
            [InlineKeyboardButton("📊 Dashboard", callback_data="dashboard"),
             InlineKeyboardButton("🖥 VPS Status", callback_data="vps_status")],
            [InlineKeyboardButton("👥 Kelola User", callback_data="manage_users"),
             InlineKeyboardButton("💼 Kelola Reseller", callback_data="manage_resellers")],
            [InlineKeyboardButton("🆕 Buat User Manual", callback_data="create_user_manual"),
             InlineKeyboardButton("🔧 Pengaturan", callback_data="settings")],
            [InlineKeyboardButton("💾 Backup", callback_data="backup"),
             InlineKeyboardButton("♻️ Restore", callback_data="restore")],
            [InlineKeyboardButton("⚡ Speed Test", callback_data="speedtest"),
             InlineKeyboardButton("📋 Log", callback_data="view_log")],
            [InlineKeyboardButton("🛍 Lihat Toko", callback_data="shop")],
        ]
    elif is_reseller(user_id):
        buttons = [
            [InlineKeyboardButton("📊 Dashboard", callback_data="dashboard"),
             InlineKeyboardButton("🖥 VPS Status", callback_data="vps_status")],
            [InlineKeyboardButton("👥 Kelola User", callback_data="manage_users"),
             InlineKeyboardButton("🆕 Buat User Manual", callback_data="create_user_manual")],
            [InlineKeyboardButton("⚡ Speed Test", callback_data="speedtest"),
             InlineKeyboardButton("🛍 Lihat Toko", callback_data="shop")],
        ]
    else:
        buttons = [
            [InlineKeyboardButton("🛍 Beli Akun VPN", callback_data="shop"),
             InlineKeyboardButton("ℹ️ Info", callback_data="info")],
            [InlineKeyboardButton("📋 Akun Saya", callback_data="my_accounts"),
             InlineKeyboardButton("💬 Support", callback_data="support")],
        ]
    
    return InlineKeyboardMarkup(buttons)

# ============================================================
# DASHBOARD
# ============================================================
async def dashboard(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_admin(user_id):
        await query.edit_message_text("❌ Akses ditolak!")
        return
    
    users_data = load_users()
    users = users_data.get('users', [])
    total = len(users)
    active = sum(1 for u in users if u.get('active') and datetime.strptime(u['expire'], '%Y-%m-%d %H:%M:%S') > datetime.now())
    expired = total - active
    
    orders = load_orders()
    pending = sum(1 for o in orders.get('orders', []) if o['status'] == 'pending')
    paid = sum(1 for o in orders.get('orders', []) if o['status'] == 'paid')
    
    # VPS Status
    vps_status = get_all_vps_status()
    vps_text = ""
    for name, info in vps_status.items():
        status_icon = "🟢" if info['active'] else "🔴"
        vps_text += f"{status_icon} {name} (`{info['ip']}`)\n"
    
    text = (
        f"📊 *Dashboard UDP ZiVPN*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        f"👥 *User Statistics*\n"
        f"├ Total User: `{total}`\n"
        f"├ User Aktif: `{active}`\n"
        f"└ User Expired: `{expired}`\n\n"
        f"🛍 *Order Statistics*\n"
        f"├ Pending: `{pending}`\n"
        f"└ Lunas: `{paid}`\n\n"
        f"🖥 *VPS Regions*\n"
        f"{vps_text}\n"
        f"⏰ Update: {datetime.now().strftime('%H:%M:%S')}"
    )
    
    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("🔄 Refresh", callback_data="dashboard"),
         InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")],
    ])
    
    await query.edit_message_text(text, reply_markup=keyboard, parse_mode=ParseMode.MARKDOWN)

# ============================================================
# VPS STATUS
# ============================================================
async def vps_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer("Mengecek status semua VPS...")
    user_id = query.from_user.id
    
    if not is_admin(user_id):
        await query.edit_message_text("❌ Akses ditolak!")
        return
    
    status_all = get_all_vps_status()
    text = "🖥 *Status Semua VPS Region*\n━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    for name, info in status_all.items():
        icon = "🟢" if info['active'] else "🔴"
        local_tag = " *(Local)*" if info.get('local') else ""
        text += f"{icon} *{name}*{local_tag}\n"
        text += f"   IP: `{info['ip']}`\n"
        text += f"   Status: {'Aktif' if info['active'] else 'Mati'}\n\n"
    
    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("🔄 Refresh", callback_data="vps_status")],
        [InlineKeyboardButton("➕ Tambah VPS", callback_data="add_vps"),
         InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")],
    ])
    
    await query.edit_message_text(text, reply_markup=keyboard, parse_mode=ParseMode.MARKDOWN)

# ============================================================
# MANAGE USERS
# ============================================================
async def manage_users(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_admin(user_id):
        await query.edit_message_text("❌ Akses ditolak!")
        return
    
    users_data = load_users()
    users = users_data.get('users', [])
    
    # Filter berdasarkan reseller
    if is_reseller(user_id) and not is_owner(user_id):
        reseller_info = get_reseller_info(user_id)
        reseller_name = reseller_info.get('name', str(user_id)) if reseller_info else str(user_id)
        users = [u for u in users if u.get('created_by') == reseller_name]
    
    now = datetime.now()
    text = f"👥 *Daftar User* ({len(users)} total)\n━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    for u in users[-10:]:  # Tampilkan 10 terakhir
        try:
            exp = datetime.strptime(u['expire'], '%Y-%m-%d %H:%M:%S')
            days_left = (exp - now).days
            icon = "🟢" if days_left > 0 else "🔴"
            text += f"{icon} `{u['username']}`\n"
            text += f"   VPS: {u.get('vps', VPS_NAME)} | Sisa: {max(0, days_left)} hari\n\n"
        except:
            pass
    
    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("🆕 Tambah User", callback_data="create_user_manual"),
         InlineKeyboardButton("🗑 Hapus User", callback_data="delete_user_menu")],
        [InlineKeyboardButton("🔄 Perpanjang", callback_data="renew_user_menu"),
         InlineKeyboardButton("📋 Semua User", callback_data="list_all_users")],
        [InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")],
    ])
    
    await query.edit_message_text(text, reply_markup=keyboard, parse_mode=ParseMode.MARKDOWN)

async def create_user_manual_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_admin(user_id):
        await query.edit_message_text("❌ Akses ditolak!")
        return ConversationHandler.END
    
    # Pilih VPS
    settings = load_settings()
    regions = settings.get('vps_regions', {})
    
    buttons = [[InlineKeyboardButton(f"🖥 {VPS_NAME} (Local)", callback_data=f"sel_vps_{VPS_NAME}")]]
    for name in regions.keys():
        buttons.append([InlineKeyboardButton(f"🖥 {name}", callback_data=f"sel_vps_{name}")])
    buttons.append([InlineKeyboardButton("❌ Batal", callback_data="manage_users")])
    
    await query.edit_message_text(
        "🖥 *Pilih VPS Region:*\nUser akan dibuat di VPS yang dipilih.",
        reply_markup=InlineKeyboardMarkup(buttons),
        parse_mode=ParseMode.MARKDOWN
    )
    return WAITING_VPS_ADD

async def select_vps_for_user(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    vps_name = query.data.replace('sel_vps_', '')
    context.user_data['selected_vps'] = vps_name
    
    await query.edit_message_text(
        f"🖥 VPS dipilih: *{vps_name}*\n\n"
        f"👤 Ketik username untuk akun VPN:\n"
        f"(Ketik /batal untuk membatalkan)",
        parse_mode=ParseMode.MARKDOWN
    )
    return WAITING_USERNAME

async def receive_username(update: Update, context: ContextTypes.DEFAULT_TYPE):
    username = update.message.text.strip()
    
    if username == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    
    if not re.match(r'^[a-zA-Z0-9_-]+$', username):
        await update.message.reply_text("❌ Username hanya boleh huruf, angka, underscore, dan dash!")
        return WAITING_USERNAME
    
    context.user_data['vpn_username'] = username
    await update.message.reply_text(
        f"✅ Username: `{username}`\n\n"
        f"🔑 Ketik password untuk akun VPN:",
        parse_mode=ParseMode.MARKDOWN
    )
    return WAITING_PASSWORD

async def receive_password(update: Update, context: ContextTypes.DEFAULT_TYPE):
    password = update.message.text.strip()
    context.user_data['vpn_password'] = password
    
    await update.message.reply_text(
        f"✅ Password tersimpan.\n\n"
        f"📅 Ketik durasi akun (hari):\nContoh: 15, 30, 7",
        parse_mode=ParseMode.MARKDOWN
    )
    return WAITING_DURATION

async def receive_duration(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        duration = int(update.message.text.strip())
        if duration < 1 or duration > 365:
            raise ValueError()
    except:
        await update.message.reply_text("❌ Durasi tidak valid! Masukkan angka 1-365.")
        return WAITING_DURATION
    
    user_id = update.effective_user.id
    username = context.user_data.get('vpn_username')
    password = context.user_data.get('vpn_password')
    vps_name = context.user_data.get('selected_vps', VPS_NAME)
    
    # Dapatkan nama creator
    if is_owner(user_id):
        created_by = 'owner'
    elif is_reseller(user_id):
        reseller_info = get_reseller_info(user_id)
        created_by = reseller_info.get('name', str(user_id)) if reseller_info else str(user_id)
    else:
        created_by = str(user_id)
    
    success = add_user_to_vps(vps_name, username, password, duration, created_by)
    
    if success:
        expire_date = (datetime.now() + timedelta(days=duration)).strftime('%Y-%m-%d %H:%M:%S')
        settings = load_settings()
        vps_ip = settings.get('vps_regions', {}).get(vps_name, {}).get('ip', 'localhost')
        if vps_name == VPS_NAME:
            vps_ip = subprocess.run(['curl', '-s4', 'ifconfig.me'], capture_output=True, text=True).stdout.strip()
        
        text = (
            f"✅ *Akun VPN Berhasil Dibuat!*\n"
            f"━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🖥 VPS: `{vps_name}`\n"
            f"🌐 IP Server: `{vps_ip}`\n"
            f"👤 Username: `{username}`\n"
            f"🔑 Password: `{password}`\n"
            f"📅 Expire: `{expire_date}`\n"
            f"⏱ Durasi: `{duration} hari`\n"
            f"━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"📲 *Cara Connect:*\n"
            f"Buka app ZiVPN, masukkan:\n"
            f"Server: `{vps_ip}`\n"
            f"Username: `{username}`\n"
            f"Password: `{password}`"
        )
        
        keyboard = InlineKeyboardMarkup([
            [InlineKeyboardButton("👥 Kelola User", callback_data="manage_users"),
             InlineKeyboardButton("🏠 Menu", callback_data="main_menu")]
        ])
        await update.message.reply_text(text, reply_markup=keyboard, parse_mode=ParseMode.MARKDOWN)
    else:
        await update.message.reply_text(
            f"❌ Gagal membuat akun! Username mungkin sudah digunakan."
        )
    
    return ConversationHandler.END

# ============================================================
# SHOP & PAYMENT
# ============================================================
async def shop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    settings = load_settings()
    regions = settings.get('vps_regions', {})
    
    text = (
        f"🛍 *Toko UDP ZiVPN*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━━\n"
        f"Pilih paket yang diinginkan:\n\n"
        f"📦 *Paket Tersedia:*\n"
        f"🔸 15 Hari → Rp 6.000\n"
        f"🔸 30 Hari → Rp 10.000\n\n"
        f"💳 *Pembayaran:* QRIS\n"
        f"⚡ *Aktivasi:* Otomatis setelah konfirmasi\n\n"
        f"🖥 *Region Tersedia:*\n"
        f"• {VPS_NAME} (Local)\n"
    )
    
    for name in regions.keys():
        text += f"• {name}\n"
    
    buttons = [
        [InlineKeyboardButton("15 Hari - Rp 6.000", callback_data="buy_15days"),
         InlineKeyboardButton("30 Hari - Rp 10.000", callback_data="buy_30days")],
        [InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")]
    ]
    
    await query.edit_message_text(text, reply_markup=InlineKeyboardMarkup(buttons), parse_mode=ParseMode.MARKDOWN)

async def buy_package(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    package = query.data.replace('buy_', '')
    context.user_data['buy_package'] = package
    
    # Pilih VPS Region
    settings = load_settings()
    regions = settings.get('vps_regions', {})
    
    buttons = [[InlineKeyboardButton(f"🖥 {VPS_NAME}", callback_data=f"buy_vps_{VPS_NAME}")]]
    for name in regions.keys():
        buttons.append([InlineKeyboardButton(f"🖥 {name}", callback_data=f"buy_vps_{name}")])
    buttons.append([InlineKeyboardButton("◀️ Kembali", callback_data="shop")])
    
    pkg = PACKAGES[package]
    await query.edit_message_text(
        f"🛍 Paket: *{pkg['label']} - Rp {pkg['price']:,}*\n\n"
        f"🖥 *Pilih Region VPS:*",
        reply_markup=InlineKeyboardMarkup(buttons),
        parse_mode=ParseMode.MARKDOWN
    )

async def buy_select_vps(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    vps_name = query.data.replace('buy_vps_', '')
    package = context.user_data.get('buy_package', '30days')
    pkg = PACKAGES[package]
    
    # Buat order
    order = create_order(
        user_id=user_id,
        username_tg=query.from_user.username or str(user_id),
        package=package,
        vps_name=vps_name
    )
    
    # Generate QRIS
    qris_bytes = generate_qris_image(pkg['price'], order['id'])
    
    text = (
        f"💳 *Pembayaran QRIS*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━━\n"
        f"🆔 Order ID: `{order['id']}`\n"
        f"📦 Paket: `{pkg['label']}`\n"
        f"🖥 VPS: `{vps_name}`\n"
        f"💰 Total: *Rp {pkg['price']:,}*\n"
        f"⏰ Batas bayar: 30 menit\n\n"
        f"📱 *Scan QR Code di bawah untuk bayar*\n"
        f"Setelah bayar, klik *Konfirmasi Pembayaran*"
    )
    
    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("✅ Konfirmasi Pembayaran", callback_data=f"confirm_pay_{order['id']}")],
        [InlineKeyboardButton("❌ Batal", callback_data="shop")],
    ])
    
    # Kirim QR Code
    await query.message.reply_photo(
        photo=io.BytesIO(qris_bytes),
        caption=text,
        reply_markup=keyboard,
        parse_mode=ParseMode.MARKDOWN
    )
    await query.delete_message()

async def confirm_payment(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer("Menunggu konfirmasi admin...")
    user_id = query.from_user.id
    
    order_id = query.data.replace('confirm_pay_', '')
    order = get_order(order_id)
    
    if not order:
        await query.edit_message_caption("❌ Order tidak ditemukan!")
        return
    
    if order['status'] != 'pending':
        await query.edit_message_caption("⚠️ Order ini sudah diproses!")
        return
    
    # Update status ke waiting_confirm
    update_order(order_id, {'status': 'waiting_confirm'})
    
    pkg = PACKAGES.get(order['package'], {})
    
    # Notifikasi ke owner
    await context.bot.send_message(
        chat_id=OWNER_ID,
        text=(
            f"🔔 *KONFIRMASI PEMBAYARAN*\n"
            f"━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🆔 Order: `{order_id}`\n"
            f"👤 User: @{order.get('username_tg', 'Unknown')} (`{user_id}`)\n"
            f"📦 Paket: `{pkg.get('label', '')}`\n"
            f"🖥 VPS: `{order['vps']}`\n"
            f"💰 Jumlah: *Rp {order['price']:,}*\n"
            f"━━━━━━━━━━━━━━━━━━━━━━━"
        ),
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("✅ APPROVE", callback_data=f"approve_{order_id}"),
             InlineKeyboardButton("❌ REJECT", callback_data=f"reject_{order_id}")]
        ]),
        parse_mode=ParseMode.MARKDOWN
    )
    
    await query.edit_message_caption(
        f"⏳ *Menunggu Konfirmasi*\n\n"
        f"Order ID: `{order_id}`\n"
        f"Status: Menunggu verifikasi admin\n\n"
        f"Anda akan mendapat notifikasi setelah dikonfirmasi.",
        parse_mode=ParseMode.MARKDOWN
    )

async def approve_payment(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_admin(user_id):
        await query.answer("❌ Hanya admin yang bisa approve!", show_alert=True)
        return
    
    order_id = query.data.replace('approve_', '')
    order = get_order(order_id)
    
    if not order:
        await query.edit_message_text("❌ Order tidak ditemukan!")
        return
    
    # Generate username & password otomatis
    vpn_username = f"ziv{order_id.lower()}"
    vpn_password = str(uuid.uuid4())[:8]
    pkg = PACKAGES.get(order['package'], {})
    duration = pkg.get('days', 30)
    
    # Buat user di VPS
    success = add_user_to_vps(
        order['vps'], vpn_username, vpn_password, duration, 'auto_shop'
    )
    
    if success:
        expire_date = (datetime.now() + timedelta(days=duration)).strftime('%Y-%m-%d %H:%M:%S')
        
        # Update order
        update_order(order_id, {
            'status': 'paid',
            'vpn_username': vpn_username,
            'vpn_password': vpn_password,
            'approved_by': user_id,
            'approved_at': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        })
        
        # Dapatkan IP VPS
        settings = load_settings()
        vps_ip = settings.get('vps_regions', {}).get(order['vps'], {}).get('ip', 'localhost')
        if order['vps'] == VPS_NAME:
            vps_ip = subprocess.run(['curl', '-s4', 'ifconfig.me'], capture_output=True, text=True).stdout.strip()
        
        # Kirim info akun ke pembeli
        buyer_text = (
            f"✅ *Pembayaran Dikonfirmasi!*\n"
            f"━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🎉 Akun VPN Anda sudah aktif!\n\n"
            f"🖥 Server: `{vps_ip}`\n"
            f"👤 Username: `{vpn_username}`\n"
            f"🔑 Password: `{vpn_password}`\n"
            f"📦 Paket: `{pkg.get('label', '')}`\n"
            f"📅 Expire: `{expire_date}`\n"
            f"━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"📲 Download ZiVPN App dan connect!\n"
            f"💬 Ada masalah? Hubungi support"
        )
        
        try:
            await context.bot.send_message(
                chat_id=order['user_id'],
                text=buyer_text,
                parse_mode=ParseMode.MARKDOWN
            )
        except Exception as e:
            logger.error(f"Gagal kirim ke buyer: {e}")
        
        # Update pesan admin
        await query.edit_message_text(
            f"✅ *ORDER DIAPPROVE*\n\n"
            f"Order: `{order_id}`\n"
            f"Username dibuat: `{vpn_username}`\n"
            f"Info akun dikirim ke pembeli.",
            parse_mode=ParseMode.MARKDOWN
        )
    else:
        await query.edit_message_text(
            f"❌ Gagal membuat akun VPN!\nCek VPS {order['vps']}",
        )

async def reject_payment(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_admin(user_id):
        await query.answer("❌ Hanya admin!", show_alert=True)
        return
    
    order_id = query.data.replace('reject_', '')
    order = get_order(order_id)
    
    if order:
        update_order(order_id, {'status': 'rejected'})
        
        try:
            await context.bot.send_message(
                chat_id=order['user_id'],
                text=(
                    f"❌ *Pembayaran Ditolak*\n\n"
                    f"Order ID: `{order_id}`\n"
                    f"Pembayaran Anda tidak dapat dikonfirmasi.\n"
                    f"Hubungi support untuk bantuan."
                ),
                parse_mode=ParseMode.MARKDOWN
            )
        except:
            pass
    
    await query.edit_message_text(f"❌ Order `{order_id}` ditolak.", parse_mode=ParseMode.MARKDOWN)

# ============================================================
# RESELLER MANAGEMENT
# ============================================================
async def manage_resellers(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_owner(user_id):
        await query.edit_message_text("❌ Hanya Owner!")
        return
    
    resellers = load_resellers()
    rs_list = resellers.get('resellers', [])
    
    text = f"💼 *Daftar Reseller* ({len(rs_list)} total)\n━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    for r in rs_list:
        text += f"👤 *{r['name']}*\n"
        text += f"   ID: `{r['telegram_id']}`\n"
        text += f"   Ditambah: {r.get('added_date', 'N/A')}\n\n"
    
    if not rs_list:
        text += "Belum ada reseller.\n"
    
    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("➕ Tambah Reseller", callback_data="add_reseller"),
         InlineKeyboardButton("🗑 Hapus Reseller", callback_data="remove_reseller")],
        [InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")],
    ])
    
    await query.edit_message_text(text, reply_markup=keyboard, parse_mode=ParseMode.MARKDOWN)

async def add_reseller_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    await query.edit_message_text(
        "💼 *Tambah Reseller*\n\n"
        "Kirim Telegram ID reseller baru:\n"
        "(Contoh: 123456789)\n\n"
        "Ketik /batal untuk membatalkan",
        parse_mode=ParseMode.MARKDOWN
    )
    return WAITING_RESELLER_ADD

async def receive_reseller_id(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = update.message.text.strip()
    
    if text == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    
    try:
        reseller_tg_id = int(text)
    except:
        await update.message.reply_text("❌ ID tidak valid! Masukkan angka.")
        return WAITING_RESELLER_ADD
    
    resellers = load_resellers()
    
    # Cek duplikat
    if any(r['telegram_id'] == reseller_tg_id for r in resellers.get('resellers', [])):
        await update.message.reply_text("⚠️ ID ini sudah terdaftar sebagai reseller!")
        return ConversationHandler.END
    
    # Dapatkan info user dari Telegram
    try:
        chat = await context.bot.get_chat(reseller_tg_id)
        name = chat.first_name or str(reseller_tg_id)
    except:
        name = str(reseller_tg_id)
    
    resellers['resellers'].append({
        'telegram_id': reseller_tg_id,
        'name': name,
        'added_date': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'added_by': update.effective_user.id
    })
    save_resellers(resellers)
    
    # Notifikasi ke reseller
    try:
        await context.bot.send_message(
            chat_id=reseller_tg_id,
            text=(
                f"🎉 *Selamat!*\n\n"
                f"Kamu telah ditambahkan sebagai *Reseller UDP ZiVPN*!\n\n"
                f"Kamu sekarang bisa:\n"
                f"✅ Membuat akun VPN gratis\n"
                f"✅ Mengelola user kamu\n"
                f"✅ Akses dashboard\n\n"
                f"Ketik /start untuk memulai."
            ),
            parse_mode=ParseMode.MARKDOWN
        )
    except:
        pass
    
    await update.message.reply_text(
        f"✅ *{name}* (`{reseller_tg_id}`) berhasil ditambah sebagai reseller!",
        parse_mode=ParseMode.MARKDOWN
    )
    return ConversationHandler.END

# ============================================================
# ADD VPS REGION
# ============================================================
async def add_vps_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_owner(user_id):
        await query.edit_message_text("❌ Hanya Owner!")
        return ConversationHandler.END
    
    await query.edit_message_text(
        "🖥 *Tambah VPS Region*\n\n"
        "Kirim info VPS dalam format:\n"
        "`NAMA|IP|PORT_SSH|PATH_SSH_KEY`\n\n"
        "Contoh:\n"
        "`VPS-SG-1|192.168.1.1|22|/root/.ssh/id_rsa`\n\n"
        "Ketik /batal untuk batal",
        parse_mode=ParseMode.MARKDOWN
    )
    return WAITING_VPS_ADD

async def receive_vps_info(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = update.message.text.strip()
    
    if text == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    
    parts = text.split('|')
    if len(parts) < 2:
        await update.message.reply_text("❌ Format salah! Gunakan: NAMA|IP|PORT|SSH_KEY")
        return WAITING_VPS_ADD
    
    vps_name = parts[0].strip()
    vps_ip = parts[1].strip()
    vps_port = int(parts[2].strip()) if len(parts) > 2 else 22
    ssh_key = parts[3].strip() if len(parts) > 3 else '/root/.ssh/id_rsa'
    
    settings = load_settings()
    if 'vps_regions' not in settings:
        settings['vps_regions'] = {}
    
    settings['vps_regions'][vps_name] = {
        'ip': vps_ip,
        'port': vps_port,
        'ssh_key': ssh_key,
        'added': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    }
    save_settings(settings)
    
    await update.message.reply_text(
        f"✅ *VPS Region Ditambahkan!*\n\n"
        f"Nama: `{vps_name}`\n"
        f"IP: `{vps_ip}`\n"
        f"Port SSH: `{vps_port}`\n"
        f"SSH Key: `{ssh_key}`\n\n"
        f"Pastikan VPS sudah terinstall UDP ZiVPN dan SSH key sudah dikopikan.",
        parse_mode=ParseMode.MARKDOWN
    )
    return ConversationHandler.END

# ============================================================
# BACKUP & RESTORE
# ============================================================
async def backup_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer("Membuat backup...")
    user_id = query.from_user.id
    
    if not is_admin(user_id):
        await query.edit_message_text("❌ Akses ditolak!")
        return
    
    await query.edit_message_text("⏳ Membuat backup dan mengirim ke Telegram...")
    
    result = subprocess.run(
        ['/bin/bash', '/usr/local/bin/udp-zivpn-manage', 'backup_telegram'],
        capture_output=True, text=True, timeout=120
    )
    
    if result.returncode == 0:
        await context.bot.send_message(
            chat_id=user_id,
            text=(
                f"✅ *Backup Berhasil!*\n\n"
                f"File backup telah dikirim ke chat ini dan ke owner.\n"
                f"Tanggal: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
            ),
            parse_mode=ParseMode.MARKDOWN
        )
    else:
        await context.bot.send_message(
            chat_id=user_id,
            text=f"❌ Backup gagal!\n\n{result.stderr}"
        )

async def restore_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_owner(user_id):
        await query.edit_message_text("❌ Hanya Owner!")
        return
    
    await query.edit_message_text(
        "♻️ *Restore Backup*\n\n"
        "Kirim file backup (.tar.gz) ke chat ini\n"
        "atau kirim File ID backup dari pesan sebelumnya:\n\n"
        "Format: `/restore FILE_ID`"
    )

async def restore_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    
    if not is_owner(user_id):
        await update.message.reply_text("❌ Hanya Owner!")
        return
    
    if context.args:
        file_id = context.args[0]
        await update.message.reply_text("⏳ Mengambil dan merestore backup...")
        
        result = subprocess.run(
            ['/bin/bash', '/usr/local/bin/udp-zivpn-manage', 'restore', file_id],
            capture_output=True, text=True, timeout=120
        )
        
        if result.returncode == 0:
            await update.message.reply_text("✅ Restore berhasil! Service direstart.")
        else:
            await update.message.reply_text(f"❌ Restore gagal!\n{result.stderr}")
    else:
        await update.message.reply_text("Gunakan: `/restore FILE_ID`", parse_mode=ParseMode.MARKDOWN)

async def handle_document(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle file yang dikirim untuk restore"""
    user_id = update.effective_user.id
    
    if not is_owner(user_id):
        return
    
    doc = update.message.document
    if doc and doc.file_name.endswith('.tar.gz'):
        await update.message.reply_text("⏳ Mengunduh dan merestore backup...")
        
        # Download file
        file = await context.bot.get_file(doc.file_id)
        restore_path = f'/tmp/restore_{int(time.time())}.tar.gz'
        await file.download_to_drive(restore_path)
        
        # Restore
        restore_dir = f'/tmp/restore_extracted_{int(time.time())}'
        os.makedirs(restore_dir)
        
        result = subprocess.run(
            ['tar', '-xzf', restore_path, '-C', restore_dir],
            capture_output=True
        )
        
        if result.returncode == 0:
            backup_subdir = os.listdir(restore_dir)[0]
            
            if os.path.exists(f"{restore_dir}/{backup_subdir}/config.json"):
                import shutil
                shutil.copy(f"{restore_dir}/{backup_subdir}/config.json", '/etc/udp-zivpn/config.json')
                shutil.copy(f"{restore_dir}/{backup_subdir}/users.json", USERS_FILE)
                
                subprocess.run(['systemctl', 'restart', 'udp-zivpn'])
                await update.message.reply_text("✅ Restore dari file berhasil!")
            else:
                await update.message.reply_text("❌ File backup tidak valid!")
        else:
            await update.message.reply_text("❌ Gagal mengekstrak backup!")
        
        # Cleanup
        import shutil
        os.remove(restore_path)
        shutil.rmtree(restore_dir, ignore_errors=True)

# ============================================================
# SPEEDTEST
# ============================================================
async def speedtest_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer("Menjalankan speed test...")
    
    await query.edit_message_text("⚡ *Menjalankan Speed Test...*\n\nMohon tunggu 30-60 detik...", parse_mode=ParseMode.MARKDOWN)
    
    try:
        result = subprocess.run(
            ['python3', '-c', 
             'import speedtest; s=speedtest.Speedtest(); s.get_best_server(); d=s.download()/1_000_000; u=s.upload()/1_000_000; ping=s.results.ping; print(f"Download: {d:.2f} Mbps\\nUpload: {u:.2f} Mbps\\nPing: {ping:.1f} ms")'],
            capture_output=True, text=True, timeout=120
        )
        
        if result.returncode == 0:
            output = result.stdout
        else:
            # Fallback speedtest
            result2 = subprocess.run(
                ['speedtest', '--accept-license', '--accept-gdpr', '--format=json'],
                capture_output=True, text=True, timeout=120
            )
            if result2.returncode == 0:
                data = json.loads(result2.stdout)
                output = (
                    f"Download: {data['download']['bandwidth'] * 8 / 1_000_000:.2f} Mbps\n"
                    f"Upload: {data['upload']['bandwidth'] * 8 / 1_000_000:.2f} Mbps\n"
                    f"Ping: {data['ping']['latency']:.1f} ms\n"
                    f"Server: {data['server']['name']}, {data['server']['location']}"
                )
            else:
                output = "Speedtest gagal dijalankan."
        
        await query.edit_message_text(
            f"⚡ *Hasil Speed Test*\n"
            f"━━━━━━━━━━━━━━━━━━━━━━━\n"
            f"🖥 VPS: `{VPS_NAME}`\n\n"
            f"`{output}`\n\n"
            f"⏰ {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
            parse_mode=ParseMode.MARKDOWN
        )
    except Exception as e:
        await query.edit_message_text(f"❌ Speed test gagal: {str(e)}")

# ============================================================
# SETTINGS
# ============================================================
async def settings_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    if not is_owner(user_id):
        await query.edit_message_text("❌ Hanya Owner!")
        return
    
    settings = load_settings()
    
    text = (
        f"⚙️ *Pengaturan Bot*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━━\n"
        f"💳 QRIS Number: `{settings.get('qris_number', 'Belum diset')}`\n"
        f"👤 Nama QRIS: `{settings.get('qris_name', 'Belum diset')}`\n"
        f"⏱ Timeout Bayar: `{settings.get('payment_timeout', 30)} menit`\n"
        f"🤖 Auto Approve: `{'Ya' if settings.get('auto_approve') else 'Tidak'}`\n"
    )
    
    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("💳 Set QRIS", callback_data="set_qris"),
         InlineKeyboardButton("⏱ Set Timeout", callback_data="set_timeout")],
        [InlineKeyboardButton("🤖 Toggle Auto Approve", callback_data="toggle_auto_approve")],
        [InlineKeyboardButton("💰 Set Harga Paket", callback_data="set_prices")],
        [InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")],
    ])
    
    await query.edit_message_text(text, reply_markup=keyboard, parse_mode=ParseMode.MARKDOWN)

async def set_qris_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    await query.edit_message_text(
        "💳 *Set QRIS*\n\n"
        "Kirim info QRIS dalam format:\n"
        "`NOMOR_QRIS|NAMA_PENERIMA`\n\n"
        "Contoh:\n"
        "`ID.CO.BRI.WWW0118936009280012345|Toko VPN`\n\n"
        "Ketik /batal untuk batal",
        parse_mode=ParseMode.MARKDOWN
    )
    return WAITING_QRIS_INFO

async def receive_qris_info(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = update.message.text.strip()
    
    if text == '/batal':
        await update.message.reply_text("❌ Dibatalkan.")
        return ConversationHandler.END
    
    parts = text.split('|')
    qris_number = parts[0].strip()
    qris_name = parts[1].strip() if len(parts) > 1 else 'UDP ZiVPN'
    
    settings = load_settings()
    settings['qris_number'] = qris_number
    settings['qris_name'] = qris_name
    save_settings(settings)
    
    await update.message.reply_text(
        f"✅ QRIS berhasil diset!\n\n"
        f"Nomor: `{qris_number}`\n"
        f"Nama: `{qris_name}`",
        parse_mode=ParseMode.MARKDOWN
    )
    return ConversationHandler.END

async def toggle_auto_approve(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    settings = load_settings()
    settings['auto_approve'] = not settings.get('auto_approve', False)
    save_settings(settings)
    
    status = "AKTIF" if settings['auto_approve'] else "NONAKTIF"
    await query.answer(f"Auto approve sekarang {status}", show_alert=True)

# ============================================================
# MY ACCOUNTS (untuk buyer)
# ============================================================
async def my_accounts(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = query.from_user.id
    
    orders = load_orders()
    user_orders = [o for o in orders.get('orders', []) if o['user_id'] == user_id and o['status'] == 'paid']
    
    if not user_orders:
        await query.edit_message_text(
            "📋 *Akun Saya*\n\n"
            "Anda belum memiliki akun VPN aktif.\n"
            "Beli paket untuk mendapatkan akun!",
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("🛍 Beli Sekarang", callback_data="shop")],
                [InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")]
            ]),
            parse_mode=ParseMode.MARKDOWN
        )
        return
    
    text = "📋 *Akun VPN Saya*\n━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    
    for order in user_orders[-5:]:
        if order.get('vpn_username'):
            text += f"👤 Username: `{order['vpn_username']}`\n"
            text += f"🔑 Password: `{order['vpn_password']}`\n"
            text += f"🖥 VPS: `{order['vps']}`\n"
            text += f"📦 Paket: `{PACKAGES.get(order['package'], {}).get('label', '')}`\n"
            text += f"🆔 Order: `{order['id']}`\n\n"
    
    await query.edit_message_text(
        text,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("🛍 Beli Lagi", callback_data="shop")],
            [InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")]
        ]),
        parse_mode=ParseMode.MARKDOWN
    )

# ============================================================
# CALLBACK ROUTER
# ============================================================
async def callback_router(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    data = query.data
    
    if data == "main_menu":
        user_id = query.from_user.id
        keyboard = get_main_keyboard(user_id)
        await query.edit_message_text("🏠 *Menu Utama*\nPilih menu:", reply_markup=keyboard, parse_mode=ParseMode.MARKDOWN)
    elif data == "dashboard":
        await dashboard(update, context)
    elif data == "vps_status":
        await vps_status(update, context)
    elif data == "manage_users":
        await manage_users(update, context)
    elif data == "manage_resellers":
        await manage_resellers(update, context)
    elif data == "shop":
        await shop(update, context)
    elif data.startswith("buy_") and not data.startswith("buy_vps_"):
        await buy_package(update, context)
    elif data.startswith("buy_vps_"):
        await buy_select_vps(update, context)
    elif data.startswith("confirm_pay_"):
        await confirm_payment(update, context)
    elif data.startswith("approve_"):
        await approve_payment(update, context)
    elif data.startswith("reject_"):
        await reject_payment(update, context)
    elif data == "backup":
        await backup_handler(update, context)
    elif data == "restore":
        await restore_handler(update, context)
    elif data == "speedtest":
        await speedtest_handler(update, context)
    elif data == "settings":
        await settings_menu(update, context)
    elif data == "set_qris":
        await set_qris_start(update, context)
    elif data == "toggle_auto_approve":
        await toggle_auto_approve(update, context)
    elif data == "my_accounts":
        await my_accounts(update, context)
    elif data == "info":
        await info_handler(update, context)
    elif data == "add_vps":
        await add_vps_start(update, context)
    elif data == "add_reseller":
        await add_reseller_start(update, context)

async def info_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    text = (
        f"ℹ️ *Info UDP ZiVPN*\n"
        f"━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        f"🔐 Protokol: UDP ZiVPN (Hysteria2)\n"
        f"🌐 Multi-Region VPS\n"
        f"⚡ Kecepatan Tinggi\n\n"
        f"📦 *Paket:*\n"
        f"• 15 Hari → Rp 6.000\n"
        f"• 30 Hari → Rp 10.000\n\n"
        f"💳 Pembayaran via QRIS\n"
        f"⚡ Aktivasi otomatis\n\n"
        f"📲 Download app ZiVPN di Play Store"
    )
    
    await query.edit_message_text(
        text,
        reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("🛍 Beli Sekarang", callback_data="shop")],
            [InlineKeyboardButton("◀️ Kembali", callback_data="main_menu")]
        ]),
        parse_mode=ParseMode.MARKDOWN
    )

# ============================================================
# MAIN
# ============================================================
def main():
    if not BOT_TOKEN:
        logger.error("BOT_TOKEN tidak ditemukan!")
        sys.exit(1)
    
    app = Application.builder().token(BOT_TOKEN).build()
    
    # Conversation handler untuk buat user manual
    create_user_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(create_user_manual_start, pattern="^create_user_manual$")],
        states={
            WAITING_VPS_ADD: [CallbackQueryHandler(select_vps_for_user, pattern="^sel_vps_")],
            WAITING_USERNAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_username)],
            WAITING_PASSWORD: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_password)],
            WAITING_DURATION: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_duration)],
        },
        fallbacks=[CommandHandler("batal", lambda u, c: ConversationHandler.END)],
    )
    
    # Conversation handler untuk tambah reseller
    add_reseller_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(add_reseller_start, pattern="^add_reseller$")],
        states={
            WAITING_RESELLER_ADD: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_reseller_id)],
        },
        fallbacks=[CommandHandler("batal", lambda u, c: ConversationHandler.END)],
    )
    
    # Conversation handler untuk tambah VPS
    add_vps_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(add_vps_start, pattern="^add_vps$")],
        states={
            WAITING_VPS_ADD: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_vps_info)],
        },
        fallbacks=[CommandHandler("batal", lambda u, c: ConversationHandler.END)],
    )
    
    # Conversation handler untuk set QRIS
    set_qris_conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(set_qris_start, pattern="^set_qris$")],
        states={
            WAITING_QRIS_INFO: [MessageHandler(filters.TEXT & ~filters.COMMAND, receive_qris_info)],
        },
        fallbacks=[CommandHandler("batal", lambda u, c: ConversationHandler.END)],
    )
    
    # Register handlers
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("restore", restore_command))
    app.add_handler(create_user_conv)
    app.add_handler(add_reseller_conv)
    app.add_handler(add_vps_conv)
    app.add_handler(set_qris_conv)
    app.add_handler(CallbackQueryHandler(callback_router))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_document))
    
    # Set bot commands
    async def post_init(application):
        await application.bot.set_my_commands([
            BotCommand("start", "Menu Utama"),
            BotCommand("restore", "Restore backup (owner only)"),
        ])
    
    app.post_init = post_init
    
    logger.info(f"Bot UDP ZiVPN dimulai - VPS: {VPS_NAME}")
    app.run_polling(drop_pending_updates=True)

if __name__ == '__main__':
    main()
