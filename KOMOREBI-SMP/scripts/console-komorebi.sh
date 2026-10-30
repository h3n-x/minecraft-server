#!/usr/bin/env bash
# =============================================================================
#  console-komorebi.sh — Envía un comando a la consola de Paper sin RCON.
#  Usa el FIFO local del socket komorebi-console (solo root, sin red) y muestra
#  la respuesta del registro.
#  Uso: sudo console-komorebi.sh "whitelist add Steve"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=komorebi-common.sh
source "$SCRIPT_DIR/komorebi-common.sh"

usage() {
  cat <<'EOF'
Uso: sudo console-komorebi.sh "COMANDO"
Ejemplos:
  sudo console-komorebi.sh "whitelist add Steve"
  sudo console-komorebi.sh "op Steve"
  sudo console-komorebi.sh "list"
Para detener o reiniciar usa stop-komorebi.sh / start-komorebi.sh (no "stop").
EOF
}

main() {
  local cmd since
  case ${1:-} in
    ''|-h|--help) usage; exit 0 ;;
  esac
  (( $# == 1 )) || { usage >&2; exit 2; }
  cmd=${1#/}
  k_init
  k_require_root
  case ${cmd%% *} in
    stop|restart)
      k_die "No uses '$cmd' por consola: systemd lo interpretaría como una salida normal." \
            "Usa: sudo stop-komorebi.sh  (o sudo systemctl restart $K_SERVICE_UNIT)" ;;
  esac
  since=$(date +%s)
  k_console_send "$cmd" || exit 1
  sleep 2
  k_info "Respuesta del servidor:"
  k_journal_since "$since"
}

main "$@"
