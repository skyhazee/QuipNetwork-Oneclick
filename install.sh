#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="quip-oneclick"
DEPLOY_REPO="https://gitlab.com/quip.network/nodes.quip.network.git"
# Upstream default branch. main carries the current v0.3 testnet line (the
# Rust coordinator + Substrate validator). Older v0.2 branches are retired.
DEPLOY_BRANCH="main"
ONECLICK_RAW_BASE="https://raw.githubusercontent.com/skyhazee/QuipNetwork-Oneclick/main"
INSTALL_DIR_DEFAULT="/opt/quip-node"
API_PORT="20049"
VALIDATOR_P2P_PORT="30333"
MPS_PIPE_DIR="/tmp/nvidia-mps"
# Rest port the coordinator's [dashboard].listen must bind so Caddy can proxy
# /api/v1/* to it. Source of truth: caddy/Caddyfile in nodes.quip.network
# (reverse_proxy quip-miner:8086). Keep the two in sync.
DASHBOARD_REST_PORT="8086"

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

docker_has_nvidia_runtime() {
  docker info 2>/dev/null | grep -q "Runtimes:.*nvidia"
}

install_nvidia_container_toolkit() {
  if command -v nvidia-ctk >/dev/null 2>&1 && docker_has_nvidia_runtime; then
    log "NVIDIA Container Toolkit sudah terpasang dan runtime docker sudah dikonfigurasi."
    return
  fi

  log "Menginstall NVIDIA Container Toolkit untuk GPU mining..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
}

start_host_mps() {
  if [[ "${NODE_VARIANT}" != "cuda" ]]; then
    return
  fi

  log "Menyiapkan NVIDIA MPS untuk berbagi GPU (profile cuda)..."
  if ! command -v nvidia-cuda-mps-control >/dev/null 2>&1; then
    warn "nvidia-cuda-mps-control tidak ditemukan di host (binary ini dari CUDA toolkit / driver)."
    warn "Miner GPU akan memakai fallback software nonce reduction (tetap jalan, tanpa SM sharing)."
    return
  fi

  mkdir -p "${MPS_PIPE_DIR}" 2>/dev/null || true
  if pgrep -f nvidia-cuda-mps-control >/dev/null 2>&1; then
    info "MPS control daemon sudah berjalan (pipe dir: ${MPS_PIPE_DIR})."
  else
    info "Menjalankan MPS control daemon (pipe dir: ${MPS_PIPE_DIR})..."
    if CUDA_MPS_PIPE_DIRECTORY="${MPS_PIPE_DIR}" nvidia-cuda-mps-control -d; then
      info "MPS control daemon berjalan."
    else
      warn "Gagal menjalankan MPS daemon (butuh root / bukan WSL2 / driver belum support)."
      warn "Miner akan memakai fallback software nonce reduction."
    fi
  fi
}

detect_gpu() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi tidak ditemukan. Driver NVIDIA tidak terdeteksi."
    return 1
  fi
  if ! nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi tidak bisa berkomunikasi dengan GPU."
    return 1
  fi
  return 0
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
  EXISTING_DOMAIN=""
  EXISTING_CERT_EMAIL=""
  EXISTING_DWAVE_API_TOKEN=""
  EXISTING_HAS_KEYSTORE="no"

  if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    return
  fi

  EXISTING_INSTALL="yes"
  local config="${INSTALL_DIR}/data/config.toml"
  local env_file="${INSTALL_DIR}/.env"

  if [[ -f "${config}" ]]; then
    # v0.3 coordinator schema requires the [dashboard] REST section (Caddy
    # proxies /api/v1/* to [dashboard].listen). The upstream v0.1→v0.2
    # converter also promotes public_port into [miner], so [miner]+public_port
    # alone is NOT enough to call a config v0.3.
    if grep -qE '^\s*\[miner\]\s*$' "${config}" &&
       grep -qE '^\s*public_port\s*=' "${config}" &&
       grep -qE '^\s*\[dashboard\]\s*$' "${config}"; then
      EXISTING_SCHEMA="v0.3"
    elif grep -qE '^\s*\[miner\]\s*$' "${config}"; then
      EXISTING_SCHEMA="v0.2"
    elif grep -qE '^\s*\[global\]\s*$' "${config}"; then
      EXISTING_SCHEMA="v0.1"
    fi

    EXISTING_NODE_NAME="$(get_config_value "${config}" "node_name")"
    EXISTING_PUBLIC_HOST="$(get_config_value "${config}" "public_host")"

    if grep -qE '^\s*\[(qpu|dwave)\]\s*$' "${config}"; then
      EXISTING_VARIANT="qpu"
    elif grep -qE '^\s*\[cuda(\.[0-9]+)?\]\s*$' "${config}"; then
      EXISTING_VARIANT="cuda"
    elif grep -qE '^\s*\[cpu\]\s*$' "${config}"; then
      EXISTING_VARIANT="cpu"
    fi
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "quip-cuda"; then
    EXISTING_VARIANT="cuda"
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "quip-cpu"; then
    EXISTING_VARIANT="${EXISTING_VARIANT:-cpu}"
  fi

  if [[ -f "${INSTALL_DIR}/data/keystore.json" ]]; then
    # Only a legacy (v0.1/v0.2) install has an incompatible keystore format.
    # A v0.3 install's keystore is the H4 hybrid the coordinator already uses,
    # so it must never be archived on a routine re-run.
    if [[ "${EXISTING_SCHEMA}" == "v0.1" || "${EXISTING_SCHEMA}" == "v0.2" ]]; then
      EXISTING_HAS_KEYSTORE="yes"
    fi
  fi

  EXISTING_DOMAIN="$(normalise_domain "$(get_env_value "${env_file}" "QUIP_HOSTNAME")")"
  EXISTING_CERT_EMAIL="$(get_env_value "${env_file}" "CERT_EMAIL")"
  EXISTING_DWAVE_API_TOKEN="$(get_env_value "${env_file}" "DWAVE_API_TOKEN")"
  [[ -z "${EXISTING_DWAVE_API_TOKEN}" ]] && \
    EXISTING_DWAVE_API_TOKEN="$(get_env_value "${env_file}" "DWAVE_API_KEY")"

  log "Menemukan deployment existing di ${INSTALL_DIR}."
  info "Schema config : ${EXISTING_SCHEMA:-tidak terdeteksi}"
  info "Varian node   : ${EXISTING_VARIANT:-tidak terdeteksi}"
  info "Nama node     : ${EXISTING_NODE_NAME:-belum ada}"
  info "Domain        : ${EXISTING_DOMAIN:-belum ada}"
  info "Public host   : ${EXISTING_PUBLIC_HOST:-belum ada}"
  if [[ "${EXISTING_HAS_KEYSTORE}" == "yes" ]]; then
    info "Keystore v0.2 : terdeteksi (akan diarsipkan sebelum upgrade v0.3)"
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
  echo "  3) QPU D-Wave (berjalan di profile CPU, butuh DWAVE_API_TOKEN)"
  local choice
  choice="$(read_prompt "Pilihan [${default_choice}]: ")"
  case "${choice:-$default_choice}" in
    1) NODE_VARIANT="cpu"; PROFILE="cpu" ;;
    2) NODE_VARIANT="cuda"; PROFILE="cuda" ;;
    3) NODE_VARIANT="qpu"; PROFILE="cpu" ;;
    *) warn "Pilihan tidak dikenal, pakai CPU."; NODE_VARIANT="cpu"; PROFILE="cpu" ;;
  esac

  if [[ "${NODE_VARIANT}" == "cuda" ]]; then
    if ! detect_gpu; then
      err "Mode CUDA dipilih tapi NVIDIA GPU/driver tidak terdeteksi lewat nvidia-smi."
      err "Pasang driver NVIDIA dulu, atau pilih CPU."
      exit 1
    fi
  fi
}

detect_public_ip() {
  local ip
  ip="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  printf "%s" "${ip}"
}

collect_inputs() {
  choose_variant

  NODE_NAME="$(prompt_default "Nama node untuk dashboard" "${EXISTING_NODE_NAME:-${HOSTNAME}}")"
  # Node name lands in config.toml and .env; strip characters that would break
  # the TOML string or the .env line.
  NODE_NAME="${NODE_NAME//[\"\`\$\\]/_}"

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

  # public_host: what peers reach this node from outside. In v0.3 this is a
  # required [miner] key (used to advertise the node's reachable endpoint).
  PUBLIC_HOST_DEFAULT=""
  if [[ -n "${EXISTING_PUBLIC_HOST}" ]]; then
    PUBLIC_HOST_DEFAULT="${EXISTING_PUBLIC_HOST}"
  elif is_public_domain "${DASHBOARD_DOMAIN}"; then
    PUBLIC_HOST_DEFAULT="${DASHBOARD_DOMAIN}"
  else
    PUBLIC_HOST_DEFAULT="$(detect_public_ip)"
  fi
  PUBLIC_HOST="$(prompt_default "Host/IP publik untuk node (public_host)" "${PUBLIC_HOST_DEFAULT}")"
  while [[ -z "${PUBLIC_HOST}" ]]; do
    warn "public_host wajib diisi (dipakai coordinator untuk advertise endpoint)."
    PUBLIC_HOST="$(prompt_optional "Host/IP publik untuk node (public_host)")"
  done

  DWAVE_API_TOKEN="${EXISTING_DWAVE_API_TOKEN}"
  if [[ "${NODE_VARIANT}" == "qpu" ]] &&
     [[ -z "${DWAVE_API_TOKEN}" || "${DWAVE_API_TOKEN}" == "your-dwave-api-token-here" ]]; then
    DWAVE_API_TOKEN="$(prompt_optional "DWAVE_API_TOKEN")"
    while [[ -z "${DWAVE_API_TOKEN}" ]]; do
      warn "DWAVE_API_TOKEN wajib diisi untuk QPU."
      DWAVE_API_TOKEN="$(prompt_optional "DWAVE_API_TOKEN")"
    done
  fi

  if [[ "${NODE_VARIANT}" == "cuda" ]]; then
    ENABLE_MPS="no"
    confirm "Jalankan daemon NVIDIA MPS di host untuk SM sharing GPU?" "Y" && ENABLE_MPS="yes"
  else
    ENABLE_MPS="no"
  fi

  ENABLE_TUNE="no"
  confirm "Jalankan kernel tuning BBR/fq dari Quip?" "Y" && ENABLE_TUNE="yes"

  ENABLE_UFW="no"
  confirm "Update firewall ufw otomatis untuk port Quip?" "Y" && ENABLE_UFW="yes"

  ENABLE_CRON="no"
  confirm "Install atau refresh cron auto-update per jam?" "Y" && ENABLE_CRON="yes"

  ENABLE_SCREEN="no"
  confirm "Buat atau refresh helper screen untuk monitor logs?" "Y" && ENABLE_SCREEN="yes"
}

stop_legacy_containers() {
  # Stop and remove any pre-existing quip containers regardless of whether the
  # install dir is this repo (protects against port conflicts when an older
  # stack runs under a different folder). quip-qpu is the legacy v0.1/v0.2 QPU
  # container and must be torn down too.
  log "Menghentikan container Quip lama sebelum upgrade..."
  docker stop quip-cpu quip-cuda quip-qpu quip-dashboard quip-postgres quip-caddy quip-validator 2>/dev/null || true
  docker rm quip-cpu quip-cuda quip-qpu quip-dashboard quip-postgres quip-caddy quip-validator 2>/dev/null || true
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

# Write a fresh v0.3 coordinator config. The upstream repo's data/config.*.toml
# are stale v0.1/v0.2-era docs; the v0.3 coordinator requires the schema below.
# public_host / public_port are mandatory. [dashboard] must bind
# DASHBOARD_REST_PORT so Caddy's /api/v1/* proxy can reach it.
write_v03_config() {
  local config="${INSTALL_DIR}/data/config.toml"
  mkdir -p "${INSTALL_DIR}/data"

  local backend_section
  case "${NODE_VARIANT}" in
    cuda) backend_section=$'[cuda.0]\nbinary = "quip-cuda-sa"\n' ;;
    qpu)  backend_section=$'[cpu]\nbinary = "quip-cpu-sa"\n\n[dwave]\nbinary = "quip-dwave-qa"\ndaily_budget = "30s"\n' ;;
    *)    backend_section=$'[cpu]\nbinary = "quip-cpu-sa"\n' ;;
  esac

  cat > "${config}" <<EOF
[miner]
validators = ["ws://quip-validator:9944", "ws://127.0.0.1:9944"]
faucet_url = "https://faucet.testnet.quip.network"
signer_key = "/data/keystore.json"
node_name = "${NODE_NAME}"
public_host = "${PUBLIC_HOST}"
public_port = ${API_PORT}
log_level = "info"

${backend_section}
[dashboard]
listen = "0.0.0.0:${DASHBOARD_REST_PORT}"
data_dir = "/data/attempts"
EOF
  chmod 644 "${config}"
}

backup_legacy_v02() {
  # v0.3 coordinator uses an H4 hybrid (sr25519 + FN-DSA-512) signer at
  # /data/keystore.json and generates one only when the file is absent. A
  # v0.2-era keystore (sr25519 + ML-DSA-44) is a different format, so on an
  # upgrade we archive it rather than let the coordinator fail against it.
  if [[ "${EXISTING_HAS_KEYSTORE}" == "yes" && ! -f "${INSTALL_DIR}/data/keystore.json.v0.2-backup" ]]; then
    log "Mengarsipkan keystore v0.2 ke data/keystore.json.v0.2-backup (node akan generate keystore v0.3 baru)."
    mv "${INSTALL_DIR}/data/keystore.json" "${INSTALL_DIR}/data/keystore.json.v0.2-backup"
    chmod 600 "${INSTALL_DIR}/data/keystore.json.v0.2-backup"
  fi
}

configure_node() {
  log "Menyiapkan konfigurasi Quip v0.3..."
  cd "${INSTALL_DIR}"

  local config_exists_v03="no"
  if [[ -f data/config.toml ]]; then
    # Keep an existing config only when it is genuinely v0.3: [miner] with the
    # public identity keys AND the [dashboard] REST section. A v0.1/v0.2 file
    # (even one the upstream converter gave a public_port) is backed up and
    # replaced with the v0.3 coordinator schema.
    if grep -qE '^\s*\[miner\]\s*$' data/config.toml &&
       grep -qE '^\s*public_port\s*=' data/config.toml &&
       grep -qE '^\s*public_host\s*=' data/config.toml &&
       grep -qE '^\s*\[dashboard\]\s*$' data/config.toml; then
      config_exists_v03="yes"
    else
      log "Config lama (${EXISTING_SCHEMA:-skema lama}) terdeteksi. Membackup dan menulis config v0.3."
      cp data/config.toml "data/config.toml.pre-v0.3.$(date +%Y%m%d%H%M%S).bak"
    fi
  fi

  # Keep an existing v0.3 config (operator may have tuned it). Otherwise write
  # a fresh coordinator config from our template.
  if [[ "${config_exists_v03}" == "yes" ]]; then
    # Refresh the identity keys the operator was just prompted for, in place,
    # without touching the rest of their config.
    python3 - "${NODE_NAME}" "${PUBLIC_HOST}" <<'PY'
import re
import sys
from pathlib import Path

node_name, public_host = sys.argv[1], sys.argv[2]
path = Path("data/config.toml")
text = path.read_text()

def replace_in_miner(text, key, value):
    # Locate the [miner] section and replace/insert key=value there.
    m = re.search(r"(?m)^\s*\[miner\]\s*$", text)
    if not m:
        return text
    sec_end = re.search(r"(?m)^\s*\[", text[m.end():])
    end = m.end() + sec_end.start() if sec_end else len(text)
    block = text[m.start():end]
    line = f'{key} = "{value}"'
    if re.search(rf"(?m)^\s*{key}\s*=", block):
        block = re.sub(rf"(?m)^\s*{key}\s*=.*$", line, block, count=1)
    else:
        block = block.rstrip() + "\n" + line + "\n"
    return text[:m.start()] + block + text[end:]

text = replace_in_miner(text, "node_name", node_name.replace("\\", "\\\\").replace('"', '\\"'))
text = replace_in_miner(text, "public_host", public_host.replace("\\", "\\\\").replace('"', '\\"'))
path.write_text(text)
PY
    log "Config v0.3 dipertahankan; node_name dan public_host diperbarui di tempat."
  else
    write_v03_config
  fi

  # A v0.2-era keystore at /data/keystore.json is a different format than the
  # v0.3 coordinator expects. On any upgrade from v0.2 archive it so the
  # coordinator generates a fresh v0.3 keystore.
  backup_legacy_v02

  # .env: preserve operator settings, remove obsolete pins/vars.
  if [[ ! -f .env ]]; then
    cp env.example .env
  fi

  unset_env "QUIP_NODE_TOKEN"
  unset_env "QUIP_NODE_URL"
  unset_env "QUIP_VALIDATOR_RPC_URL"
  # v0.3 images default to `latest`; remove any stale v0.2 pins from a prior
  # one-click run so the node tracks the current build.
  unset_env "QUIP_MINER_TAG"
  unset_env "QUIP_DASHBOARD_TAG"
  unset_env "QUIP_VALIDATOR_TAG"
  unset_env "QUIP_FAUCET_TAG"
  # v0.2-era telemetry/REST vars are gone in v0.3 (config-driven).
  unset_env "QUIP_REST_PORT"
  unset_env "QUIP_REST_HOST"
  unset_env "QUIP_SIGNER_KEY"
  unset_env "QUIP_MODE"
  unset_env "QUIP_VALIDATORS"
  unset_env "QUIP_FAUCET_URL"

  set_env "PUID" "$(id -u "${RUN_USER}")"
  set_env "PGID" "$(id -g "${RUN_USER}")"
  set_env "VALIDATOR_NAME" "${NODE_NAME}"
  set_env "QUIP_MINER_CPUSET" "0"
  set_env "QUIP_MINER_MEM_LIMIT" "16g"

  if [[ "${ENABLE_TLS}" == "yes" ]]; then
    set_env "QUIP_HOSTNAME" "${DASHBOARD_DOMAIN}, ${DASHBOARD_DOMAIN}:${API_PORT}"
    set_env "CERT_EMAIL" "${CERT_EMAIL}"
  else
    set_env "QUIP_HOSTNAME" ":${API_PORT}"
    unset_env "CERT_EMAIL"
    set_env "CERT_EMAIL" ""
  fi

  if [[ "${NODE_VARIANT}" == "qpu" ]]; then
    set_env "DWAVE_API_TOKEN" "${DWAVE_API_TOKEN}"
    set_env "DWAVE_API_KEY" "${DWAVE_API_TOKEN}"
  fi

  if [[ "${NODE_VARIANT}" == "cuda" ]]; then
    set_env "QUIP_GPU_UTILIZATION" "100"
  fi

  chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"
}

set_env() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" .env; then
    # Escape characters that are special in the sed replacement string so
    # operator-supplied values (node name, domain, D-Wave token) can't corrupt
    # the .env line.
    local esc="${value}"
    esc="${esc//\\/\\\\}"
    esc="${esc//&/\\&}"
    esc="${esc//|/\\|}"
    sed -i "s|^${key}=.*|${key}=${esc}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

unset_env() {
  local key="$1"
  sed -i "/^[[:space:]]*#\\?[[:space:]]*${key}=/d" .env
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

  log "Memperbarui firewall ufw untuk Quip..."
  ufw allow OpenSSH || true
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
  if [[ "${NODE_VARIANT}" == "cuda" && "${ENABLE_MPS}" == "yes" ]]; then
    start_host_mps
  fi

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
    warn "Menghapus PM2 watchdog lama. Docker restart policy sudah cukup."
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
  echo "Upstream branch     : ${DEPLOY_BRANCH} (v0.3)"
  echo "Miner variant       : ${NODE_VARIANT}"
  echo "Compose profile     : ${PROFILE}"
  echo "Public API          : ${API_PORT}/tcp"
  echo "Validator libp2p    : ${VALIDATOR_P2P_PORT}/tcp + ${VALIDATOR_P2P_PORT}/udp"
  echo "Config              : ${INSTALL_DIR}/data/config.toml"
  echo "Env                 : ${INSTALL_DIR}/.env"

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

  # CUDA profile requires the docker `nvidia` runtime (NVIDIA Container Toolkit).
  if [[ "${NODE_VARIANT}" == "cuda" ]]; then
    install_nvidia_container_toolkit
  fi

  # Update the deployment repo first so a git failure leaves the running stack
  # untouched; only then tear the old containers down.
  clone_or_update_repo
  stop_legacy_containers
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
