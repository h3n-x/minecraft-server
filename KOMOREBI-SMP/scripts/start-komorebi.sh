#!/usr/bin/env bash
# =============================================================================
#  start-komorebi.sh — Inicia KOMOREBI SMP mediante systemd.
#  No arranca un segundo proceso si el servidor ya está en marcha ni si hay un
#  Paper lanzado a mano fuera de systemd.
#  Uso: sudo start-komorebi.sh [--wait] [--help]
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=komorebi-common.sh
source "$SCRIPT_DIR/komorebi-common.sh"

usage() {
  cat <<'EOF'
Uso: sudo start-komorebi.sh [--wait]
  --wait   Espera (hasta 5 min) a que Paper confirme el arranque ("Done").
EOF
}

main() {
  local wait=0 stray since
  while (( $# )); do
    case $1 in
      --wait) wait=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  k_init
  k_require_root
  if k_service_active; then
    k_ok "KOMOREBI SMP ya está en ejecución (PID $(k_service_prop MainPID)). No se inicia otra instancia."
    exit 0
  fi
  stray=$(k_stray_paper_pids)
  if [[ -n $stray ]]; then
    k_die "Hay un Paper ejecutándose fuera de systemd (PID: ${stray//$'\n'/ })." \
          "Deténlo de forma ordenada (escribe 'stop' en su consola) antes de usar el servicio."
  fi
  [[ -f $MC_DIR/paper.jar ]] || k_die "No existe $MC_DIR/paper.jar." "Instálalo: sudo bash installer/install-komorebi.sh --paper"
  k_eula_accepted || k_die "El EULA de Minecraft no está aceptado." "Léelo y acéptalo: sudo bash installer/install-komorebi.sh --eula"
  if [[ $(systemctl is-failed -- "$K_SERVICE_UNIT" 2>/dev/null || true) == failed ]]; then
    k_warn "El servicio estaba en estado 'failed'. Revisa antes: journalctl -u $K_SERVICE_UNIT -e"
    systemctl reset-failed -- "$K_SERVICE_UNIT"
  fi
  since=$(date +%s)
  k_info "Iniciando $K_SERVICE_UNIT…"
  k_start_server
  if (( wait )); then
    if k_wait_for_log "$since" 'Done (' 300; then
      k_ok "KOMOREBI SMP está listo."
    else
      k_die "Paper no confirmó el arranque en 5 minutos." "Revisa: journalctl -u $K_SERVICE_UNIT -e"
    fi
  else
    k_ok "Servicio iniciado. Sigue el arranque con: journalctl -fu $K_SERVICE_UNIT"
  fi
}

main "$@"
