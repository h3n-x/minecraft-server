#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  system.sh — Comprobaciones previas, informe de hardware, usuario del
#  servicio, directorios, /etc/komorebi/komorebi.conf y gestión opcional de la
#  suspensión de la laptop.
#
#  Nota: para evitar falsos fallos con `set -o pipefail`, nunca se corta una
#  tubería (sin `head`, `grep -q` ni `awk ... exit` sobre la salida de otro
#  comando): se captura la salida completa y se filtra después.
# =============================================================================

PRE_CRIT=0
PRE_WARN=0
DETECTED_RAM_MB=0
RECOMMENDED_XMX="4G"
RECOMMENDED_XMS="2G"
MEMORY_MAX_MB=0
DEFAULT_IFACE=""
LOCAL_IP=""
LOCAL_CIDR=""
IS_LAPTOP=0

check_warn() { warn "$*"; PRE_WARN=$((PRE_WARN + 1)); }
check_crit() { error "$*"; PRE_CRIT=$((PRE_CRIT + 1)); }

# os_release_value CLAVE — Lee una clave de /etc/os-release sin ejecutarlo.
os_release_value() {
  local key=$1 file=${KOMOREBI_OS_RELEASE_FILE:-/etc/os-release} line val
  [[ -r $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == "$key="* ]]; then
      val=${line#*=}
      val=${val#\"}; val=${val%\"}
      val=${val#\'}; val=${val%\'}
      printf '%s\n' "$val"
      return 0
    fi
  done <"$file"
  return 1
}

# nearest_existing_dir RUTA — Primer ancestro existente de RUTA.
nearest_existing_dir() {
  local p=$1
  while [[ ! -d $p && $p != / ]]; do
    p=$(dirname -- "$p")
  done
  printf '%s\n' "$p"
}

# java_major_of BINARIO — Versión mayor de Java (21, 17, 8…). Vacío si falla.
java_major_of() {
  local out
  [[ -x $1 ]] || return 1
  out=$("$1" -version 2>&1 || true)
  if [[ $out =~ version\ \"1\.([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ $out =~ version\ \"([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

# first_line TEXTO — Primera línea de un texto.
first_line() {
  printf '%s\n' "${1%%$'\n'*}"
}

# print_cmd_output COMANDO... — Muestra la salida de un comando sangrada.
print_cmd_output() {
  local out line
  out=$("$@" 2>/dev/null || true)
  while IFS= read -r line; do
    if [[ -n $line ]]; then detail "$line"; fi
  done <<<"$out"
  return 0
}

# -----------------------------------------------------------------------------
# Comprobaciones individuales
# -----------------------------------------------------------------------------

check_os() {
  local id like pretty
  id=$(os_release_value ID || true)
  like=$(os_release_value ID_LIKE || true)
  pretty=$(os_release_value PRETTY_NAME || true)
  if [[ $id == arch ]]; then
    ok "Sistema operativo: ${pretty:-Arch Linux}"
  elif [[ " $like " == *" arch "* ]]; then
    check_warn "Distribución derivada de Arch (${pretty:-$id}). Solo Arch Linux está soportado: sus repositorios pueden diferir."
  else
    check_crit "Sistema no compatible: ${pretty:-desconocido}. Este instalador es exclusivo para Arch Linux."
  fi
}

check_arch() {
  local m
  m=$(uname -m)
  if [[ $m == x86_64 ]]; then
    ok "Arquitectura: $m"
  else
    check_crit "Arquitectura $m no soportada: $JAVA_PACKAGE solo existe para x86_64 en los repositorios oficiales."
  fi
}

check_root_access() {
  local need_root=$1
  if [[ $EUID -eq 0 ]]; then
    ok "Privilegios de administrador${SUDO_USER:+ (sudo, usuario $SUDO_USER)}"
  elif (( need_root )); then
    check_crit "Se necesitan privilegios de administrador. Ejecuta con sudo."
  else
    info "Sin privilegios de root: algunas comprobaciones serán parciales."
  fi
}

check_pacman() {
  local v
  if ! command -v pacman >/dev/null 2>&1; then
    check_crit "pacman no está disponible."
    return 0
  fi
  v=$(pacman -Q pacman 2>/dev/null || true)
  ok "Gestor de paquetes: ${v:-pacman}"
  if [[ -e /var/lib/pacman/db.lck ]]; then
    check_crit "pacman está bloqueado (/var/lib/pacman/db.lck): otra operación en curso o un bloqueo huérfano."
    hint "Espera a que termine. Si no hay ningún pacman activo (pgrep -a pacman), elimina el bloqueo manualmente."
  fi
}

check_systemd() {
  local state
  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    check_crit "systemd no es el sistema de inicio activo."
    return 0
  fi
  state=$(systemctl is-system-running 2>/dev/null || true)
  case $state in
    running) ok "systemd: $state" ;;
    degraded) check_warn "systemd degradado: hay unidades fallidas (consulta: systemctl --failed)." ;;
    *) check_warn "Estado de systemd: ${state:-desconocido}" ;;
  esac
}

check_internet() {
  local required=$1 u host
  for u in "$PAPER_API_BASE/projects/$PAPER_PROJECT" "https://archlinux.org/"; do
    host=${u#https://}
    host=${host%%/*}
    if curl --proto '=https' -sS -o /dev/null --connect-timeout 10 --max-time 20 \
         -A "$(http_user_agent)" -- "$u" 2>/dev/null; then
      ok "Conexión HTTPS con $host"
    elif (( required )); then
      check_crit "Sin conexión HTTPS con $host (comprueba la red, el DNS y la hora del sistema)."
    else
      check_warn "Sin conexión HTTPS con $host."
    fi
  done
}

check_disk() {
  local target free_mb dev_mc dev_bk
  target=$(nearest_existing_dir "$MC_DIR")
  free_mb=$(df -Pm -- "$target" | awk 'NR==2 {print $4}')
  if [[ ! $free_mb =~ ^[0-9]+$ ]]; then
    check_warn "No se pudo calcular el espacio libre en $target."
    return 0
  fi
  if (( free_mb < MIN_FREE_DISK_MB )); then
    check_crit "Espacio libre insuficiente en $target: ${free_mb} MiB (mínimo ${MIN_FREE_DISK_MB} MiB)."
  elif (( free_mb < RECOMMENDED_FREE_DISK_MB )); then
    check_warn "Espacio libre en $target: ${free_mb} MiB (recomendado ≥ ${RECOMMENDED_FREE_DISK_MB} MiB para mundos y backups)."
  else
    ok "Espacio libre en $target: ${free_mb} MiB"
  fi
  dev_mc=$(stat -c '%d' -- "$target")
  dev_bk=$(stat -c '%d' -- "$(nearest_existing_dir "$BACKUP_DIR")")
  if [[ $dev_mc == "$dev_bk" ]]; then
    info "Los backups se guardarán en el mismo disco que el servidor."
    record_pending "Programar copias externas (USB/NAS) de $BACKUP_DIR: el mismo SSD no protege ante su fallo."
  fi
}

# recommend_heap — Calcula Xms/Xmx recomendados según la RAM detectada,
# dejando siempre memoria para Arch Linux.
recommend_heap() {
  if (( DETECTED_RAM_MB >= 7000 )); then
    RECOMMENDED_XMX="4G"; RECOMMENDED_XMS="2G"
  elif (( DETECTED_RAM_MB >= 5500 )); then
    RECOMMENDED_XMX="3G"; RECOMMENDED_XMS="2G"
  else
    RECOMMENDED_XMX="2G"; RECOMMENDED_XMS="1G"
  fi
}

check_ram() {
  local total_kb avail_kb swap_kb
  total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
  DETECTED_RAM_MB=$(( ${total_kb:-0} / 1024 ))
  recommend_heap
  if (( DETECTED_RAM_MB < MIN_RAM_MB )); then
    check_crit "RAM insuficiente: ${DETECTED_RAM_MB} MiB (mínimo ${MIN_RAM_MB} MiB)."
  elif (( DETECTED_RAM_MB < RECOMMENDED_RAM_MB )); then
    check_warn "RAM: ${DETECTED_RAM_MB} MiB. Se recomienda heap de $RECOMMENDED_XMX en lugar de 4G."
  else
    ok "RAM total: ${DETECTED_RAM_MB} MiB (disponible $(( ${avail_kb:-0} / 1024 )) MiB) → heap recomendado -Xms$RECOMMENDED_XMS -Xmx$RECOMMENDED_XMX"
  fi
  info "Swap configurada: $(( ${swap_kb:-0} / 1024 )) MiB (el instalador no modifica swap, zram ni sysctl)."
}

check_cpu() {
  local model="" cpus
  if command -v lscpu >/dev/null 2>&1; then
    model=$(LC_ALL=C lscpu | awk -F: '/^Model name:/ && !done {sub(/^[ \t]+/, "", $2); print $2; done=1}')
  fi
  if [[ -z $model ]]; then
    model=$(awk -F: '/^model name/ && !done {sub(/^[ \t]+/, "", $2); print $2; done=1}' /proc/cpuinfo)
  fi
  cpus=$(nproc 2>/dev/null || printf '1')
  ok "CPU: ${model:-desconocida} ($cpus hilos)"
  if [[ $model =~ i3-10[0-9]{2,3} ]]; then
    info "Coincide con un Intel Core i3 de 10.ª generación."
  else
    info "La documentación prevé un Intel Core i3 de 10.ª gen (modelo pendiente); el detectado es el indicado arriba."
  fi
  if (( cpus < 2 )); then
    check_warn "Solo $cpus hilo de CPU: Paper funcionará con dificultad."
  fi
}

check_java_existing() {
  local j v found=0 status major
  for j in /usr/lib/jvm/*/bin/java; do
    [[ -x $j ]] || continue
    found=1
    v=$("$j" -version 2>&1 || true)
    info "Java instalado: $j → $(first_line "$v")"
  done
  if (( ! found )); then
    info "No hay ningún Java instalado en /usr/lib/jvm."
  fi
  major=$(java_major_of "$JAVA_BIN" || true)
  if [[ $major == "$JAVA_REQUIRED_MAJOR" ]]; then
    ok "Java $JAVA_REQUIRED_MAJOR disponible en $JAVA_BIN"
  else
    info "Java $JAVA_REQUIRED_MAJOR no está en $JAVA_BIN: se instalará $JAVA_PACKAGE."
  fi
  if command -v archlinux-java >/dev/null 2>&1; then
    status=$(archlinux-java status 2>&1 || true)
    info "archlinux-java status:"
    while IFS= read -r v; do
      if [[ -n $v ]]; then detail "$v"; fi
    done <<<"$status"
  fi
}

check_ports_and_conflicts() {
  local out
  if command -v ss >/dev/null 2>&1; then
    out=$(ss -Hltn "sport = :$SERVER_PORT" 2>/dev/null || true)
    if [[ -n $out ]]; then
      if k_service_active; then
        ok "Puerto TCP $SERVER_PORT en uso por $K_SERVICE_UNIT (esperado)."
      else
        check_warn "El puerto TCP $SERVER_PORT ya está en uso por otro proceso (ss -ltnp 'sport = :$SERVER_PORT')."
      fi
    else
      ok "Puerto TCP $SERVER_PORT libre o usado por KOMOREBI."
    fi
  fi
  if command -v pacman >/dev/null 2>&1 && pacman -Q minecraft-server >/dev/null 2>&1; then
    check_warn "Está instalado el paquete AUR minecraft-server (usuario minecraft, /srv/minecraft). Revisa que no compita con KOMOREBI."
  fi
  if [[ -d /run/systemd/system ]] && systemctl is-active --quiet minecraftd.service 2>/dev/null; then
    check_warn "minecraftd.service está activo: dos servidores en el mismo puerto entrarían en conflicto."
  fi
  out=$(k_stray_paper_pids)
  if [[ -n $out ]]; then
    check_warn "Hay procesos Paper fuera de systemd (PID: ${out//$'\n'/ }). Deténlos antes de usar el servicio."
  fi
}

check_network() {
  local route addr a b
  if ! command -v ip >/dev/null 2>&1; then
    check_warn "No está disponible 'ip' (iproute2)."
    return 0
  fi
  route=$(ip -o -4 route show default 2>/dev/null || true)
  DEFAULT_IFACE=$(awk 'NR==1 {for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' <<<"$route")
  if [[ -z $DEFAULT_IFACE ]]; then
    check_warn "No hay ruta IPv4 por defecto: el servidor no será accesible."
    return 0
  fi
  addr=$(ip -o -4 addr show dev "$DEFAULT_IFACE" 2>/dev/null || true)
  LOCAL_CIDR=$(awk 'NR==1 {print $4}' <<<"$addr")
  LOCAL_IP=${LOCAL_CIDR%/*}
  if [[ -d /sys/class/net/$DEFAULT_IFACE/wireless || -e /sys/class/net/$DEFAULT_IFACE/phy80211 ]]; then
    check_warn "Red Wi-Fi ($DEFAULT_IFACE, IP ${LOCAL_IP:-?}): más latencia y posibles cortes. Se recomienda Ethernet."
  else
    ok "Red cableada: $DEFAULT_IFACE, IP local ${LOCAL_IP:-?}"
  fi
  if [[ -n $LOCAL_IP ]]; then
    record_pending "Reservar en el router la IP local $LOCAL_IP para este equipo (DHCP estático)."
    IFS=. read -r a b _ <<<"$LOCAL_IP"
    if [[ $a == 100 ]] && (( b >= 64 && b <= 127 )); then
      check_warn "La IP $LOCAL_IP está en 100.64.0.0/10 (espacio CGNAT): el acceso desde Internet no será posible sin VPN o túnel."
    fi
  fi
}

# logind_prop PROPIEDAD — Propiedad de org.freedesktop.login1.Manager.
logind_prop() {
  local out
  command -v busctl >/dev/null 2>&1 || return 1
  out=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager "$1" 2>/dev/null) || return 1
  out=${out#* }
  out=${out#\"}
  printf '%s\n' "${out%\"}"
}

detect_laptop() {
  IS_LAPTOP=0
  if compgen -G '/sys/class/power_supply/BAT*' >/dev/null || compgen -G '/proc/acpi/button/lid/*' >/dev/null; then
    IS_LAPTOP=1
  fi
}

check_lid_power() {
  local lid ext idle ac
  detect_laptop
  if (( ! IS_LAPTOP )); then
    info "No se detecta batería ni tapa: no parece una laptop."
    return 0
  fi
  lid=$(logind_prop HandleLidSwitch || true)
  ext=$(logind_prop HandleLidSwitchExternalPower || true)
  idle=$(logind_prop IdleAction || true)
  info "Laptop detectada. logind: HandleLidSwitch=${lid:-?} HandleLidSwitchExternalPower=${ext:-?} IdleAction=${idle:-?}"
  case "$lid $ext $idle" in
    *suspend*|*hibernate*|*sleep*|*poweroff*)
      if [[ -f $LOGIND_DROPIN_FILE ]]; then
        info "Existe $LOGIND_DROPIN_FILE; si los valores no coinciden, otro fichero o el escritorio tiene prioridad."
      fi
      check_warn "La laptop puede suspenderse (tapa o inactividad) y detener el servidor."
      record_pending "Revisar la suspensión de la laptop: sudo bash installer/install-komorebi.sh --power"
      ;;
    *) ok "Cerrar la tapa o la inactividad no suspenden el sistema." ;;
  esac
  for ac in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online; do
    if [[ -r $ac && $(<"$ac") == 0 ]]; then
      check_warn "La laptop está funcionando con batería: conéctala a la corriente."
    fi
  done
}

# check_reboot — Avisa si el kernel se actualizó y falta reiniciar.
check_reboot() {
  if reboot_pending; then
    check_warn "Reinicio pendiente: el kernel en ejecución ($(uname -r)) ya no tiene sus módulos en disco. Reinicia antes de arrancar el servidor o configurar el cortafuegos."
    record_pending "Reiniciar el equipo (kernel actualizado)."
  fi
}

check_existing_install() {
  local items=() w n
  [[ -d $MC_DIR ]] || return 0
  if [[ -f $MC_DIR/paper.jar ]]; then items+=("paper.jar"); fi
  if [[ -f $MC_DIR/server.properties ]]; then items+=("server.properties"); fi
  for w in world world_nether world_the_end; do
    if [[ -d $MC_DIR/$w ]]; then items+=("$w/"); fi
  done
  n=$(compgen -G "$MC_DIR/plugins/*.jar" | wc -l || true)
  if (( n > 0 )); then items+=("$n plugins"); fi
  if (( ${#items[@]} )); then
    info "Instalación existente en $MC_DIR: ${items[*]}. Se conservará; nada se sobrescribe sin confirmación."
  fi
}

# -----------------------------------------------------------------------------
# Informe de hardware
# -----------------------------------------------------------------------------
hardware_report() {
  local f
  section "Informe de hardware"
  detail "Kernel: $(uname -srm)"
  if command -v lscpu >/dev/null 2>&1; then
    info "CPU (lscpu):"
    print_cmd_output lscpu_summary
  fi
  info "Memoria (free -h):"
  print_cmd_output free -h
  if command -v lsblk >/dev/null 2>&1; then
    info "Discos (lsblk; ROTA=0 indica SSD):"
    print_cmd_output lsblk -d -e 7 -o NAME,SIZE,ROTA,TYPE,TRAN,MODEL
  fi
  info "Espacio (df -h):"
  print_cmd_output df -h / "$(nearest_existing_dir "$MC_DIR")"
  if command -v ip >/dev/null 2>&1; then
    info "Red (ip -br addr):"
    print_cmd_output ip -br addr
  fi
  for f in /sys/class/power_supply/BAT*; do
    [[ -r $f/capacity ]] || continue
    detail "Batería ${f##*/}: $(<"$f/capacity")% ($(<"$f/status"))"
  done
  for f in /proc/acpi/button/lid/*/state; do
    if [[ -r $f ]]; then detail "Tapa: $(<"$f")"; fi
  done
  return 0
}

# lscpu_summary — Resumen compacto de lscpu (usado por hardware_report).
lscpu_summary() {
  LC_ALL=C lscpu | awk -F: '/^(Model name|CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|CPU max MHz|Virtualization)/'
}

# run_preflight NECESITA_ROOT NECESITA_INTERNET — Ejecuta todas las
# comprobaciones. Devuelve 1 si hay fallos críticos.
run_preflight() {
  local need_root=$1 need_internet=$2
  section "Comprobaciones del sistema"
  PRE_CRIT=0
  PRE_WARN=0
  check_os
  check_arch
  check_root_access "$need_root"
  check_pacman
  check_systemd
  check_internet "$need_internet"
  check_disk
  check_ram
  check_cpu
  check_java_existing
  check_ports_and_conflicts
  check_network
  check_lid_power
  check_reboot
  check_existing_install
  info "Resultado: $PRE_CRIT fallos críticos, $PRE_WARN avisos."
  (( PRE_CRIT == 0 ))
}

# enforce_preflight NECESITA_ROOT NECESITA_INTERNET — Detiene la ejecución si
# hay fallos críticos (en simulación solo avisa y continúa sin efectos).
enforce_preflight() {
  if run_preflight "$1" "$2"; then
    return 0
  fi
  if (( DRY_RUN )); then
    warn "Hay $PRE_CRIT requisitos críticos sin cumplir: una ejecución real se detendría aquí. La simulación continúa sin efectos."
    return 0
  fi
  die "No se cumplen $PRE_CRIT requisitos críticos; no se ha modificado nada." \
      "Corrige los errores marcados con [ERR ] y vuelve a ejecutar el instalador."
}

# -----------------------------------------------------------------------------
# Usuario del servicio
# -----------------------------------------------------------------------------

# ensure_user — Crea el usuario de sistema o audita el existente. Nunca borra
# usuarios; las correcciones requieren confirmación.
ensure_user() {
  local entry uid home shell sys_max groups g pw
  section "Usuario del servicio: $MC_USER"
  sys_max=$(awk '$1 == "SYS_UID_MAX" {print $2}' /etc/login.defs 2>/dev/null || true)
  sys_max=${sys_max:-999}

  if ! entry=$(getent passwd "$MC_USER"); then
    if getent group "$MC_GROUP" >/dev/null; then
      run useradd --system --gid "$MC_GROUP" --home-dir "$MC_DIR" --no-create-home \
        --shell /usr/bin/nologin --comment "KOMOREBI SMP Minecraft server" "$MC_USER"
    elif [[ $MC_GROUP == "$MC_USER" ]]; then
      run useradd --system --user-group --home-dir "$MC_DIR" --no-create-home \
        --shell /usr/bin/nologin --comment "KOMOREBI SMP Minecraft server" "$MC_USER"
    else
      run groupadd --system "$MC_GROUP"
      run useradd --system --gid "$MC_GROUP" --home-dir "$MC_DIR" --no-create-home \
        --shell /usr/bin/nologin --comment "KOMOREBI SMP Minecraft server" "$MC_USER"
    fi
    ok "Usuario de sistema $MC_USER creado (sin shell, sin sudo, hogar $MC_DIR)."
    record_change "Usuario de sistema creado: $MC_USER"
    return 0
  fi

  IFS=: read -r _ _ uid _ _ home shell <<<"$entry"
  ok "El usuario $MC_USER ya existe (uid $uid); se audita sin borrarlo."
  if (( uid == 0 )); then
    die "El usuario $MC_USER tiene UID 0 (equivale a root)." "Corrige la cuenta manualmente: Paper nunca debe ejecutarse como root."
  fi
  if (( uid > sys_max )); then
    warn "$MC_USER no es un usuario de sistema (uid $uid > $sys_max). No se cambia el UID automáticamente."
  fi
  case $shell in
    /usr/bin/nologin|/sbin/nologin|/usr/sbin/nologin|/bin/false|/usr/bin/false)
      ok "Shell no interactiva: $shell" ;;
    *)
      warn "$MC_USER tiene una shell interactiva ($shell)."
      if confirm "¿Cambiar la shell de $MC_USER a /usr/bin/nologin?" s; then
        run usermod --shell /usr/bin/nologin "$MC_USER"
        record_change "Shell de $MC_USER cambiada a /usr/bin/nologin"
      else
        record_skip "Shell de $MC_USER sin cambios ($shell)"
      fi ;;
  esac
  if [[ $home != "$MC_DIR" ]]; then
    warn "El directorio personal de $MC_USER es $home (se esperaba $MC_DIR)."
    if confirm "¿Cambiar el directorio personal a $MC_DIR? (no se mueven ficheros)" n; then
      run usermod --home "$MC_DIR" "$MC_USER"
      record_change "Directorio personal de $MC_USER: $MC_DIR"
    else
      record_skip "Directorio personal de $MC_USER sin cambios ($home)"
    fi
  fi
  groups=$(id -nG "$MC_USER" 2>/dev/null || true)
  for g in wheel sudo adm root; do
    if [[ " $groups " == *" $g "* ]]; then
      warn "$MC_USER pertenece al grupo privilegiado '$g'."
      if confirm "¿Quitar a $MC_USER del grupo $g?" s; then
        run gpasswd --delete "$MC_USER" "$g"
        record_change "$MC_USER retirado del grupo $g"
      fi
    fi
  done
  if [[ -r /etc/sudoers ]] && grep -rqsw -- "$MC_USER" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
    warn "$MC_USER aparece en /etc/sudoers o /etc/sudoers.d: revísalo manualmente con visudo (no se modifica)."
  fi
  pw=$(passwd -S "$MC_USER" 2>/dev/null || true)
  read -r _ pw _ <<<"$pw"
  if [[ $pw == P ]]; then
    warn "$MC_USER tiene una contraseña utilizable."
    if confirm "¿Bloquear la contraseña de $MC_USER (passwd -l)?" s; then
      run passwd --lock "$MC_USER"
      record_change "Contraseña de $MC_USER bloqueada"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Directorios
# -----------------------------------------------------------------------------
ensure_directories() {
  local foreign worldw
  section "Directorios y permisos"
  ensure_dir "$MC_DIR" "$MC_USER" "$MC_GROUP" 0750
  ensure_dir "$MC_DIR/plugins" "$MC_USER" "$MC_GROUP" 0750
  ensure_dir "$MC_DIR/config" "$MC_USER" "$MC_GROUP" 0750
  ensure_dir "$BACKUP_DIR" root root 0750
  ensure_dir "$BACKUP_DIR/daily" root root 0750
  ensure_dir "$BACKUP_DIR/weekly" root root 0750
  ensure_dir "$BACKUP_DIR/manual" root root 0750
  ensure_dir "$BACKUP_DIR/installer" root root 0700
  ensure_dir "$CONFIG_DIR" root root 0755
  ensure_dir "$LOG_DIR" root root 0750
  ok "Estructura de directorios correcta."

  if [[ -d $MC_DIR ]] && getent passwd "$MC_USER" >/dev/null; then
    foreign=$(find "$MC_DIR" -xdev \( ! -user "$MC_USER" -o ! -group "$MC_GROUP" \) -print -quit 2>/dev/null || true)
    if [[ -n $foreign ]]; then
      warn "Hay ficheros en $MC_DIR que no pertenecen a $MC_USER:$MC_GROUP (por ejemplo: $foreign)."
      if confirm "¿Corregir el propietario de todo $MC_DIR a $MC_USER:$MC_GROUP?" s; then
        run chown -R "$MC_USER:$MC_GROUP" -- "$MC_DIR"
        record_change "Propietario corregido recursivamente: $MC_DIR"
      else
        record_skip "Propietarios de $MC_DIR sin corregir"
      fi
    fi
    worldw=$(find "$MC_DIR" -xdev -perm -o+w ! -type l -print -quit 2>/dev/null || true)
    if [[ -n $worldw ]]; then
      warn "Hay ficheros escribibles por cualquier usuario en $MC_DIR (por ejemplo: $worldw)."
      if confirm "¿Retirar los permisos de 'otros' en $MC_DIR (chmod -R o-rwx)?" s; then
        run chmod -R o-rwx -- "$MC_DIR"
        record_change "Permisos de 'otros' retirados en $MC_DIR"
      fi
    fi
  fi
}

# -----------------------------------------------------------------------------
# Configuración /etc/komorebi
# -----------------------------------------------------------------------------

# compute_memory_limits — Valida Xms/Xmx frente a la RAM y calcula MemoryMax.
compute_memory_limits() {
  local xmx_mb
  xmx_mb=$(k_size_to_mb "$JVM_XMX")
  if (( DETECTED_RAM_MB > 0 )); then
    if (( xmx_mb >= DETECTED_RAM_MB - 1024 )); then
      die "JVM_XMX=$JVM_XMX es demasiado alto para ${DETECTED_RAM_MB} MiB de RAM." \
          "Edita $KOMOREBI_CONFIG (recomendado: JVM_XMX=$RECOMMENDED_XMX) y repite con --service."
    fi
    if (( xmx_mb > DETECTED_RAM_MB - 2560 )); then
      warn "JVM_XMX=$JVM_XMX deja poco margen al sistema (RAM ${DETECTED_RAM_MB} MiB). Recomendado: $RECOMMENDED_XMX."
    fi
  fi
  # Heap + ~2 GiB para metaspace, JIT, hilos y buffers de red, sin superar la RAM.
  MEMORY_MAX_MB=$(( xmx_mb + 2048 ))
  if (( DETECTED_RAM_MB > 0 && MEMORY_MAX_MB > DETECTED_RAM_MB - 768 )); then
    MEMORY_MAX_MB=$(( DETECTED_RAM_MB - 768 ))
  fi
  if (( MEMORY_MAX_MB < xmx_mb + 512 )); then
    MEMORY_MAX_MB=$(( xmx_mb + 512 ))
  fi
}

# ensure_komorebi_config — Crea /etc/komorebi/komorebi.conf si no existe
# (memoria ajustada a la RAM detectada). Si existe, se respeta.
ensure_komorebi_config() {
  local tmp
  section "Configuración de KOMOREBI ($KOMOREBI_CONFIG)"
  if [[ -f $KOMOREBI_CONFIG ]]; then
    ok "Se usa la configuración existente (no se sobrescribe)."
    info "Memoria Java configurada: -Xms$JVM_XMS -Xmx$JVM_XMX (recomendado para esta RAM: -Xms$RECOMMENDED_XMS -Xmx$RECOMMENDED_XMX)."
    record_skip "komorebi.conf existente conservado"
    return 0
  fi
  if [[ $JVM_XMX != "$RECOMMENDED_XMX" ]]; then
    info "Ajustando la memoria a la RAM detectada: -Xmx$RECOMMENDED_XMX."
  fi
  JVM_XMX=$RECOMMENDED_XMX
  JVM_XMS=$RECOMMENDED_XMS
  tmp=$(make_tmp_file)
  register_tmp "$tmp"
  render_template "$TEMPLATES_CONFIG_DIR/komorebi.conf.example" "$tmp" \
    "INSTALLER_VERSION=$INSTALLER_VERSION" "GENERATED=$(date '+%F %T')" \
    "MC_VERSION=$MC_VERSION" "PAPER_BUILD=$PAPER_BUILD" "PAPER_SHA256=$PAPER_SHA256" \
    "JAVA_BIN=$JAVA_BIN" "JVM_XMS=$JVM_XMS" "JVM_XMX=$JVM_XMX" "JVM_FLAGS=$JVM_FLAGS" \
    "MC_USER=$MC_USER" "MC_GROUP=$MC_GROUP" "MC_DIR=$MC_DIR" "BACKUP_DIR=$BACKUP_DIR" \
    "LOG_DIR=$LOG_DIR" "SERVICE_NAME=$SERVICE_NAME" "CONSOLE_FIFO=$CONSOLE_FIFO" \
    "SERVER_PORT=$SERVER_PORT" "MAX_PLAYERS=$MAX_PLAYERS" "VIEW_DISTANCE=$VIEW_DISTANCE" \
    "SIMULATION_DISTANCE=$SIMULATION_DISTANCE" "STOP_TIMEOUT=$STOP_TIMEOUT" \
    "BACKUP_MODE=$BACKUP_MODE" "BACKUP_COMPRESSION=$BACKUP_COMPRESSION" \
    "BACKUP_KEEP_DAILY=$BACKUP_KEEP_DAILY" "BACKUP_KEEP_WEEKLY=$BACKUP_KEEP_WEEKLY" \
    "BACKUP_KEEP_MANUAL=$BACKUP_KEEP_MANUAL" "BACKUP_WEEKLY_DAY=$BACKUP_WEEKLY_DAY" \
    "BACKUP_ONCALENDAR=$BACKUP_ONCALENDAR" "BACKUP_STOP_WARNING=$BACKUP_STOP_WARNING" \
    "BACKUP_MAX_AGE_HOURS=$BACKUP_MAX_AGE_HOURS" "HTTP_CONTACT=$HTTP_CONTACT"
  deploy_file "$tmp" "$KOMOREBI_CONFIG" 0644 root root "Configuración komorebi.conf"
  record_pending "Opcional: indica un contacto (correo o URL) en HTTP_CONTACT de $KOMOREBI_CONFIG; PaperMC lo pide en el User-Agent."
}

# -----------------------------------------------------------------------------
# Suspensión de la laptop (opcional, --power)
# -----------------------------------------------------------------------------

# configure_power — Evita la suspensión por tapa/inactividad con un drop-in de
# logind reversible. Requiere confirmación escrita.
configure_power() {
  local tmp de=() p
  section "Gestión de energía de la laptop (opcional)"
  detect_laptop
  if (( ! IS_LAPTOP )); then
    info "No se detecta una laptop; no es necesario cambiar la gestión de energía."
    return 0
  fi
  check_lid_power
  for p in gnome-shell plasmashell xfce4-power-manager mate-power-manager cinnamon; do
    if pgrep -x "$p" >/dev/null 2>&1; then de+=("$p"); fi
  done
  if (( ${#de[@]} )); then
    warn "Hay un entorno de escritorio con gestor de energía propio (${de[*]}): ajusta también allí la suspensión por inactividad y al cerrar la tapa."
  fi
  info "Inhibidores activos (systemd-inhibit --list):"
  print_cmd_output systemd-inhibit --list --no-pager
  cat <<EOF

  Propuesta: crear $LOGIND_DROPIN_FILE con
      [Login]
      HandleLidSwitch=ignore
      HandleLidSwitchExternalPower=ignore
      HandleLidSwitchDocked=ignore
      IdleAction=ignore
  y recargar logind (SIGHUP, sin cerrar sesiones).

  Riesgos: con la tapa cerrada algunas laptops ventilan peor (vigila 'sensors');
  mantén el equipo conectado a la corriente y en una superficie dura.
  Revertir: sudo bash installer/install-komorebi.sh --power-revert

EOF
  if ! confirm_typed "¿Aplicar esta configuración de energía?" "SI"; then
    record_skip "Gestión de energía sin cambios"
    record_pending "Si la laptop se suspende al cerrar la tapa, ejecuta: sudo bash installer/install-komorebi.sh --power"
    return 0
  fi
  ensure_dir "$LOGIND_DROPIN_DIR" root root 0755
  tmp=$(make_tmp_file)
  register_tmp "$tmp"
  cat >"$tmp" <<'EOF'
# Gestionado por el instalador de KOMOREBI SMP (木漏れ日).
# Evita que la laptop se suspenda al cerrar la tapa o por inactividad mientras
# aloja el servidor. Para revertir: borra este fichero y ejecuta
#   sudo systemctl kill -s HUP systemd-logind.service
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF
  deploy_file "$tmp" "$LOGIND_DROPIN_FILE" 0644 root root "Drop-in de logind"
  if (( DEPLOY_CHANGED )); then
    run systemctl kill -s HUP systemd-logind.service
    ok "logind recargado. Comprueba con: busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch"
  fi
}

# revert_power — Elimina el drop-in de logind creado por el instalador.
revert_power() {
  section "Revertir la gestión de energía"
  if [[ ! -f $LOGIND_DROPIN_FILE ]]; then
    ok "No existe $LOGIND_DROPIN_FILE: nada que revertir."
    return 0
  fi
  if ! grep -q 'KOMOREBI SMP' -- "$LOGIND_DROPIN_FILE"; then
    die "$LOGIND_DROPIN_FILE no fue creado por este instalador." "Revísalo manualmente."
  fi
  if confirm "¿Eliminar $LOGIND_DROPIN_FILE y recargar logind?" n; then
    backup_file "$LOGIND_DROPIN_FILE"
    run rm -f -- "$LOGIND_DROPIN_FILE"
    run systemctl kill -s HUP systemd-logind.service
    record_change "Drop-in de logind eliminado (comportamiento de energía por defecto)"
  fi
}
