#!/bin/bash

# ====================================================================
# Skrip Auto Instalasi V2Ray (Xray-core) dengan Protokol Trojan WS + TLS
# Dibuat untuk VPS Ubuntu/Debian
# Pengembang: Gemini (Google)
# ====================================================================

# --- Variabel Konfigurasi ---
# NAMA DOMAIN UTAMA SERVER ANDA (untuk Sertifikat SSL/TLS dan SNI)
DOMAIN="mp3.whykho.web.id"
# ALAMAT EMAIL VALID ANDA UNTUK SERTIFIKAT SSL LET'S ENCRYPT
EMAIL="mentasproject@gmail.com"
# PORT INTERNAL XRAY (Jangan gunakan 80 atau 443)
XRAY_PORT=44433 # Port internal Xray untuk mendengarkan koneksi WS
# Path WebSocket untuk Trojan
WS_PATH="/trojanws"

# ALAMAT YANG AKAN DIMASUKKAN KLIEN (bisa berbeda jika menggunakan CDN/Reverse Proxy)
CLIENT_CONNECT_ADDRESS="vidio.whykho.web.id"

# Lokasi file konfigurasi Xray
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"
# Lokasi file untuk menyimpan nama akun dan UUID
TROJAN_USERS_FILE="/etc/xray/trojan_users.json"

# --- Fungsi Pembantu ---
print_status() {
    echo -e "\n\033[1;32m[STATUS]\033[0m $1"
}

print_error() {
    echo -e "\n\033[1;31m[ERROR]\033[0m $1" >&2
}

check_jq_installed() {
    if ! command -v jq &> /dev/null
    then
        print_status "jq tidak ditemukan. Menginstal jq..."
        apt install -y jq || { print_error "Gagal menginstal jq."; return 1; }
    fi
    return 0
}

# --- Fungsi Instalasi & Konfigurasi Awal ---
install_initial_setup() {
    print_status "Memulai instalasi awal..."

    # 1. Perbarui Sistem dan Instal Dependensi
    print_status "Memperbarui paket sistem..."
    apt update -y && apt upgrade -y || { print_error "Gagal memperbarui sistem."; return 1; }

    print_status "Menginstal dependensi yang diperlukan (curl, socat, nginx, certbot, python3-certbot-nginx, jq)..."
    apt install -y curl socat nginx certbot python3-certbot-nginx jq || { print_error "Gagal menginstal dependensi."; return 1; }

    # Pastikan direktori untuk TROJAN_USERS_FILE ada
    print_status "Memastikan direktori $(dirname "$TROJAN_USERS_FILE") ada..."
    mkdir -p "$(dirname "$TROJAN_USERS_FILE")" || { print_error "Gagal membuat direktori $(dirname "$TROJAN_USERS_FILE")."; return 1; }

    # Inisialisasi file trojan_users.json jika belum ada
    if [ ! -f "$TROJAN_USERS_FILE" ]; then
        print_status "Menginisialisasi $TROJAN_USERS_FILE..."
        echo "[]" > "$TROJAN_USERS_FILE" || { print_error "Gagal membuat $TROJAN_USERS_FILE."; return 1; }
    fi

    # 2. Konfigurasi Firewall (UFW)
    print_status "Mengkonfigurasi Firewall (UFW)..."
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP (for Certbot validation)'
    ufw allow 443/tcp comment 'HTTPS (for Trojan/TLS)'
    ufw enable -y || { print_error "Gagal mengaktifkan UFW. Pastikan tidak ada masalah konektivitas."; }
    ufw status verbose

    # 3. Instal Xray-core (V2Ray Fork)
    print_status "Menginstal Xray-core..."
    bash -c "$(curl -L https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" || { print_error "Gagal menginstal Xray-core."; return 1; }

    # 4. Dapatkan Sertifikat Let's Encrypt
    print_status "Mendapatkan sertifikat SSL dari Let's Encrypt untuk $DOMAIN..."
    systemctl stop nginx # Hentikan Nginx sementara untuk Certbot stand-alone
    certbot certonly --standalone --agree-tos --no-eff-email --email "$EMAIL" -d "$DOMAIN" || { print_error "Gagal mendapatkan sertifikat SSL. Pastikan domain '$DOMAIN' sudah mengarah ke IP ini dan email valid."; return 1; }
    systemctl start nginx # Mulai kembali Nginx

    # 5. Konfigurasi Xray-core untuk Trojan WS+TLS ---
    print_status "Mengkonfigurasi Xray-core untuk protokol Trojan WS+TLS..."

    # Buat UUID baru untuk user default
    DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)
    DEFAULT_USERNAME="default-user"

    cat > "$XRAY_CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "$DEFAULT_UUID"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
            }
          ]
        },
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

    # Tambahkan user default ke file trojan_users.json
    jq --arg name "$DEFAULT_USERNAME" --arg uuid "$DEFAULT_UUID" \
        '. += [{"name": $name, "uuid": $uuid}]' "$TROJAN_USERS_FILE" > temp_users.json && \
        mv temp_users.json "$TROJAN_USERS_FILE" || { print_error "Gagal menambahkan user default ke $TROJAN_USERS_FILE."; return 1; }

    # Restart Xray service
    print_status "Memulai ulang layanan Xray..."
    systemctl enable xray && systemctl restart xray || { print_error "Gagal memulai ulang layanan Xray."; return 1; }
    systemctl status xray --no-pager

    # 6. Konfigurasi Nginx sebagai Reverse Proxy untuk WS+TLS ---
    print_status "Mengkonfigurasi Nginx sebagai reverse proxy untuk WS+TLS..."

    cat > /etc/nginx/conf.d/v2ray.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:DHE+CHACHA20;
    ssl_prefer_server_ciphers on;
    ssl_stapling on;
    ssl_stapling_verify on;

    # Serve a default web page for the root path
    root /var/www/html;
    index index.html index.htm;
    try_files \$uri \$uri/ =404; # Serve existing files or 404

    # Proxy WebSocket traffic to Xray
    location $WS_PATH { # Ini adalah path untuk WebSocket Trojan
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$XRAY_PORT; # Proxy ke port internal Xray
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade; # Diperlukan untuk WebSockets
        proxy_set_header Connection "upgrade";   # Diperlukan untuk WebSockets
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s; # Optional: Untuk koneksi yang lebih lama
        proxy_send_timeout 300s; # Optional: Untuk koneksi yang lebih lama
    }
}
EOF
    # Test Nginx configuration and reload
    print_status "Memeriksa konfigurasi Nginx dan memuat ulang..."
    nginx -t && systemctl reload nginx || { print_error "Gagal mengkonfigurasi Nginx. Periksa file /etc/nginx/conf.d/v2ray.conf"; return 1; }

    # Informasi Akun Default
    print_status "Instalasi V2Ray Trojan Anda telah selesai!"
    echo "==================================================="
    echo "           DETAIL AKUN TROJAN DEFAULT"
    echo "==================================================="
    echo "  Nama Akun: $DEFAULT_USERNAME"
    echo "  Protokol: Trojan"
    echo "  Alamat:   $CLIENT_CONNECT_ADDRESS" # Menggunakan CLIENT_CONNECT_ADDRESS
    echo "  Port:     443"
    echo "  Password: $DEFAULT_UUID"
    echo "  Jaringan: ws (WebSocket)"
    echo "  Path WS:  $WS_PATH"
    echo "  TLS:      True"
    echo "  SNI:      $DOMAIN" # Tetap DOMAIN untuk SNI
    echo "  Host WS Header: $DOMAIN" # Tetap DOMAIN untuk Host Header
    echo "  Allow Insecure: False (Rekomendasi: Jangan centang jika domain benar)"
    echo "---------------------------------------------------"
    echo "Detail ini juga bisa Anda gunakan untuk menguji koneksi."
    echo "==================================================="
    return 0
}

# --- Fungsi untuk Menambah User Baru ---
add_trojan_user() {
    print_status "Memulai proses penambahan akun Trojan baru..."
    if ! check_jq_installed; then return 1; fi

    if [ ! -f "$XRAY_CONFIG_FILE" ]; then
        print_error "File konfigurasi Xray tidak ditemukan: $XRAY_CONFIG_FILE. Harap lakukan instalasi awal terlebih dahulu."
        return 1
    fi
    if [ ! -f "$TROJAN_USERS_FILE" ]; then
        print_error "File daftar user tidak ditemukan: $TROJAN_USERS_FILE. Harap lakukan instalasi awal terlebih dahulu."
        return 1
    fi

    read -p "Masukkan nama akun baru (misal: user-ani): " NEW_USERNAME
    if [ -z "$NEW_USERNAME" ]; then
        print_error "Nama akun tidak boleh kosong. Pembatalan."
        return 1
    fi

    # Cek apakah nama akun sudah ada
    if jq -e --arg name "$NEW_USERNAME" 'map(select(.name == $name)) | length > 0' "$TROJAN_USERS_FILE" > /dev/null; then
        print_error "Nama akun '$NEW_USERNAME' sudah ada. Harap gunakan nama lain."
        return 1
    fi

    NEW_PASSWORD=$(cat /proc/sys/kernel/random/uuid)
    print_status "Menambahkan client baru ke konfigurasi Xray dan daftar user..."

    # Tambahkan ke Xray config
    jq --arg pass "$NEW_PASSWORD" '.inbounds[0].settings.clients += [{"password": $pass}]' "$XRAY_CONFIG_FILE" > temp_config.json && \
    mv temp_config.json "$XRAY_CONFIG_FILE" || { print_error "Gagal menambahkan user ke konfigurasi Xray."; return 1; }

    # Tambahkan ke trojan_users.json
    jq --arg name "$NEW_USERNAME" --arg uuid "$NEW_PASSWORD" \
        '. += [{"name": $name, "uuid": $uuid}]' "$TROJAN_USERS_FILE" > temp_users.json && \
        mv temp_users.json "$TROJAN_USERS_FILE" || { print_error "Gagal menambahkan user ke $TROJAN_USERS_FILE."; return 1; }


    systemctl restart xray || { print_error "Gagal me-restart Xray setelah menambahkan user."; return 1; }
    systemctl status xray --no-pager

    echo "==================================================="
    echo "           DETAIL AKUN TROJAN BARU"
    echo "==================================================="
    echo "  Nama Akun: $NEW_USERNAME"
    echo "  Protokol: Trojan"
    echo "  Alamat:   $CLIENT_CONNECT_ADDRESS" # Menggunakan CLIENT_CONNECT_ADDRESS
    echo "  Port:     443"
    echo "  Password: $NEW_PASSWORD"
    echo "  Jaringan: ws (WebSocket)"
    echo "  Path WS:  $WS_PATH"
    echo "  TLS:      True"
    echo "  SNI:      $DOMAIN" # Tetap DOMAIN untuk SNI
    echo "  Host WS Header: $DOMAIN" # Tetap DOMAIN untuk Host Header
    echo "  Allow Insecure: False"
    echo "---------------------------------------------------"
    echo "Gunakan detail ini untuk mengkonfigurasi klien Anda."
    echo "==================================================="
    return 0
}

# --- Fungsi untuk Melihat Daftar User ---
list_trojan_users() {
    print_status "Menampilkan daftar akun Trojan yang ada..."
    if ! check_jq_installed; then return 1; fi

    if [ ! -f "$TROJAN_USERS_FILE" ] || [ "$(cat "$TROJAN_USERS_FILE")" == "[]" ]; then
        print_status "Tidak ada akun Trojan bernama yang ditemukan. Menampilkan UUID dari konfigurasi Xray utama."
        if [ ! -f "$XRAY_CONFIG_FILE" ]; then
            print_error "File konfigurasi Xray tidak ditemukan: $XRAY_CONFIG_FILE."
            return 1
        fi
        echo "==================================================="
        echo "         DAFTAR UUID TROJAN AKTIF"
        echo "       (Tidak ada nama akun tersimpan)"
        echo "==================================================="
        jq -r '.inbounds[0].settings.clients[].password' "$XRAY_CONFIG_FILE" || { print_error "Gagal membaca daftar user dari konfigurasi Xray."; return 1; }
        echo "==================================================="
        echo "Ini adalah daftar 'password' (UUID) yang sedang aktif."
        echo "Anda dapat menggunakan salah satu dari ini untuk koneksi."
        echo "==================================================="
    else
        echo "==================================================="
        echo "         DAFTAR AKUN TROJAN AKTIF"
        echo "==================================================="
        jq -r '.[] | "Nama Akun: \(.name)\nUUID: \(.uuid)\n-------------------"' "$TROJAN_USERS_FILE" || { print_error "Gagal membaca daftar user dari $TROJAN_USERS_FILE."; return 1; }
        echo "==================================================="
        echo "Ini adalah daftar akun Trojan Anda dengan nama dan UUID."
        echo "==================================================="
    fi
    return 0
}

# --- Fungsi untuk Cek Status Sertifikat ---
show_cert_info() {
    print_status "Memeriksa status sertifikat Let's Encrypt..."

    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        print_error "Sertifikat untuk $DOMAIN tidak ditemukan. Harap pastikan instalasi awal berhasil."
        return 1
    fi

    echo "==================================================="
    echo "         STATUS SERTIFIKAT SSL/TLS"
    echo "==================================================="
    certbot certificates -d "$DOMAIN"
    echo "---------------------------------------------------"
    echo "PENTING: Sertifikat Let's Encrypt secara otomatis diperpanjang oleh Certbot."
    echo "Proses perpanjangan biasanya terjadi di latar belakang sebelum masa berlaku habis."
    echo "Anda dapat menguji proses perpanjangan manual dengan: \033[1;33msudo certbot renew --dry-run\033[0m"
    echo "Jika ada masalah dengan 'perpanjangan akun', biasanya berarti Anda perlu membuat akun Trojan baru (UUID baru)."
    echo "Skrip ini tidak mengelola 'masa berlaku' untuk setiap UUID secara individual."
    echo "==================================================="
    return 0
}

# --- Fungsi Tampilan Menu ---
show_menu() {
    echo -e "\n==================================================="
    echo "           PENGELOLA V2RAY TROJAN (XRAY)"
    echo "==================================================="
    echo "1. Instalasi & Konfigurasi Awal (Jalankan sekali)"
    echo "2. Tambah Akun Trojan Baru"
    echo "3. Lihat Daftar Akun Trojan Aktif"
    echo "4. Periksa Status Sertifikat & Info Perpanjangan"
    echo "5. Keluar"
    echo "==================================================="
    read -p "Pilih opsi [1-5]: " OPTION
}

# --- Logika Utama Skrip ---
# Jika ada argumen, coba jalankan fungsi terkait
if [ "$1" == "install" ]; then
    install_initial_setup
elif [ "$1" == "adduser" ]; then
    add_trojan_user
elif [ "$1" == "listusers" ]; then
    list_trojan_users
elif [ "$1" == "certinfo" ]; then
    show_cert_info
else
    # Jika tidak ada argumen atau argumen tidak valid, tampilkan menu
    while true; do
        show_menu
        case $OPTION in
            1)
                install_initial_setup
                ;;
            2)
                add_trojan_user
                ;;
            3)
                list_trojan_users
                ;;
            4)
                show_cert_info
                ;;
            5)
                print_status "Terima kasih, sampai jumpa!"
                exit 0
                ;;
            *)
                print_error "Opsi tidak valid. Silakan coba lagi."
                ;;
        esac
        echo -e "\nTekan ENTER untuk kembali ke menu..."
        read -s
    done
fi
