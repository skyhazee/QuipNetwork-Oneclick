# Quip Network One-Click Installer

One-click installer interaktif untuk menjalankan Quip Network node di VPS Linux memakai Docker Compose deployment resmi Quip.

Repo resmi Quip yang dipakai installer:

https://gitlab.com/quip.network/nodes.quip.network

## 1. Buat Akun, Quest, Dan Wallet

Sebelum install node, kerjakan ini dulu.

### Quest / Airdrop

Buka:

https://quest.quip.network/airdrop?referral_code=SKYHAZE

Buat akun atau login, lalu selesaikan quest untuk mengumpulkan poin.

### Wallet / Account Quip

Buka:

https://account.quip.network/?ref=0x52decdff72fa150be1d36b7e63aa32daaf1b0356

Buat wallet atau connect wallet kamu.

Penting: akun quest dan account Quip harus pakai **wallet yang sama**.

## 2. Siapkan Domain

Disarankan pakai subdomain khusus, contoh:

```text
quip.example.com
```

Buat DNS record:

```text
Type  : A
Name  : quip
Value : IP_VPS_KAMU
TTL   : Auto
```

Tunggu sampai DNS resolve ke IP VPS.

## 3. Install Node

Login ke VPS sebagai root atau user sudo, lalu jalankan:

```bash
curl -fsSL -o quip-install.sh https://raw.githubusercontent.com/skyhazee/QuipNetwork-Oneclick/main/install.sh
sudo bash quip-install.sh
```

Ikuti menu interaktifnya.

Rekomendasi jawaban untuk VPS biasa:

```text
Mode node: CPU
Profile: Full node + dashboard + Caddy/TLS
Username node: username kamu
Wallet address: wallet kamu
Port P2P: 20049
Domain: quip.example.com
Email Let's Encrypt: email aktif kamu
Node secret: kosongkan saja
POSTGRES_PASSWORD: kosongkan saja
Kernel tuning: Y
Buka port otomatis dengan ufw: Y
Cron auto-update: Y
PM2 watchdog: N
Screen logs helper: Y
```

## Format Nama Node

Nama node harus memakai format:

```text
username - wallet
```

Perhatikan spasinya:

```text
username[spasi]-[spasi]0xWalletAddress
```

Contoh:

```text
myusername - 0x1234567890abcdef1234567890abcdef12345678
```

Installer akan menanyakan `Username node` dan `Wallet address`, lalu otomatis membuat `node_name` dengan format tersebut.

Kalau node sudah terlanjur terinstall, edit manual:

```bash
cd /opt/quip-node
nano data/config.toml
```

Cari:

```toml
node_name = "nama-lama"
```

Ubah menjadi:

```toml
node_name = "username - 0xWalletAddress"
```

Restart:

```bash
cd /opt/quip-node
docker compose restart cpu
```

## Port

Installer bisa membuka port otomatis dengan `ufw`. Saat ditanya:

```text
Auto buka port dengan ufw? [Y/n]
```

Jawab `Y` atau langsung tekan Enter.

Port yang dibuka:

```text
20049/tcp
20049/udp
80/tcp
443/tcp
```

Kalau VPS provider kamu punya firewall/security group tambahan, buka port yang sama di panel provider.

## Credential Yang Dibutuhkan

Untuk mode CPU biasa:

- Domain: perlu untuk dashboard HTTPS.
- Email Let's Encrypt: perlu untuk SSL otomatis.
- Node secret: boleh dikosongkan, installer akan generate otomatis.
- POSTGRES_PASSWORD: boleh dikosongkan.

Tidak perlu:

- Private key wallet.
- DWAVE_API_KEY, kecuali kamu pilih mode QPU/D-Wave.

Backup file ini setelah install:

```text
/opt/quip-node/data/config.toml
/opt/quip-node/.env
```

## Dashboard

Kalau pakai domain:

```text
https://quip.example.com
```

Kalau pilih no TLS:

```text
http://IP_VPS:20080
```

## Cek Node

Semua command Docker Compose harus dijalankan dari folder install:

```bash
cd /opt/quip-node
```

Cek container:

```bash
docker compose ps
```

Lihat logs:

```bash
docker compose logs --tail=200 -f
```

Command logs dengan `-f` adalah realtime/follow mode. Kalau tidak ada log baru, layar bisa diam. Keluar dengan:

```text
Ctrl+C
```

Kalau hanya mau lihat log terakhir tanpa follow:

```bash
docker compose logs --tail=200
```

Kalau kamu aktifkan screen helper:

```bash
quip-logs
```

Detach dari screen:

```text
Ctrl+A lalu D
```

Attach lagi:

```bash
quip-logs-attach
```

## Auto Update

Kalau kamu jawab `Y` di cron auto-update, installer akan pasang update otomatis per jam.

Cek log update:

```bash
cd /opt/quip-node
tail -f data/update.log
```

Run update manual:

```bash
cd /opt/quip-node
bash ./cron.sh
```

## Restart / Stop

Restart node CPU:

```bash
cd /opt/quip-node
docker compose restart cpu
```

Stop node:

```bash
cd /opt/quip-node
docker compose --profile cpu down
```

## Troubleshooting Singkat

Kalau dashboard HTTPS belum bisa dibuka:

- Pastikan DNS sudah mengarah ke IP VPS.
- Pastikan port `80/tcp` dan `443/tcp` terbuka.
- Cek logs Caddy:

```bash
cd /opt/quip-node
docker compose logs -f caddy
```

Kalau node susah peer:

- Pastikan port `20049/tcp` dan `20049/udp` terbuka.
- Pastikan `public_host` di `/opt/quip-node/data/config.toml` benar.

## Disclaimer

Installer ini hanya wrapper untuk mempermudah setup. Runtime node tetap memakai deployment resmi Quip Network.
