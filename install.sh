#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="quip-oneclick"
DEPLOY_REPO="https://gitlab.com/quip.network/nodes.quip.network.git"
INSTALL_DIR_DEFAULT="/opt/quip-node"
DEFAULT_P2P_PORT="20049"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

log() { printf "${GREEN}[%s]${NC} %s\n" "$APP_NAME" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
err() { printf "${RED}[error]${NC} %s\n" "$*" >&2; }
info() { printf "${BLUE}[info]${NC} %s\n" "$*"; }

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    err "Installer ini dibuat untuk VPS Linux."
    exit 1
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Jalankan sebagai root: sudo bash install.sh"
    exit 1
  fi
}

require_interactive_stdin() {
  if [[ ! -t 0 ]]; then
    err "Installer ini interaktif, jangan jalankan dengan: curl ... | sudo bash"
    err "Gunakan:"
    err "  curl -fsSL -o quip-install.sh https://raw.githubusercontent.com/skyhazee/QuipNetwork-Oneclick/main/install.sh"
    err "  sudo bash quip-install.sh"
    exit 1
  fi
}

detect_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    RUN_USER="${SUDO_USER}"
  else
    RUN_USER="root"
  fi
  RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  value="$(read_prompt "${prompt} [${default}]: ")"
  printf "%s" "${value:-$default}"
}

prompt_optional() {
  local prompt="$1"
  local value
  value="$(read_prompt "${prompt}: ")"
  printf "%s" "${value}"
}

read_prompt() {
  local prompt="$1"
  local value
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf "%s" "${prompt}" > /dev/tty
    IFS= read -r value < /dev/tty
  else
    printf "%s" "${prompt}" >&2
    IFS= read -r value
  fi
  printf "%s" "${value}"
}

confirm() {
  local prompt="$1"
  local default="${2:-Y}"
  local suffix="[Y/n]"
  [[ "${default}" == "N" ]] && suffix="[y/N]"

  local answer
  answer="$(read_prompt "${prompt} ${suffix}: ")"
  answer="${answer:-$default}"
  [[ "${answer}" =~ ^[Yy]$ ]]
}

choose_mode() {
  echo
  echo "Pilih mode node:"
  echo "  1) CPU mining (recommended untuk VPS biasa)"
  echo "  2) CUDA GPU mining (butuh NVIDIA GPU + driver)"
  echo "  3) QPU D-Wave (butuh DWAVE_API_KEY)"
  choice="$(read_prompt "Pilihan [1]: ")"
  case "${choice:-1}" in
    1) NODE_MODE="cpu" ;;
    2) NODE_MODE="cuda" ;;
    3) NODE_MODE="qpu" ;;
    *) warn "Pilihan tidak dikenal, pakai CPU."; NODE_MODE="cpu" ;;
  esac
}

choose_profile() {
  echo
  echo "Pilih varian deployment:"
  echo "  1) Full: node + dashboard + Caddy/TLS (recommended kalau punya domain)"
  echo "  2) No TLS: node + dashboard tanpa Caddy"
  echo "  3) No dashboard: node saja"
  choice="$(read_prompt "Pilihan [1]: ")"
  case "${choice:-1}" in
    1) PROFILE="${NODE_MODE}" ;;
    2) PROFILE="${NODE_MODE}-notls" ;;
    3) PROFILE="${NODE_MODE}-nodash" ;;
    *) warn "Pilihan tidak dikenal, pakai full profile."; PROFILE="${NODE_MODE}" ;;
  esac
}

install_packages() {
  log "Memastikan dependency dasar tersedia..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl git gnupg lsb-release screen cron openssl ufw python3
  else
    err "Saat ini installer otomatis baru mendukung Debian/Ubuntu dengan apt-get."
    exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker dan Docker Compose sudah tersedia."
    return
  fi

  log "Menginstall Docker Engine dan Compose plugin..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  local docker_distro="ubuntu"
  if [[ "${ID:-}" == "debian" ]]; then
    docker_distro="debian"
  fi
  local codename="${VERSION_CODENAME:-$(lsb_release -cs)}"
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_distro} ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_pm2_if_needed() {
  if [[ "${ENABLE_PM2}" != "yes" ]]; then
    return
  fi

  if command -v pm2 >/dev/null 2>&1; then
    log "PM2 sudah tersedia."
    return
  fi

  if ! command -v npm >/dev/null 2>&1; then
    log "Menginstall Node.js/npm untuk PM2..."
    apt-get install -y nodejs npm
  fi

  log "Menginstall PM2..."
  npm install -g pm2
}

clone_or_update_repo() {
  log "Menyiapkan deployment repo di ${INSTALL_DIR}..."
  mkdir -p "$(dirname "${INSTALL_DIR}")"

  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    git -C "${INSTALL_DIR}" pull --ff-only
  elif [[ -e "${INSTALL_DIR}" ]]; then
    err "${INSTALL_DIR} sudah ada tapi bukan git repo. Pilih folder lain atau pindahkan folder tersebut."
    exit 1
  else
    git clone "${DEPLOY_REPO}" "${INSTALL_DIR}"
  fi
}

generate_secret() {
  openssl rand -hex 32
}

configure_node() {
  log "Membuat konfigurasi node..."
  cd "${INSTALL_DIR}"

  cp "data/config.${NODE_MODE}.toml" data/config.toml

  local secret_value
  if [[ -n "${NODE_SECRET}" ]]; then
    secret_value="${NODE_SECRET}"
  else
    secret_value="$(generate_secret)"
  fi

  python3 - "$secret_value" "$PUBLIC_HOST" "$NODE_NAME" "$P2P_PORT" <<'PY'
import re
import sys
from pathlib import Path

secret, public_host, node_name, p2p_port = sys.argv[1:5]
path = Path("data/config.toml")
text = path.read_text()

def render(value, quote=True):
    return f'"{value}"' if quote else str(value)

def strip_accidental_top_level(src):
    first_section = re.search(r'(?m)^\s*\[', src)
    if not first_section:
        return src
    head, tail = src[:first_section.start()], src[first_section.start():]
    for key in ("secret", "node_name", "public_host", "public_port"):
        head = re.sub(rf'(?m)^\s*{re.escape(key)}\s*=.*\n?', '', head)
    return head.rstrip() + "\n\n" + tail.lstrip()

def section_bounds(src, section):
    header = re.search(rf'(?m)^\s*\[{re.escape(section)}\]\s*$', src)
    if not header:
        raise SystemExit(f"Missing [{section}] section in data/config.toml")
    next_header = re.search(r'(?m)^\s*\[', src[header.end():])
    end = header.end() + next_header.start() if next_header else len(src)
    return header.start(), end

def set_section_value(src, section, key, value, quote=True):
    start, end = section_bounds(src, section)
    block = src[start:end]
    tail = src[end:]
    pattern = rf'(?m)^(\s*#?\s*{re.escape(key)}\s*=\s*).*$'
    replacement = lambda m: re.sub(r'#\s*', '', m.group(1), count=1) + render(value, quote)
    if re.search(pattern, block):
        block = re.sub(pattern, replacement, block, count=1)
    else:
        block = block.rstrip() + f'\n{key} = {render(value, quote)}\n'
    return src[:start] + block + tail

def set_existing_section_value(src, section, key, value, quote=True):
    try:
        start, end = section_bounds(src, section)
    except SystemExit:
        return src
    block = src[start:end]
    pattern = rf'(?m)^(\s*{re.escape(key)}\s*=\s*).*$'
    if re.search(pattern, block):
        block = re.sub(pattern, lambda m: f'{m.group(1)}{render(value, quote)}', block, count=1)
    return src[:start] + block + src[end:]

text = strip_accidental_top_level(text)
text = set_section_value(text, "global", "secret", secret)
text = set_section_value(text, "global", "node_name", node_name)
text = set_section_value(text, "global", "public_host", public_host)
text = set_section_value(text, "global", "public_port", p2p_port, quote=False)
text = set_existing_section_value(text, "cpu", "public_host", public_host)
text = set_existing_section_value(text, "cpu", "public_port", p2p_port, quote=False)
text = set_existing_section_value(text, "cuda", "public_host", public_host)
text = set_existing_section_value(text, "cuda", "public_port", p2p_port, quote=False)
text = set_existing_section_value(text, "qpu", "public_host", public_host)
text = set_existing_section_value(text, "qpu", "public_port", p2p_port, quote=False)

path.write_text(text)
PY

  cp env.example .env
  {
    echo "PUID=$(id -u "${RUN_USER}")"
    echo "PGID=$(id -g "${RUN_USER}")"
  } >> .env

  if [[ "${PROFILE}" == "${NODE_MODE}" ]]; then
    set_env "QUIP_HOSTNAME" "${QUIP_HOSTNAME}"
    [[ -n "${CERT_EMAIL}" ]] && set_env "CERT_EMAIL" "${CERT_EMAIL}"
  else
    set_env "QUIP_HOSTNAME" "localhost:20080"
  fi

  if [[ "${NODE_MODE}" == "qpu" && -n "${DWAVE_API_KEY}" ]]; then
    set_env "DWAVE_API_KEY" "${DWAVE_API_KEY}"
  fi

  if [[ -n "${POSTGRES_PASSWORD}" ]]; then
    set_env "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"
  fi

  chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"
}

set_env() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

tune_kernel() {
  if [[ "${ENABLE_TUNE}" == "yes" ]]; then
    log "Menjalankan kernel tuning dari repo Quip..."
    cd "${INSTALL_DIR}"
    bash ./scripts/sysctl-tune.sh
  fi
}

configure_firewall() {
  if [[ "${ENABLE_UFW}" != "yes" ]]; then
    return
  fi

  log "Membuka port firewall dengan ufw..."
  ufw allow OpenSSH || true
  ufw allow "${P2P_PORT}/tcp"
  ufw allow "${P2P_PORT}/udp"

  if [[ "${PROFILE}" == "${NODE_MODE}" ]]; then
    ufw allow 80/tcp
    ufw allow 443/tcp
  elif [[ "${PROFILE}" == "${NODE_MODE}-notls" ]]; then
    ufw allow 20080/tcp
  fi

  ufw --force enable
}

start_node() {
  log "Menjalankan Quip profile: ${PROFILE}"
  cd "${INSTALL_DIR}"
  docker compose --profile "${PROFILE}" up -d
}

install_cron_update() {
  if [[ "${ENABLE_CRON}" == "yes" ]]; then
    log "Menginstall auto-update cron Quip..."
    cd "${INSTALL_DIR}"
    bash ./cron.sh --install
  fi
}

setup_pm2_watchdog() {
  if [[ "${ENABLE_PM2}" != "yes" ]]; then
    return
  fi

  log "Mendaftarkan PM2 watchdog helper..."
  local script_path="${INSTALL_DIR}/pm2-quip-watchdog.sh"
  cat > "${script_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${INSTALL_DIR}"
while true; do
  docker compose --profile "${PROFILE}" up -d
  sleep 300
done
EOF
  chmod +x "${script_path}"
  chown "${RUN_USER}:${RUN_USER}" "${script_path}"

  if [[ "${RUN_USER}" == "root" ]]; then
    pm2 start "${script_path}" --name quip-watchdog
    pm2 save
    pm2 startup systemd -u root --hp /root || true
  else
    sudo -u "${RUN_USER}" pm2 start "${script_path}" --name quip-watchdog
    sudo -u "${RUN_USER}" pm2 save
    pm2 startup systemd -u "${RUN_USER}" --hp "${RUN_HOME}" || true
  fi
}

create_screen_helpers() {
  if [[ "${ENABLE_SCREEN}" != "yes" ]]; then
    return
  fi

  log "Membuat helper screen untuk monitor logs..."
  local helper="/usr/local/bin/quip-logs"
  cat > "${helper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${INSTALL_DIR}"
if screen -list | grep -q "[.]quip-logs"; then
  exec screen -r quip-logs
fi
exec screen -S quip-logs bash -lc 'echo "Quip logs - detach: Ctrl+A lalu D"; echo; docker compose ps; echo; docker compose logs --tail=200 -f'
EOF
  chmod +x "${helper}"

  local attach="/usr/local/bin/quip-logs-attach"
  cat > "${attach}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if screen -list | grep -q "[.]quip-logs"; then
  exec screen -r quip-logs
fi
echo "Tidak ada session quip-logs. Jalankan: quip-logs"
EOF
  chmod +x "${attach}"
}

print_summary() {
  echo
  log "Install selesai."
  echo "Folder install      : ${INSTALL_DIR}"
  echo "Mode/profile        : ${PROFILE}"
  echo "P2P port            : ${P2P_PORT}/tcp + ${P2P_PORT}/udp"
  echo "Config              : ${INSTALL_DIR}/data/config.toml"
  echo "Env                 : ${INSTALL_DIR}/.env"

  if [[ "${PROFILE}" == "${NODE_MODE}" ]]; then
    echo "Dashboard           : https://${QUIP_HOSTNAME}/"
  elif [[ "${PROFILE}" == "${NODE_MODE}-notls" ]]; then
    echo "Dashboard           : http://SERVER_IP:20080/"
  else
    echo "Dashboard           : disabled"
  fi

  echo
  echo "Command penting:"
  echo "  cd ${INSTALL_DIR}"
  echo "  docker compose ps"
  echo "  docker compose logs --tail=200 ${NODE_MODE}"
  echo "  docker compose logs --tail=200 -f ${NODE_MODE}  # realtime, keluar Ctrl+C"
  echo "  docker compose restart ${NODE_MODE}"
  echo "  bash ./cron.sh"
  if [[ "${ENABLE_SCREEN}" == "yes" ]]; then
    echo "  quip-logs          # buka logs di screen baru"
    echo "  quip-logs-attach   # attach ulang ke screen logs"
  fi
}

collect_inputs() {
  INSTALL_DIR="$(prompt_default "Folder install" "${INSTALL_DIR_DEFAULT}")"
  choose_mode
  choose_profile

  NODE_USERNAME="$(prompt_default "Username node" "${HOSTNAME}")"
  NODE_WALLET="$(prompt_optional "Wallet address, contoh 0x1234...")"
  while [[ -z "${NODE_WALLET}" ]]; do
    warn "Wallet address tidak boleh kosong untuk format node name."
    NODE_WALLET="$(prompt_optional "Wallet address")"
  done
  NODE_NAME="${NODE_USERNAME} - ${NODE_WALLET}"
  log "Node name akan diset: ${NODE_NAME}"
  P2P_PORT="$(prompt_default "Port P2P public" "${DEFAULT_P2P_PORT}")"

  if [[ "${PROFILE}" == "${NODE_MODE}" ]]; then
    QUIP_HOSTNAME="$(prompt_optional "Domain untuk dashboard/TLS, contoh node.example.com")"
    while [[ -z "${QUIP_HOSTNAME}" || "${QUIP_HOSTNAME}" == *":"* ]]; do
      warn "Untuk TLS otomatis, isi domain asli tanpa port."
      QUIP_HOSTNAME="$(prompt_optional "Domain untuk dashboard/TLS")"
    done
    PUBLIC_HOST="${QUIP_HOSTNAME}"
    CERT_EMAIL="$(prompt_optional "Email Let's Encrypt")"
  else
    PUBLIC_HOST="$(prompt_optional "Public host untuk node, idealnya domain. Boleh IP jika belum punya domain")"
    while [[ -z "${PUBLIC_HOST}" ]]; do
      PUBLIC_HOST="$(prompt_optional "Public host tidak boleh kosong")"
    done
    QUIP_HOSTNAME="localhost:20080"
    CERT_EMAIL=""
  fi

  NODE_SECRET="$(prompt_optional "Node secret, kosongkan untuk generate otomatis")"

  DWAVE_API_KEY=""
  if [[ "${NODE_MODE}" == "qpu" ]]; then
    DWAVE_API_KEY="$(prompt_optional "DWAVE_API_KEY")"
  fi

  POSTGRES_PASSWORD="$(prompt_optional "POSTGRES_PASSWORD, kosongkan untuk default repo")"

  ENABLE_TUNE="no"
  confirm "Jalankan kernel tuning BBR/fq dari Quip?" "Y" && ENABLE_TUNE="yes"

  ENABLE_UFW="no"
  confirm "Auto buka port dengan ufw?" "Y" && ENABLE_UFW="yes"

  ENABLE_CRON="no"
  confirm "Install cron auto-update per jam?" "Y" && ENABLE_CRON="yes"

  ENABLE_PM2="no"
  confirm "Aktifkan PM2 watchdog helper? Docker detached tetap jalan 24/7 tanpa ini" "N" && ENABLE_PM2="yes"

  ENABLE_SCREEN="no"
  confirm "Buat helper screen untuk monitor logs?" "Y" && ENABLE_SCREEN="yes"
}

main() {
  require_linux
  require_root
  require_interactive_stdin
  detect_user
  collect_inputs
  install_packages
  install_docker
  install_pm2_if_needed
  clone_or_update_repo
  configure_node
  tune_kernel
  configure_firewall
  start_node
  install_cron_update
  setup_pm2_watchdog
  create_screen_helpers
  print_summary
}

main "$@"
