#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${QUIP_INSTALL_DIR:-/opt/quip-node}"
REFRESH_SECONDS="${QUIP_DASHBOARD_REFRESH:-5}"
LOG_LINES="${QUIP_DASHBOARD_LOG_LINES:-8}"
DASHBOARD_ONCE="${QUIP_DASHBOARD_ONCE:-0}"

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
BOLD="\033[1m"
NC="\033[0m"

PREV_BEST=""
PREV_TIME=""

container_state() {
  local name="$1"
  local state health

  if ! docker inspect "${name}" >/dev/null 2>&1; then
    printf "${RED}missing${NC}"
    return
  fi

  state="$(docker inspect --format '{{.State.Status}}' "${name}" 2>/dev/null || true)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${name}" 2>/dev/null || true)"

  case "${state}" in
    running)
      if [[ -n "${health}" && "${health}" != "healthy" ]]; then
        printf "${YELLOW}%s (%s)${NC}" "${state}" "${health}"
      else
        printf "${GREEN}%s%s${NC}" "${state}" "${health:+ (${health})}"
      fi
      ;;
    created|exited|restarting)
      printf "${YELLOW}%s${NC}" "${state}"
      ;;
    *)
      printf "${RED}%s${NC}" "${state:-unknown}"
      ;;
  esac
}

format_duration() {
  local seconds="${1:-0}"
  if (( seconds < 60 )); then
    printf "%ss" "${seconds}"
  elif (( seconds < 3600 )); then
    printf "%sm %ss" "$((seconds / 60))" "$((seconds % 60))"
  else
    printf "%sh %sm" "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  fi
}

latest_validator_sync_line() {
  docker logs --tail 400 quip-validator 2>&1 |
    grep -E 'Syncing|Imported #[0-9]+|Idle \(' |
    tail -n 1 || true
}

render_sync_status() {
  local now line best target remaining peers rate eta sync_state
  now="$(date +%s)"
  line="$(latest_validator_sync_line)"
  best="$(sed -nE 's/.*best: #([0-9]+).*/\1/p' <<<"${line}")"
  target="$(sed -nE 's/.*target=#([0-9]+).*/\1/p' <<<"${line}")"
  peers="$(sed -nE 's/.*\(([0-9]+) peers?\).*/\1/p' <<<"${line}")"

  if [[ -n "${best}" && -z "${target}" ]] && grep -qE 'Idle|Imported #[0-9]+' <<<"${line}"; then
    printf "Validator sync      : ${GREEN}synced${NC}\n"
    printf "Current block       : %s\n" "${best}"
    printf "Peers               : %s\n" "${peers:-unknown}"
    PREV_BEST="${best}"
    PREV_TIME="${now}"
    return
  fi

  if [[ -z "${best}" || -z "${target}" ]]; then
    printf "Validator sync      : ${YELLOW}waiting for sync metrics${NC}\n"
    [[ -n "${line}" ]] && printf "Latest validator log: %s\n" "${line}"
    PREV_BEST=""
    PREV_TIME="${now}"
    return
  fi

  remaining=$((target - best))
  (( remaining < 0 )) && remaining=0

  rate=""
  if [[ -n "${PREV_BEST}" && -n "${PREV_TIME}" && "${now}" -gt "${PREV_TIME}" ]]; then
    rate="$(awk -v current="${best}" -v previous="${PREV_BEST}" -v elapsed="$((now - PREV_TIME))" \
      'BEGIN { printf "%.1f", (current - previous) / elapsed }')"
  fi

  if (( remaining == 0 )); then
    sync_state="${GREEN}synced${NC}"
  else
    sync_state="${YELLOW}syncing${NC}"
  fi

  printf "Validator sync      : %b\n" "${sync_state}"
  printf "Block progress      : %s / %s (%s blocks remaining)\n" "${best}" "${target}" "${remaining}"
  printf "Peers               : %s\n" "${peers:-unknown}"

  if [[ -n "${rate}" ]] && awk -v rate="${rate}" 'BEGIN { exit !(rate > 0) }'; then
    eta="$(awk -v remaining="${remaining}" -v rate="${rate}" 'BEGIN { printf "%.0f", remaining / rate }')"
    printf "Sync speed          : %s blocks/s\n" "${rate}"
    printf "Estimated full sync : %s\n" "$(format_duration "${eta}")"
  else
    printf "Sync speed          : calculating, wait %ss...\n" "${REFRESH_SECONDS}"
    printf "Estimated full sync : calculating...\n"
  fi

  PREV_BEST="${best}"
  PREV_TIME="${now}"
}

render_logs() {
  local title="$1"
  local container="$2"

  printf "\n${BOLD}${BLUE}== %s ==${NC}\n" "${title}"
  if docker inspect "${container}" >/dev/null 2>&1; then
    docker logs --tail "${LOG_LINES}" "${container}" 2>&1 || true
  else
    printf "Container %s belum tersedia.\n" "${container}"
  fi
}

render() {
  printf "\033[H\033[2J"
  printf "${BOLD}Quip Node Dashboard${NC}  %s\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf "Refresh             : every %ss | exit: Ctrl+C\n" "${REFRESH_SECONDS}"
  printf "Install dir         : %s\n\n" "${INSTALL_DIR}"

  printf "${BOLD}${BLUE}== Container Status ==${NC}\n"
  printf "validator           : %b\n" "$(container_state quip-validator)"
  printf "bootstrap           : %b\n" "$(container_state quip-bootstrap)"
  printf "miner cpu           : %b\n" "$(container_state quip-cpu)"
  printf "miner cuda          : %b\n" "$(container_state quip-cuda)"
  printf "dashboard           : %b\n" "$(container_state quip-dashboard)"
  printf "postgres            : %b\n" "$(container_state quip-postgres)"
  printf "caddy               : %b\n\n" "$(container_state quip-caddy)"

  printf "${BOLD}${BLUE}== Validator Sync ==${NC}\n"
  render_sync_status

  render_logs "Validator Logs" "quip-validator"
  if docker inspect quip-cuda >/dev/null 2>&1; then
    render_logs "CUDA Mining Logs" "quip-cuda"
  else
    render_logs "CPU Mining Logs" "quip-cpu"
  fi
  render_logs "Bootstrap Logs" "quip-bootstrap"
}

if [[ ! -d "${INSTALL_DIR}" ]]; then
  printf "Install directory tidak ditemukan: %s\n" "${INSTALL_DIR}" >&2
  printf "Override dengan: QUIP_INSTALL_DIR=/path/to/quip-node quip-dashboard\n" >&2
  exit 1
fi

cd "${INSTALL_DIR}"

while true; do
  render
  [[ "${DASHBOARD_ONCE}" == "1" ]] && break
  sleep "${REFRESH_SECONDS}"
done
