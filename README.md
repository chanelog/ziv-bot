# UDP ZiVPN - Panduan Lengkap

## 📁 Struktur File

```
udp-zivpn/
├── install.sh      → Script instalasi utama (jalankan ini pertama)
├── tunnel.sh       → Management tunnel via CLI
├── bot.py          → Telegram bot (auto-sales + management)
└── README.md       → Panduan ini
```

---

## 🚀 Cara Instalasi

### 1. Upload ke VPS
```bash
# Upload semua file ke VPS
scp -r udp-zivpn/ root@IP_VPS:/root/

# Atau clone jika ada di git
# git clone ... && cd udp-zivpn
```

### 2. Jalankan Installer
```bash
cd /root/udp-zivpn
chmod +x install.sh tunnel.sh bot.py
bash install.sh
```

Installer akan meminta:
- **UDP Port** (default: 36712)
- **Password Obfuscation** (default: zivpn2024)  
- **Bandwidth limit** (up/down dalam Mbps)
- **Telegram Bot Token** (dari @BotFather)
- **Telegram Owner ID** (dari @userinfobot)
- **Nama VPS** (contoh: VPS-ID-1, VPS-SG-1)

---

## 🤖 Cara Mendapatkan Bot Token & Owner ID

### Bot Token:
1. Buka Telegram, cari **@BotFather**
2. Kirim `/newbot`
3. Ikuti instruksi, copy token yang diberikan

### Owner ID:
1. Buka Telegram, cari **@userinfobot**
2. Kirim `/start`
3. Copy angka "Id:" yang muncul

---

## 📱 Fitur Telegram Bot

### 👑 Owner (ID Telegram pemilik)
| Fitur | Keterangan |
|-------|-----------|
| Dashboard | Statistik user, order, VPS |
| VPS Status | Status semua region VPS |
| Kelola User | Lihat, hapus, perpanjang user |
| Kelola Reseller | Tambah/hapus reseller |
| Buat User Manual | Gratis, tanpa bayar |
| Tambah VPS Region | Multi-VPS unlimited |
| Backup | Backup & kirim file ke Telegram |
| Restore | Restore dari file Telegram |
| Speed Test | Ookla speedtest |
| Pengaturan | Set QRIS, harga, auto-approve |

### 💼 Reseller (ditambahkan oleh Owner)
| Fitur | Keterangan |
|-------|-----------|
| Dashboard | Statistik user miliknya |
| Kelola User | User yang dia buat |
| Buat User Manual | Gratis, tanpa bayar |
| Speed Test | Test kecepatan server |

### 👤 Member/Buyer (umum)
| Fitur | Keterangan |
|-------|-----------|
| Toko | Pilih paket & region |
| Pembayaran QRIS | QR Code otomatis |
| Akun Saya | Lihat akun aktif |
| Info | Info layanan |

---

## 💳 Setup Pembayaran QRIS

1. Buka bot Telegram sebagai Owner
2. Menu → **⚙️ Pengaturan** → **💳 Set QRIS**
3. Kirim dalam format:
   ```
   NOMOR_QRIS|NAMA_TOKO
   ```
   Contoh:
   ```
   ID.CO.BRI.WWW011893600928001|Toko VPN Saya
   ```

---

## 💰 Paket & Harga

| Paket | Durasi | Harga |
|-------|--------|-------|
| Paket Hemat | 15 Hari | Rp 6.000 |
| Paket Bulanan | 30 Hari | Rp 10.000 |

Harga dapat diubah di `bot.py` pada bagian `PACKAGES`.

---

## 🖥 Multi-VPS / Multi-Region

### Cara Menambah VPS Baru:
1. **Install dulu** UDP ZiVPN di VPS baru dengan `install.sh`
2. **Buka bot Telegram** sebagai Owner
3. Menu → **🖥 VPS Status** → **➕ Tambah VPS**
4. Kirim dalam format:
   ```
   NAMA_VPS|IP_VPS|PORT_SSH|PATH_SSH_KEY
   ```
   Contoh:
   ```
   VPS-SG-1|192.168.1.100|22|/root/.ssh/id_rsa
   ```

### Setup SSH Key (agar bot bisa kontrol VPS remote):
```bash
# Di VPS utama (yang ada botnya):
ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""

# Copy ke VPS remote:
ssh-copy-id -i /root/.ssh/id_rsa.pub root@IP_VPS_REMOTE

# Test koneksi:
ssh -i /root/.ssh/id_rsa root@IP_VPS_REMOTE 'systemctl status udp-zivpn'
```

> ✅ Unlimited VPS bisa ditambahkan, semua dikontrol dari 1 bot Telegram!

---

## 💾 Backup & Restore

### Backup Manual (via Telegram bot):
- Menu → **💾 Backup** → File dikirim otomatis ke chat bot

### Backup Manual (via CLI):
```bash
vpnmanage backup
```

### Restore dari Telegram:
1. Cari pesan backup di bot
2. **Forward** file ke bot
3. Bot auto-restore, atau:
   ```
   /restore FILE_ID_TELEGRAM
   ```

### Backup Otomatis:
Cron job berjalan setiap hari jam 03:00, backup dikirim ke Owner.

---

## ⚡ Speed Test

### Via Telegram Bot:
- Menu → **⚡ Speed Test**

### Via CLI:
```bash
vpnmanage speedtest
```

Menggunakan Ookla Speedtest official. Fallback ke speedtest-cli jika tidak tersedia.

---

## 🔧 Perintah CLI

```bash
# Buka menu interaktif
tunnel
# atau
vpnmanage

# Perintah langsung:
vpnmanage start           # Start tunnel
vpnmanage stop            # Stop tunnel
vpnmanage restart         # Restart tunnel
vpnmanage status          # Lihat status
vpnmanage add_user        # Tambah user
vpnmanage del_user USER   # Hapus user
vpnmanage renew_user USER HARI  # Perpanjang user
vpnmanage list_users      # Daftar user
vpnmanage backup          # Backup + kirim Telegram
vpnmanage speedtest       # Speed test Ookla
vpnmanage check_expired   # Cek & nonaktifkan expired user
```

---

## 📂 Lokasi File Penting

| File | Lokasi |
|------|--------|
| Binary ZiVPN | `/usr/local/bin/udp-zivpn` |
| Config tunnel | `/etc/udp-zivpn/config.json` |
| Data users | `/var/lib/udp-zivpn/users.json` |
| Data resellers | `/var/lib/udp-zivpn/resellers.json` |
| Data orders | `/var/lib/udp-zivpn/orders.json` |
| Pengaturan bot | `/var/lib/udp-zivpn/settings.json` |
| Bot script | `/var/lib/udp-zivpn/bot.py` |
| Bot config | `/var/lib/udp-zivpn/bot.conf` |
| Log tunnel | `/var/log/udp-zivpn/tunnel.log` |
| Log bot | `/var/log/udp-zivpn/bot.log` |

---

## 🔄 Manage Services

```bash
# Tunnel service
systemctl status udp-zivpn
systemctl start udp-zivpn
systemctl stop udp-zivpn
systemctl restart udp-zivpn

# Bot service
systemctl status udp-zivpn-bot
systemctl start udp-zivpn-bot
systemctl stop udp-zivpn-bot
systemctl restart udp-zivpn-bot

# Lihat log real-time
journalctl -u udp-zivpn -f
journalctl -u udp-zivpn-bot -f
tail -f /var/log/udp-zivpn/bot.log
```

---

## ⚙️ Konfigurasi ZiVPN Client

Setelah akun dibuat, buyer mengisi di app ZiVPN:
- **Server**: IP VPS
- **Port**: (sesuai konfigurasi, default 36712)
- **Username**: username yang diberikan
- **Password**: password yang diberikan
- **Obfs**: salamander
- **Obfs Password**: (sesuai konfigurasi)

---

## 📋 Alur Pembelian

```
Buyer → /start → 🛍 Beli Akun VPN
  → Pilih Paket (15/30 hari)
  → Pilih Region VPS
  → QR Code QRIS muncul
  → Buyer scan & bayar
  → Klik "Konfirmasi Pembayaran"
  → Notifikasi masuk ke Owner/Admin
  → Owner klik APPROVE
  → Akun otomatis dibuat
  → Info akun dikirim ke buyer ✅
```

---

## 🔒 Keamanan

- Config dan bot.conf hanya readable oleh root (chmod 600)
- Semua user/pass tersimpan di local JSON (tidak ke internet)
- QRIS number tersimpan lokal di server
- Backup dienkripsi dengan tar.gz (bisa ditambah gpg untuk extra security)

---

## ❓ Troubleshooting

**Bot tidak merespons:**
```bash
systemctl restart udp-zivpn-bot
journalctl -u udp-zivpn-bot -n 50
```

**Tunnel tidak bisa connect:**
```bash
systemctl restart udp-zivpn
journalctl -u udp-zivpn -n 50
netstat -tulpn | grep UDP_PORT
```

**User tidak bisa login setelah dibuat:**
```bash
# Cek config auth sudah terupdate
cat /etc/udp-zivpn/config.json | jq '.auth.userpass'
systemctl restart udp-zivpn
```
