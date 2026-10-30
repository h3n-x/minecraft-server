#!/usr/bin/env bash
# =============================================================================
#  restore-komorebi.sh — Restaura una copia de KOMOREBI SMP sin destruir nada.
#
#  1. Verifica el .sha256 y la integridad del archivo, y que todas sus rutas
#     estén dentro de "<nombre de MC_DIR>/" (sin rutas absolutas ni '..').
#  2. Exige el servidor detenido (lo detiene si se confirma).
#  3. Extrae en un directorio temporal del mismo disco.
#  4. Mueve la instalación actual a MC_DIR.pre-restore-<fecha> (NO se borra)
#     y coloca la restaurada en su lugar.
#
#  Uso: sudo restore-komorebi.sh [--yes] [--start] [--dry-run] ARCHIVO
#       sudo restore-komorebi.sh --list
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=komorebi-common.sh
source "$SCRIPT_DIR/komorebi-common.sh"

STAGING=""

usage() {
  cat <<'EOF'
Uso: sudo restore-komorebi.sh [opciones] ARCHIVO
     sudo restore-komorebi.sh --list
  --yes       No pide confirmación (detiene el servidor si está activo).
  --start     Inicia el servidor al terminar.
  --dry-run   Verifica el archivo y muestra el plan sin cambiar nada.
La instalación actual se conserva en <MC_DIR>.pre-restore-<fecha>.
EOF
}

cleanup() {
  if [[ -n $STAGING && -d $STAGING && ${STAGING##*/} == .komorebi-restore.* ]]; then
    rm -rf -- "$STAGING"
  fi
}

main() {
  local yes=0 start=0 dry=0 archive="" base parent ts sidecar want got names line size free old was_active=0 d ans
  while (( $# )); do
    case $1 in
      --yes) yes=1 ;;
      --start) start=1 ;;
      --dry-run) dry=1 ;;
      --list) exec "$SCRIPT_DIR/backup-komorebi.sh" --list ;;
      -h|--help) usage; exit 0 ;;
      -*) usage >&2; exit 2 ;;
      *) [[ -z $archive ]] || { usage >&2; exit 2; }; archive=$1 ;;
    esac
    shift
  done
  [[ -n $archive ]] || { usage >&2; exit 2; }
  k_init
  k_require_root
  [[ -f $archive && -r $archive ]] || k_die "No se puede leer $archive."
  [[ $archive == *.tar.zst || $archive == *.tar.gz ]] || k_die "Formato no reconocido (se espera .tar.zst o .tar.gz)."
  base=$(basename -- "$MC_DIR")
  parent=$(dirname -- "$MC_DIR")
  ts=$(date +%Y%m%d-%H%M%S)

  # 1. Integridad
  sidecar="$archive.sha256"
  if [[ -f $sidecar ]]; then
    read -r want _ <"$sidecar"
    got=$(sha256sum -- "$archive" | cut -d' ' -f1)
    [[ $want == "$got" ]] || k_die "El SHA-256 no coincide con $sidecar: archivo dañado o alterado."
    k_ok "SHA-256 verificado."
  else
    k_warn "No hay fichero .sha256: solo se comprobará la estructura del archivo."
  fi
  names=$(tar --list --file="$archive") || k_die "El archivo está dañado o no es un tar válido."
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    if [[ $line == /* || $line == ../* || $line == */../* || $line == */.. ||
          ( $line != "$base" && $line != "$base/" && $line != "$base/"* ) ]]; then
      k_die "Ruta no permitida dentro del archivo: $line" "Solo se restauran copias generadas para $MC_DIR."
    fi
  done <<<"$names"
  size=$(tar --list --verbose --file="$archive" | awk '{s += $3} END {printf "%d", s}')
  free=$(df -PB1 -- "$parent" | awk 'NR==2 {print $4}')
  if (( free < size + 536870912 )); then
    k_die "Espacio insuficiente en $parent: libre $(k_human_bytes "$free"), necesario ~$(k_human_bytes "$size")."
  fi
  k_ok "Archivo válido: $(wc -l <<<"$names") entradas, ~$(k_human_bytes "$size") sin comprimir."
  old="$MC_DIR.pre-restore-$ts"
  if (( dry )); then
    k_info "[simulación] se movería $MC_DIR → $old y se restauraría $archive."
    exit 0
  fi

  # 2. Servidor detenido
  if [[ -n $(k_stray_paper_pids) ]]; then
    k_die "Hay un Paper fuera de systemd en ejecución." "Detenlo antes de restaurar."
  fi
  if k_service_active; then
    was_active=1
    if (( ! yes )); then
      printf '¿Detener KOMOREBI SMP para restaurar? [s/N] '
      IFS= read -r ans || ans=''
      [[ ${ans,,} == s || ${ans,,} == si || ${ans,,} == sí ]] || k_die "Restauración cancelada."
    fi
    k_stop_server || k_die "No se pudo detener el servidor."
  fi
  if (( ! yes )); then
    printf 'Se moverá %s a %s y se restaurará la copia.\nEscribe RESTAURAR para continuar: ' "$MC_DIR" "$old"
    IFS= read -r ans || ans=''
    [[ $ans == RESTAURAR ]] || k_die "Restauración cancelada (no se ha cambiado nada)."
  fi

  # 3. Extracción en temporal (mismo sistema de ficheros → mv atómico)
  trap cleanup EXIT
  STAGING=$(mktemp -d "$parent/.komorebi-restore.XXXXXXXX")
  chmod 0700 -- "$STAGING"
  tar --extract --file="$archive" --directory="$STAGING" --same-permissions --same-owner ||
    k_die "Falló la extracción; la instalación actual no se ha tocado."
  [[ -d $STAGING/$base ]] || k_die "El archivo no contiene $base/."
  # Cachés regenerables que la copia excluye: se reutilizan si existen.
  for d in cache libraries versions; do
    if [[ -d $MC_DIR/$d && ! -e $STAGING/$base/$d ]]; then
      cp -a -- "$MC_DIR/$d" "$STAGING/$base/$d"
    fi
  done
  chown -R "$MC_USER:$MC_GROUP" -- "$STAGING/$base"
  chmod 0750 -- "$STAGING/$base"

  # 4. Intercambio (la instalación previa se conserva)
  if [[ -e $MC_DIR ]]; then
    mv -- "$MC_DIR" "$old"
  fi
  if ! mv -- "$STAGING/$base" "$MC_DIR"; then
    if [[ -e $old && ! -e $MC_DIR ]]; then mv -- "$old" "$MC_DIR"; fi
    k_die "No se pudo colocar la copia restaurada; se ha devuelto la instalación original."
  fi
  k_ok "Copia restaurada en $MC_DIR."
  if [[ -e $old ]]; then
    k_info "La instalación anterior se conserva en $old (bórrala manualmente cuando confirmes que todo funciona)."
  fi
  if (( start || was_active )); then
    if k_start_server; then
      k_ok "Servidor iniciado."
    else
      k_warn "No se pudo iniciar: sudo start-komorebi.sh"
    fi
  fi
}

main "$@"
