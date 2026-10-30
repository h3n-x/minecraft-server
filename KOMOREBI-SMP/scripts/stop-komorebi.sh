#!/usr/bin/env bash
# =============================================================================
#  stop-komorebi.sh — Detiene KOMOREBI SMP de forma ordenada.
#  systemd envía SIGTERM: Paper guarda mundos y datos y se cierra. Opcionalmente
#  avisa antes a los jugadores por la consola.
#  Uso: sudo stop-komorebi.sh [--warn SEGUNDOS] [--help]
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=komorebi-common.sh
source "$SCRIPT_DIR/komorebi-common.sh"

usage() {
  cat <<'EOF'
Uso: sudo stop-komorebi.sh [--warn SEGUNDOS]
  --warn N   Avisa a los jugadores y espera N segundos (máx. 600) antes de parar.
EOF
}

main() {
  local warn_secs=0 start
  while (( $# )); do
    case $1 in
      --warn)
        if [[ ! ${2:-} =~ ^[0-9]+$ ]] || (( 10#$2 > 600 )); then usage >&2; exit 2; fi
        warn_secs=$((10#$2)); shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  k_init
  k_require_root
  if ! k_service_active; then
    k_ok "KOMOREBI SMP ya está detenido."
    if [[ -n $(k_stray_paper_pids) ]]; then
      k_warn "Hay un Paper ejecutándose fuera de systemd; este script no lo detiene."
    fi
    exit 0
  fi
  if (( warn_secs > 0 )); then
    k_console_send "say El servidor se detendrá en $warn_secs segundos." || k_warn "No se pudo avisar por consola."
    sleep "$warn_secs"
  fi
  start=$(date +%s)
  k_info "Deteniendo $K_SERVICE_UNIT (guardado ordenado; hasta ${STOP_TIMEOUT}s)…"
  k_stop_server || k_die "La parada no terminó correctamente." "Revisa: journalctl -u $K_SERVICE_UNIT -e"
  k_ok "KOMOREBI SMP detenido en $(( $(date +%s) - start ))s."
}

main "$@"
