#!/usr/bin/env bash
# shellcheck shell=bash
# Biblioteca: muchas variables (colores, unidades, valores) se usan en los
# scripts que la cargan.
# shellcheck disable=SC2034
# =============================================================================
#  komorebi-common.sh — Biblioteca común de KOMOREBI SMP (木漏れ日)
#
#  Se carga con `source` desde los scripts de administración y desde el
#  instalador. No ejecuta acciones por sí misma.
#
#  Proporciona:
#    * Valores por defecto (fuente única de verdad para instalador y scripts).
#    * Lectura SEGURA de /etc/komorebi/komorebi.conf: no usa `source` ni `eval`;
#      solo acepta líneas CLAVE=valor cuya clave está en una lista blanca.
#    * Validación de la configuración.
#    * Mensajes con o sin color.
#    * Utilidades de systemd: servicio, socket de consola, procesos duplicados.
# =============================================================================

if [[ -n ${_KOMOREBI_COMMON_LOADED:-} ]]; then
  return 0
fi
_KOMOREBI_COMMON_LOADED=1

# Ruta del fichero de configuración. Puede sobrescribirse con la variable de
# entorno KOMOREBI_CONFIG (útil para pruebas; sudo la elimina por defecto).
KOMOREBI_CONFIG=${KOMOREBI_CONFIG:-/etc/komorebi/komorebi.conf}

# Claves admitidas en komorebi.conf (lista blanca).
K_CONFIG_KEYS=(
  MC_VERSION PAPER_BUILD PAPER_SHA256 JAVA_BIN JVM_XMS JVM_XMX JVM_FLAGS
  MC_USER MC_GROUP MC_DIR BACKUP_DIR LOG_DIR SERVICE_NAME CONSOLE_FIFO
  SERVER_PORT MAX_PLAYERS VIEW_DISTANCE SIMULATION_DISTANCE STOP_TIMEOUT
  BACKUP_MODE BACKUP_COMPRESSION BACKUP_KEEP_DAILY BACKUP_KEEP_WEEKLY
  BACKUP_KEEP_MANUAL BACKUP_WEEKLY_DAY BACKUP_ONCALENDAR BACKUP_STOP_WARNING
  BACKUP_MAX_AGE_HOURS HTTP_CONTACT
)

# -----------------------------------------------------------------------------
# k_set_defaults — Define los valores por defecto de todas las claves.
# -----------------------------------------------------------------------------
k_set_defaults() {
  MC_VERSION="1.20.1"
  # Build 196: última de 1.20.1 y la primera con soporte de Java 21.
  PAPER_BUILD="196"
  PAPER_SHA256="234a9b32098100c6fc116664d64e36ccdb58b5b649af0f80bcccb08b0255eaea"
  JAVA_BIN="/usr/lib/jvm/java-21-openjdk/bin/java"
  JVM_XMS="2G"
  JVM_XMX="4G"
  # Flags recomendados por la API oficial de Paper (Fill v3) para 1.20.1.
  JVM_FLAGS="-XX:+AlwaysPreTouch -XX:+DisableExplicitGC -XX:+ParallelRefProcEnabled -XX:+PerfDisableSharedMem -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:G1HeapRegionSize=8M -XX:G1HeapWastePercent=5 -XX:G1MaxNewSizePercent=40 -XX:G1MixedGCCountTarget=4 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1NewSizePercent=30 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:G1ReservePercent=20 -XX:InitiatingHeapOccupancyPercent=15 -XX:MaxGCPauseMillis=200 -XX:MaxTenuringThreshold=1 -XX:SurvivorRatio=32"
  MC_USER="minecraft"
  MC_GROUP="minecraft"
  MC_DIR="/var/lib/minecraft"
  BACKUP_DIR="/var/backups/minecraft"
  LOG_DIR="/var/log/komorebi"
  SERVICE_NAME="komorebi"
  CONSOLE_FIFO="/run/komorebi/console"
  SERVER_PORT="25565"
  MAX_PLAYERS="10"
  VIEW_DISTANCE="7"
  SIMULATION_DISTANCE="5"
  STOP_TIMEOUT="180"
  BACKUP_MODE="stop"
  BACKUP_COMPRESSION="zstd"
  BACKUP_KEEP_DAILY="7"
  BACKUP_KEEP_WEEKLY="4"
  BACKUP_KEEP_MANUAL="0"
  BACKUP_WEEKLY_DAY="7"
  BACKUP_ONCALENDAR="*-*-* 04:30:00"
  BACKUP_STOP_WARNING="60"
  BACKUP_MAX_AGE_HOURS="36"
  HTTP_CONTACT="self-hosted server; set HTTP_CONTACT in /etc/komorebi/komorebi.conf"
}

# -----------------------------------------------------------------------------
# Mensajes
# -----------------------------------------------------------------------------

# k_init_colors — Activa colores ANSI solo si la salida es una terminal y el
# usuario no los ha desactivado (NO_COLOR, KOMOREBI_NO_COLOR=1 o TERM=dumb).
k_init_colors() {
  if [[ -t 1 && -z ${NO_COLOR:-} && ${KOMOREBI_NO_COLOR:-0} != 1 && ${TERM:-dumb} != dumb ]]; then
    C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m' C_MAGENTA=$'\e[35m' C_CYAN=$'\e[36m'
  else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
    C_BLUE='' C_MAGENTA='' C_CYAN=''
  fi
}

k_info()  { printf '%s[INFO]%s %s\n' "${C_BLUE:-}" "${C_RESET:-}" "$*"; }
k_ok()    { printf '%s[ OK ]%s %s\n' "${C_GREEN:-}" "${C_RESET:-}" "$*"; }
k_warn()  { printf '%s[WARN]%s %s\n' "${C_YELLOW:-}" "${C_RESET:-}" "$*" >&2; }
k_error() { printf '%s[ERR ]%s %s\n' "${C_RED:-}" "${C_RESET:-}" "$*" >&2; }
k_hint()  { printf '%s   ->%s %s\n' "${C_CYAN:-}" "${C_RESET:-}" "$*" >&2; }

# k_die MENSAJE [SUGERENCIA...] — Muestra el error y sugerencias, y termina.
k_die() {
  local msg=$1 h
  shift
  k_error "$msg"
  for h in "$@"; do
    k_hint "$h"
  done
  exit 1
}

# -----------------------------------------------------------------------------
# Configuración
# -----------------------------------------------------------------------------

# k_is_config_key CLAVE — Devuelve 0 si la clave está en la lista blanca.
k_is_config_key() {
  local k
  for k in "${K_CONFIG_KEYS[@]}"; do
    if [[ $k == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

# k_check_config_perms FICHERO — Rechaza configuraciones que no sean propiedad
# de root o que sean escribibles por grupo/otros: los scripts se ejecutan como
# root y usan estas rutas para mover y rotar ficheros.
k_check_config_perms() {
  local file=$1 owner perm
  owner=$(stat -c '%u' -- "$file")
  perm=$(stat -c '%a' -- "$file")
  if [[ $owner != 0 ]]; then
    k_error "$file no pertenece a root (uid $owner)."
    k_hint "Corrígelo con: sudo chown root:root $file"
    return 1
  fi
  if (( 8#$perm & 8#022 )); then
    k_error "$file es escribible por grupo u otros (modo $perm)."
    k_hint "Corrígelo con: sudo chmod 0644 $file"
    return 1
  fi
  return 0
}

# k_load_config [FICHERO] — Lee CLAVE=valor de la lista blanca. No ejecuta
# nada. Admite valores entre comillas simples o dobles. Las líneas vacías y
# los comentarios (#) se ignoran. No se admiten comentarios al final de línea.
k_load_config() {
  local file=${1:-$KOMOREBI_CONFIG} line key val lineno=0
  if [[ ! -e $file ]]; then
    return 0
  fi
  if [[ ! -r $file ]]; then
    k_error "No se puede leer $file."
    return 1
  fi
  k_check_config_perms "$file" || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    if [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      val=${BASH_REMATCH[2]}
      # Quitar espacios finales y comillas envolventes.
      val=${val%"${val##*[![:space:]]}"}
      if [[ $val =~ ^\"(.*)\"$ ]] || [[ $val =~ ^\'(.*)\'$ ]]; then
        val=${BASH_REMATCH[1]}
      fi
      if k_is_config_key "$key"; then
        printf -v "$key" '%s' "$val"
      else
        k_warn "$file:$lineno: clave desconocida '$key' (se ignora)."
      fi
    else
      k_warn "$file:$lineno: línea con formato no válido (se ignora)."
    fi
  done <"$file"
  return 0
}

# _k_int_in_range NOMBRE VALOR MIN MAX — Valida un entero en un rango.
_k_int_in_range() {
  local name=$1 val=$2 min=$3 max=$4
  if [[ ! $val =~ ^[0-9]+$ ]] || (( 10#$val < min || 10#$val > max )); then
    k_error "$name='$val' no es válido (entero entre $min y $max)."
    return 1
  fi
  return 0
}

# _k_safe_abs_path NOMBRE RUTA — Ruta absoluta sin espacios, sin '..' y que no
# sea la raíz.
_k_safe_abs_path() {
  local name=$1 p=$2
  if [[ ! $p =~ ^/[A-Za-z0-9._/-]+$ || $p == */../* || $p == */.. || $p == */./* || $p == */ || $p == *//* ]]; then
    k_error "$name='$p' no es una ruta absoluta segura."
    return 1
  fi
  return 0
}

# k_size_to_mb TAMAÑO — Convierte 2G/2048M a MiB. Imprime el resultado.
k_size_to_mb() {
  local s=$1
  case $s in
    *G) printf '%s\n' "$(( 10#${s%G} * 1024 ))" ;;
    *M) printf '%s\n' "$(( 10#${s%M} ))" ;;
    *) return 1 ;;
  esac
}

# k_validate_config — Valida todos los valores cargados. Devuelve 1 si alguno
# es incorrecto (mostrando cada problema).
k_validate_config() {
  local bad=0 p tok
  for p in MC_DIR BACKUP_DIR LOG_DIR JAVA_BIN CONSOLE_FIFO; do
    _k_safe_abs_path "$p" "${!p}" || bad=1
  done
  case "$MC_DIR/" in
    "$BACKUP_DIR"/*) k_error "BACKUP_DIR no puede contener a MC_DIR."; bad=1 ;;
  esac
  case "$BACKUP_DIR/" in
    "$MC_DIR"/*) k_error "BACKUP_DIR no puede estar dentro de MC_DIR."; bad=1 ;;
  esac
  if [[ ! $MC_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then k_error "MC_USER='$MC_USER' no es válido."; bad=1; fi
  if [[ ! $MC_GROUP =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then k_error "MC_GROUP='$MC_GROUP' no es válido."; bad=1; fi
  if [[ ! $SERVICE_NAME =~ ^[a-z][a-z0-9-]{0,40}$ ]]; then k_error "SERVICE_NAME='$SERVICE_NAME' no es válido."; bad=1; fi
  if [[ ! $MC_VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then k_error "MC_VERSION='$MC_VERSION' no es válido."; bad=1; fi
  if [[ ! $PAPER_BUILD =~ ^([0-9]+|latest-stable)$ ]]; then k_error "PAPER_BUILD debe ser un número o 'latest-stable'."; bad=1; fi
  if [[ -n $PAPER_SHA256 && ! $PAPER_SHA256 =~ ^[0-9a-f]{64}$ ]]; then k_error "PAPER_SHA256 debe tener 64 caracteres hexadecimales."; bad=1; fi
  if [[ ! $JVM_XMS =~ ^[0-9]+[MG]$ ]]; then k_error "JVM_XMS='$JVM_XMS' no es válido (ej. 2G)."; bad=1; fi
  if [[ ! $JVM_XMX =~ ^[0-9]+[MG]$ ]]; then k_error "JVM_XMX='$JVM_XMX' no es válido (ej. 4G)."; bad=1; fi
  if [[ $JVM_XMS =~ ^[0-9]+[MG]$ && $JVM_XMX =~ ^[0-9]+[MG]$ ]] &&
     (( $(k_size_to_mb "$JVM_XMS") > $(k_size_to_mb "$JVM_XMX") )); then
    k_error "JVM_XMS ($JVM_XMS) no puede ser mayor que JVM_XMX ($JVM_XMX)."; bad=1
  fi
  for tok in $JVM_FLAGS; do
    # Solo flags -X / -D sin caracteres que systemd o el shell interpreten.
    if [[ ! $tok =~ ^-[XD][A-Za-z0-9_.:+=,/-]*$ ]]; then
      k_error "JVM_FLAGS contiene un elemento no permitido: '$tok'."; bad=1
    fi
  done
  _k_int_in_range SERVER_PORT "$SERVER_PORT" 1024 65535 || bad=1
  _k_int_in_range MAX_PLAYERS "$MAX_PLAYERS" 1 200 || bad=1
  _k_int_in_range VIEW_DISTANCE "$VIEW_DISTANCE" 2 32 || bad=1
  _k_int_in_range SIMULATION_DISTANCE "$SIMULATION_DISTANCE" 2 32 || bad=1
  _k_int_in_range STOP_TIMEOUT "$STOP_TIMEOUT" 30 1800 || bad=1
  _k_int_in_range BACKUP_KEEP_DAILY "$BACKUP_KEEP_DAILY" 0 365 || bad=1
  _k_int_in_range BACKUP_KEEP_WEEKLY "$BACKUP_KEEP_WEEKLY" 0 520 || bad=1
  _k_int_in_range BACKUP_KEEP_MANUAL "$BACKUP_KEEP_MANUAL" 0 1000 || bad=1
  _k_int_in_range BACKUP_WEEKLY_DAY "$BACKUP_WEEKLY_DAY" 1 7 || bad=1
  _k_int_in_range BACKUP_STOP_WARNING "$BACKUP_STOP_WARNING" 0 600 || bad=1
  _k_int_in_range BACKUP_MAX_AGE_HOURS "$BACKUP_MAX_AGE_HOURS" 1 1000 || bad=1
  case $BACKUP_MODE in stop|hot) ;; *) k_error "BACKUP_MODE debe ser 'stop' o 'hot'."; bad=1 ;; esac
  case $BACKUP_COMPRESSION in zstd|gzip) ;; *) k_error "BACKUP_COMPRESSION debe ser 'zstd' o 'gzip'."; bad=1 ;; esac
  if [[ ! $BACKUP_ONCALENDAR =~ ^[A-Za-z0-9*:.,/~\ -]+$ ]]; then k_error "BACKUP_ONCALENDAR contiene caracteres no permitidos."; bad=1; fi
  if [[ ! $HTTP_CONTACT =~ ^[A-Za-z0-9@._:/+\;=\ -]{3,120}$ ]]; then k_error "HTTP_CONTACT contiene caracteres no permitidos."; bad=1; fi
  return "$bad"
}

# k_units — Nombres de las unidades systemd derivadas de SERVICE_NAME.
k_units() {
  K_SERVICE_UNIT="${SERVICE_NAME}.service"
  K_SOCKET_UNIT="${SERVICE_NAME}-console.socket"
  K_BACKUP_SERVICE_UNIT="${SERVICE_NAME}-backup.service"
  K_BACKUP_TIMER_UNIT="${SERVICE_NAME}-backup.timer"
}

# k_init — Inicialización estándar de los scripts de administración.
k_init() {
  k_init_colors
  k_set_defaults
  k_load_config || k_die "La configuración no es válida." "Revisa $KOMOREBI_CONFIG"
  k_validate_config || k_die "La configuración no es válida." "Revisa $KOMOREBI_CONFIG"
  k_units
}

# k_require_root — Termina si no se ejecuta como root.
k_require_root() {
  if [[ $EUID -ne 0 ]]; then
    k_die "Este script necesita privilegios de administrador." "Ejecútalo con: sudo $0"
  fi
}

# -----------------------------------------------------------------------------
# systemd y procesos
# -----------------------------------------------------------------------------

# k_service_active — 0 si el servicio está activo (o arrancando/recargando).
k_service_active() {
  local state
  state=$(systemctl is-active -- "$K_SERVICE_UNIT" 2>/dev/null || true)
  case $state in
    active|activating|reloading|deactivating) return 0 ;;
    *) return 1 ;;
  esac
}

# k_service_prop PROPIEDAD — Valor de una propiedad del servicio.
k_service_prop() {
  systemctl show -p "$1" --value -- "$K_SERVICE_UNIT" 2>/dev/null || true
}

# k_paper_pids — PIDs de procesos Java del usuario del servidor que ejecutan
# paper.jar (dentro o fuera de systemd).
k_paper_pids() {
  pgrep -u "$MC_USER" -f -- '-jar paper\.jar' 2>/dev/null || true
}

# k_stray_paper_pids — PIDs de Paper que NO pertenecen al cgroup del servicio
# (por ejemplo, un `java -jar paper.jar` lanzado a mano). Evita duplicados.
k_stray_paper_pids() {
  local pid cg
  for pid in $(k_paper_pids); do
    cg=$(cat "/proc/$pid/cgroup" 2>/dev/null || true)
    if [[ $cg != *"/${K_SERVICE_UNIT}"* ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

# k_stop_server — Parada ordenada (SIGTERM → Paper guarda y cierra). Detiene
# también el socket de consola para que ningún dato pendiente en el FIFO
# reactive el servicio (activación por socket) mientras está parado.
k_stop_server() {
  local i
  systemctl stop -- "$K_SERVICE_UNIT" "$K_SOCKET_UNIT"
  for (( i = 0; i < 15; i++ )); do
    if ! k_service_active && [[ -z $(k_paper_pids) ]]; then
      return 0
    fi
    sleep 1
  done
  k_error "El servidor sigue en ejecución tras la parada."
  return 1
}

# k_start_server — Inicia el servicio (systemd arranca antes el socket).
k_start_server() {
  systemctl start -- "$K_SERVICE_UNIT"
}

# k_console_send COMANDO — Envía una línea a la consola de Paper a través del
# FIFO (solo root). Rechaza saltos de línea y caracteres de control.
k_console_send() {
  local cmd=$1
  if [[ -z $cmd || ${#cmd} -gt 1000 || $cmd == *[[:cntrl:]]* ]]; then
    k_error "Comando de consola vacío, demasiado largo o con caracteres de control."
    return 1
  fi
  if ! k_service_active; then
    k_error "El servidor no está en ejecución."
    return 1
  fi
  if [[ ! -p $CONSOLE_FIFO ]]; then
    k_error "No existe el FIFO de consola $CONSOLE_FIFO."
    k_hint "Comprueba: systemctl status $K_SOCKET_UNIT"
    return 1
  fi
  # timeout evita un bloqueo indefinido si el FIFO no tuviera lector.
  printf '%s\n' "$cmd" | timeout 5 tee -- "$CONSOLE_FIFO" >/dev/null
}

# k_journal_since EPOCH — Registro del servicio desde un instante (segundos).
k_journal_since() {
  journalctl -u "$K_SERVICE_UNIT" --since "@$1" -o cat --no-pager -q 2>/dev/null || true
}

# k_wait_for_log EPOCH TEXTO SEGUNDOS — Espera a que TEXTO aparezca en el
# registro del servicio desde EPOCH. Devuelve 1 si se agota el tiempo.
# (Se captura la salida en vez de usar `| grep -q`: con pipefail, el SIGPIPE de
# journalctl daría falsos negativos.)
k_wait_for_log() {
  local since=$1 text=$2 timeout=$3 i out
  for (( i = 0; i < timeout; i++ )); do
    out=$(k_journal_since "$since")
    if [[ $out == *"$text"* ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# k_eula_accepted — 0 si eula.txt contiene exactamente eula=true.
k_eula_accepted() {
  [[ -r $MC_DIR/eula.txt ]] && grep -qx 'eula=true' -- "$MC_DIR/eula.txt"
}

# k_human_bytes BYTES — Tamaño legible (KiB, MiB, GiB).
k_human_bytes() {
  numfmt --to=iec-i --suffix=B -- "$1" 2>/dev/null || printf '%s B\n' "$1"
}
