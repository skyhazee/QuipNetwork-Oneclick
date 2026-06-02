#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${QUIP_INSTALL_DIR:-/opt/quip-node}"
ENV_FILE="${INSTALL_DIR}/.env"

log() { printf '[quip-dashboard-sync] %s\n' "$*"; }

if [[ ! -d "${INSTALL_DIR}" || ! -f "${ENV_FILE}" ]]; then
  log "deployment tidak ditemukan di ${INSTALL_DIR}"
  exit 1
fi

cd "${INSTALL_DIR}"

miner_container=""
profile=""
for candidate in quip-cpu quip-cuda; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "${candidate}" 2>/dev/null || true)" == "true" ]]; then
    miner_container="${candidate}"
    profile="${candidate#quip-}"
    break
  fi
done

if [[ -z "${miner_container}" ]]; then
  log "miner belum running; akan dicoba lagi pada jadwal berikutnya"
  exit 0
fi

address="$(
  docker exec "${miner_container}" python3 -c \
    'import json,urllib.request; print(json.load(urllib.request.urlopen("http://127.0.0.1:80/api/v1/status", timeout=5))["data"]["ss58_address"])'
)"

if [[ ! "${address}" =~ ^[1-9A-HJ-NP-Za-km-z]{40,64}$ ]]; then
  log "address miner lokal tidak valid: ${address}"
  exit 1
fi

env_changed="no"

set_env() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=${value}$" "${ENV_FILE}"; then
    return
  elif grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
  env_changed="yes"
}

# Keep both the current and transitional dashboard image configuration pointed
# at this deployment's colocated validator and miner.
set_env "QUIP_VALIDATOR_RPC_URLS" "ws://quip-validator:9944"
set_env "QUIP_NODE_URL" "http://quip-miner:80"
set_env "QUIP_VALIDATOR_RPC_URL" "ws://quip-validator:9944"

# Seed the correct local account on future dashboard recreates. The value is
# discovered from this host's miner REST endpoint, never copied from a tutorial.
set_env "QUIP_OPERATOR_ACCOUNT" "${address}"

postgres_user="$(sed -n 's/^POSTGRES_USER=//p' "${ENV_FILE}" | tail -n 1)"
postgres_db="$(sed -n 's/^POSTGRES_DB=//p' "${ENV_FILE}" | tail -n 1)"
postgres_user="${postgres_user:-quip}"
postgres_db="${postgres_db:-quip}"

docker compose exec -T postgres psql -U "${postgres_user}" -d "${postgres_db}" \
  -v ON_ERROR_STOP=1 \
  -c "INSERT INTO meta (key, value) VALUES ('self_address', '${address}') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;" \
  >/dev/null

if [[ "${env_changed}" == "yes" ]]; then
  docker compose --profile "${profile}" up -d --force-recreate dashboard >/dev/null
  log "dashboard direcreate untuk memuat konfigurasi terbaru"
fi

log "dashboard diarahkan ke miner lokal ${address}"
