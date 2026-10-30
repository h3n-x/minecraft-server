#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  functions.sh — Utilidades del instalador: interfaz, registro, confirmaciones,
#  ejecución de comandos con modo simulación y escritura atómica de ficheros.
# =============================================================================

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
LOG_FILE=${LOG_FILE:-}
RUN_ID=$(date '+%Y%m%d-%H%M%S')
DEPLOY_CHANGED=0

SUMMARY_CHANGES=()
SUMMARY_SKIPPED=()
SUMMARY_PENDING=()
SUMMARY_WARNINGS=()
_TMP_PATHS=()

# -----------------------------------------------------------------------------
# Registro y mensajes
# -----------------------------------------------------------------------------

# _log_file NIVEL MENSAJE — Añade una línea al registro (nunca en simulación).
_log_file() {
  if [[ -n $LOG_FILE && $DRY_RUN -eq 0 ]]; then
    printf '%s [%-4s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

info()    { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; _log_file INFO "$*"; }
ok()      { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _log_file OK "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_file WARN "$*"; SUMMARY_WARNINGS+=("$*"); }
error()   { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log_file ERR "$*"; }
detail()  { printf '       %s\n' "$*"; _log_file INFO "  $*"; }
hint()    { printf '%s   ->%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; _log_file HINT "$*"; }
sim()     { printf '%s[SIM ]%s %s\n' "$C_MAGENTA" "$C_RESET" "$*"; }

# section TÍTULO — Encabezado de etapa.
section() {
  printf '\n%s%s━━ %s %s\n' "$C_BOLD" "$C_MAGENTA" "$*" "$C_RESET"
  _log_file STEP "$*"
}

# die MENSAJE [SUGERENCIA...] — Error con sugerencias de solución; termina.
die() {
  local msg=$1 h
  shift
  error "$msg"
  for h in "$@"; do
    hint "$h"
  done
  exit 1
}

record_change()  { SUMMARY_CHANGES+=("$*"); }
record_skip()    { SUMMARY_SKIPPED+=("$*"); }
record_pending() { SUMMARY_PENDING+=("$*"); }

# utf8_terminal — 0 si la terminal usa UTF-8 (para mostrar 木漏れ日).
utf8_terminal() {
  local cm
  cm=$(locale charmap 2>/dev/null || true)
  [[ $cm == UTF-8 ]]
}

# banner — Cabecera del instalador.
banner() {
  local jp='木漏れ日'
  utf8_terminal || jp='(komorebi)'
  printf '%s' "$C_GREEN"
  cat <<'ART'
 _  __  ___   __  __   ___   ___  ___  ___  ___
| |/ / / _ \ |  \/  | / _ \ | _ \| __|| _ )|_ _|
| ' < | (_) || |\/| || (_) ||   /| _| | _ \ | |
|_|\_\ \___/ |_|  |_| \___/ |_|_\|___||___/|___|
ART
  printf '%s' "$C_RESET"
  printf '%s=================================================%s\n' "$C_DIM" "$C_RESET"
  printf '  %sKOMOREBI SMP %s SERVER%s\n' "$C_BOLD" "$jp" "$C_RESET"
  printf '  Arch Linux Minecraft Server Installer  v%s\n' "$INSTALLER_VERSION"
  printf '  Paper %s · Java %s · systemd\n' "$MC_VERSION" "$JAVA_REQUIRED_MAJOR"
  printf '%s=================================================%s\n' "$C_DIM" "$C_RESET"
  if (( DRY_RUN )); then
    printf '  %sMODO SIMULACIÓN: no se modificará el sistema.%s\n' "$C_MAGENTA" "$C_RESET"
  fi
}

# -----------------------------------------------------------------------------
# Errores, limpieza y temporales
# -----------------------------------------------------------------------------

# on_error CÓDIGO LÍNEA COMANDO FICHERO — Manejador de la trampa ERR.
on_error() {
  local rc=$1 line=$2 cmd=$3 src=${4:-?}
  trap - ERR
  error "Fallo inesperado (código $rc) en ${src##*/}:$line"
  detail "Comando: $cmd"
  if [[ -n $LOG_FILE ]]; then
    hint "Revisa el registro: $LOG_FILE"
  fi
  hint "Corrige la causa y vuelve a ejecutar el instalador: es idempotente y no repetirá lo ya hecho."
  exit "$rc"
}

# register_tmp RUTA — Registra un temporal para borrarlo al salir.
register_tmp() {
  _TMP_PATHS+=("$1")
}

# make_tmp_file [DIR] — Crea un temporal (.komorebi-tmp.*) y lo registra.
# Imprime la ruta. Sin DIR usa $TMPDIR (permitido también en simulación).
make_tmp_file() {
  local dir=${1:-${TMPDIR:-/tmp}} t
  t=$(mktemp "$dir/.komorebi-tmp.XXXXXXXX")
  printf '%s\n' "$t"
}

# cleanup — Borra solo temporales propios (patrón .komorebi-tmp.*).
cleanup() {
  local p
  for p in "${_TMP_PATHS[@]}"; do
    if [[ -n $p && ${p##*/} == .komorebi-tmp.* && -e $p ]]; then
      rm -rf -- "$p"
    fi
  done
}

# -----------------------------------------------------------------------------
# Ejecución de comandos
# -----------------------------------------------------------------------------

# quote_cmd ARGS... — Representación legible y segura de un comando.
quote_cmd() {
  local parts=() a
  for a in "$@"; do
    parts+=("$(printf '%q' "$a")")
  done
  printf '%s' "${parts[*]}"
}

# run COMANDO [ARGS...] — Ejecuta un comando que modifica el sistema. En modo
# simulación solo lo muestra. Nunca usa eval: los argumentos se pasan tal cual.
run() {
  if (( DRY_RUN )); then
    sim "$(quote_cmd "$@")"
    return 0
  fi
  _log_file CMD "$(quote_cmd "$@")"
  "$@"
}

# require_cmd COMANDO... — Comprueba que existen los comandos indicados.
require_cmd() {
  local c missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    die "Faltan comandos necesarios: ${missing[*]}" \
        "Instala las dependencias con: sudo bash installer/install-komorebi.sh --dependencies"
  fi
}

# require_root — Termina si no se ejecuta como root (salvo en simulación).
require_root() {
  if [[ $EUID -ne 0 ]]; then
    if (( DRY_RUN )); then
      warn "Simulación sin root: algunas comprobaciones serán incompletas."
      return 0
    fi
    die "Esta operación necesita privilegios de administrador." \
        "Ejecuta: sudo bash installer/install-komorebi.sh $*"
  fi
}

# -----------------------------------------------------------------------------
# Confirmaciones
# -----------------------------------------------------------------------------

# confirm PREGUNTA [s|n] — Pregunta sí/no. --yes responde "sí"; sin terminal y
# en simulación se usa la respuesta por defecto (en simulación sin efectos,
# porque run() no ejecuta nada).
confirm() {
  local q=$1 def=${2:-n} ans prompt
  if [[ $def == s ]]; then prompt='[S/n]'; else prompt='[s/N]'; fi
  if (( DRY_RUN )); then
    if [[ $def == s ]]; then
      sim "$q $prompt -> respuesta por defecto: sí"
      return 0
    fi
    sim "$q $prompt -> respuesta por defecto: no"
    return 1
  fi
  if (( ASSUME_YES )); then
    info "$q -> sí (--yes)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    warn "$q -> sin terminal interactiva; se usa la respuesta por defecto ($def)."
    if [[ $def == s ]]; then return 0; else return 1; fi
  fi
  while true; do
    printf '%s[ ?? ]%s %s %s ' "$C_YELLOW" "$C_RESET" "$q" "$prompt"
    IFS= read -r ans || ans=''
    ans=${ans,,}
    case $ans in
      '') if [[ $def == s ]]; then return 0; else return 1; fi ;;
      s|si|sí|y|yes) _log_file ASK "$q -> sí"; return 0 ;;
      n|no) _log_file ASK "$q -> no"; return 1 ;;
      *) printf '       Responde "s" o "n".\n' ;;
    esac
  done
}

# confirm_typed PREGUNTA PALABRA — Confirmación reforzada: hay que escribir la
# palabra exacta. --yes NO la responde y en simulación se omite (devuelve 1).
confirm_typed() {
  local q=$1 word=$2 ans
  if (( DRY_RUN )); then
    sim "$q (requiere escribir '$word'; se omite en simulación)"
    return 1
  fi
  if [[ ! -t 0 ]]; then
    warn "$q -> requiere confirmación interactiva; se omite."
    return 1
  fi
  printf '%s[ ?? ]%s %s\n       Escribe %s%s%s para confirmar (cualquier otra cosa cancela): ' \
    "$C_YELLOW" "$C_RESET" "$q" "$C_BOLD" "$word" "$C_RESET"
  IFS= read -r ans || ans=''
  if [[ $ans == "$word" ]]; then
    _log_file ASK "$q -> confirmado ($word)"
    return 0
  fi
  _log_file ASK "$q -> cancelado"
  return 1
}

# -----------------------------------------------------------------------------
# Ficheros
# -----------------------------------------------------------------------------

# ensure_dir RUTA PROPIETARIO GRUPO MODO — Crea o ajusta un directorio (no
# recursivo, no destructivo).
ensure_dir() {
  local path=$1 owner=$2 group=$3 mode=$4 cur
  if [[ -d $path ]]; then
    cur=$(stat -c '%U:%G %a' -- "$path")
    if [[ $cur == "$owner:$group ${mode#0}" ]]; then
      return 0
    fi
    warn "Ajustando propietario/permisos de $path ($cur -> $owner:$group $mode)."
    run chown "$owner:$group" -- "$path"
    run chmod "$mode" -- "$path"
    record_change "Permisos ajustados: $path"
    return 0
  fi
  if [[ -e $path ]]; then
    die "$path existe pero no es un directorio." "Revísalo manualmente; el instalador no lo borrará."
  fi
  run install -d -o "$owner" -g "$group" -m "$mode" -- "$path"
  record_change "Directorio creado: $path ($owner:$group $mode)"
}

# backup_file RUTA — Copia un fichero existente a
# $BACKUP_DIR/installer/<RUN_ID>/<ruta original> antes de modificarlo.
backup_file() {
  local src=$1 dest
  [[ -e $src ]] || return 0
  dest="$BACKUP_DIR/installer/$RUN_ID$src"
  run install -d -m 0700 -- "$(dirname -- "$dest")"
  run cp -a -- "$src" "$dest"
  info "Copia de seguridad: $dest"
}

# install_file SRC DEST MODO PROPIETARIO GRUPO — Copia atómica (temporal en el
# mismo directorio + mv).
install_file() {
  local src=$1 dest=$2 mode=$3 owner=$4 group=$5 tmp
  if (( DRY_RUN )); then
    sim "instalar $dest ($owner:$group $mode)"
    return 0
  fi
  tmp=$(make_tmp_file "$(dirname -- "$dest")")
  register_tmp "$tmp"
  cp -- "$src" "$tmp"
  chown "$owner:$group" -- "$tmp"
  chmod "$mode" -- "$tmp"
  mv -f -- "$tmp" "$dest"
  _log_file FILE "escrito $dest"
}

# same_file A B — 0 si ambos ficheros tienen el mismo contenido. Usa cmp
# (paquete diffutils, que NO forma parte de 'base' en Arch) y, si no existe,
# compara SHA-256 (coreutils), para que la idempotencia no dependa de diffutils.
same_file() {
  [[ -f $1 && -f $2 ]] || return 1
  if command -v cmp >/dev/null 2>&1; then
    cmp -s -- "$1" "$2"
  else
    same_file_by_hash "$1" "$2"
  fi
}

# same_file_by_hash A B — Comparación por SHA-256 (alternativa a cmp).
same_file_by_hash() {
  [[ $(sha_of sha256 "$1") == "$(sha_of sha256 "$2")" ]]
}

# show_diff ACTUAL NUEVO — Muestra diferencias si diff está disponible.
show_diff() {
  local out
  if command -v diff >/dev/null 2>&1; then
    out=$(diff -u -- "$1" "$2" || true)
    printf '%s\n' "$out" | sed -n '1,80p'
  else
    detail "(diff no disponible: instala diffutils para ver las diferencias)"
  fi
}

# deploy_file SRC DEST MODO PROPIETARIO GRUPO DESCRIPCIÓN — Instala SRC en DEST
# de forma idempotente: si es idéntico no hace nada; si difiere muestra las
# diferencias, pide confirmación y guarda copia. Fija DEPLOY_CHANGED=1/0.
deploy_file() {
  local src=$1 dest=$2 mode=$3 owner=$4 group=$5 desc=$6
  DEPLOY_CHANGED=0
  if [[ -e $dest ]]; then
    if same_file "$src" "$dest"; then
      ok "$desc sin cambios: $dest"
      record_skip "$desc (sin cambios)"
      return 0
    fi
    warn "$desc ya existe y es diferente: $dest"
    show_diff "$dest" "$src"
    if ! confirm "¿Reemplazar $dest? (se guardará una copia de seguridad)" n; then
      record_skip "$desc (se conservó la versión existente)"
      return 0
    fi
    backup_file "$dest"
  fi
  install_file "$src" "$dest" "$mode" "$owner" "$group"
  DEPLOY_CHANGED=1
  ok "$desc instalado: $dest"
  record_change "$desc: $dest"
}

# render_template PLANTILLA SALIDA CLAVE=VALOR... — Sustituye @@CLAVE@@ por su
# valor (sin sed: sustitución literal de bash). Falla si queda algún marcador.
render_template() {
  local tpl=$1 out=$2 line kv key val
  shift 2
  [[ -r $tpl ]] || die "No se encuentra la plantilla $tpl." "Ejecuta el instalador desde la carpeta completa del proyecto."
  : >"$out"
  while IFS= read -r line || [[ -n $line ]]; do
    for kv in "$@"; do
      key=${kv%%=*}
      val=${kv#*=}
      line=${line//"@@${key}@@"/"$val"}
    done
    printf '%s\n' "$line" >>"$out"
  done <"$tpl"
  if grep -q '@@[A-Z0-9_]*@@' -- "$out"; then
    die "La plantilla $tpl tiene marcadores sin resolver." "Informa del error: es un fallo del instalador."
  fi
}

# sha_of ALGORITMO FICHERO — Imprime el hash (sha256 o sha512).
sha_of() {
  local algo=$1 file=$2 out
  case $algo in
    sha256) out=$(sha256sum -- "$file") ;;
    sha512) out=$(sha512sum -- "$file") ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${out%% *}"
}

# http_user_agent — User-Agent exigido por PaperMC (software + contacto).
http_user_agent() {
  printf 'komorebi-smp-installer/%s (+%s)' "$INSTALLER_VERSION" "$HTTP_CONTACT"
}

# http_get_json URL — Descarga JSON por HTTPS a stdout. Falla si HTTP != 200.
# Se usa dentro de $(...): borra su propio temporal (no puede registrarlo).
http_get_json() {
  local url=$1 tmp code rc=0
  tmp=$(make_tmp_file)
  code=$(curl --proto '=https' --tlsv1.2 -sS -L --proto-redir '=https' \
    --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 3 \
    -A "$(http_user_agent)" -H 'Accept: application/json' \
    -o "$tmp" -w '%{http_code}' -- "$url") || rc=$?
  if (( rc != 0 )); then
    error "No se pudo contactar con $url (curl código $rc)"
  elif [[ $code != 200 ]]; then
    error "Respuesta HTTP $code de $url"
    rc=1
  else
    cat -- "$tmp"
  fi
  rm -f -- "$tmp"
  return "$rc"
}

# http_download URL DESTINO — Descarga un fichero por HTTPS (también en
# redirecciones). Falla si HTTP != 200.
http_download() {
  local url=$1 dest=$2 code
  code=$(curl --proto '=https' --tlsv1.2 -sS -L --proto-redir '=https' \
    --connect-timeout 15 --max-time 900 --retry 3 --retry-delay 5 \
    -A "$(http_user_agent)" -o "$dest" -w '%{http_code}' -- "$url") || {
    error "Falló la descarga de $url"
    return 1
  }
  if [[ $code != 200 ]]; then
    error "Respuesta HTTP $code al descargar $url"
    return 1
  fi
}

# print_summary — Resumen final de operaciones.
print_summary() {
  local i
  section "Resumen"
  if (( ${#SUMMARY_CHANGES[@]} )); then
    printf '%sCambios realizados%s%s:\n' "$C_BOLD" "$( (( DRY_RUN )) && printf ' (simulados)')" "$C_RESET"
    for i in "${SUMMARY_CHANGES[@]}"; do printf '  + %s\n' "$i"; done
  else
    printf '%sSin cambios en el sistema.%s\n' "$C_BOLD" "$C_RESET"
  fi
  if (( ${#SUMMARY_SKIPPED[@]} )); then
    printf '%sSin cambios / omitido:%s\n' "$C_BOLD" "$C_RESET"
    for i in "${SUMMARY_SKIPPED[@]}"; do printf '  = %s\n' "$i"; done
  fi
  if (( ${#SUMMARY_WARNINGS[@]} )); then
    printf '%sAvisos:%s\n' "$C_BOLD$C_YELLOW" "$C_RESET"
    for i in "${SUMMARY_WARNINGS[@]}"; do printf '  ! %s\n' "$i"; done
  fi
  if (( ${#SUMMARY_PENDING[@]} )); then
    printf '%sAcciones manuales pendientes:%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
    for i in "${SUMMARY_PENDING[@]}"; do printf '  > %s\n' "$i"; done
  fi
  if [[ -n $LOG_FILE && $DRY_RUN -eq 0 ]]; then
    printf '\nRegistro completo: %s\n' "$LOG_FILE"
  fi
}
