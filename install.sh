#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="quip-oneclick"
DEPLOY_REPO="https://gitlab.com/quip.network/nodes.quip.network.git"
DEPLOY_BRANCH="v0.2"
ONECLICK_RAW_BASE="https://raw.githubusercontent.com/skyhazee/QuipNetwork-Oneclick/main"
INSTALL_DIR_DEFAULT="/opt/quip-node"
API_PORT="20049"
VALIDATOR_P2P_PORT="30333"

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
    err "Jalankan sebagai root: sudo bash quip-install.sh"
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

get_env_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

get_config_value() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  python3 - "${file}" "${key}" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="replace")
key = re.escape(sys.argv[2])
match = re.search(rf'(?m)^\s*{key}\s*=\s*"([^"]*)"\s*$', text)
if match:
    print(match.group(1))
PY
}

normalise_domain() {
  local value="$1"
  value="${value%%,*}"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%:20049}"
  value="${value%:20080}"
  printf "%s" "${value}"
}

is_public_domain() {
  local value="$1"
  [[ -n "${value}" ]] &&
    [[ "${value}" != ":${API_PORT}" ]] &&
    [[ "${value}" != "localhost" ]] &&
    [[ "${value}" != "localhost:"* ]] &&
    [[ "${value}" != "127.0.0.1" ]] &&
    [[ "${value}" != *:* ]] &&
    [[ ! "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
    [[ "${value}" == *.* ]]
}

detect_existing_install() {
  EXISTING_INSTALL="no"
  EXISTING_SCHEMA=""
  EXISTING_VARIANT=""
  EXISTING_NODE_NAME=""
  EXISTING_PUBLIC_HOST=""
  EXISTING_SECRET_PRESENT="no"
  EXISTING_DOMAIN=""
  EXISTING_CERT_EMAIL=""
  EXISTING_DWAVE_API_KEY=""

  if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    return
  fi

  EXISTING_INSTALL="yes"
  local config="${INSTALL_DIR}/data/config.toml"
  local env_file="${INSTALL_DIR}/.env"

  if [[ -f "${config}" ]]; then
    if grep -qE '^\s*\[miner\]\s*$' "${config}"; then
      EXISTING_SCHEMA="v0.2"
    elif grep -qE '^\s*\[global\]\s*$' "${config}"; then
      if grep -qE '^\s*validators\s*=' "${config}"; then
        EXISTING_SCHEMA="v0.2-template"
      else
        EXISTING_SCHEMA="v0.1"
      fi
    fi

    EXISTING_NODE_NAME="$(get_config_value "${config}" "node_name")"
    EXISTING_PUBLIC_HOST="$(get_config_value "${config}" "public_host")"
    if [[ -n "$(get_config_value "${config}" "secret")" ]]; then
      EXISTING_SECRET_PRESENT="yes"
    fi
    if grep -qE '^\s*\[(qpu|dwave)\]\s*$' "${config}"; then
      EXISTING_VARIANT="qpu"
    elif grep -qE '^\s*\[(gpu|cuda)(\.|])' "${config}"; then
      EXISTING_VARIANT="cuda"
    elif grep -qE '^\s*\[cpu\]\s*$' "${config}"; then
      EXISTING_VARIANT="cpu"
    fi
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "quip-qpu"; then
    EXISTING_VARIANT="qpu"
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "quip-cuda"; then
    EXISTING_VARIANT="cuda"
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "quip-cpu"; then
    EXISTING_VARIANT="${EXISTING_VARIANT:-cpu}"
  fi

  EXISTING_DOMAIN="$(normalise_domain "$(get_env_value "${env_file}" "QUIP_HOSTNAME")")"
  EXISTING_CERT_EMAIL="$(get_env_value "${env_file}" "CERT_EMAIL")"
  EXISTING_DWAVE_API_KEY="$(get_env_value "${env_file}" "DWAVE_API_KEY")"

  log "Menemukan deployment existing di ${INSTALL_DIR}."
  info "Schema config : ${EXISTING_SCHEMA:-tidak terdeteksi}"
  info "Varian node   : ${EXISTING_VARIANT:-tidak terdeteksi}"
  info "Nama node     : ${EXISTING_NODE_NAME:-belum ada}"
  info "Domain        : ${EXISTING_DOMAIN:-belum ada}"
  info "Public host/IP: ${EXISTING_PUBLIC_HOST:-belum ada}"
  if [[ "${EXISTING_SECRET_PRESENT}" == "yes" ]]; then
    info "Secret v0.1   : terdeteksi, akan tetap tersimpan di backup"
  fi
}

choose_variant() {
  local default="${EXISTING_VARIANT:-cpu}"

  if [[ "${EXISTING_INSTALL}" == "yes" && -n "${EXISTING_VARIANT}" ]]; then
    NODE_VARIANT="${EXISTING_VARIANT}"
    PROFILE="${NODE_VARIANT}"
    [[ "${NODE_VARIANT}" == "qpu" ]] && PROFILE="cpu"
    log "Mempertahankan varian miner existing: ${NODE_VARIANT} (profile ${PROFILE})."
    return
  fi

  local default_choice="1"
  [[ "${default}" == "cuda" ]] && default_choice="2"
  [[ "${default}" == "qpu" ]] && default_choice="3"

  echo
  echo "Pilih varian miner:"
  echo "  1) CPU mining (recommended untuk VPS biasa)"
  echo "  2) CUDA GPU mining (butuh NVIDIA GPU + driver)"
  echo "  3) QPU D-Wave (berjalan di profile CPU, butuh DWAVE_API_KEY)"
  local choice
  choice="$(read_prompt "Pilihan [${default_choice}]: ")"
  case "${choice:-$default_choice}" in
    1) NODE_VARIANT="cpu"; PROFILE="cpu" ;;
    2) NODE_VARIANT="cuda"; PROFILE="cuda" ;;
    3) NODE_VARIANT="qpu"; PROFILE="cpu" ;;
    *) warn "Pilihan tidak dikenal, pakai CPU."; NODE_VARIANT="cpu"; PROFILE="cpu" ;;
  esac
}

collect_inputs() {
  choose_variant

  NODE_NAME="$(prompt_default "Nama node untuk dashboard" "${EXISTING_NODE_NAME:-${HOSTNAME}}")"

  local tls_default="N"
  if is_public_domain "${EXISTING_DOMAIN}"; then
    tls_default="Y"
  fi

  ENABLE_TLS="no"
  if confirm "Gunakan domain + HTTPS otomatis untuk dashboard?" "${tls_default}"; then
    ENABLE_TLS="yes"
    if is_public_domain "${EXISTING_DOMAIN}"; then
      DASHBOARD_DOMAIN="$(prompt_default "Domain dashboard tanpa http/https" "${EXISTING_DOMAIN}")"
    else
      DASHBOARD_DOMAIN="$(prompt_optional "Domain dashboard tanpa http/https, contoh node.example.com")"
    fi
    DASHBOARD_DOMAIN="$(normalise_domain "${DASHBOARD_DOMAIN}")"
    while ! is_public_domain "${DASHBOARD_DOMAIN}"; do
      warn "Isi domain publik yang valid, contoh node.example.com."
      DASHBOARD_DOMAIN="$(normalise_domain "$(prompt_optional "Domain dashboard tanpa http/https")")"
    done

    if [[ -n "${EXISTING_CERT_EMAIL}" ]]; then
      CERT_EMAIL="$(prompt_default "Email Let's Encrypt" "${EXISTING_CERT_EMAIL}")"
    else
      CERT_EMAIL="$(prompt_optional "Email Let's Encrypt")"
    fi
    while [[ -z "${CERT_EMAIL}" || "${CERT_EMAIL}" != *@* ]]; do
      warn "Email Let's Encrypt wajib diisi untuk HTTPS otomatis."
      CERT_EMAIL="$(prompt_optional "Email Let's Encrypt")"
    done
  else
    DASHBOARD_DOMAIN=""
    CERT_EMAIL=""
  fi

  DWAVE_API_KEY="${EXISTING_DWAVE_API_KEY}"
  if [[ "${NODE_VARIANT}" == "qpu" ]] &&
     [[ -z "${DWAVE_API_KEY}" || "${DWAVE_API_KEY}" == "your-dwave-api-token-here" ]]; then
    DWAVE_API_KEY="$(prompt_optional "DWAVE_API_KEY")"
    while [[ -z "${DWAVE_API_KEY}" ]]; do
      warn "DWAVE_API_KEY wajib diisi untuk QPU."
      DWAVE_API_KEY="$(prompt_optional "DWAVE_API_KEY")"
    done
  fi

  ENABLE_TUNE="no"
  confirm "Jalankan kernel tuning BBR/fq dari Quip?" "Y" && ENABLE_TUNE="yes"

  ENABLE_UFW="no"
  confirm "Update firewall ufw otomatis untuk port Quip v0.2?" "Y" && ENABLE_UFW="yes"

  ENABLE_CRON="no"
  confirm "Install atau refresh cron auto-update per jam?" "Y" && ENABLE_CRON="yes"

  ENABLE_SCREEN="no"
  confirm "Buat atau refresh helper screen untuk monitor logs?" "Y" && ENABLE_SCREEN="yes"
}

stop_legacy_containers() {
  if [[ "${EXISTING_INSTALL}" != "yes" ]]; then
    return
  fi

  log "Menghentikan container Quip lama sebelum upgrade..."
  docker stop quip-cpu quip-cuda quip-qpu quip-dashboard quip-postgres quip-caddy 2>/dev/null || true
  docker rm quip-cpu quip-cuda quip-qpu quip-dashboard quip-postgres quip-caddy 2>/dev/null || true
}

clone_or_update_repo() {
  log "Menyiapkan deployment repo ${DEPLOY_BRANCH} di ${INSTALL_DIR}..."
  mkdir -p "$(dirname "${INSTALL_DIR}")"

  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    git -C "${INSTALL_DIR}" fetch --prune origin
    if git -C "${INSTALL_DIR}" show-ref --verify --quiet "refs/heads/${DEPLOY_BRANCH}"; then
      git -C "${INSTALL_DIR}" switch "${DEPLOY_BRANCH}"
    else
      git -C "${INSTALL_DIR}" switch --track -c "${DEPLOY_BRANCH}" "origin/${DEPLOY_BRANCH}"
    fi
    git -C "${INSTALL_DIR}" pull --ff-only origin "${DEPLOY_BRANCH}"
  elif [[ -e "${INSTALL_DIR}" ]]; then
    err "${INSTALL_DIR} sudah ada tapi bukan git repo. Pilih folder lain atau pindahkan folder tersebut."
    exit 1
  else
    git clone --branch "${DEPLOY_BRANCH}" --single-branch "${DEPLOY_REPO}" "${INSTALL_DIR}"
  fi

  if [[ -e "${INSTALL_DIR}/docker-compose.override.yml" ]]; then
    local backup="${INSTALL_DIR}/docker-compose.override.yml.v0.1_backup.$(date +%Y%m%d%H%M%S)"
    warn "Memindahkan override lama agar node tidak masuk dev chain tanpa sengaja."
    mv "${INSTALL_DIR}/docker-compose.override.yml" "${backup}"
    info "Backup override: ${backup}"
  fi
}

run_config_converter() {
  if python3 -c 'import tomllib' >/dev/null 2>&1; then
    python3 scripts/upgrade-config.py data
  else
    warn "Python host belum punya tomllib. Menjalankan converter resmi lewat python:3.12-alpine."
    docker run --rm \
      -v "${INSTALL_DIR}:/work" \
      -w /work \
      python:3.12-alpine \
      python3 scripts/upgrade-config.py data
  fi
}

append_qpu_config() {
  cat >> data/config.toml <<'EOF'

[qpu]

[dwave]
solver = "Advantage2_system1.13"
dwave_region_url = "https://na-west-1.cloud.dwavesys.com/sapi/v2/"
daily_budget = "16m"
EOF
}

set_config_node_name() {
  python3 - "${NODE_NAME}" <<'PY'
import re
import sys
from pathlib import Path

node_name = sys.argv[1].replace("\\", "\\\\").replace('"', '\\"')
path = Path("data/config.toml")
text = path.read_text()
section = "miner" if re.search(r"(?m)^\s*\[miner\]\s*$", text) else "global"
header = re.search(rf"(?m)^\s*\[{section}\]\s*$", text)
if not header:
    raise SystemExit(f"Missing [{section}] section in data/config.toml")
next_header = re.search(r"(?m)^\s*\[", text[header.end():])
end = header.end() + next_header.start() if next_header else len(text)
block = text[header.start():end]
line = f'node_name = "{node_name}"'
if re.search(r"(?m)^\s*node_name\s*=", block):
    block = re.sub(r"(?m)^\s*node_name\s*=.*$", line, block, count=1)
else:
    block = block.rstrip() + "\n" + line + "\n"
path.write_text(text[:header.start()] + block + text[end:])
PY
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

unset_env() {
  local key="$1"
  sed -i "/^[[:space:]]*#\\?[[:space:]]*${key}=/d" .env
}

configure_node() {
  log "Menyiapkan konfigurasi Quip v0.2..."
  cd "${INSTALL_DIR}"

  if [[ "${EXISTING_INSTALL}" == "yes" && "${EXISTING_SCHEMA}" == "v0.1" ]]; then
    log "Mengonversi data/config.toml v0.1 ke v0.2. Data lama akan dibackup otomatis."
    run_config_converter
  elif [[ ! -f data/config.toml ]]; then
    if [[ "${NODE_VARIANT}" == "cuda" ]]; then
      cp data/config.cuda.toml data/config.toml
    else
      cp data/config.cpu.toml data/config.toml
    fi
    if [[ "${NODE_VARIANT}" == "qpu" ]]; then
      append_qpu_config
    fi
  fi

  set_config_node_name

  if [[ ! -f .env ]]; then
    cp env.example .env
  fi

  unset_env "QUIP_NODE_TOKEN"
  unset_env "DASHBOARD_PORT"
  set_env "PUID" "$(id -u "${RUN_USER}")"
  set_env "PGID" "$(id -g "${RUN_USER}")"
  set_env "VALIDATOR_NAME" "${NODE_NAME}"
  set_env "QUIP_MINER_TAG" "v0.2"
  set_env "QUIP_DASHBOARD_TAG" "v0.2"
  set_env "QUIP_VALIDATOR_TAG" "v0.2"
  set_env "QUIP_VALIDATOR_RPC_URLS" "ws://quip-validator:9944"
  # Compatibility for rolling v0.2 dashboard images that still consume the
  # previous REST URL and singular validator RPC variables.
  set_env "QUIP_NODE_URL" "http://quip-miner:80"
  set_env "QUIP_VALIDATOR_RPC_URL" "ws://quip-validator:9944"

  if [[ "${ENABLE_TLS}" == "yes" ]]; then
    set_env "QUIP_HOSTNAME" "${DASHBOARD_DOMAIN}, ${DASHBOARD_DOMAIN}:${API_PORT}"
    set_env "CERT_EMAIL" "${CERT_EMAIL}"
  else
    set_env "QUIP_HOSTNAME" ":${API_PORT}"
    set_env "CERT_EMAIL" ""
  fi

  if [[ "${NODE_VARIANT}" == "qpu" ]]; then
    set_env "DWAVE_API_KEY" "${DWAVE_API_KEY}"
  fi

  chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"
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

  log "Memperbarui firewall ufw untuk Quip v0.2..."
  ufw allow OpenSSH || true
  ufw --force delete allow "${API_PORT}/udp" >/dev/null 2>&1 || true
  ufw allow "${API_PORT}/tcp"
  ufw allow "${VALIDATOR_P2P_PORT}/tcp"
  ufw allow "${VALIDATOR_P2P_PORT}/udp"

  if [[ "${ENABLE_TLS}" == "yes" ]]; then
    ufw allow 80/tcp
    ufw allow 443/tcp
  fi

  ufw --force enable
}

start_node() {
  log "Memvalidasi dan menjalankan Quip profile: ${PROFILE}"
  cd "${INSTALL_DIR}"
  docker compose --profile "${PROFILE}" config >/dev/null
  docker compose --profile "${PROFILE}" up -d
}

install_cron_update() {
  if [[ "${ENABLE_CRON}" == "yes" ]]; then
    log "Menginstall auto-update cron Quip..."
    cd "${INSTALL_DIR}"
    bash ./cron.sh --install
  fi
}

remove_legacy_pm2_watchdog() {
  if ! command -v pm2 >/dev/null 2>&1; then
    return
  fi
  if pm2 describe quip-watchdog >/dev/null 2>&1; then
    warn "Menghapus PM2 watchdog lama. Docker restart policy v0.2 sudah cukup."
    pm2 delete quip-watchdog || true
    pm2 save || true
  fi
}

install_dashboard_helper() {
  log "Menginstall terminal dashboard Quip..."
  curl -fsSL "${ONECLICK_RAW_BASE}/quip-dashboard.sh" -o /usr/local/bin/quip-dashboard
  chmod +x /usr/local/bin/quip-dashboard
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
  log "Install atau upgrade selesai."
  echo "Folder install      : ${INSTALL_DIR}"
  echo "Upstream branch     : ${DEPLOY_BRANCH}"
  echo "Miner variant       : ${NODE_VARIANT}"
  echo "Compose profile     : ${PROFILE}"
  echo "Public API          : ${API_PORT}/tcp"
  echo "Validator libp2p    : ${VALIDATOR_P2P_PORT}/tcp + ${VALIDATOR_P2P_PORT}/udp"
  echo "Config              : ${INSTALL_DIR}/data/config.toml"
  echo "Env                 : ${INSTALL_DIR}/.env"

  if [[ "${EXISTING_SCHEMA}" == "v0.1" ]]; then
    echo "Backup config lama  : ${INSTALL_DIR}/data/.v0.1_backup/"
    echo "Backup env lama     : ${INSTALL_DIR}/.env.v0.1_backup"
  fi

  if [[ "${ENABLE_TLS}" == "yes" ]]; then
    echo "Dashboard           : https://${DASHBOARD_DOMAIN}/"
  else
    echo "Dashboard           : http://SERVER_IP:${API_PORT}/"
  fi

  echo
  echo "Command penting:"
  echo "  cd ${INSTALL_DIR}"
  echo "  docker compose --profile ${PROFILE} ps"
  echo "  docker compose logs --tail=200 -f ${PROFILE}"
  echo "  docker compose logs --tail=200 -f quip-validator"
  echo "  docker compose logs --tail=200 -f quip-bootstrap"
  echo "  quip-dashboard     # dashboard status + logs, refresh tiap 5 detik"
  echo "  bash ./cron.sh"
  if [[ "${ENABLE_SCREEN}" == "yes" ]]; then
    echo "  quip-logs          # buka logs di screen"
    echo "  quip-logs-attach   # attach ulang"
  fi
}

main() {
  require_linux
  require_root
  require_interactive_stdin
  detect_user
  INSTALL_DIR="$(prompt_default "Folder install" "${INSTALL_DIR_DEFAULT}")"
  install_packages
  install_docker
  detect_existing_install
  collect_inputs
  stop_legacy_containers
  clone_or_update_repo
  configure_node
  tune_kernel
  configure_firewall
  remove_legacy_pm2_watchdog
  install_dashboard_helper
  start_node
  install_cron_update
  create_screen_helpers
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
