#!/usr/bin/env bash
# =============================================================================
#  run-tests.sh — Pruebas del instalador KOMOREBI SMP (no destructivas).
#
#  * Estáticas: bash -n y ShellCheck (si está disponible o SHELLCHECK=ruta).
#  * Funcionales: en un sandbox temporal, con root simulado (unshare -r) y
#    stubs de systemctl/journalctl/pgrep/pacman. Nunca tocan /var/lib/minecraft,
#    /etc, systemd ni pacman reales.
#  * De red (desactivables con KOMOREBI_TEST_OFFLINE=1): API de Paper, descarga
#    y verificación de paper.jar y de un plugin.
#
#  Uso: bash tests/run-tests.sh
# =============================================================================
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(dirname -- "$TESTS_DIR")

# Detección de root: antes de entrar en el espacio de nombres, como usuario
# normal, el instalador debe negarse a modificar el sistema.
if [[ $EUID -ne 0 && -z ${KOMOREBI_TEST_NS:-} ]]; then
  _out=$(KOMOREBI_NO_COLOR=1 KOMOREBI_CONFIG=/nonexistent bash "$PROJECT_DIR/installer/install-komorebi.sh" --paper </dev/null 2>&1)
  _rc=$?
  if (( _rc != 0 )) && [[ $_out == *"Se necesitan privilegios de administrador"* && $_out == *"no se ha modificado nada"* ]]; then
    export KOMOREBI_TEST_NONROOT=pass
  else
    export KOMOREBI_TEST_NONROOT="fail (código $_rc)"
  fi
  # Root simulado: un espacio de nombres de usuario permite probar chown/chmod
  # y las comprobaciones de "propiedad de root" sin privilegios reales.
  if command -v unshare >/dev/null 2>&1 && unshare -r true 2>/dev/null; then
    exec env KOMOREBI_TEST_NS=1 unshare -r bash "$0" "$@"
  fi
fi

PASS=0 FAIL=0 SKIP=0
OFFLINE=${KOMOREBI_TEST_OFFLINE:-0}
SHELLCHECK=${SHELLCHECK:-$(command -v shellcheck || true)}
WORK=$(mktemp -d /tmp/komorebi-tests.XXXXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
STUBS="$WORK/stubs"
export STUB_STATE="$WORK/stubstate"
mkdir -p "$STUBS" "$STUB_STATE"

section() { printf '\n== %s ==\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  [SKIP] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }

# run_test NOMBRE FUNCIÓN — Ejecuta FUNCIÓN en un subshell; pasa si sale con 0.
run_test() {
  local name=$1 fn=$2 log="$WORK/last.log" rc
  ( "$fn" ) >"$log" 2>&1
  rc=$?
  if (( rc == 0 )); then
    pass "$name"
  else
    fail "$name (código $rc)"
    sed -n '1,400p' "$log" | tail -n 25 | sed 's/^/         | /'
  fi
}

assert_eq() { if [[ $1 != "$2" ]]; then printf 'ASSERT: %s\n  esperado: [%s]\n  obtenido: [%s]\n' "$3" "$2" "$1"; exit 1; fi; }
assert_true() { if ! eval "$1"; then printf 'ASSERT: %s\n' "$2"; exit 1; fi; }
assert_contains() { if [[ $1 != *"$2"* ]]; then printf 'ASSERT: %s\n  no contiene: [%s]\n' "$3" "$2"; exit 1; fi; }

# -----------------------------------------------------------------------------
# Stubs
# -----------------------------------------------------------------------------
cat >"$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
# Stub de systemctl. Estado del servidor y del socket en $STUB_STATE/state;
# otras unidades en $STUB_STATE/unit-<unidad> (por defecto inactive).
printf 'systemctl %s\n' "$*" >>"$STUB_STATE/calls"
cmd=$1; shift
quiet=0
for a in "$@"; do [[ $a == --quiet || $a == -q ]] && quiet=1; done
unit=${*: -1}
unit_state() {
  if [[ -f $STUB_STATE/unit-$1 ]]; then cat "$STUB_STATE/unit-$1"
  elif [[ $1 == komorebi.service || $1 == komorebi-console.socket ]]; then cat "$STUB_STATE/state" 2>/dev/null || echo inactive
  else echo inactive; fi
}
case $cmd in
  is-active) st=$(unit_state "$unit"); (( quiet )) || echo "$st"; [[ $st == active ]] ;;
  is-enabled)
    if [[ -f $STUB_STATE/enabled-$unit ]]; then (( quiet )) || echo enabled; exit 0; fi
    (( quiet )) || echo disabled; exit 1 ;;
  enable) for u in "$@"; do [[ $u == -* ]] || touch "$STUB_STATE/enabled-$u"; done ;;
  is-failed) unit_state "$unit"; exit 1 ;;
  is-system-running) echo running ;;
  show)
    case "$*" in
      *MainPID*) echo 4242 ;; *NRestarts*) echo 0 ;; *MemoryCurrent*) echo 1073741824 ;;
      *MemoryMax*) echo 6442450944 ;; *Monotonic*) echo 0 ;;
      *NeedDaemonReload*) cat "$STUB_STATE/needreload" 2>/dev/null || echo no ;;
      *Result*) cat "$STUB_STATE/result" 2>/dev/null || echo success ;;
      *) echo "" ;;
    esac ;;
  start)
    if [[ -n ${STUB_PARTIAL_GLOB:-} ]] && compgen -G "$STUB_PARTIAL_GLOB" >/dev/null; then
      echo "partial-present" >>"$STUB_STATE/calls"
    fi
    echo active >"$STUB_STATE/state" ;;
  stop) echo inactive >"$STUB_STATE/state" ;;
  *) : ;;
esac
EOF
cat >"$STUBS/journalctl" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_STATE/journal" 2>/dev/null || true
EOF
cat >"$STUBS/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$STUBS/pacman" <<'EOF'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >>"$STUB_STATE/calls"
case $1 in
  -T) shift; [[ -f $STUB_STATE/pacman-installed ]] && exit 0; printf '%s\n' "$@"; exit 127 ;;
  -Syu) touch "$STUB_STATE/pacman-installed" ;;
  -Q) [[ ${2:-} == pacman ]] && { echo 'pacman 7.0.0-1'; exit 0; }; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

# new_sandbox — Árbol de directorios aislado y configuración de prueba.
new_sandbox() {
  SANDBOX=$(mktemp -d "$WORK/sb.XXXXXXXX")
  mkdir -p "$SANDBOX"/{var/lib/minecraft/plugins,var/backups/minecraft/{daily,weekly,manual,installer},var/log/komorebi,etc/komorebi,run,usr/local/lib/komorebi,usr/local/sbin,etc/systemd/system}
  cat >"$SANDBOX/etc/komorebi/komorebi.conf" <<EOF
MC_DIR=$SANDBOX/var/lib/minecraft
BACKUP_DIR=$SANDBOX/var/backups/minecraft
LOG_DIR=$SANDBOX/var/log/komorebi
CONSOLE_FIFO=$SANDBOX/run/console
MC_USER=$(id -un)
MC_GROUP=$(id -gn)
BACKUP_COMPRESSION=gzip
BACKUP_STOP_WARNING=0
BACKUP_KEEP_DAILY=2
BACKUP_KEEP_WEEKLY=4
JAVA_BIN=/usr/bin/true
EOF
  chmod 0644 "$SANDBOX/etc/komorebi/komorebi.conf"
  export KOMOREBI_CONFIG="$SANDBOX/etc/komorebi/komorebi.conf"
  echo inactive >"$STUB_STATE/state"
  : >"$STUB_STATE/calls"
  : >"$STUB_STATE/journal"
  rm -f "$STUB_STATE"/enabled-* "$STUB_STATE"/unit-* "$STUB_STATE"/needreload "$STUB_STATE"/result "$STUB_STATE"/pacman-installed
  unset STUB_PARTIAL_GLOB
}

# fake_world — Datos de servidor ficticios.
fake_world() {
  local d="$SANDBOX/var/lib/minecraft"
  mkdir -p "$d/world/region" "$d/world_nether" "$d/plugins/Essentials/userdata" "$d/cache" "$d/logs"
  echo "LEVEL-ORIGINAL" >"$d/world/level.dat"
  head -c 4096 /dev/urandom >"$d/world/region/r.0.0.mca"
  echo "money: 1250" >"$d/plugins/Essentials/userdata/steve.yml"
  echo "eula=true" >"$d/eula.txt"
  printf 'motd=test\nonline-mode=true\n' >"$d/server.properties"
  echo "cache" >"$d/cache/mojang.jar"
  echo "log" >"$d/logs/latest.log"
}

# load_installer — Carga los módulos del instalador con rutas del sandbox.
load_installer() {
  INSTALLER_DIR="$PROJECT_DIR/installer"
  # shellcheck source=../scripts/komorebi-common.sh
  source "$PROJECT_DIR/scripts/komorebi-common.sh"
  local m
  for m in config functions system dependencies java papermc plugins systemd security backup; do
    # shellcheck disable=SC1090
    source "$INSTALLER_DIR/$m.sh"
  done
  KOMOREBI_NO_COLOR=1 k_init_colors
  k_set_defaults
  k_load_config "$KOMOREBI_CONFIG"
  k_units
  CONFIG_DIR="$SANDBOX/etc/komorebi"
  LIB_DIR="$SANDBOX/usr/local/lib/komorebi"
  BIN_DIR="$SANDBOX/usr/local/sbin"
  SYSTEMD_UNIT_DIR="$SANDBOX/etc/systemd/system"
  PLUGINS_MANIFEST_FILE="$CONFIG_DIR/plugins-manifest.conf"
  VERSIONS_STATE_FILE="$CONFIG_DIR/installed-versions.txt"
  DETECTED_RAM_MB=7800
  ASSUME_YES=1
  KERNEL_MODULES_DIR="$SANDBOX/no-modules"
  trap cleanup EXIT
}

# =============================================================================
section "Pruebas estáticas"
# =============================================================================
for f in "$PROJECT_DIR"/installer/*.sh "$PROJECT_DIR"/scripts/*.sh "$PROJECT_DIR"/tests/*.sh; do
  if bash -n "$f" 2>"$WORK/bn.log"; then pass "bash -n ${f#"$PROJECT_DIR"/}"; else fail "bash -n ${f#"$PROJECT_DIR"/}"; cat "$WORK/bn.log"; fi
done
if [[ -n $SHELLCHECK ]]; then
  if "$SHELLCHECK" -x -P "$PROJECT_DIR/installer" -P "$PROJECT_DIR/scripts" -S style \
       "$PROJECT_DIR/installer/install-komorebi.sh" "$PROJECT_DIR"/scripts/*-komorebi.sh >"$WORK/sc.log" 2>&1; then
    pass "ShellCheck (estilo) en instalador y scripts, siguiendo los 'source'"
  else
    fail "ShellCheck"; sed 's/^/         | /' "$WORK/sc.log" | tail -n 30
  fi
else
  skip "ShellCheck no disponible"
fi
for f in "$PROJECT_DIR"/installer/install-komorebi.sh "$PROJECT_DIR"/scripts/*-komorebi.sh; do
  if [[ -x $f ]]; then pass "ejecutable: ${f#"$PROJECT_DIR"/}"; else fail "no ejecutable: ${f#"$PROJECT_DIR"/}"; fi
done
if grep -RInE 'chmod[[:space:]]+(-R[[:space:]]+)?0?777|^[^#]*(^|[;&|[:space:]])eval[[:space:]]' "$PROJECT_DIR/installer" "$PROJECT_DIR/scripts" >"$WORK/grep.log"; then
  fail "Se encontró chmod 777 o eval"; cat "$WORK/grep.log"
else
  pass "Sin chmod 777 ni eval en instalador y scripts"
fi
# Se ignoran comentarios y el consejo oficial de recuperación del keyring que
# solo se MUESTRA al usuario (pacman -Sy archlinux-keyring && pacman -Su).
if grep -RIhE 'pacman -Sy[^u]|-Sy\)' "$PROJECT_DIR/installer" | grep -vE '^[[:space:]]*#|archlinux-keyring' | grep -q .; then fail "Actualización parcial (pacman -Sy) detectada"; else pass "Sin actualizaciones parciales (pacman -Sy) ejecutables"; fi
if grep -RIhE 'kill -9|kill -KILL|-s KILL|SIGKILL' "$PROJECT_DIR/scripts" | grep -vE '^[[:space:]]*#' | grep -q .; then fail "kill -9 en los scripts"; else pass "Sin kill -9 en los scripts de administración"; fi

# =============================================================================
section "CLI del instalador"
# =============================================================================
t_cli() {
  local out rc
  out=$(bash "$PROJECT_DIR/installer/install-komorebi.sh" --help); rc=$?
  assert_eq "$rc" 0 "--help sale con 0"
  assert_contains "$out" "--dependencies" "--help documenta --dependencies"
  out=$(bash "$PROJECT_DIR/installer/install-komorebi.sh" --version)
  assert_eq "$out" "KOMOREBI SMP installer $(cat "$PROJECT_DIR/VERSION")" "--version"
  bash "$PROJECT_DIR/installer/install-komorebi.sh" --bogus >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 2 "opción desconocida → código 2"
  bash "$PROJECT_DIR/installer/install-komorebi.sh" --paper --plugins >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 2 "dos modos → código 2"
}
run_test "Argumentos: --help, --version, opción inválida, modos incompatibles" t_cli

t_check_mode() {
  local out rc
  export KOMOREBI_CONFIG="$WORK/no-existe.conf"
  out=$(KOMOREBI_NO_COLOR=1 bash "$PROJECT_DIR/installer/install-komorebi.sh" --check 2>&1); rc=$?
  assert_eq "$rc" 0 "--check es de solo lectura y termina con 0"
  assert_contains "$out" "Informe de hardware" "--check muestra el informe de hardware"
  assert_contains "$out" "Estado de la instalación" "--check muestra el estado"
  if [[ $(. /etc/os-release && echo "$ID") != arch ]]; then
    assert_contains "$out" "Sistema no compatible" "detecta que no es Arch Linux"
  fi
}
run_test "--check: detección de sistema (no Arch) sin modificar nada" t_check_mode

case ${KOMOREBI_TEST_NONROOT:-} in
  pass) pass "Sin root, --paper se niega con instrucciones y sin modificar nada" ;;
  '') skip "Detección de root (las pruebas ya se lanzaron como root)" ;;
  *) fail "Detección de root: $KOMOREBI_TEST_NONROOT" ;;
esac

t_dry_run() {
  local out rc before after
  printf 'NAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\nID=arch\n' >"$WORK/os-release-arch"
  export KOMOREBI_OS_RELEASE_FILE="$WORK/os-release-arch"
  export KOMOREBI_CONFIG="$WORK/no-existe.conf"
  before=$(ls -d /var/lib/minecraft /etc/komorebi /var/backups/minecraft /var/log/komorebi /etc/systemd/system/komorebi.service 2>/dev/null | wc -l)
  out=$(KOMOREBI_NO_COLOR=1 bash "$PROJECT_DIR/installer/install-komorebi.sh" --dry-run </dev/null 2>&1); rc=$?
  after=$(ls -d /var/lib/minecraft /etc/komorebi /var/backups/minecraft /var/log/komorebi /etc/systemd/system/komorebi.service 2>/dev/null | wc -l)
  printf '%s\n' "$out" | tail -n 40
  assert_eq "$rc" 0 "--dry-run termina con 0"
  assert_eq "$after" "$before" "--dry-run no crea rutas del sistema"
  assert_contains "$out" "MODO SIMULACIÓN" "banner de simulación"
  assert_contains "$out" "[SIM ]" "las acciones se muestran como simulación"
  assert_contains "$out" "useradd --system" "simula la creación del usuario"
  assert_contains "$out" "pacman -Syu --needed" "simula pacman -Syu --needed"
  assert_contains "$out" "se omite en simulación" "el EULA nunca se acepta en simulación"
  if [[ $OFFLINE != 1 ]]; then assert_contains "$out" "build 196" "consulta la build 196 en la API"; fi
  if grep -q '^pacman -Syu' "$STUB_STATE/calls" 2>/dev/null; then echo "pacman real invocado"; exit 1; fi
}
run_test "--dry-run completo (os-release Arch simulado): sin efectos" t_dry_run

# =============================================================================
section "Configuración y validación"
# =============================================================================
t_config_parser() {
  new_sandbox; load_installer
  cat >>"$KOMOREBI_CONFIG" <<'EOF'
# comentario
JVM_XMX="3G"
BACKUP_ONCALENDAR='*-*-* 05:00:00'
DESCONOCIDA=1
esto no es valido
EOF
  k_set_defaults
  k_load_config "$KOMOREBI_CONFIG" 2>"$WORK/warn.log"
  assert_eq "$JVM_XMX" 3G "comillas dobles eliminadas"
  assert_eq "$BACKUP_ONCALENDAR" '*-*-* 05:00:00' "comillas simples eliminadas"
  assert_contains "$(cat "$WORK/warn.log")" "clave desconocida 'DESCONOCIDA'" "clave desconocida avisada"
  assert_contains "$(cat "$WORK/warn.log")" "formato no válido" "línea inválida avisada"
  k_validate_config || { echo "config válida rechazada"; exit 1; }
  chmod 0666 "$KOMOREBI_CONFIG"
  if k_load_config "$KOMOREBI_CONFIG" 2>/dev/null; then echo "aceptó config escribible por otros"; exit 1; fi
  chmod 0644 "$KOMOREBI_CONFIG"
  JVM_XMS=8G; JVM_XMX=4G
  if k_validate_config 2>/dev/null; then echo "aceptó Xms > Xmx"; exit 1; fi
  k_set_defaults; MC_DIR="/var/lib/../etc"
  if k_validate_config 2>/dev/null; then echo "aceptó ruta con .."; exit 1; fi
  k_set_defaults; JVM_FLAGS="-Xmx1G;rm"
  if k_validate_config 2>/dev/null; then echo "aceptó flag con ;"; exit 1; fi
  k_set_defaults; BACKUP_DIR="/var/lib/minecraft/backups"
  if k_validate_config 2>/dev/null; then echo "aceptó backups dentro de MC_DIR"; exit 1; fi
  k_set_defaults; k_validate_config
}
run_test "Lector seguro de komorebi.conf y validación de valores" t_config_parser

t_memory() {
  new_sandbox; load_installer
  DETECTED_RAM_MB=7800; recommend_heap
  assert_eq "$RECOMMENDED_XMX/$RECOMMENDED_XMS" "4G/2G" "8 GB → -Xmx4G -Xms2G"
  DETECTED_RAM_MB=6000; recommend_heap
  assert_eq "$RECOMMENDED_XMX" "3G" "6 GB → 3G"
  DETECTED_RAM_MB=4000; recommend_heap
  assert_eq "$RECOMMENDED_XMX" "2G" "4 GB → 2G"
  DETECTED_RAM_MB=7800; JVM_XMX=4G; compute_memory_limits
  assert_eq "$MEMORY_MAX_MB" 6144 "MemoryMax = Xmx + 2 GiB"
  if ( DETECTED_RAM_MB=4096; JVM_XMX=4G; compute_memory_limits ) >/dev/null 2>&1; then echo "aceptó Xmx igual a la RAM"; exit 1; fi
}
run_test "Memoria: recomendación según RAM y MemoryMax" t_memory

t_lan() {
  new_sandbox; load_installer
  assert_eq "$(lan_network_of 192.168.1.23/24)" "192.168.1.0/24" "LAN 192.168"
  assert_eq "$(lan_network_of 10.20.30.40/8)" "10.0.0.0/8" "LAN 10/8"
  assert_eq "$(lan_network_of 172.20.5.9/16)" "172.20.0.0/16" "LAN 172.16/12"
  if lan_network_of 8.8.8.8/24 >/dev/null; then echo "aceptó IP pública"; exit 1; fi
  if lan_network_of 100.64.1.1/10 >/dev/null; then echo "aceptó CGNAT como LAN"; exit 1; fi
}
run_test "Cálculo de la red local para la regla SSH de ufw" t_lan

# =============================================================================
section "server.properties"
# =============================================================================
t_properties() {
  local f out1 out2 kv k
  new_sandbox; load_installer
  build_server_properties
  f="$WORK/sp.properties"
  printf '#Minecraft server properties\r\n# comentario propio\r\nlevel-name=komorebi\r\nview-distance=12\r\nmotd = viejo\r\nview-distance=14\r\nsome-key: x\r\n' >"$f"
  out1="$WORK/sp1"; out2="$WORK/sp2"
  properties_render "$f" "$out1" "${SERVER_PROPERTIES[@]}"
  properties_render "$out1" "$out2" "${SERVER_PROPERTIES[@]}"
  cmp -s "$out1" "$out2" || { echo "no idempotente"; diff "$out1" "$out2"; exit 1; }
  assert_contains "$(cat "$out1")" "# comentario propio" "conserva comentarios"
  assert_contains "$(cat "$out1")" "level-name=komorebi" "conserva claves ajenas"
  assert_contains "$(cat "$out1")" "some-key: x" "conserva formato de claves ajenas"
  assert_eq "$(grep -c '^view-distance=' "$out1")" 1 "elimina duplicados de claves gestionadas"
  assert_eq "$(properties_get "$out1" view-distance)" 7 "view-distance=7"
  assert_eq "$(properties_get "$out1" motd)" '\u00A7d\u6728\u6F0F\u308C\u65E5 \u00A7f| \u00A7aKOMOREBI SMP' "MOTD con escapes"
  assert_eq "$(properties_get "$out1" online-mode)" true "online-mode=true"
  assert_eq "$(properties_get "$out1" enable-rcon)" false "RCON desactivado"
  if grep -q $'\r' "$out1"; then echo "quedaron CR"; exit 1; fi
  # El ejemplo del repositorio coincide con lo que genera el instalador.
  for kv in "${SERVER_PROPERTIES[@]}"; do
    k=${kv%%=*}
    assert_eq "$(properties_get "$PROJECT_DIR/config/server.properties.example" "$k")" "${kv#*=}" "ejemplo: $k"
  done
  # El MOTD escapado se decodifica como 木漏れ日.
  if command -v python3 >/dev/null; then
    assert_eq "$(properties_get "$out1" motd | python3 -c 'import sys; print(sys.stdin.read().strip().encode().decode("unicode_escape"))')" "§d木漏れ日 §f| §aKOMOREBI SMP" "decodificación del MOTD"
  fi
}
run_test "Editor de server.properties: conserva, deduplica, idempotente, CRLF" t_properties

t_properties_flow() {
  local f
  new_sandbox; load_installer
  f="$MC_DIR/server.properties"
  configure_server_properties >/dev/null
  assert_true "[[ -f $f ]]" "crea server.properties"
  SUMMARY_CHANGES=()
  configure_server_properties >/dev/null
  assert_eq "${#SUMMARY_CHANGES[@]}" 0 "segunda ejecución sin cambios"
  sed -i 's/^online-mode=true$/online-mode=false/' "$f"
  printf 'view-distance=12\n' >>"$f"
  assert_eq "$(properties_get "$f" view-distance)" 12 "con claves repetidas gana la última (java.util.Properties)"
  configure_server_properties >/dev/null 2>&1
  assert_eq "$(properties_get "$f" view-distance)" 7 "duplicado resuelto"
  assert_eq "$(grep -c '^view-distance=' "$f")" 1 "una sola view-distance"
  assert_eq "$(properties_get "$f" online-mode)" true "restaura online-mode=true (con --yes)"
  assert_true "compgen -G '$BACKUP_DIR/installer/*$f' >/dev/null" "copia de seguridad previa"
}
run_test "server.properties: creación, idempotencia y copia previa" t_properties_flow

# =============================================================================
section "Plantillas y systemd"
# =============================================================================
t_templates() {
  local t out
  new_sandbox; load_installer
  compute_memory_limits
  unit_render_args
  for t in komorebi.service komorebi-console.socket komorebi-backup.service komorebi-backup.timer; do
    render_template "$PROJECT_DIR/systemd/$t" "$SANDBOX/etc/systemd/system/$t" "${UNIT_ARGS[@]}"
    if grep -q '@@' "$SANDBOX/etc/systemd/system/$t"; then echo "marcadores en $t"; exit 1; fi
  done
  out=$(cat "$SANDBOX/etc/systemd/system/komorebi.service")
  assert_contains "$out" "User=$MC_USER" "User="
  assert_contains "$out" "StandardOutput=journal" "salida al journal"
  assert_contains "$out" "-Xms2G -Xmx4G" "memoria 2G/4G"
  assert_contains "$out" "MemoryMax=6144M" "MemoryMax"
  assert_contains "$out" "SuccessExitStatus=0 143" "SIGTERM = salida correcta"
  assert_contains "$out" "StartLimitBurst=3" "límite de reinicios"
  if grep -q '^MemoryDenyWriteExecute' <<<"$out"; then echo "MemoryDenyWriteExecute rompe el JIT"; exit 1; fi
  render_template "$PROJECT_DIR/config/komorebi.conf.example" "$WORK/k.conf" \
    INSTALLER_VERSION=1 GENERATED=x MC_VERSION="$MC_VERSION" PAPER_BUILD="$PAPER_BUILD" PAPER_SHA256="$PAPER_SHA256" \
    JAVA_BIN="$JAVA_BIN" JVM_XMS=2G JVM_XMX=4G JVM_FLAGS="$JVM_FLAGS" MC_USER=minecraft MC_GROUP=minecraft \
    MC_DIR=/var/lib/minecraft BACKUP_DIR=/var/backups/minecraft LOG_DIR=/var/log/komorebi SERVICE_NAME=komorebi \
    CONSOLE_FIFO=/run/komorebi/console SERVER_PORT=25565 MAX_PLAYERS=10 VIEW_DISTANCE=7 SIMULATION_DISTANCE=5 \
    STOP_TIMEOUT=180 BACKUP_MODE=stop BACKUP_COMPRESSION=zstd BACKUP_KEEP_DAILY=7 BACKUP_KEEP_WEEKLY=4 \
    BACKUP_KEEP_MANUAL=0 BACKUP_WEEKLY_DAY=7 "BACKUP_ONCALENDAR=*-*-* 04:30:00" BACKUP_STOP_WARNING=60 \
    BACKUP_MAX_AGE_HOURS=36 "HTTP_CONTACT=$HTTP_CONTACT"
  chmod 0644 "$WORK/k.conf"
  k_set_defaults; k_load_config "$WORK/k.conf" 2>"$WORK/w"; k_validate_config
  assert_eq "$(cat "$WORK/w")" "" "komorebi.conf generado sin avisos"
  assert_eq "$JVM_FLAGS" "$(k_set_defaults; printf '%s' "$JVM_FLAGS")" "JVM_FLAGS conserva los flags"
}
run_test "Renderizado de unidades systemd y de komorebi.conf" t_templates

t_systemd_verify() {
  local out bad
  command -v systemd-analyze >/dev/null || { echo "SKIP"; exit 0; }
  new_sandbox; load_installer
  JAVA_BIN=/usr/bin/true
  compute_memory_limits; unit_render_args
  for t in komorebi.service komorebi-console.socket komorebi-backup.service komorebi-backup.timer; do
    render_template "$PROJECT_DIR/systemd/$t" "$SANDBOX/etc/systemd/system/$t" "${UNIT_ARGS[@]}"
  done
  # Sin systemd como init, "verify" solo funciona en modo --user con un
  # XDG_RUNTIME_DIR propio; el análisis de sintaxis es el mismo.
  export XDG_RUNTIME_DIR="$WORK/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
  out=$(cd "$SANDBOX/etc/systemd/system" && systemd-analyze --user verify --man=no \
        ./komorebi.service ./komorebi-console.socket ./komorebi-backup.service ./komorebi-backup.timer 2>&1 || true)
  printf '%s\n' "$out"
  # Único aviso admitido: el script de backup aún no está instalado aquí.
  bad=$(grep -v 'backup-komorebi.sh is not executable' <<<"$out" | grep -v '^$' || true)
  assert_eq "$bad" "" "systemd-analyze verify sin errores ni claves desconocidas"
  # Control: una clave mal escrita sí se detecta.
  sed 's/^TimeoutStopSec=/TimeoutStopSecc=/' "$SANDBOX/etc/systemd/system/komorebi.service" >"$WORK/bad.service"
  out=$(systemd-analyze --user verify --man=no "$WORK/bad.service" 2>&1 || true)
  assert_contains "$out" "Unknown key" "el verificador detecta errores (prueba de control)"
}
run_test "systemd-analyze verify: sintaxis de las unidades" t_systemd_verify

t_service_idempotent() {
  new_sandbox; load_installer
  touch "$MC_DIR/paper.jar"
  java_ready() { return 0; }
  install_admin_scripts >/dev/null
  install_service_units >/dev/null
  assert_true "[[ -f $SYSTEMD_UNIT_DIR/komorebi.service && -f $SYSTEMD_UNIT_DIR/komorebi-console.socket ]]" "unidades instaladas"
  assert_true "[[ -L $BIN_DIR/backup-komorebi.sh ]]" "enlaces de scripts"
  assert_eq "$(stat -c %a "$SYSTEMD_UNIT_DIR/komorebi.service")" 644 "permisos de la unidad"
  assert_eq "$(grep -c 'daemon-reload' "$STUB_STATE/calls")" 1 "daemon-reload tras instalar"
  SUMMARY_CHANGES=()
  install_admin_scripts >/dev/null
  install_service_units >/dev/null
  assert_eq "${#SUMMARY_CHANGES[@]}" 0 "segunda ejecución: sin cambios"
  assert_eq "$(grep -c 'daemon-reload' "$STUB_STATE/calls")" 1 "sin daemon-reload innecesario"
}
run_test "Instalación de scripts y unidades: idempotente" t_service_idempotent


t_diffutils_hash() {
  local a="$WORK/h1" c="$WORK/h2"
  new_sandbox; load_installer
  assert_contains " ${REQUIRED_PACKAGES[*]} " " diffutils " "diffutils en los paquetes necesarios"
  echo uno >"$a"; echo uno >"$c"
  same_file_by_hash "$a" "$c" || { echo "iguales no detectados"; exit 1; }
  echo dos >"$c"
  if same_file_by_hash "$a" "$c"; then echo "distintos tomados por iguales"; exit 1; fi
}
run_test "Comparación de ficheros sin cmp (diffutils no está en base)" t_diffutils_hash

t_eula_gating() {
  new_sandbox; load_installer
  touch "$MC_DIR/paper.jar"
  printf 'eula=false\n' >"$MC_DIR/eula.txt"
  java_ready() { return 0; }
  install_service_units >/dev/null
  assert_true "[[ -f $STUB_STATE/enabled-komorebi-console.socket ]]" "socket habilitado"
  assert_true "[[ ! -f $STUB_STATE/enabled-komorebi.service ]]" "sin EULA el servicio NO se habilita"
  printf 'eula=true\n' >"$MC_DIR/eula.txt"
  enable_service_if_eula >/dev/null
  assert_true "[[ -f $STUB_STATE/enabled-komorebi.service ]]" "con EULA el servicio se habilita"
}
run_test "El servicio solo se habilita al arranque con el EULA aceptado" t_eula_gating

t_need_reload() {
  new_sandbox; load_installer
  touch "$MC_DIR/paper.jar"
  java_ready() { return 0; }
  install_service_units >/dev/null
  : >"$STUB_STATE/calls"
  install_service_units >/dev/null
  assert_eq "$(grep -c daemon-reload "$STUB_STATE/calls")" 0 "sin cambios ni recarga pendiente: no recarga"
  echo yes >"$STUB_STATE/needreload"
  install_service_units >/dev/null
  assert_eq "$(grep -c daemon-reload "$STUB_STATE/calls")" 1 "NeedDaemonReload=yes: recarga aunque el fichero no cambie"
}
run_test "daemon-reload tras una ejecución interrumpida (NeedDaemonReload)" t_need_reload

t_timer_restart() {
  new_sandbox; load_installer
  install_backup_units >/dev/null
  assert_true "[[ -f $STUB_STATE/enabled-komorebi-backup.timer ]]" "temporizador habilitado"
  echo active >"$STUB_STATE/unit-komorebi-backup.timer"
  BACKUP_ONCALENDAR="*-*-* 03:15:00"
  install_backup_units >/dev/null 2>&1
  assert_contains "$(cat "$SYSTEMD_UNIT_DIR/komorebi-backup.timer")" "OnCalendar=*-*-* 03:15:00" "nueva hora en la unidad"
  assert_contains "$(cat "$STUB_STATE/calls")" "systemctl restart -- komorebi-backup.timer" "temporizador reiniciado"
}
run_test "Cambiar la hora del backup reinicia el temporizador" t_timer_restart

t_pacman_prompt() {
  local rc
  new_sandbox; load_installer
  ASSUME_YES=0
  ( install_dependencies 0 </dev/null >/dev/null 2>&1 ); rc=$?
  assert_true "(( rc != 0 ))" "sin confirmación explícita no continúa"
  if grep -q 'pacman -Syu' "$STUB_STATE/calls"; then echo "ejecutó pacman -Syu sin permiso"; exit 1; fi
  ASSUME_YES=1
  install_dependencies 0 >/dev/null 2>&1
  assert_contains "$(cat "$STUB_STATE/calls")" "pacman -Syu --needed --noconfirm" "con --yes ejecuta -Syu --needed"
}
run_test "pacman -Syu: por defecto NO, solo con confirmación" t_pacman_prompt

t_reboot_gating() {
  new_sandbox; load_installer
  mkdir -p "$SANDBOX/modules"; KERNEL_MODULES_DIR="$SANDBOX/modules"
  reboot_pending || { echo "no detecta reinicio pendiente"; exit 1; }
  printf 'eula=true\n' >"$MC_DIR/eula.txt"
  offer_first_start >/dev/null 2>&1
  if grep -q '^systemctl start' "$STUB_STATE/calls"; then echo "arrancó con reinicio pendiente"; exit 1; fi
  assert_contains "$(configure_firewall 2>&1)" "reinicio pendiente" "el cortafuegos espera al reinicio"
  mkdir -p "$SANDBOX/modules/$(uname -r)"
  if reboot_pending; then echo "falso positivo"; exit 1; fi
}
run_test "Reinicio pendiente: no arranca el servidor ni toca el cortafuegos" t_reboot_gating

t_firewalld_zone() {
  new_sandbox; load_installer
  mkdir -p "$WORK/fw"
  cat >"$WORK/fw/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
printf 'firewall-cmd %s\n' "$*" >>"$STUB_STATE/calls"
case "$*" in
  --get-zone-of-interface=wlan0) echo home ;;
  --get-default-zone) echo public ;;
  *--query-port*) exit 1 ;;
esac
EOF
  chmod +x "$WORK/fw/firewall-cmd"
  PATH="$WORK/fw:$PATH"
  echo active >"$STUB_STATE/unit-firewalld.service"
  DEFAULT_IFACE=wlan0
  configure_firewall >/dev/null 2>&1
  assert_contains "$(cat "$STUB_STATE/calls")" "firewall-cmd --zone=home --permanent --add-port=25565/tcp" "puerto abierto en la zona de la interfaz"
}
run_test "firewalld: abre el puerto en la zona real de la interfaz" t_firewalld_zone

t_vpn_detect() {
  new_sandbox; load_installer
  SYS_NET_DIR="$WORK/net"; mkdir -p "$SYS_NET_DIR"/{lo,wlan0,tailscale0,wg0}
  assert_eq "$(detect_vpn_ifaces | sort | tr '\n' ' ')" "tailscale0 wg0 " "detecta Tailscale y WireGuard"
}
run_test "ufw: detección de interfaces VPN para no cortar el SSH remoto" t_vpn_detect

t_plugin_dep_disk() {
  local out
  new_sandbox; load_installer
  touch "$MC_DIR/paper.jar"
  TEMPLATES_CONFIG_DIR="$WORK/tplcfg2"; mkdir -p "$TEMPLATES_CONFIG_DIR"
  grep '^confirmed|yes|WorldEdit|' "$PROJECT_DIR/config/plugins-manifest.example" |
    awk -F'|' -v OFS='|' '{ $7="https://cdn.modrinth.com/data/no-existe/komorebi-test.jar"; print }' >"$TEMPLATES_CONFIG_DIR/plugins-manifest.example"
  grep '^confirmed|yes|WorldGuard|' "$PROJECT_DIR/config/plugins-manifest.example" >>"$TEMPLATES_CONFIG_DIR/plugins-manifest.example"
  out=$(install_plugins 2>&1)
  assert_contains "$out" "OMITIDO (dependencia WorldEdit no instalada)" "WorldGuard espera a que WorldEdit esté instalado"
  if compgen -G "$MC_DIR/plugins/*.jar" >/dev/null; then echo "se instaló algún JAR"; exit 1; fi
}
run_test "Plugins: una dependencia que no se descargó bloquea a sus dependientes" t_plugin_dep_disk

# =============================================================================
section "Usuarios, directorios y EULA"
# =============================================================================
t_dirs_eula() {
  new_sandbox; load_installer
  rm -rf "$SANDBOX/var/lib/minecraft" "$SANDBOX/var/backups/minecraft"
  ensure_directories >/dev/null
  assert_eq "$(stat -c %a "$MC_DIR")" 750 "MC_DIR 0750"
  assert_eq "$(stat -c %a "$BACKUP_DIR/installer")" 700 "backups del instalador 0700"
  for d in plugins config; do assert_true "[[ -d $MC_DIR/$d ]]" "$d/"; done
  for d in daily weekly manual; do assert_true "[[ -d $BACKUP_DIR/$d ]]" "$d/"; done
  SUMMARY_CHANGES=()
  ensure_directories >/dev/null
  assert_eq "${#SUMMARY_CHANGES[@]}" 0 "directorios idempotentes"
  ensure_eula_file >/dev/null
  assert_eq "$(grep -v '^#' "$MC_DIR/eula.txt")" "eula=false" "eula.txt con eula=false"
  touch "$MC_DIR/paper.jar"
  ( accept_eula </dev/null >/dev/null 2>&1 ) || true
  assert_eq "$(grep -v '^#' "$MC_DIR/eula.txt")" "eula=false" "sin terminal el EULA no se acepta (ni con --yes)"
  ensure_komorebi_config >/dev/null
  assert_contains "$(ensure_komorebi_config)" "no se sobrescribe" "komorebi.conf existente se respeta"
}
run_test "Directorios con permisos, EULA nunca automático, idempotencia" t_dirs_eula

t_deploy_file() {
  local a="$WORK/a" dest
  new_sandbox; load_installer
  dest="$CONFIG_DIR/test.conf"
  echo uno >"$a"
  deploy_file "$a" "$dest" 0644 root root "Prueba" >/dev/null
  assert_eq "$DEPLOY_CHANGED" 1 "primera instalación"
  deploy_file "$a" "$dest" 0644 root root "Prueba" >/dev/null
  assert_eq "$DEPLOY_CHANGED" 0 "idéntico: sin cambios"
  echo dos >"$a"
  ASSUME_YES=0
  deploy_file "$a" "$dest" 0644 root root "Prueba" </dev/null >/dev/null 2>&1
  assert_eq "$(cat "$dest")" uno "sin consentimiento no se sobrescribe"
  ASSUME_YES=1
  deploy_file "$a" "$dest" 0644 root root "Prueba" >/dev/null 2>&1
  assert_eq "$(cat "$dest")" dos "con consentimiento se reemplaza"
  assert_eq "$(cat "$BACKUP_DIR/installer/$RUN_ID$dest")" uno "y se guarda copia"
}
run_test "Escritura de configuración: consentimiento y copia previa" t_deploy_file

# =============================================================================
section "Manifiesto de plugins"
# =============================================================================
t_manifest() {
  local i reason confirmed=0 optional=0 pending=0
  new_sandbox; load_installer
  load_manifest "$PROJECT_DIR/config/plugins-manifest.example" 2>"$WORK/w"
  assert_eq "$(cat "$WORK/w")" "" "manifiesto sin líneas inválidas"
  assert_eq "${#M_NAME[@]}" 11 "11 entradas"
  for i in "${!M_NAME[@]}"; do
    reason=$(validate_manifest_entry "$i")
    assert_eq "$reason" "" "entrada válida: ${M_NAME[i]}"
    case ${M_STATUS[i]} in confirmed) confirmed=$((confirmed+1));; optional) optional=$((optional+1));; pending) pending=$((pending+1));; esac
    if [[ ${M_STATUS[i]} == optional && ${M_ENABLED[i]} == yes ]]; then echo "opcional activado por defecto"; exit 1; fi
  done
  assert_eq "$confirmed/$optional/$pending" "8/2/1" "8 confirmados, 2 opcionales, 1 pendiente"
  for want in LuckPerms EssentialsX EssentialsXSpawn Vault CoreProtect GriefPrevention WorldEdit WorldGuard; do
    i=$(manifest_index_of "$want"); plugin_wanted "$i" || { echo "$want no activo"; exit 1; }
  done
  M_URL[0]="http://cdn.modrinth.com/x.jar"; assert_contains "$(validate_manifest_entry 0)" "URL no permitida" "rechaza HTTP"
  M_URL[0]="https://evil.example.com/x.jar"; assert_contains "$(validate_manifest_entry 0)" "URL no permitida" "rechaza hosts no permitidos"
  load_manifest "$PROJECT_DIR/config/plugins-manifest.example"
  M_HASH[0]="abc"; assert_contains "$(validate_manifest_entry 0)" "hash" "rechaza hash corto"
  M_FILE[0]="../../etc/passwd.jar"; M_HASH[0]=${M_HASH[1]}; assert_contains "$(validate_manifest_entry 0)" "fichero" "rechaza rutas en el nombre"
}
run_test "Manifiesto: 8 confirmados, 2 opcionales desactivados, spark pendiente, validación" t_manifest

t_plugins_network() {
  local out
  [[ $OFFLINE == 1 ]] && { echo "SKIP (offline)"; exit 0; }
  new_sandbox; load_installer
  touch "$MC_DIR/paper.jar"
  TEMPLATES_CONFIG_DIR="$WORK/tplcfg"; mkdir -p "$TEMPLATES_CONFIG_DIR"
  grep -E '^(#|confirmed\|yes\|Vault\|)' "$PROJECT_DIR/config/plugins-manifest.example" >"$TEMPLATES_CONFIG_DIR/plugins-manifest.example"
  # Entrada manipulada: URL de Vault con el hash de otro plugin.
  grep '^confirmed|yes|Vault|' "$PROJECT_DIR/config/plugins-manifest.example" |
    awk -F'|' -v OFS='|' '{ $3="VaultFalso"; $5="VaultFalso.jar"; $6="VaultFalso*.jar"; $9="'"$(printf '0%.0s' {1..128})"'"; print }' >>"$TEMPLATES_CONFIG_DIR/plugins-manifest.example"
  grep '^pending' "$PROJECT_DIR/config/plugins-manifest.example" >>"$TEMPLATES_CONFIG_DIR/plugins-manifest.example"
  out=$(install_plugins 2>&1)
  printf '%s\n' "$out"
  assert_true "[[ -f $MC_DIR/plugins/Vault-1.7.3.jar ]]" "Vault instalado"
  assert_eq "$(sha512sum "$MC_DIR/plugins/Vault-1.7.3.jar" | cut -d' ' -f1)" "$(grep '^confirmed|yes|Vault|' "$PROJECT_DIR/config/plugins-manifest.example" | cut -d'|' -f9)" "hash de Vault"
  assert_eq "$(stat -c %a "$MC_DIR/plugins/Vault-1.7.3.jar")" 640 "permisos 0640"
  assert_true "[[ ! -e $MC_DIR/plugins/VaultFalso.jar ]]" "el fichero con hash incorrecto se descarta"
  assert_contains "$out" "ERROR (hash no coincide)" "informa del hash incorrecto"
  assert_contains "$out" "PENDIENTE DE VALIDACIÓN" "spark queda pendiente"
  if compgen -G "$MC_DIR/plugins/.komorebi-tmp.*" >/dev/null; then echo "quedaron temporales"; exit 1; fi
  out=$(install_plugins 2>&1)
  assert_contains "$out" "YA INSTALADO (hash verificado)" "segunda ejecución: ya instalado"
  mv "$MC_DIR/plugins/Vault-1.7.3.jar" "$MC_DIR/plugins/Vault.jar"
  out=$(install_plugins 2>&1)
  assert_contains "$out" "OMITIDO (otra versión presente)" "no duplica si hay otra versión"
  assert_true "[[ ! -e $MC_DIR/plugins/Vault-1.7.3.jar ]]" "sin duplicado"
}
run_test "Plugins (red): descarga verificada, hash incorrecto rechazado, sin duplicados" t_plugins_network

# =============================================================================
section "PaperMC (red)"
# =============================================================================
t_paper() {
  local out
  [[ $OFFLINE == 1 ]] && { echo "SKIP (offline)"; exit 0; }
  new_sandbox; load_installer
  out=$( (PAPER_SHA256=$(printf 'a%.0s' {1..64}); resolve_paper_build) 2>&1 ) && { echo "aceptó un SHA-256 fijado distinto"; exit 1; }
  assert_contains "$out" "no coincide" "detecta discrepancia con el hash fijado"
  install_paper >/dev/null 2>&1 || { install_paper; exit 1; }
  assert_eq "$(sha256sum "$MC_DIR/paper.jar" | cut -d' ' -f1)" "$PAPER_SHA256" "paper.jar verificado"
  assert_eq "$(stat -c %a "$MC_DIR/paper.jar")" 640 "permisos 0640"
  assert_eq "$PAPER_RESOLVED_BUILD/$PAPER_RESOLVED_CHANNEL" "196/STABLE" "build 196 STABLE"
  if compgen -G "$MC_DIR/.komorebi-tmp.*" >/dev/null; then echo "quedaron temporales"; exit 1; fi
  out=$(install_paper 2>&1)
  assert_contains "$out" "ya corresponde a la build 196" "segunda ejecución: no vuelve a descargar"
  assert_contains "$(cat "$VERSIONS_STATE_FILE")" "paper_build=196" "registro de versiones"
}
run_test "Paper 1.20.1: API Fill v3, SHA-256, idempotencia" t_paper

# =============================================================================
section "Backups y restauración"
# =============================================================================
b() { bash "$PROJECT_DIR/scripts/backup-komorebi.sh" "$@"; }
r() { bash "$PROJECT_DIR/scripts/restore-komorebi.sh" "$@"; }

t_backup_stopped() {
  local a lst
  new_sandbox; fake_world
  b >/dev/null
  a=$(ls "$SANDBOX"/var/backups/minecraft/manual/komorebi-manual-*.tar.gz)
  assert_true "[[ -f $a && -f $a.sha256 ]]" "archivo y .sha256"
  ( cd "$(dirname "$a")" && sha256sum -c --quiet "$(basename "$a").sha256" ) || { echo "sha256 inválido"; exit 1; }
  assert_eq "$(stat -c %a "$a")" 600 "archivo 0600"
  lst=$(tar -tzf "$a")
  assert_contains "$lst" "minecraft/world/level.dat" "incluye el mundo"
  assert_contains "$lst" "minecraft/plugins/Essentials/userdata/steve.yml" "incluye datos económicos"
  if grep -q 'minecraft/cache/\|minecraft/logs/' <<<"$lst"; then echo "incluye cachés/logs"; exit 1; fi
  if grep -q '^systemctl stop' "$STUB_STATE/calls"; then echo "detuvo un servidor ya detenido"; exit 1; fi
  assert_contains "$(cat "$SANDBOX/var/log/komorebi/backup.log")" "Copia completada" "registro del resultado"
}
run_test "Backup con el servidor detenido: contenido, exclusiones, SHA-256, log" t_backup_stopped

t_backup_running() {
  new_sandbox; fake_world
  echo active >"$STUB_STATE/state"
  b --scheduled >/dev/null
  assert_contains "$(cat "$STUB_STATE/calls")" "systemctl stop -- komorebi.service komorebi-console.socket" "parada ordenada (servicio + socket)"
  assert_contains "$(cat "$STUB_STATE/calls")" "systemctl start -- komorebi.service" "rearranque tras la copia"
  assert_eq "$(cat "$STUB_STATE/state")" active "el servidor vuelve a estar activo"
  assert_true "compgen -G '$SANDBOX/var/backups/minecraft/daily/komorebi-daily-*.tar.gz' >/dev/null" "copia diaria creada"
}
run_test "Backup con el servidor activo: stop → copia → start" t_backup_running

t_backup_retention_weekly() {
  local n
  new_sandbox; fake_world
  sed -i "s/^BACKUP_KEEP_DAILY=.*/BACKUP_KEEP_DAILY=2/" "$KOMOREBI_CONFIG"
  echo "BACKUP_WEEKLY_DAY=$(date +%u)" >>"$KOMOREBI_CONFIG"
  for d in 20200101-000000 20200102-000000 20200103-000000; do
    echo x >"$SANDBOX/var/backups/minecraft/daily/komorebi-daily-$d.tar.gz"
    echo x >"$SANDBOX/var/backups/minecraft/daily/komorebi-daily-$d.tar.gz.sha256"
  done
  echo "no tocar" >"$SANDBOX/var/backups/minecraft/daily/nota-del-admin.txt"
  b --scheduled >/dev/null
  n=$(ls "$SANDBOX"/var/backups/minecraft/daily/komorebi-daily-*.tar.gz | wc -l)
  assert_eq "$n" 2 "retención diaria = 2"
  assert_true "[[ -f $SANDBOX/var/backups/minecraft/daily/komorebi-daily-20200103-000000.tar.gz ]]" "conserva las más recientes"
  assert_true "[[ ! -f $SANDBOX/var/backups/minecraft/daily/komorebi-daily-20200101-000000.tar.gz.sha256 ]]" "borra también el .sha256"
  assert_true "[[ -f $SANDBOX/var/backups/minecraft/daily/nota-del-admin.txt ]]" "no toca ficheros ajenos"
  assert_true "compgen -G '$SANDBOX/var/backups/minecraft/weekly/komorebi-weekly-*.tar.gz' >/dev/null" "promoción semanal"
  b --scheduled >/dev/null
  assert_eq "$(ls "$SANDBOX"/var/backups/minecraft/weekly/komorebi-weekly-*.tar.gz | wc -l)" 1 "una sola semanal por semana"
}
run_test "Retención por tipo y promoción semanal sin tocar ficheros ajenos" t_backup_retention_weekly

t_backup_failure_restarts() {
  local rc
  new_sandbox; fake_world
  echo active >"$STUB_STATE/state"
  mkdir -p "$WORK/failtar"
  cat >"$WORK/failtar/tar" <<'EOF'
#!/usr/bin/env bash
# Simula un disco lleno: deja un archivo parcial y falla.
f=""; c=0
for a; do case $a in --file=*) f=${a#--file=} ;; --create) c=1 ;; esac; done
if (( c )); then printf 'parcial' >"$f"; exit 2; fi
exec /usr/bin/tar "$@"
EOF
  chmod +x "$WORK/failtar/tar"
  export STUB_PARTIAL_GLOB="$SANDBOX/var/backups/minecraft/*/.komorebi-tmp.*"
  PATH="$WORK/failtar:$PATH" b >/dev/null 2>&1; rc=$?
  if grep -q partial-present "$STUB_STATE/calls"; then echo "el servidor se reinició con el archivo parcial aún en disco"; exit 1; fi
  assert_true "(( rc != 0 ))" "la copia fallida devuelve error"
  assert_eq "$(cat "$STUB_STATE/state")" active "el servidor se reinicia aunque la copia falle"
  if compgen -G "$SANDBOX/var/backups/minecraft/manual/*" >/dev/null; then echo "quedó un archivo parcial"; exit 1; fi
}
run_test "Fallo durante la copia: parcial borrado antes de reiniciar el servidor" t_backup_failure_restarts

t_backup_orphans_timeout() {
  local out orphan
  new_sandbox; fake_world
  orphan="$SANDBOX/var/backups/minecraft/daily/.komorebi-tmp.komorebi-daily-20200101-000000.tar.gz"
  echo x >"$orphan"
  echo active >"$STUB_STATE/state"
  echo timeout >"$STUB_STATE/result"
  out=$(b 2>&1)
  assert_true "[[ ! -e $orphan ]]" "temporal huérfano eliminado"
  assert_contains "$out" "forzó la parada" "avisa si systemd tuvo que forzar la parada"
  assert_eq "$(cat "$STUB_STATE/state")" active "servidor activo al terminar"
}
run_test "Backup: limpia temporales huérfanos y avisa de paradas forzadas" t_backup_orphans_timeout

t_restore() {
  local a old
  new_sandbox; fake_world
  b >/dev/null
  a=$(ls "$SANDBOX"/var/backups/minecraft/manual/komorebi-manual-*.tar.gz)
  echo "LEVEL-DAÑADO" >"$SANDBOX/var/lib/minecraft/world/level.dat"
  r --dry-run "$a" >/dev/null
  assert_eq "$(cat "$SANDBOX/var/lib/minecraft/world/level.dat")" "LEVEL-DAÑADO" "--dry-run no cambia nada"
  r --yes "$a" >/dev/null
  assert_eq "$(cat "$SANDBOX/var/lib/minecraft/world/level.dat")" "LEVEL-ORIGINAL" "mundo restaurado"
  old=$(ls -d "$SANDBOX"/var/lib/minecraft.pre-restore-*)
  assert_eq "$(cat "$old/world/level.dat")" "LEVEL-DAÑADO" "la instalación anterior se conserva"
  assert_true "[[ -f $SANDBOX/var/lib/minecraft/cache/mojang.jar ]]" "reutiliza cachés excluidas"
  assert_eq "$(stat -c %a "$SANDBOX/var/lib/minecraft")" 750 "permisos 0750"
  if grep -q '^systemctl start' "$STUB_STATE/calls"; then echo "arrancó un servidor que estaba detenido"; exit 1; fi
}
run_test "Restauración: verifica, conserva la instalación previa, no arranca sin pedirlo" t_restore

t_restore_rejects() {
  local evil="$WORK/evil.tar.gz" other="$WORK/other.tar.gz" sum
  new_sandbox; fake_world
  mkdir -p "$WORK/evilsrc/minecraft"; echo x >"$WORK/evilsrc/minecraft/a"; echo x >"$WORK/evilsrc/fuera"
  tar -czf "$evil" -C "$WORK/evilsrc" minecraft/a fuera
  if r --yes "$evil" >/dev/null 2>&1; then echo "aceptó un archivo con rutas fuera de minecraft/"; exit 1; fi
  tar -czf "$other" -C "$WORK/evilsrc" --transform 's,^,../,' minecraft/a 2>/dev/null
  if r --yes "$other" >/dev/null 2>&1; then echo "aceptó rutas con .."; exit 1; fi
  b >/dev/null
  sum=$(ls "$SANDBOX"/var/backups/minecraft/manual/komorebi-manual-*.tar.gz)
  printf '%s  x\n' "$(printf '0%.0s' {1..64})" >"$sum.sha256"
  if r --yes "$sum" >/dev/null 2>&1; then echo "aceptó un SHA-256 incorrecto"; exit 1; fi
  assert_eq "$(cat "$SANDBOX/var/lib/minecraft/world/level.dat")" "LEVEL-ORIGINAL" "el mundo actual no se toca"
}
run_test "Restauración: rechaza rutas peligrosas y SHA-256 incorrecto" t_restore_rejects

# =============================================================================
section "Scripts de administración"
# =============================================================================
t_admin_scripts() {
  local out rc
  new_sandbox; fake_world
  echo "eula=false" >"$SANDBOX/var/lib/minecraft/eula.txt"
  touch "$SANDBOX/var/lib/minecraft/paper.jar"
  bash "$PROJECT_DIR/scripts/start-komorebi.sh" >/dev/null 2>&1; rc=$?
  assert_true "(( rc != 0 ))" "start se niega sin EULA"
  echo "eula=true" >"$SANDBOX/var/lib/minecraft/eula.txt"
  bash "$PROJECT_DIR/scripts/start-komorebi.sh" >/dev/null
  assert_eq "$(grep -c '^systemctl start' "$STUB_STATE/calls")" 1 "start usa systemctl"
  out=$(bash "$PROJECT_DIR/scripts/start-komorebi.sh")
  assert_contains "$out" "No se inicia otra instancia" "no duplica procesos"
  assert_eq "$(grep -c '^systemctl start' "$STUB_STATE/calls")" 1 "sin segundo start"
  bash "$PROJECT_DIR/scripts/console-komorebi.sh" stop >/dev/null 2>&1; rc=$?
  assert_true "(( rc != 0 ))" "la consola rechaza 'stop'"
  bash "$PROJECT_DIR/scripts/stop-komorebi.sh" >/dev/null
  assert_eq "$(cat "$STUB_STATE/state")" inactive "stop detiene el servicio"
  out=$(bash "$PROJECT_DIR/scripts/stop-komorebi.sh")
  assert_contains "$out" "ya está detenido" "stop idempotente"
  bash "$PROJECT_DIR/scripts/healthcheck-komorebi.sh" --quiet >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 2 "healthcheck: servicio detenido = crítico (2)"
  out=$(bash "$PROJECT_DIR/scripts/status-komorebi.sh" --lines 0)
  assert_contains "$out" "Servicio:" "status muestra el estado"
}
run_test "start/stop/status/healthcheck/console con systemctl simulado" t_admin_scripts

# =============================================================================
printf '\nResultado: %d correctas, %d fallidas, %d omitidas.\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
