#!/usr/bin/env bash
# =============================================================================
#  healthcheck-komorebi.sh — Comprobación de salud de KOMOREBI SMP.
#  Códigos de salida: 0 = OK · 1 = avisos · 2 = problemas críticos.
#  Uso: sudo healthcheck-komorebi.sh [--quiet]
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=komorebi-common.sh
source "$SCRIPT_DIR/komorebi-common.sh"

WORST=0
QUIET=0

h_ok()   { (( QUIET )) || k_ok "$*"; }
h_warn() { k_warn "$*"; (( WORST < 1 )) && WORST=1; return 0; }
h_crit() { k_error "$*"; WORST=2; }

check_disk() {
  local path=$1 label=$2 pct
  [[ -d $path ]] || return 0
  pct=$(df -P -- "$path" | awk 'NR==2 {gsub("%", "", $5); print $5}')
  [[ $pct =~ ^[0-9]+$ ]] || return 0
  if (( pct >= 95 )); then h_crit "Disco de $label al ${pct}%."
  elif (( pct >= 90 )); then h_warn "Disco de $label al ${pct}%."
  else h_ok "Disco de $label al ${pct}%."; fi
}

main() {
  local pid user restarts mem max port up_s since newest="" age_h f d t maxt=0 errors log
  case ${1:-} in
    --quiet) QUIET=1 ;;
    -h|--help) printf 'Uso: sudo healthcheck-komorebi.sh [--quiet]\n'; exit 0 ;;
    '') ;;
    *) printf 'Uso: sudo healthcheck-komorebi.sh [--quiet]\n' >&2; exit 2 ;;
  esac
  k_init
  if [[ $EUID -ne 0 ]]; then
    h_warn "Sin root: comprobaciones parciales (registro y backups pueden no ser accesibles)."
  fi

  if k_service_active; then
    pid=$(k_service_prop MainPID)
    user=$(ps -o user= -p "$pid" 2>/dev/null || true)
    user=${user//[[:space:]]/}
    if [[ $user == root ]]; then h_crit "¡Paper se está ejecutando como root!"
    elif [[ $user == "$MC_USER" ]]; then h_ok "Servicio activo (PID $pid, usuario $user)."
    else h_warn "Servicio activo con usuario inesperado: ${user:-?}"; fi
    restarts=$(k_service_prop NRestarts)
    if [[ $restarts =~ ^[0-9]+$ ]] && (( restarts > 0 )); then
      h_warn "El servicio se ha reiniciado $restarts veces tras fallos."
    fi
    mem=$(k_service_prop MemoryCurrent)
    max=$(k_service_prop MemoryMax)
    if [[ $mem =~ ^[0-9]+$ && $max =~ ^[0-9]+$ ]] && (( max > 0 )); then
      if (( mem * 100 / max >= 90 )); then h_warn "Memoria al $(( mem * 100 / max ))% del límite ($(k_human_bytes "$mem"))."
      else h_ok "Memoria: $(k_human_bytes "$mem") de $(k_human_bytes "$max")."; fi
    fi
    since=$(systemctl show -p ActiveEnterTimestampMonotonic --value -- "$K_SERVICE_UNIT" 2>/dev/null || printf '0')
    up_s=$(( $(awk '{printf "%d", $1}' /proc/uptime) - ${since:-0} / 1000000 ))
    port=$(ss -Hltn "sport = :$SERVER_PORT" 2>/dev/null || true)
    if [[ -n $port ]]; then h_ok "Puerto TCP $SERVER_PORT escuchando."
    elif (( up_s < 300 )); then h_warn "El puerto $SERVER_PORT aún no escucha (arrancando desde hace ${up_s}s)."
    else h_crit "El servicio está activo pero el puerto $SERVER_PORT no escucha."; fi
    log=$(journalctl -u "$K_SERVICE_UNIT" --since "-1h" -o cat --no-pager -q 2>/dev/null || true)
    errors=$(grep -c ' ERROR\]' <<<"$log" || true)
    if (( errors > 0 )); then h_warn "$errors líneas ERROR en el registro de la última hora (journalctl -u $K_SERVICE_UNIT --since -1h)."; fi
  else
    h_crit "El servicio $K_SERVICE_UNIT no está activo ($(systemctl is-active -- "$K_SERVICE_UNIT" 2>/dev/null || true))."
  fi
  if [[ -n $(k_stray_paper_pids) ]]; then
    h_crit "Hay procesos Paper fuera de systemd (riesgo de duplicados)."
  fi
  if [[ -r $MC_DIR/eula.txt ]] && ! k_eula_accepted; then
    h_warn "El EULA no está aceptado."
  fi

  check_disk "$MC_DIR" "servidor"
  check_disk "$BACKUP_DIR" "backups"

  for d in daily weekly manual; do
    for f in "$BACKUP_DIR/$d"/komorebi-*.tar.zst "$BACKUP_DIR/$d"/komorebi-*.tar.gz; do
      [[ -f $f ]] || continue
      if [[ -z $newest || $f -nt $newest ]]; then newest=$f; fi
    done
  done
  if [[ -z $newest ]]; then
    h_warn "No se encontraron copias de seguridad."
  else
    age_h=$(( ( $(date +%s) - $(stat -c '%Y' -- "$newest") ) / 3600 ))
    if (( age_h > BACKUP_MAX_AGE_HOURS )); then h_warn "Última copia hace ${age_h} h (${newest##*/})."
    else h_ok "Última copia hace ${age_h} h (${newest##*/})."; fi
  fi

  for f in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r $f ]] || continue
    t=$(<"$f")
    [[ $t =~ ^[0-9]+$ ]] || continue
    (( t > maxt )) && maxt=$t
  done
  if (( maxt > 0 )); then
    maxt=$(( maxt / 1000 ))
    if (( maxt >= 95 )); then h_crit "Temperatura máxima ${maxt} °C."
    elif (( maxt >= 85 )); then h_warn "Temperatura máxima ${maxt} °C: revisa la ventilación."
    else h_ok "Temperatura máxima ${maxt} °C."; fi
  fi

  case $WORST in
    0) h_ok "Estado general: OK" ;;
    1) k_warn "Estado general: con avisos" ;;
    2) k_error "Estado general: CRÍTICO" ;;
  esac
  exit "$WORST"
}

main "$@"
