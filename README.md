# Quip Network One-Click Installer

Installer interaktif untuk menjalankan atau meng-upgrade Quip Network node di VPS Debian/Ubuntu memakai Docker Compose deployment resmi Quip.

Repo resmi yang dipakai installer:

https://gitlab.com/quip.network/nodes.quip.network

Installer mengikuti **upstream `main`** yang membawa **stack v0.3** (coordinator Rust + validator Substrate). Versi ini mengganti node mesh lama dengan miner (CPU/CUDA/QPU) yang diawasi coordinator, plus validator lokal.

## Perubahan Penting v0.3

- Miner sekarang binary Rust yang dijalankan **coordinator** (`quip-coordinator`), image tunggal `quip-miner` (CPU) / `quip-miner-cuda` (GPU).
- Tidak ada lagi container `quip-bootstrap`. Keystore dibuat otomatis saat entrypoint pertama jalan, lalu miner self-register + self-funding lewat faucet testnet.
- Port API/dashboard tetap `20049/tcp`, validator `30333/tcp` + `30333/udp`.
- Config skema `[miner]`: `public_host`, `public_port`, `signer_key`, `faucet_url`, `validators`, `node_name`. Section backend: `[cpu]`, `[cuda.N]`, `[dwave]`.
- REST `/api/v1/*` disediakan coordinator lewat section `[dashboard]` dan diproxy Caddy.
- Image v0.3 default ke tag `latest`. Pin tag lama (v0.2) dihapus otomatis oleh installer.
- QPU memakai `[dwave]` backend dan membutuhkan `DWAVE_API_TOKEN`.

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

- Mendeteksi instalasi existing (v0.1 / v0.2 / v0.3).
- Memakai nama node, domain, email TLS, dan `public_host` lama sebagai default jika tersedia.
- Menghentikan dan menghapus container lama sebelum upgrade.
- Menarik branch upstream `main` (v0.3) dan menghapus `docker-compose.override.yml` lama agar node tidak masuk dev chain.
- Menulis `data/config.toml` skema v0.3 (coordinator), menyimpan config lama sebagai backup `data/config.toml.pre-v0.3.*.bak`.
- Jika ada keystore v0.2 lama (`data/keystore.json`), mengarsipkannya ke `data/keystore.json.v0.2-backup` karena format signer v0.3 berbeda (H4 hybrid sr25519 + FN-DSA-512 vs ML-DSA-44). Node akan generate keystore v0.3 baru.
- Membersihkan `.env` dari variabel/image-tag v0.2 yang sudah mati (`QUIP_NODE_URL`, `QUIP_NODE_TOKEN`, `QUIP_VALIDATOR_RPC_URL`, pin `QUIP_*_TAG`, dll).
- Membuka port firewall yang dipakai v0.3.
- Menjalankan coordinator + validator + dashboard + Postgres + Caddy.

Backup hasil migrasi disimpan di folder install. Jangan hapus sebelum node v0.3 berjalan normal.

## Fresh Install

### 1. Siapkan VPS Linux

- Debian/Ubuntu amd64 (Ubuntu 22.04/24.04 LTS disarankan).
- Untuk **CUDA GPU**: NVIDIA GPU (compute capability 7.0–12.1), driver NVIDIA, dan NVIDIA Container Toolkit. Installer akan mendeteksi `nvidia-smi` dan menolak mode CUDA kalau tidak ada.
- **Bukan** WSL2 / Docker Desktop untuk GPU (MPS SM sharing tidak didukung di sana; GPU jalan fallback).

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
Host/IP publik untuk node (public_host): IP_VPS_ATAU_DOMAIN
Gunakan domain + HTTPS otomatis: Y
Domain dashboard: quip.example.com
Email Let's Encrypt: email aktif kamu
Kernel tuning: Y
Update firewall ufw otomatis: Y
Cron auto-update: Y
Screen logs helper: Y
```

Wallet dan secret tidak perlu dimasukkan ke installer. Keystore signer dibuat otomatis saat entrypoint pertama.

## Mode Miner

Pilihan yang tersedia:

```text
1) CPU mining
2) CUDA GPU mining
3) QPU D-Wave
```

CUDA membutuhkan NVIDIA GPU + driver + NVIDIA Container Toolkit (installer membantu mendeteksi & mengingatkan; untuk CUDA ia juga bisa menjalankan daemon MPS host untuk berbagi GPU).

QPU membutuhkan `DWAVE_API_TOKEN` (backend `[dwave]` di profile Compose `cpu`).

## Dashboard

Dengan domain dan HTTPS:

```text
https://quip.example.com/
```

Tanpa domain:

```text
http://IP_VPS:20049/
```

Untuk HTTPS, installer menyimpan format Caddy berikut di `.env`:

```text
QUIP_HOSTNAME=quip.example.com, quip.example.com:20049
```

## Firewall

Installer dapat memperbarui `ufw` otomatis. Port Quip v0.3:

```text
20049/tcp       Caddy, dashboard, API, dan RPC publik
30333/tcp       Validator libp2p
30333/udp       Validator libp2p
80/tcp          Let's Encrypt HTTP-01
443/tcp         Dashboard HTTPS
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

Lihat log coordinator (miner):

```bash
docker compose logs --tail=200 -f cpu
```

Lihat log validator:

```bash
docker compose logs --tail=200 -f quip-validator
```

Cek sinkronisasi validator (initial sync bisa berjam-jam):

```bash
docker compose ps          # quip-validator: (health: starting) -> (healthy)
```

Catatan v0.3: tidak ada container `quip-bootstrap` lagi.

## Terminal Dashboard

Installer memasang dashboard terminal yang merangkum status container, progres sync validator, jumlah block tersisa, kecepatan sync, estimasi waktu full sync, serta log validator dan miner.

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

Restart coordinator (miner CPU) setelah edit config:

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

Kalau coordinator/miner belum berjalan setelah install:

- Tunggu validator sync selesai (`quip-validator` health `healthy`). Coordinator membaca runtime dari validator; kalau validator masih di genesis, coordinator bisa exit dengan pesan runtime mismatch — itu bukan butuh upgrade, tapi validator belum selesai sync.
- Kalau public_host salah/tidak bisa dijangkau peer, coordinator tidak bisa file descriptor. Pastikan `public_host` / `public_port` benar di `data/config.toml`.
- Cek log coordinator:

```bash
cd /opt/quip-node
docker compose logs --tail=200 -f cpu    # atau cuda
```

Cek status REST miner (address SS58, is_mining):

```bash
curl -fsSL http://127.0.0.1:20049/api/v1/status
```

Kalau memakai CUDA dan log menyebut "MPS not active in container — using software nonce reduction only": itu fallback yang masih jalan (degraded, tanpa SM sharing). Untuk SM sharing penuh, pastikan daemon MPS host berjalan (`sudo nvidia-cuda-mps-control -d`, atau jawab "Y" saat installer menawarkan menjalankan MPS). MPS tidak didukung di WSL2/Docker Desktop.

## File Penting

Backup file berikut setelah install atau upgrade. Simpan arsip di perangkat lain yang aman karena `keystore.json`, `.env`, mnemonic, dan file signing dapat berisi secret:

```text
/opt/quip-node/data/keystore.json    Wajib: signer v0.3 dan address SS58
/opt/quip-node/data/config.toml      Wajib: konfigurasi coordinator
/opt/quip-node/.env                  Wajib: domain, tag image, dan konfigurasi deployment
```

Simpan juga file berikut jika tersedia:

```text
/opt/quip-node/data/keystore.json.v0.2-backup   Keystore v0.2 yang diarsipkan saat upgrade
/opt/quip-node/data/config.toml.pre-v0.3.*.bak  Config lama (v0.1/v0.2)
/opt/quip-node/data/node-key         Identitas libp2p validator
```

Contoh membuat arsip backup dengan permission privat:

```bash
cd /opt/quip-node
umask 077
tar --ignore-failed-read -czf "$HOME/quip-node-backup-$(date +%F).tar.gz" \
  .env \
  data/config.toml data/keystore.json data/node-key \
  data/keystore.json.v0.2-backup data/config.toml.pre-v0.3.*.bak
```

Pindahkan arsip tersebut ke perangkat lain, lalu hapus salinan arsip dari VPS jika sudah tidak diperlukan.

Folder berikut berukuran besar dan umumnya tidak perlu masuk backup rutin karena dapat dibuat ulang atau disinkronkan ulang:

```text
/opt/quip-node/data/validator-data/
/opt/quip-node/dashboard-data/
/opt/quip-node/data/attempts/
Docker volume quip-pgdata
Docker volume quip-caddy-data
Docker volume quip-caddy-config
```

## Disclaimer

Installer ini adalah wrapper untuk mempermudah setup dan upgrade. Runtime node tetap memakai deployment resmi Quip Network.
