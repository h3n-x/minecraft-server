#!/usr/bin/env bash
# =============================================================================
#  KOMOREBI SMP INSTALLER — 木漏れ日
#  Instalador de Minecraft Paper 1.20.1 + OpenJDK 21 + systemd para Arch Linux.
#
#  Uso:  sudo bash installer/install-komorebi.sh [MODO] [OPCIONES]
#        bash installer/install-komorebi.sh --help
#
#  Es idempotente: ejecutarlo varias veces no duplica usuarios, servicios,
#  ficheros ni configuraciones y nunca borra mundos.
# =============================================================================
set -Eeuo pipefail
umask 022

INSTALLER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(dirname -- "$INSTALLER_DIR")

# shellcheck source=../scripts/komorebi-common.sh
source "$PROJECT_DIR/scripts/komorebi-common.sh"
# shellcheck source=config.sh
source "$INSTALLER_DIR/config.sh"
# shellcheck source=functions.sh
source "$INSTALLER_DIR/functions.sh"
# shellcheck source=system.sh
source "$INSTALLER_DIR/system.sh"
# shellcheck source=dependencies.sh
source "$INSTALLER_DIR/dependencies.sh"
# shellcheck source=java.sh
source "$INSTALLER_DIR/java.sh"
# shellcheck source=papermc.sh
source "$INSTALLER_DIR/papermc.sh"
# shellcheck source=plugins.sh
source "$INSTALLER_DIR/plugins.sh"
# shellcheck source=systemd.sh
source "$INSTALLER_DIR/systemd.sh"
# shellcheck source=security.sh
source "$INSTALLER_DIR/security.sh"
# shellcheck source=backup.sh
source "$INSTALLER_DIR/backup.sh"

ACTION=""
WITH_MONITORING=0
LOCK_FD=""

usage() {
  cat <<EOF
KOMOREBI SMP INSTALLER v$INSTALLER_VERSION — Paper $MC_VERSION · Java $JAVA_REQUIRED_MAJOR · Arch Linux

Uso: sudo bash installer/install-komorebi.sh [MODO] [OPCIONES]

Modos (uno por ejecución; sin modo = instalación completa):
  (ninguno)         Instalación completa e interactiva.
  --check           Comprueba el sistema y el estado de la instalación (solo lectura; no requiere root).
  --dependencies    Instala solo los paquetes necesarios (pacman -Syu --needed) y verifica Java 21.
  --paper           Usuario, directorios, configuración y Paper $MC_VERSION verificado (+ eula.txt, server.properties).
  --plugins         Plugins del manifiesto (requiere Paper instalado).
  --service         Scripts de administración y unidades systemd (requiere Java 21 y Paper).
  --backup          Unidades de backup (servicio + temporizador diario).
  --eula            Muestra el EULA de Minecraft y solicita su aceptación explícita.
  --firewall        Abre TCP $SERVER_PORT en el cortafuegos activo o propone ufw (con confirmación).
  --ssh             Instala/habilita OpenSSH de forma segura (sin root, drop-in validado).
  --power           Evita la suspensión de la laptop (tapa/inactividad) con confirmación.
  --power-revert    Revierte el cambio de --power.
  --version         Muestra la versión.
  --help            Muestra esta ayuda.

Opciones:
  --dry-run         Simulación: muestra lo que se haría sin modificar el sistema.
  --yes, -y         Responde "sí" a las confirmaciones ordinarias (pacman, reemplazos con copia).
                    Nunca acepta el EULA ni cambia cortafuegos, SSH o energía.
  --with-monitoring Instala también lm_sensors, htop y smartmontools.
  --no-color        Desactiva los colores (también: NO_COLOR=1).

Ejemplos:
  sudo bash installer/install-komorebi.sh
  sudo bash installer/install-komorebi.sh --dry-run
  bash installer/install-komorebi.sh --check
  sudo bash installer/install-komorebi.sh --plugins

Rutas: servidor $MC_DIR · backups $BACKUP_DIR · configuración $CONFIG_DIR · registros $LOG_DIR
Documentación: INSTALADOR.md e INVESTIGACION.md en la carpeta del proyecto.
EOF
}

# set_action MODO — Registra el modo; solo se admite uno.
set_action() {
  if [[ -n $ACTION && $ACTION != "$1" ]]; then
    error "Solo se admite un modo por ejecución (--$ACTION y --$1)."
    hint "Consulta: bash installer/install-komorebi.sh --help"
    exit 2
  fi
  ACTION=$1
}

parse_args() {
  while (( $# )); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --no-color) KOMOREBI_NO_COLOR=1 ;;
      --with-monitoring) WITH_MONITORING=1 ;;
      --check) set_action check ;;
      --dependencies) set_action dependencies ;;
      --paper) set_action paper ;;
      --plugins) set_action plugins ;;
      --service) set_action service ;;
      --backup) set_action backup ;;
      --eula) set_action eula ;;
      --firewall) set_action firewall ;;
      --ssh) set_action ssh ;;
      --power) set_action power ;;
      --power-revert) set_action power-revert ;;
      --version|-V) set_action version ;;
      --help|-h) set_action help ;;
      *)
        error "Opción desconocida: $1"
        hint "Consulta: bash installer/install-komorebi.sh --help"
        exit 2 ;;
    esac
    shift
  done
  ACTION=${ACTION:-full}
}

# load_configuration — Valores por defecto + /etc/komorebi/komorebi.conf.
load_configuration() {
  k_set_defaults
  k_load_config "$KOMOREBI_CONFIG" || die "No se pudo cargar $KOMOREBI_CONFIG."
  k_validate_config || die "La configuración no es válida." "Revisa $KOMOREBI_CONFIG"
  k_units
}

# setup_logging — Registro en /var/log/komorebi (no en simulación ni --check).
setup_logging() {
  (( DRY_RUN )) && return 0
  [[ $EUID -eq 0 ]] || return 0
  case $ACTION in help|version|check) return 0 ;; esac
  install -d -o root -g root -m 0750 -- "$LOG_DIR"
  LOG_FILE="$LOG_DIR/install-$RUN_ID.log"
  : >"$LOG_FILE"
  chmod 0640 -- "$LOG_FILE"
  _log_file INFO "KOMOREBI SMP installer v$INSTALLER_VERSION · modo: $ACTION · argumentos: $*"
}

# acquire_lock — Impide dos instaladores simultáneos.
acquire_lock() {
  (( DRY_RUN )) && return 0
  [[ $EUID -eq 0 ]] || return 0
  # --check es de solo lectura: no crea ni el fichero de bloqueo.
  case $ACTION in help|version|check) return 0 ;; esac
  exec {LOCK_FD}>/run/komorebi-installer.lock
  flock -n "$LOCK_FD" || die "Ya hay otra ejecución del instalador en curso."
}

# -----------------------------------------------------------------------------
# Estado de la instalación (--check, solo lectura)
# -----------------------------------------------------------------------------
installation_status() {
  local d u st en f newest="" n
  section "Estado de la instalación"
  if getent passwd "$MC_USER" >/dev/null; then ok "Usuario $MC_USER: existe"; else info "Usuario $MC_USER: no existe"; fi
  for d in "$MC_DIR" "$MC_DIR/plugins" "$BACKUP_DIR" "$CONFIG_DIR" "$LOG_DIR"; do
    if [[ -d $d ]]; then detail "$d → $(stat -c '%U:%G %a' -- "$d")"; else detail "$d → no existe"; fi
  done
  if [[ -f $KOMOREBI_CONFIG ]]; then ok "Configuración: $KOMOREBI_CONFIG (heap -Xms$JVM_XMS -Xmx$JVM_XMX)"; else info "Configuración: sin crear"; fi
  if java_ready; then ok "Java $JAVA_REQUIRED_MAJOR: $JAVA_BIN"; else info "Java $JAVA_REQUIRED_MAJOR: no instalado"; fi
  f="$MC_DIR/paper.jar"
  if [[ -r $f ]]; then
    if [[ $(sha_of sha256 "$f") == "$PAPER_SHA256" ]]; then
      ok "paper.jar: build $PAPER_BUILD verificada (SHA-256)"
    else
      warn "paper.jar no coincide con el SHA-256 configurado (build $PAPER_BUILD)."
    fi
  elif [[ -e $f ]]; then
    info "paper.jar: presente (sin permiso de lectura para verificarlo; usa sudo)"
  else
    info "paper.jar: no instalado"
  fi
  if [[ -r $MC_DIR/eula.txt ]]; then
    if k_eula_accepted; then ok "EULA: aceptado"; else info "EULA: pendiente"; fi
  fi
  if [[ -r $MC_DIR/server.properties ]]; then check_security_properties; fi
  if [[ -r $MC_DIR/plugins ]]; then
    n=0
    for f in "$MC_DIR"/plugins/*.jar; do
      [[ -e $f ]] || continue
      detail "plugin: ${f##*/}"
      n=$((n + 1))
    done
    info "Plugins instalados: $n"
  fi
  if [[ -d /run/systemd/system ]]; then
    for u in "$K_SOCKET_UNIT" "$K_SERVICE_UNIT" "$K_BACKUP_TIMER_UNIT"; do
      en=$(systemctl is-enabled -- "$u" 2>/dev/null || true)
      st=$(systemctl is-active -- "$u" 2>/dev/null || true)
      detail "$u → habilitada: ${en:-no}, estado: ${st:-desconocido}"
    done
    report_firewall
    st=$(systemctl is-active sshd.service 2>/dev/null || true)
    detail "sshd → ${st:-desconocido}"
  fi
  if [[ -f $LOGIND_DROPIN_FILE ]]; then detail "Gestión de tapa KOMOREBI: aplicada ($LOGIND_DROPIN_FILE)"; fi
  for d in daily weekly manual; do
    for f in "$BACKUP_DIR/$d"/komorebi-*.tar.*; do
      [[ -f $f && $f != *.sha256 ]] || continue
      if [[ -z $newest || $f -nt $newest ]]; then newest=$f; fi
    done
  done
  if [[ -n $newest ]]; then ok "Último backup: $newest"; else info "Backups: ninguno encontrado (o sin permiso de lectura)"; fi
}

# -----------------------------------------------------------------------------
# Modos
# -----------------------------------------------------------------------------

optional_extras() {
  section "Configuraciones opcionales"
  if (( ASSUME_YES )); then
    info "Con --yes no se modifican cortafuegos, SSH ni energía."
    record_pending "Opcional: sudo bash installer/install-komorebi.sh --firewall | --ssh | --power"
    return 0
  fi
  if confirm "¿Revisar el cortafuegos ahora?" n; then configure_firewall; else record_pending "Cortafuegos: sudo bash installer/install-komorebi.sh --firewall"; fi
  if confirm "¿Configurar SSH para administración en la LAN ahora?" n; then configure_ssh; else record_pending "SSH: sudo bash installer/install-komorebi.sh --ssh"; fi
  detect_laptop
  if (( IS_LAPTOP )); then
    if confirm "¿Revisar la suspensión de la laptop ahora?" n; then configure_power; fi
  fi
}

mode_full() {
  local mon=$WITH_MONITORING
  enforce_preflight 1 1
  hardware_report
  if (( ! mon && ! ASSUME_YES && ! DRY_RUN )) && [[ -t 0 ]]; then
    if confirm "¿Instalar también herramientas de monitorización (${MONITORING_PACKAGES[*]})?" n; then mon=1; fi
  fi
  install_dependencies "$mon"
  ensure_user
  ensure_directories
  ensure_komorebi_config
  verify_java
  install_paper
  ensure_eula_file
  configure_server_properties
  check_security_properties
  install_plugins
  install_admin_scripts
  install_service_units
  install_backup_units
  if ! k_eula_accepted; then
    accept_eula
  fi
  offer_first_start
  optional_extras
  print_network_guidance
}

mode_check() {
  run_preflight 0 0 || true
  hardware_report
  installation_status
}

mode_dependencies() {
  enforce_preflight 1 1
  install_dependencies "$WITH_MONITORING"
  verify_java
}

mode_paper() {
  enforce_preflight 1 1
  ensure_user
  ensure_directories
  ensure_komorebi_config
  install_paper
  ensure_eula_file
  configure_server_properties
  check_security_properties
}

mode_plugins() {
  enforce_preflight 1 1
  install_plugins
}

mode_service() {
  enforce_preflight 1 0
  verify_java
  install_admin_scripts
  install_service_units
  install_backup_units
}

main() {
  k_init_colors
  parse_args "$@"
  k_init_colors
  load_configuration
  case $ACTION in
    help) usage; exit 0 ;;
    version) printf 'KOMOREBI SMP installer %s\n' "$INSTALLER_VERSION"; exit 0 ;;
  esac
  trap 'on_error "$?" "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[0]:-}"' ERR
  trap cleanup EXIT
  trap 'error "Interrumpido."; exit 130' INT TERM
  setup_logging "$@"
  acquire_lock
  banner
  case $ACTION in
    full) mode_full ;;
    check) mode_check ;;
    dependencies) mode_dependencies ;;
    paper) mode_paper ;;
    plugins) mode_plugins ;;
    service) mode_service ;;
    backup) require_root --backup; install_backup_units ;;
    eula) require_root --eula; accept_eula; offer_first_start ;;
    firewall) require_root --firewall; check_network; configure_firewall ;;
    ssh) require_root --ssh; check_network; configure_ssh ;;
    power) require_root --power; configure_power ;;
    power-revert) require_root --power-revert; revert_power ;;
  esac
  print_summary
}

main "$@"
