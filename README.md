# Quip Network One-Click Installer

Installer interaktif untuk menjalankan atau meng-upgrade Quip Network node di VPS Debian/Ubuntu memakai Docker Compose deployment resmi Quip.

Repo resmi yang dipakai installer:

https://gitlab.com/quip.network/nodes.quip.network

Installer saat ini mengikuti branch upstream `v0.2`. Versi ini mengganti node mesh lama dengan miner dan validator Substrate lokal.

## Perubahan Penting v0.2

- `quip-node` lama berubah menjadi `quip-miner`.
- Setiap node menjalankan validator lokal.
- Miner baru otomatis membuat keystore, register ke chain, dan meminta dana testnet dari faucet.
- Port API/dashboard tetap memakai `20049/tcp`.
- Port validator baru memakai `30333/tcp` dan `30333/udp`.
- Secret node v0.1 tidak dipakai lagi. Signer baru disimpan sebagai keystore.
- QPU tetap didukung, tetapi berjalan di profile Compose `cpu` dengan konfigurasi D-Wave tambahan.

## Upgrade Dari Installer Lama

Kalau sebelumnya sudah install memakai repo ini, cukup download installer terbaru dan jalankan ulang:

```bash
curl -fsSL -o quip-install.sh https://raw.githubusercontent.com/skyhazee/QuipNetwork-Oneclick/main/install.sh
sudo bash quip-install.sh
```

Pakai folder install lama saat ditanya. Default:

```text
/opt/quip-node
```

Installer akan otomatis:

- Mendeteksi config v0.1 dan mode lama: CPU, CUDA, atau QPU.
- Memakai nama node, domain, email TLS, dan `DWAVE_API_KEY` lama sebagai default jika tersedia.
- Mempertahankan `public_host` atau IP lama di config hasil migrasi jika sebelumnya ada.
- Menghentikan dan menghapus container v0.1 sebelum migrasi.
- Memindahkan deployment resmi ke branch upstream `v0.2`.
- Menjalankan converter resmi untuk `data/config.toml` dan `.env`.
- Menyimpan backup data lama.
- Mengubah format domain Caddy untuk HTTPS v0.2.
- Menulis env dashboard resmi dan env kompatibilitas untuk image v0.2 yang masih dalam masa transisi.
- Membuka port firewall baru dan menghapus rule UDP `20049` lama.
- Menjalankan miner, validator, dashboard, Postgres, Caddy, dan bootstrap otomatis.

Backup hasil migrasi:

```text
/opt/quip-node/data/.v0.1_backup/
/opt/quip-node/.env.v0.1_backup
```

Secret lama tetap tersimpan di backup config. v0.2 tidak menggunakannya lagi karena signer memakai:

```text
/opt/quip-node/data/keystore.json
```

Jangan hapus folder backup sebelum node v0.2 berjalan normal.

## Fresh Install

### 1. Buat Akun, Quest, Dan Wallet

Quest / airdrop:

https://quest.quip.network/airdrop?referral_code=SKYHAZE

Account Quip:

https://account.quip.network/?ref=0x52decdff72fa150be1d36b7e63aa32daaf1b0356

Gunakan wallet yang sama untuk akun quest dan account Quip.

### 2. Siapkan Domain

Domain disarankan agar dashboard memakai HTTPS. Buat subdomain khusus, contoh:

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

### 3. Jalankan Installer

```bash
curl -fsSL -o quip-install.sh https://raw.githubusercontent.com/skyhazee/QuipNetwork-Oneclick/main/install.sh
sudo bash quip-install.sh
```

Rekomendasi jawaban untuk VPS CPU biasa:

```text
Folder install: /opt/quip-node
Varian miner: CPU
Nama node untuk dashboard: username-kamu
Gunakan domain + HTTPS otomatis: Y
Domain dashboard: quip.example.com
Email Let's Encrypt: email aktif kamu
Kernel tuning: Y
Update firewall ufw otomatis: Y
Cron auto-update: Y
Screen logs helper: Y
```

Wallet dan secret tidak perlu dimasukkan ke installer v0.2. Keystore signer dibuat otomatis saat bootstrap pertama.

## Mode Miner

Pilihan yang tersedia:

```text
1) CPU mining
2) CUDA GPU mining
3) QPU D-Wave
```

CUDA membutuhkan NVIDIA GPU dan driver yang sesuai.

QPU membutuhkan:

```text
DWAVE_API_KEY
```

QPU memakai profile Compose `cpu`, lalu miner membaca section `[qpu]` dan `[dwave]` dari config.

## Dashboard

Dengan domain dan HTTPS:

```text
https://quip.example.com/
```

Tanpa domain:

```text
http://IP_VPS:20049/
```

Untuk HTTPS, installer menyimpan format Caddy v0.2 berikut di `.env`:

```text
QUIP_HOSTNAME=quip.example.com, quip.example.com:20049
```

## Firewall

Installer dapat memperbarui `ufw` otomatis. Port Quip v0.2:

```text
20049/tcp       Caddy, dashboard, API, dan RPC publik
30333/tcp       Validator libp2p
30333/udp       Validator libp2p
80/tcp          Let's Encrypt HTTP-01
443/tcp         Dashboard HTTPS
```

Rule lama berikut akan dihapus karena tidak dipakai v0.2:

```text
20049/udp
```

Kalau provider VPS punya firewall atau security group tambahan, buka port yang sama dari panel provider.

Cek port publik dari VPS:

```bash
curl -sS https://check.quip.network/checkport?port=20049
curl -sS https://check.quip.network/checkport?port=30333
curl -sS https://check.quip.network/checkport?port=80
curl -sS https://check.quip.network/checkport?port=443
```

Port `80` dan `443` hanya diperlukan jika memakai domain + HTTPS.

## Cek Node

Masuk ke folder deployment:

```bash
cd /opt/quip-node
```

Cek semua container:

```bash
docker compose --profile cpu ps
```

Untuk CUDA, ganti profile menjadi:

```bash
docker compose --profile cuda ps
```

Lihat log miner CPU:

```bash
docker compose logs --tail=200 -f cpu
```

Lihat log validator:

```bash
docker compose logs --tail=200 -f quip-validator
```

Lihat log bootstrap:

```bash
docker compose logs --tail=200 -f quip-bootstrap
```

## Terminal Dashboard

Installer memasang dashboard terminal yang merangkum status container, progres sync validator, jumlah block tersisa, kecepatan sync, estimasi waktu full sync, serta log validator, miner, dan bootstrap.

Untuk deployment yang sudah terinstall sebelum fitur dashboard tersedia, jalankan ulang installer one-click agar helper dipasang.

Jalankan:

```bash
quip-dashboard
```

Dashboard refresh otomatis setiap 5 detik. Keluar dengan:

```text
Ctrl+C
```

Atur interval refresh atau jumlah baris log jika diperlukan:

```bash
QUIP_DASHBOARD_REFRESH=10 QUIP_DASHBOARD_LOG_LINES=15 quip-dashboard
```

Kalau memakai folder install non-default:

```bash
QUIP_INSTALL_DIR=/path/to/quip-node quip-dashboard
```

Keluar dari follow mode dengan:

```text
Ctrl+C
```

Kalau mengaktifkan screen helper:

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

Kalau cron auto-update diaktifkan, installer memasang pengecekan image per jam.

Cek log:

```bash
cd /opt/quip-node
tail -f data/update.log
```

Jalankan update image manual:

```bash
cd /opt/quip-node
bash ./cron.sh
```

Untuk mengambil perubahan file deployment upstream, jalankan ulang installer one-click.

## Restart Dan Stop

Restart miner CPU setelah edit config:

```bash
cd /opt/quip-node
docker compose restart cpu
```

Recreate stack setelah edit `.env`:

```bash
cd /opt/quip-node
docker compose --profile cpu up -d --force-recreate
```

Stop stack:

```bash
cd /opt/quip-node
docker compose --profile cpu down
```

## Troubleshooting

Kalau dashboard HTTPS belum bisa dibuka:

- Pastikan DNS domain sudah mengarah ke IP VPS.
- Pastikan port `80/tcp` dan `443/tcp` terbuka.
- Cek log Caddy:

```bash
cd /opt/quip-node
docker compose logs --tail=200 -f caddy
```

Kalau validator tidak mendapat peer:

- Pastikan `30333/tcp` dan `30333/udp` terbuka di `ufw`.
- Pastikan security group provider juga membuka port `30333`.
- Cek log validator:

```bash
cd /opt/quip-node
docker compose logs --tail=200 -f quip-validator
```

Kalau miner belum berjalan setelah upgrade:

- Tunggu validator sync dan bootstrap selesai.
- Pastikan VPS dapat mengakses faucet testnet.
- Cek log bootstrap:

```bash
cd /opt/quip-node
docker compose logs --tail=200 quip-bootstrap
```

Kalau address `Connected Node` di dashboard berbeda dengan `ss58 address` hasil bootstrap, cek address miner lokal:

```bash
cd /opt/quip-node
docker exec quip-cpu python3 -c \
  'import json,urllib.request; print(json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:80/api/v1/status")), indent=2))'
```

Untuk deployment CPU, arahkan ulang dashboard ke miner dan validator lokal lalu hapus cache pointer address dashboard:

```bash
cd /opt/quip-node
grep -q '^QUIP_VALIDATOR_RPC_URLS=' .env && sed -i 's|^QUIP_VALIDATOR_RPC_URLS=.*|QUIP_VALIDATOR_RPC_URLS=ws://quip-validator:9944|' .env || echo 'QUIP_VALIDATOR_RPC_URLS=ws://quip-validator:9944' >> .env
grep -q '^QUIP_NODE_URL=' .env && sed -i 's|^QUIP_NODE_URL=.*|QUIP_NODE_URL=http://quip-miner:80|' .env || echo 'QUIP_NODE_URL=http://quip-miner:80' >> .env
grep -q '^QUIP_VALIDATOR_RPC_URL=' .env && sed -i 's|^QUIP_VALIDATOR_RPC_URL=.*|QUIP_VALIDATOR_RPC_URL=ws://quip-validator:9944|' .env || echo 'QUIP_VALIDATOR_RPC_URL=ws://quip-validator:9944' >> .env
docker compose exec -T postgres psql -U quip -d quip -c "DELETE FROM meta WHERE key = 'self_address';"
docker compose --profile cpu up -d --force-recreate dashboard
docker compose logs --tail=100 -f dashboard
```

Perintah SQL tersebut hanya menghapus pointer address milik indexer dashboard. Keystore miner dan saldo account tidak dihapus.

## File Penting

Backup file berikut setelah install atau upgrade. Simpan arsip di perangkat lain yang aman karena `keystore.json`, `.env`, mnemonic, dan file signing dapat berisi secret:

```text
/opt/quip-node/data/keystore.json    Wajib: signer miner dan address SS58
/opt/quip-node/data/config.toml      Wajib: konfigurasi miner
/opt/quip-node/.env                  Wajib: domain, tag image, dan konfigurasi deployment
```

Simpan juga file berikut jika tersedia:

```text
/opt/quip-node/data/node-key         Identitas libp2p validator
/opt/quip-node/data/signing.json     Material signing tambahan
/opt/quip-node/data/*.mnemonic       Mnemonic jika pernah dibuat manual
/opt/quip-node/data/.v0.1_backup/
/opt/quip-node/.env.v0.1_backup
```

Contoh membuat arsip backup dengan permission privat:

```bash
cd /opt/quip-node
umask 077
tar --ignore-failed-read -czf "$HOME/quip-node-backup-$(date +%F).tar.gz" \
  .env .env.v0.1_backup \
  data/config.toml data/keystore.json data/node-key data/signing.json \
  data/*.mnemonic data/.v0.1_backup
```

Pindahkan arsip tersebut ke perangkat lain, lalu hapus salinan arsip dari VPS jika sudah tidak diperlukan.

Folder berikut berukuran besar dan umumnya tidak perlu masuk backup rutin karena dapat dibuat ulang atau disinkronkan ulang:

```text
/opt/quip-node/data/validator-data/
/opt/quip-node/dashboard-data/
Docker volume quip-pgdata
Docker volume quip-caddy-data
Docker volume quip-caddy-config
```

## Disclaimer

Installer ini adalah wrapper untuk mempermudah setup dan upgrade. Runtime node tetap memakai deployment resmi Quip Network.
