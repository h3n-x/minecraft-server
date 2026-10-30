#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  systemd.sh — Scripts de administración y unidades systemd del servidor:
#    komorebi.service         Paper como usuario minecraft (nunca root)
#    komorebi-console.socket  FIFO local para la consola (sin red, solo root)
# =============================================================================

ADMIN_SCRIPTS=(start-komorebi.sh stop-komorebi.sh status-komorebi.sh backup-komorebi.sh
               restore-komorebi.sh healthcheck-komorebi.sh console-komorebi.sh)

# install_admin_scripts — Copia los scripts a $LIB_DIR y crea enlaces en
# $BIN_DIR. Son código gestionado: se actualizan con copia de seguridad.
install_admin_scripts() {
  local s src dest link cur
  section "Scripts de administración"
  ensure_dir "$LIB_DIR" root root 0755
  for s in komorebi-common.sh "${ADMIN_SCRIPTS[@]}"; do
    src="$PROJECT_SCRIPTS_DIR/$s"
    dest="$LIB_DIR/$s"
    [[ -r $src ]] || die "Falta $src en el proyecto." "Ejecuta el instalador desde la carpeta completa del proyecto."
    if same_file "$src" "$dest"; then
      record_skip "Script $s (sin cambios)"
    else
      if [[ -f $dest ]]; then
        backup_file "$dest"
      fi
      if [[ $s == komorebi-common.sh ]]; then
        install_file "$src" "$dest" 0644 root root
      else
        install_file "$src" "$dest" 0755 root root
      fi
      record_change "Script instalado: $dest"
    fi
  done
  for s in "${ADMIN_SCRIPTS[@]}"; do
    link="$BIN_DIR/$s"
    if [[ -L $link ]]; then
      cur=$(readlink -- "$link")
      if [[ $cur == "$LIB_DIR/$s" ]]; then
        continue
      fi
      warn "$link apunta a $cur (no gestionado por KOMOREBI); se conserva."
      continue
    fi
    if [[ -e $link ]]; then
      warn "$link ya existe y no es un enlace de KOMOREBI; se conserva."
      continue
    fi
    run ln -s -- "$LIB_DIR/$s" "$link"
    record_change "Enlace: $link"
  done
  ok "Scripts disponibles en $BIN_DIR: ${ADMIN_SCRIPTS[*]}"
}

# unit_render_args — Variables comunes para las plantillas de unidades.
unit_render_args() {
  UNIT_ARGS=(
    "INSTALLER_VERSION=$INSTALLER_VERSION" "MC_VERSION=$MC_VERSION"
    "PAPER_BUILD=$PAPER_BUILD" "MC_USER=$MC_USER" "MC_GROUP=$MC_GROUP"
    "MC_DIR=$MC_DIR" "JAVA_BIN=$JAVA_BIN" "JVM_XMS=$JVM_XMS" "JVM_XMX=$JVM_XMX"
    "JVM_FLAGS=$JVM_FLAGS" "STOP_TIMEOUT=$STOP_TIMEOUT" "MEMORY_MAX=${MEMORY_MAX_MB}M"
    "SERVICE_UNIT=$K_SERVICE_UNIT" "SOCKET_UNIT=$K_SOCKET_UNIT"
    "CONSOLE_FIFO=$CONSOLE_FIFO" "BIN_DIR=$BIN_DIR"
    "BACKUP_ONCALENDAR=$BACKUP_ONCALENDAR" "BACKUP_SERVICE_UNIT=$K_BACKUP_SERVICE_UNIT"
  )
}

# deploy_unit PLANTILLA UNIDAD — Renderiza e instala una unidad. Acumula en
# UNITS_CHANGED si hubo cambios.
deploy_unit() {
  local tpl=$1 unit=$2 tmp dest="$SYSTEMD_UNIT_DIR/$2"
  tmp=$(make_tmp_file)
  register_tmp "$tmp"
  render_template "$TEMPLATES_SYSTEMD_DIR/$tpl" "$tmp" "${UNIT_ARGS[@]}"
  if [[ -f $dest ]] && ! grep -q 'KOMOREBI SMP installer' -- "$dest"; then
    warn "$dest existe y no fue creado por este instalador."
  fi
  deploy_file "$tmp" "$dest" 0644 root root "Unidad $unit"
  if (( DEPLOY_CHANGED )); then
    UNITS_CHANGED=1
  fi
}

# verify_units UNIDAD... — systemd-analyze verify (avisos no fatales).
verify_units() {
  local u out paths=()
  (( DRY_RUN )) && return 0
  command -v systemd-analyze >/dev/null 2>&1 || return 0
  for u in "$@"; do paths+=("$SYSTEMD_UNIT_DIR/$u"); done
  if out=$(systemd-analyze verify "${paths[@]}" 2>&1); then
    ok "systemd-analyze verify: sin errores."
  else
    warn "systemd-analyze verify informó de problemas:"
    while IFS= read -r u; do
      if [[ -n $u ]]; then detail "$u"; fi
    done <<<"$out"
  fi
}

# enable_unit UNIDAD — Habilita una unidad si no lo está (no la arranca).
enable_unit() {
  local state
  state=$(systemctl is-enabled -- "$1" 2>/dev/null || true)
  if [[ $state == enabled ]]; then
    ok "$1 ya está habilitada."
    return 0
  fi
  run systemctl enable -- "$1"
  record_change "Unidad habilitada al arranque: $1"
}

# reload_units_if_needed UNIDAD... — daemon-reload si las unidades cambiaron
# en esta ejecución o si systemd indica que su copia en memoria está obsoleta
# (por ejemplo, porque una ejecución anterior se interrumpió tras escribirlas).
reload_units_if_needed() {
  local u need=$UNITS_CHANGED
  if (( ! need )); then
    for u in "$@"; do
      if [[ $(systemctl show -p NeedDaemonReload --value -- "$u" 2>/dev/null || true) == yes ]]; then
        need=1
        info "systemd tiene una versión antigua de $u en memoria."
      fi
    done
  fi
  if (( need )); then
    run systemctl daemon-reload
  fi
}

# enable_service_if_eula — Habilita komorebi.service solo si el EULA está
# aceptado. Así, una instalación sin EULA no deja un servicio que falla en
# cada arranque del equipo.
enable_service_if_eula() {
  [[ -f $SYSTEMD_UNIT_DIR/$K_SERVICE_UNIT ]] || return 0
  if k_eula_accepted; then
    enable_unit "$K_SERVICE_UNIT"
  else
    info "$K_SERVICE_UNIT no se habilita al arranque hasta que se acepte el EULA (--eula)."
    record_pending "Aceptar el EULA para habilitar e iniciar el servidor: sudo bash installer/install-komorebi.sh --eula"
  fi
}

# reboot_pending — 0 si el kernel en ejecución ya no tiene sus módulos en disco
# (pacman actualizó el paquete del kernel y falta reiniciar). Con el paquete
# kernel-modules-hook instalado esta detección no funciona.
reboot_pending() {
  [[ -d $KERNEL_MODULES_DIR ]] || return 1
  [[ ! -d $KERNEL_MODULES_DIR/$(uname -r) ]]
}

# install_service_units — Instala komorebi.service y komorebi-console.socket.
install_service_units() {
  section "Servicio systemd ($K_SERVICE_UNIT)"
  if (( ! DRY_RUN )); then
    java_ready || die "Java $JAVA_REQUIRED_MAJOR no está disponible en $JAVA_BIN." \
                      "Instálalo primero: sudo bash installer/install-komorebi.sh --dependencies"
    [[ -f $MC_DIR/paper.jar ]] || die "Paper no está instalado en $MC_DIR." \
                      "Instálalo primero: sudo bash installer/install-komorebi.sh --paper"
    getent passwd "$MC_USER" >/dev/null || die "No existe el usuario $MC_USER." "Ejecuta la instalación completa."
  fi
  compute_memory_limits
  info "Java: $JAVA_BIN · heap -Xms$JVM_XMS -Xmx$JVM_XMX · MemoryMax=${MEMORY_MAX_MB}M · TimeoutStopSec=${STOP_TIMEOUT}s"
  unit_render_args
  UNITS_CHANGED=0
  deploy_unit komorebi-console.socket "$K_SOCKET_UNIT"
  deploy_unit komorebi.service "$K_SERVICE_UNIT"
  reload_units_if_needed "$K_SOCKET_UNIT" "$K_SERVICE_UNIT"
  verify_units "$K_SOCKET_UNIT" "$K_SERVICE_UNIT"
  enable_unit "$K_SOCKET_UNIT"
  enable_service_if_eula
  if (( UNITS_CHANGED )) && k_service_active; then
    record_pending "Reiniciar el servidor para aplicar la nueva unidad: sudo systemctl restart $K_SERVICE_UNIT"
  fi
  info "Revisión de seguridad opcional: systemd-analyze security $K_SERVICE_UNIT"
}

# offer_first_start — Ofrece iniciar el servidor si el EULA está aceptado.
offer_first_start() {
  local since
  section "Primer arranque"
  if k_service_active; then
    ok "El servidor ya está en ejecución."
    return 0
  fi
  if ! k_eula_accepted; then
    info "El EULA no está aceptado: el servidor no se inicia."
    return 0
  fi
  if reboot_pending; then
    warn "Hay un reinicio pendiente (kernel actualizado): el servidor no se inicia ahora."
    record_pending "Reiniciar el equipo; el servidor arrancará solo al encenderse (servicio habilitado)."
    return 0
  fi
  if ! confirm "¿Iniciar KOMOREBI SMP ahora?" s; then
    record_pending "Iniciar el servidor: sudo start-komorebi.sh"
    return 0
  fi
  since=$(date +%s)
  run systemctl start -- "$K_SERVICE_UNIT"
  (( DRY_RUN )) && return 0
  info "Esperando a que Paper termine de arrancar (hasta 5 minutos; el primer arranque genera el mundo)…"
  if k_wait_for_log "$since" 'Done (' 300; then
    ok "Servidor en marcha. Consola: sudo console-komorebi.sh \"whitelist add <jugador>\""
    record_change "Servidor iniciado"
  else
    warn "Paper no confirmó el arranque en 5 minutos. Revisa: journalctl -u $K_SERVICE_UNIT -e"
  fi
}
