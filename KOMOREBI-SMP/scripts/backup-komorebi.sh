#!/usr/bin/env bash
# =============================================================================
#  backup-komorebi.sh — Copia de seguridad consistente de KOMOREBI SMP.
#
#  Modos (BACKUP_MODE en /etc/komorebi/komorebi.conf o --mode):
#    stop (por defecto)  Aviso a jugadores → parada ordenada (SIGTERM) →
#                        copia → arranque inmediato. Copia 100 % consistente
#                        (mundos y bases de datos de plugins).
#    hot  (experimental) save-off + save-all flush por la consola local →
#                        copia → save-on. Los mundos quedan consistentes, pero
#                        las bases de datos de plugins (CoreProtect SQLite,
#                        LuckPerms H2) pueden seguir escribiendo.
#
#  Incluye mundos, plugins (con sus datos: economía, permisos, claims,
#  registros), configuraciones y paper.jar. Excluye cachés regenerables y logs.
#  Verifica la integridad (tar + compresor), guarda un .sha256, aplica la
#  retención y registra el resultado en $LOG_DIR/backup.log.
#
#  Uso: sudo backup-komorebi.sh [--scheduled] [--mode stop|hot] [--dry-run] [--list]
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=komorebi-common.sh
source "$SCRIPT_DIR/komorebi-common.sh"

TYPE="manual"
MODE=""
DRY=0
STOPPED_BY_US=0
SAVE_OFF=0
TMP_ARCHIVE=""
BACKUP_LOG=""
LOCK_FD=""
# Rutas (relativas al directorio padre de MC_DIR) que no se copian.
EXCLUDES=(cache libraries versions logs crash-reports debug)
NAME_RE='^komorebi-(daily|weekly|manual)-[0-9]{8}-[0-9]{6}\.tar\.(zst|gz)$'

usage() {
  cat <<'EOF'
Uso: sudo backup-komorebi.sh [opciones]
  (sin opciones)    Copia manual en manual/ (se conserva según BACKUP_KEEP_MANUAL; 0 = siempre).
  --scheduled       Copia diaria (temporizador): daily/ y promoción semanal a weekly/.
  --mode stop|hot   stop = parada controlada (por defecto); hot = save-off/save-all (experimental).
  --dry-run         Muestra el plan sin detener nada ni escribir.
  --list            Lista las copias existentes.
EOF
}

_blog() {
  if [[ -n $BACKUP_LOG && $DRY -eq 0 ]]; then
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$BACKUP_LOG" 2>/dev/null || true
  fi
}
b_info()  { k_info "$*"; _blog INFO "$*"; }
b_ok()    { k_ok "$*"; _blog OK "$*"; }
b_warn()  { k_warn "$*"; _blog WARN "$*"; }
b_error() { k_error "$*"; _blog ERR "$*"; }
b_die()   { b_error "$1"; shift; local h; for h in "$@"; do k_hint "$h"; done; exit 1; }

# list_backups — Lista las copias con tamaño.
list_backups() {
  local d f n=0
  for d in daily weekly manual; do
    printf '%s%s/%s\n' "$C_BOLD" "$d" "$C_RESET"
    for f in "$BACKUP_DIR/$d"/komorebi-*.tar.*; do
      [[ -f $f && ${f##*/} =~ $NAME_RE ]] || continue
      printf '  %-48s %10s\n' "${f##*/}" "$(k_human_bytes "$(stat -c '%s' -- "$f")")"
      n=$((n + 1))
    done
  done
  printf 'Total: %s copias en %s\n' "$n" "$BACKUP_DIR"
}

# on_exit — Garantiza que el servidor vuelve a su estado previo aunque la
# copia falle, y elimina archivos parciales.
on_exit() {
  local rc=$?
  trap - EXIT
  # Primero se libera el espacio del archivo parcial, después se reanuda Paper
  # (si el disco se llenó, Paper no debe arrancar sin espacio).
  if [[ -n $TMP_ARCHIVE && -e $TMP_ARCHIVE ]]; then
    rm -f -- "$TMP_ARCHIVE"
  fi
  if (( SAVE_OFF )); then
    k_console_send "save-on" || b_error "No se pudo reactivar el guardado: ejecuta 'sudo console-komorebi.sh save-on'."
  fi
  if (( STOPPED_BY_US )); then
    b_warn "Reiniciando el servidor tras la interrupción de la copia…"
    k_start_server || b_error "No se pudo reiniciar el servidor: sudo start-komorebi.sh"
  fi
  if (( rc != 0 )); then
    b_error "Copia de seguridad FALLIDA (código $rc)."
  fi
  exit "$rc"
}

# rotate DIR TIPO CONSERVAR — Borra las copias más antiguas de un tipo (solo
# ficheros con el patrón exacto de nombre y su .sha256). 0 = sin límite.
rotate() {
  local dir=$1 type=$2 keep=$3 f files=() sorted=() n i
  (( keep == 0 )) && return 0
  for f in "$dir"/komorebi-"$type"-*.tar.*; do
    [[ -f $f && ${f##*/} =~ $NAME_RE ]] || continue
    files+=("$f")
  done
  n=${#files[@]}
  (( n > keep )) || return 0
  mapfile -t sorted < <(printf '%s\n' "${files[@]}" | sort)
  for (( i = 0; i < n - keep; i++ )); do
    rm -f -- "${sorted[i]}" "${sorted[i]}.sha256"
    b_info "Retención: eliminada ${sorted[i]##*/}"
  done
}

# promote_weekly ARCHIVO — Si hoy es BACKUP_WEEKLY_DAY y no hay copia semanal
# de esta semana ISO, enlaza la copia diaria en weekly/.
promote_weekly() {
  local src=$1 week f d wname wdest
  [[ $(date +%u) == "$BACKUP_WEEKLY_DAY" ]] || return 0
  week=$(date +%G-W%V)
  for f in "$BACKUP_DIR/weekly"/komorebi-weekly-*.tar.*; do
    [[ -f $f && ${f##*/} =~ $NAME_RE ]] || continue
    d=${f##*/komorebi-weekly-}
    d=${d:0:8}
    if [[ $(date -d "$d" +%G-W%V 2>/dev/null || true) == "$week" ]]; then
      return 0
    fi
  done
  wname=${src##*/}
  wname=${wname/komorebi-daily-/komorebi-weekly-}
  wdest="$BACKUP_DIR/weekly/$wname"
  ln -- "$src" "$wdest" 2>/dev/null || cp -- "$src" "$wdest"
  chmod 0600 -- "$wdest"
  printf '%s  %s\n' "$(sha256sum -- "$wdest" | cut -d' ' -f1)" "$wname" >"$wdest.sha256"
  chmod 0600 -- "$wdest.sha256"
  b_ok "Copia semanal: $wdest"
}

main() {
  local ts base parent ext comp_opt dest need free start t_stop out rc lst sha name
  while (( $# )); do
    case $1 in
      --scheduled) TYPE="daily" ;;
      --mode) [[ ${2:-} == stop || ${2:-} == hot ]] || { usage >&2; exit 2; }; MODE=$2; shift ;;
      --dry-run) DRY=1 ;;
      --list) k_init; list_backups; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  k_init
  k_require_root
  MODE=${MODE:-$BACKUP_MODE}
  [[ -d $LOG_DIR ]] && BACKUP_LOG="$LOG_DIR/backup.log"
  [[ -d $MC_DIR ]] || b_die "No existe $MC_DIR." "¿Está instalado KOMOREBI SMP?"
  [[ -d $BACKUP_DIR/$TYPE ]] || b_die "No existe $BACKUP_DIR/$TYPE." "Ejecuta: sudo bash installer/install-komorebi.sh --backup"
  command -v tar >/dev/null || b_die "Falta tar."
  case $BACKUP_COMPRESSION in
    zstd) ext=zst; comp_opt=--zstd; command -v zstd >/dev/null || b_die "Falta zstd (pacman -S zstd)." ;;
    gzip) ext=gz; comp_opt=--gzip; command -v gzip >/dev/null || b_die "Falta gzip." ;;
  esac

  exec {LOCK_FD}>"$BACKUP_DIR/.komorebi-backup.lock"
  flock -n "$LOCK_FD" || b_die "Ya hay otra copia de seguridad en curso."
  # Con el bloqueo tomado, cualquier temporal es huérfano de una copia
  # interrumpida (corte de luz, SIGKILL): se elimina (solo el patrón propio).
  local orphan
  for orphan in "$BACKUP_DIR"/{daily,weekly,manual}/.komorebi-tmp.komorebi-*; do
    if [[ -f $orphan ]]; then
      rm -f -- "$orphan"
      b_warn "Eliminado temporal huérfano de una copia interrumpida: ${orphan##*/}"
    fi
  done

  base=$(basename -- "$MC_DIR")
  parent=$(dirname -- "$MC_DIR")
  ts=$(date +%Y%m%d-%H%M%S)
  name="komorebi-$TYPE-$ts.tar.$ext"
  dest="$BACKUP_DIR/$TYPE/$name"

  # Espacio: tamaño sin comprimir de lo que se copia + 512 MiB de margen.
  local ex_args=() e
  for e in "${EXCLUDES[@]}"; do ex_args+=("--exclude=$base/$e"); done
  need=$(du -sb "${ex_args[@]}" -- "$MC_DIR" 2>/dev/null | awk '{print $1}' || true)
  free=$(df -PB1 -- "$BACKUP_DIR" | awk 'NR==2 {print $4}')
  if [[ $need =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] && (( free < need + 536870912 )); then
    b_die "Espacio insuficiente en $BACKUP_DIR: libre $(k_human_bytes "$free"), necesario ~$(k_human_bytes "$need")." \
          "Libera espacio o reduce la retención en $KOMOREBI_CONFIG."
  fi

  if (( DRY )); then
    k_info "[simulación] tipo=$TYPE modo=$MODE destino=$dest"
    k_info "[simulación] tamaño a copiar ~$(k_human_bytes "${need:-0}"); excluidos: ${EXCLUDES[*]}"
    if k_service_active; then
      k_info "[simulación] el servidor está activo: se $( [[ $MODE == stop ]] && printf 'detendría y reiniciaría' || printf 'usaría save-off/save-all flush/save-on')."
    fi
    exit 0
  fi

  trap on_exit EXIT
  # Una interrupción (systemctl stop, Ctrl+C) pasa por on_exit: el servidor se
  # reinicia o se reactiva el guardado.
  trap 'exit 143' TERM
  trap 'exit 130' INT
  start=$(date +%s)
  b_info "Inicio de copia $TYPE (modo $MODE) → $dest"

  # --- Preparación: dejar los datos en reposo -----------------------------
  if k_service_active; then
    if [[ $MODE == hot ]]; then
      t_stop=$(date +%s)
      k_console_send "save-off" || b_die "No se pudo enviar save-off por la consola."
      SAVE_OFF=1
      k_console_send "save-all flush" || b_die "No se pudo enviar save-all flush."
      k_wait_for_log "$t_stop" "Saved the game" 300 || b_die "Paper no confirmó el guardado (\"Saved the game\")."
      b_ok "Guardado automático desactivado y mundos volcados a disco."
    else
      if (( BACKUP_STOP_WARNING > 0 )); then
        k_console_send "say Copia de seguridad: el servidor se reiniciará en $BACKUP_STOP_WARNING segundos." ||
          b_warn "No se pudo avisar a los jugadores."
        sleep "$BACKUP_STOP_WARNING"
      fi
      t_stop=$(date +%s)
      STOPPED_BY_US=1
      k_stop_server || b_die "No se pudo detener el servidor; la copia se cancela para no copiar datos inconsistentes."
      if [[ $(k_service_prop Result) == timeout ]]; then
        b_warn "Paper no terminó en ${STOP_TIMEOUT}s y systemd forzó la parada: esta copia puede contener datos sin guardar. Considera subir STOP_TIMEOUT."
      else
        b_ok "Servidor detenido de forma ordenada."
      fi
    fi
  elif [[ -n $(k_stray_paper_pids) ]]; then
    b_die "Hay un Paper ejecutándose fuera de systemd: no se puede garantizar una copia consistente." \
          "Detenlo y repite la copia."
  else
    b_info "El servidor estaba detenido."
  fi

  # --- Copia ----------------------------------------------------------------
  TMP_ARCHIVE="$BACKUP_DIR/$TYPE/.komorebi-tmp.$name"
  rc=0
  ( umask 077; tar --create --file="$TMP_ARCHIVE" "$comp_opt" --directory="$parent" \
      "${ex_args[@]}" --exclude="$base/.komorebi-tmp.*" --exclude="$base/plugins/.komorebi-tmp.*" \
      -- "$base" ) || rc=$?
  # Si tar falló (salvo el aviso admitido en modo hot), se borra el parcial
  # ANTES de reanudar el servidor.
  if (( rc != 0 )) && ! { (( rc == 1 )) && [[ $MODE == hot ]]; }; then
    rm -f -- "$TMP_ARCHIVE"
    TMP_ARCHIVE=""
  fi

  # --- Reanudar el servidor cuanto antes ------------------------------------
  if (( STOPPED_BY_US )); then
    k_start_server || b_error "No se pudo reiniciar el servidor: sudo start-komorebi.sh"
    STOPPED_BY_US=0
    b_info "Servidor reiniciado (sin servicio durante $(( $(date +%s) - t_stop ))s)."
  fi
  if (( SAVE_OFF )); then
    k_console_send "save-on" || b_error "No se pudo reactivar el guardado: sudo console-komorebi.sh save-on"
    SAVE_OFF=0
  fi
  if (( rc == 1 )) && [[ $MODE == hot ]]; then
    b_warn "tar informó de ficheros modificados durante la copia (esperable en modo hot con plugins activos)."
  elif (( rc != 0 )); then
    b_die "tar falló (código $rc)."
  fi

  # --- Verificación ---------------------------------------------------------
  if [[ $ext == zst ]]; then
    zstd -tq -- "$TMP_ARCHIVE" || b_die "La verificación de zstd falló."
  else
    gzip -t -- "$TMP_ARCHIVE" || b_die "La verificación de gzip falló."
  fi
  lst=$(tar --list --file="$TMP_ARCHIVE") || b_die "No se pudo leer el archivo generado."
  for out in server.properties eula.txt world/level.dat; do
    if [[ -e $MC_DIR/$out && $'\n'$lst$'\n' != *$'\n'"$base/$out"$'\n'* ]]; then
      b_die "El archivo no contiene $base/$out."
    fi
  done
  mv -f -- "$TMP_ARCHIVE" "$dest"
  TMP_ARCHIVE=""
  chmod 0600 -- "$dest"
  sha=$(sha256sum -- "$dest" | cut -d' ' -f1)
  printf '%s  %s\n' "$sha" "$name" >"$dest.sha256"
  chmod 0600 -- "$dest.sha256"
  b_ok "Copia verificada: $dest ($(k_human_bytes "$(stat -c '%s' -- "$dest")"), sha256 ${sha:0:16}…)"

  # --- Semanal y retención --------------------------------------------------
  if [[ $TYPE == daily ]]; then
    promote_weekly "$dest"
    rotate "$BACKUP_DIR/daily" daily "$BACKUP_KEEP_DAILY"
    rotate "$BACKUP_DIR/weekly" weekly "$BACKUP_KEEP_WEEKLY"
  else
    rotate "$BACKUP_DIR/manual" manual "$BACKUP_KEEP_MANUAL"
  fi
  b_ok "Copia completada en $(( $(date +%s) - start ))s."
  if [[ $(stat -c '%d' -- "$BACKUP_DIR") == "$(stat -c '%d' -- "$MC_DIR")" ]]; then
    k_info "Recuerda copiar periódicamente $BACKUP_DIR a otro disco (USB/NAS)."
  fi
}

main "$@"
