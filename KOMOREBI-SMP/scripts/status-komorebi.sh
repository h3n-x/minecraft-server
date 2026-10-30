#!/usr/bin/env bash
# =============================================================================
#  status-komorebi.sh — Estado de KOMOREBI SMP (solo lectura).
#  Con sudo muestra también el registro reciente del servicio.
#  Uso: [sudo] status-komorebi.sh [--lines N] [--help]
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=komorebi-common.sh
source "$SCRIPT_DIR/komorebi-common.sh"

usage() {
  printf 'Uso: [sudo] status-komorebi.sh [--lines N]\n'
}

main() {
  local lines=15 state enabled pid mem since restarts port newest f d timer
  while (( $# )); do
    case $1 in
      --lines) [[ ${2:-} =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; lines=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  k_init
  state=$(systemctl is-active -- "$K_SERVICE_UNIT" 2>/dev/null || true)
  enabled=$(systemctl is-enabled -- "$K_SERVICE_UNIT" 2>/dev/null || true)
  printf '%sKOMOREBI SMP%s — Paper %s (build %s)\n' "$C_BOLD" "$C_RESET" "$MC_VERSION" "$PAPER_BUILD"
  printf '  Servicio:      %s (%s al arranque)\n' "${state:-desconocido}" "${enabled:-no}"
  printf '  Consola FIFO:  %s\n' "$(systemctl is-active -- "$K_SOCKET_UNIT" 2>/dev/null || true)"
  if k_service_active; then
    pid=$(k_service_prop MainPID)
    mem=$(k_service_prop MemoryCurrent)
    since=$(k_service_prop ActiveEnterTimestamp)
    restarts=$(k_service_prop NRestarts)
    printf '  PID:           %s (usuario %s)\n' "$pid" "$(ps -o user= -p "$pid" 2>/dev/null || printf '?')"
    printf '  Activo desde:  %s\n' "${since:-?}"
    if [[ $mem =~ ^[0-9]+$ ]]; then
      printf '  Memoria:       %s (límite %s)\n' "$(k_human_bytes "$mem")" "$(k_service_prop MemoryMax)"
    fi
    printf '  Reinicios:     %s\n' "${restarts:-0}"
  fi
  port=$(ss -Hltn "sport = :$SERVER_PORT" 2>/dev/null || true)
  printf '  Puerto TCP %s: %s\n' "$SERVER_PORT" "$([[ -n $port ]] && printf 'escuchando' || printf 'cerrado')"
  printf '  EULA:          %s\n' "$(k_eula_accepted && printf 'aceptado' || printf 'pendiente / sin acceso')"
  timer=$(systemctl show -p NextElapseUSecRealtime --value -- "$K_BACKUP_TIMER_UNIT" 2>/dev/null || true)
  printf '  Próximo backup: %s\n' "${timer:-no programado}"
  newest=""
  for d in daily weekly manual; do
    for f in "$BACKUP_DIR/$d"/komorebi-*.tar.zst "$BACKUP_DIR/$d"/komorebi-*.tar.gz; do
      [[ -f $f ]] || continue
      if [[ -z $newest || $f -nt $newest ]]; then newest=$f; fi
    done
  done
  printf '  Último backup: %s\n' "${newest:-ninguno visible}"
  if [[ -n $(k_stray_paper_pids) ]]; then
    k_warn "Hay procesos Paper fuera de systemd."
  fi
  if (( lines > 0 )); then
    printf '\n%sÚltimas %s líneas del registro:%s\n' "$C_BOLD" "$lines" "$C_RESET"
    journalctl -u "$K_SERVICE_UNIT" -n "$lines" -o cat --no-pager -q 2>/dev/null ||
      k_warn "Sin acceso al registro (usa sudo o pertenece al grupo systemd-journal)."
  fi
}

main "$@"
