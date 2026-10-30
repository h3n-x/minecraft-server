#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  security.sh — Seguridad: propiedades del servidor, cortafuegos opcional,
#  SSH opcional y guía de acceso externo (CGNAT, port forwarding manual).
#
#  Nunca: desactiva un cortafuegos, activa dos gestores a la vez, abre SSH a
#  Internet, cambia el router ni la política de autenticación sin aprobación.
# =============================================================================

ACTIVE_FIREWALLS=()

# check_security_properties — Avisa si server.properties relaja la seguridad.
check_security_properties() {
  local f="$MC_DIR/server.properties" kv key want cur bad=0
  [[ -f $f ]] || return 0
  for kv in "${SECURITY_PROPERTIES[@]}" 'white-list=true'; do
    key=${kv%%=*}
    want=${kv#*=}
    cur=$(properties_get "$f" "$key" || true)
    if [[ -n $cur && $cur != "$want" ]]; then
      warn "server.properties: $key=$cur (se recomienda $want)."
      bad=1
    fi
  done
  if (( ! bad )); then
    ok "server.properties: online-mode, whitelist, RCON y command blocks con valores seguros."
  fi
}

# lan_network_of IP/PREFIJO — Red privada IPv4 (ej. 192.168.1.0/24). Vacío si
# la dirección no es privada (RFC 1918).
lan_network_of() {
  local cidr=$1 ip prefix a b c d n mask net
  ip=${cidr%/*}
  prefix=${cidr#*/}
  # Dos comprobaciones separadas: un segundo =~ sobrescribiría BASH_REMATCH.
  [[ $prefix =~ ^[0-9]+$ ]] || return 1
  [[ $ip =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  if ! { (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) || (( a == 192 && b == 168 )); }; then
    return 1
  fi
  (( prefix >= 8 && prefix <= 30 )) || return 1
  n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  net=$(( n & mask ))
  printf '%d.%d.%d.%d/%d\n' $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) $(( (net >> 8) & 255 )) $(( net & 255 )) "$prefix"
}

# detect_firewalls — Rellena ACTIVE_FIREWALLS con los gestores activos.
detect_firewalls() {
  local out
  ACTIVE_FIREWALLS=()
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw.service 2>/dev/null; then
    out=$(ufw status 2>/dev/null || true)
    if [[ $out == *"Status: active"* ]]; then ACTIVE_FIREWALLS+=(ufw); fi
  fi
  if systemctl is-active --quiet firewalld.service 2>/dev/null; then ACTIVE_FIREWALLS+=(firewalld); fi
  if systemctl is-active --quiet nftables.service 2>/dev/null; then ACTIVE_FIREWALLS+=(nftables); fi
  if systemctl is-active --quiet iptables.service 2>/dev/null || systemctl is-active --quiet ip6tables.service 2>/dev/null; then
    ACTIVE_FIREWALLS+=(iptables)
  fi
}

# report_firewall — Muestra el estado del cortafuegos (solo lectura).
report_firewall() {
  detect_firewalls
  if (( ${#ACTIVE_FIREWALLS[@]} == 0 )); then
    info "Cortafuegos: ninguno activo (Arch Linux no trae uno activado por defecto)."
  elif (( ${#ACTIVE_FIREWALLS[@]} > 1 )); then
    warn "Hay varios gestores de cortafuegos activos a la vez: ${ACTIVE_FIREWALLS[*]}. Puede provocar reglas contradictorias."
  else
    ok "Cortafuegos activo: ${ACTIVE_FIREWALLS[0]}"
  fi
}

# ssh_lan_rule_needed — 0 si conviene permitir SSH desde la LAN al activar ufw
# (sshd habilitado o sesión actual por SSH) para no bloquear el acceso.
ssh_lan_rule_needed() {
  [[ -n ${SSH_CONNECTION:-} ]] && return 0
  # sudo suele borrar SSH_CONNECTION: si sshd está activo o habilitado se
  # asume que puede haber sesiones remotas.
  systemctl is-active --quiet sshd.service 2>/dev/null && return 0
  systemctl is-enabled --quiet sshd.service 2>/dev/null
}

# detect_vpn_ifaces — Imprime interfaces de VPN presentes (Tailscale,
# WireGuard, ZeroTier, OpenVPN/tun). Activar ufw con SSH solo desde la LAN
# bloquearía las conexiones SSH nuevas que lleguen por ellas.
detect_vpn_ifaces() {
  local d n
  for d in "$SYS_NET_DIR"/*; do
    [[ -e $d ]] || continue
    n=${d##*/}
    case $n in
      tailscale*|wg*|zt*|tun*|tap*) printf '%s\n' "$n" ;;
    esac
  done
}

# firewalld_zone — Zona de firewalld de la interfaz de salida (si se conoce) o
# la zona por defecto. NetworkManager puede asignar el Wi-Fi a otra zona.
firewalld_zone() {
  local z=""
  if [[ -n $DEFAULT_IFACE ]]; then
    z=$(firewall-cmd --get-zone-of-interface="$DEFAULT_IFACE" 2>/dev/null || true)
  fi
  if [[ -z $z ]]; then
    z=$(firewall-cmd --get-default-zone 2>/dev/null || true)
  fi
  printf '%s\n' "$z"
}

# configure_firewall — Abre TCP SERVER_PORT en el gestor activo, o propone ufw
# si no hay ninguno. Requiere confirmación.
configure_firewall() {
  local lan rules zone vpn v
  section "Cortafuegos (opcional)"
  if reboot_pending; then
    warn "Hay un reinicio pendiente (kernel actualizado): los módulos de netfilter podrían no cargarse."
    record_pending "Reiniciar y después configurar el cortafuegos: sudo bash installer/install-komorebi.sh --firewall"
    return 0
  fi
  detect_firewalls
  if (( ${#ACTIVE_FIREWALLS[@]} > 1 )); then
    warn "Gestores activos: ${ACTIVE_FIREWALLS[*]}. No se modifica nada para no empeorar el conflicto."
    record_pending "Dejar un único gestor de cortafuegos activo y abrir TCP $SERVER_PORT en él."
    return 0
  fi
  case ${ACTIVE_FIREWALLS[0]:-none} in
    ufw)
      rules=$(ufw status 2>/dev/null || true)
      if [[ $rules == *"$SERVER_PORT/tcp"* ]]; then
        ok "ufw ya permite $SERVER_PORT/tcp."
        return 0
      fi
      if confirm "¿Añadir a ufw la regla 'allow $SERVER_PORT/tcp' (Minecraft)?" s; then
        run ufw allow "$SERVER_PORT/tcp" comment 'KOMOREBI SMP Minecraft'
        record_change "ufw: permitido $SERVER_PORT/tcp"
      fi
      ;;
    firewalld)
      zone=$(firewalld_zone)
      if [[ -z $zone ]]; then
        warn "No se pudo determinar la zona de firewalld; no se modifica nada."
        record_pending "Abrir TCP $SERVER_PORT en la zona de firewalld de ${DEFAULT_IFACE:-la interfaz de red}."
        return 0
      fi
      if firewall-cmd --zone="$zone" --query-port="$SERVER_PORT/tcp" >/dev/null 2>&1; then
        ok "firewalld ya permite $SERVER_PORT/tcp en la zona $zone."
        return 0
      fi
      if confirm "¿Abrir $SERVER_PORT/tcp en firewalld (zona '$zone' de ${DEFAULT_IFACE:-la interfaz}, permanente)?" s; then
        run firewall-cmd --zone="$zone" --permanent --add-port="$SERVER_PORT/tcp"
        run firewall-cmd --zone="$zone" --add-port="$SERVER_PORT/tcp"
        record_change "firewalld: abierto $SERVER_PORT/tcp en la zona $zone"
      fi
      ;;
    nftables|iptables)
      info "Gestor activo: ${ACTIVE_FIREWALLS[0]}. Su configuración es manual y no se edita automáticamente."
      cat <<EOF
  Añade una regla de entrada para TCP $SERVER_PORT, por ejemplo en /etc/nftables.conf,
  dentro de la cadena 'input' de la tabla 'inet filter':
      tcp dport $SERVER_PORT accept comment "KOMOREBI SMP"
  Comprueba la sintaxis con:  sudo nft -c -f /etc/nftables.conf
  Aplica con:                 sudo systemctl reload nftables
EOF
      record_pending "Abrir TCP $SERVER_PORT en ${ACTIVE_FIREWALLS[0]} manualmente (ver instrucciones mostradas)."
      ;;
    none)
      info "No hay cortafuegos activo. Se puede instalar ufw con: denegar entradas, permitir $SERVER_PORT/tcp y SSH solo desde la LAN."
      lan=$(lan_network_of "${LOCAL_CIDR:-}" || true)
      if ssh_lan_rule_needed && [[ -z $lan ]]; then
        warn "SSH está habilitado pero no se pudo determinar la red local: activar ufw podría bloquear tu acceso. Configúralo manualmente."
        record_pending "Configurar un cortafuegos manualmente (no se pudo determinar la LAN)."
        return 0
      fi
      vpn=$(detect_vpn_ifaces)
      if [[ -n $vpn ]]; then
        warn "Interfaces de VPN detectadas: ${vpn//$'\n'/, }. Con ufw activo, el SSH que llegue por ellas quedaría bloqueado salvo que se permita."
      fi
      if ! confirm_typed "¿Instalar y activar ufw (deny incoming, allow $SERVER_PORT/tcp${lan:+, SSH desde $lan})?" "SI"; then
        record_skip "Cortafuegos sin configurar"
        record_pending "Valorar un cortafuegos: sudo bash installer/install-komorebi.sh --firewall"
        return 0
      fi
      if ! command -v ufw >/dev/null 2>&1; then
        if [[ -e /var/lib/pacman/db.lck ]]; then
          die "pacman está bloqueado (/var/lib/pacman/db.lck)." "Espera a que termine y repite con --firewall."
        fi
        run pacman -Syu --needed ufw
      fi
      run ufw default deny incoming
      run ufw default allow outgoing
      run ufw allow "$SERVER_PORT/tcp" comment 'KOMOREBI SMP Minecraft'
      if [[ -n $lan ]]; then
        run ufw allow from "$lan" to any port 22 proto tcp comment 'SSH solo LAN'
      fi
      for v in $vpn; do
        if confirm "¿Permitir también SSH entrante por la interfaz de VPN $v?" s; then
          run ufw allow in on "$v" to any port 22 proto tcp comment "SSH por VPN $v"
          record_change "ufw: SSH permitido por $v"
        fi
      done
      run systemctl enable --now ufw.service
      run ufw --force enable
      record_change "ufw instalado y activado (entrada denegada; $SERVER_PORT/tcp permitido${lan:+; SSH desde $lan})"
      ;;
  esac
}

# configure_ssh — Instala/activa OpenSSH de forma segura (opcional).
configure_ssh() {
  local tmp out admin_user home keys=0 prev_backup
  section "SSH (opcional)"
  if ! command -v sshd >/dev/null 2>&1; then
    if ! confirm "OpenSSH no está instalado. ¿Instalarlo con 'pacman -Syu --needed openssh'?" n; then
      record_skip "SSH no instalado"
      return 0
    fi
    if [[ -e /var/lib/pacman/db.lck ]]; then
      die "pacman está bloqueado (/var/lib/pacman/db.lck)." "Espera a que termine y repite con --ssh."
    fi
    run pacman -Syu --needed openssh
    record_change "openssh instalado"
  fi
  if [[ -f $SSHD_CONFIG ]] && ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' -- "$SSHD_CONFIG"; then
    warn "$SSHD_CONFIG no incluye /etc/ssh/sshd_config.d/*.conf: no se aplicará el drop-in y no se edita el fichero principal."
    record_pending "Revisar $SSHD_CONFIG manualmente (PermitRootLogin no) haciendo antes una copia."
  else
    if confirm "¿Crear $SSHD_DROPIN_FILE con 'PermitRootLogin no' (no modifica sshd_config)?" s; then
      ensure_dir "$SSHD_DROPIN_DIR" root root 0755
      tmp=$(make_tmp_file)
      register_tmp "$tmp"
      {
        printf '# Gestionado por el instalador de KOMOREBI SMP.\n'
        printf '# Se evalúa antes que 99-archlinux.conf; la primera coincidencia gana.\n'
        printf 'PermitRootLogin no\n'
      } >"$tmp"
      admin_user=${SUDO_USER:-}
      if [[ -n $admin_user && $admin_user != root ]]; then
        home=$(getent passwd "$admin_user" | cut -d: -f6)
        if [[ -s $home/.ssh/authorized_keys ]]; then keys=1; fi
      fi
      if (( keys )); then
        info "El usuario $admin_user tiene claves en ~/.ssh/authorized_keys."
        if confirm_typed "¿Desactivar el acceso por contraseña (solo claves SSH)?" "SI"; then
          printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >>"$tmp"
        fi
      else
        info "No se encontraron claves SSH de ${admin_user:-tu usuario}: se mantiene la autenticación por contraseña."
        record_pending "Crear claves SSH (ssh-keygen -t ed25519; ssh-copy-id usuario@$LOCAL_IP) y después desactivar contraseñas."
      fi
      deploy_file "$tmp" "$SSHD_DROPIN_FILE" 0644 root root "Drop-in de sshd"
      if (( DEPLOY_CHANGED && ! DRY_RUN )); then
        if ! out=$(sshd -t 2>&1); then
          error "sshd -t rechaza la configuración: $out"
          prev_backup="$BACKUP_DIR/installer/$RUN_ID$SSHD_DROPIN_FILE"
          if [[ -f $prev_backup ]]; then
            cp -a -- "$prev_backup" "$SSHD_DROPIN_FILE"
          else
            rm -f -- "$SSHD_DROPIN_FILE"
          fi
          die "Se ha revertido $SSHD_DROPIN_FILE; sshd no se ha recargado." "Revisa la configuración de SSH manualmente."
        fi
        ok "sshd -t: configuración válida."
        if systemctl is-active --quiet sshd.service; then
          run systemctl reload sshd.service
        fi
      fi
    fi
  fi
  if systemctl is-enabled --quiet sshd.service 2>/dev/null; then
    ok "sshd ya está habilitado."
  elif confirm "¿Habilitar e iniciar sshd ahora?" n; then
    run systemctl enable --now sshd.service
    record_change "sshd habilitado e iniciado"
  fi
  cat <<EOF

  Conexión desde otro equipo de la red local:
      ssh ${SUDO_USER:-usuario}@${LOCAL_IP:-IP_LOCAL}
  No redirijas el puerto 22 en el router. Para administrar desde fuera de casa
  usa una VPN (por ejemplo WireGuard) en lugar de exponer SSH a Internet.

EOF
}

# print_network_guidance — Guía de acceso externo (no cambia nada).
print_network_guidance() {
  section "Acceso desde Internet (guía; no se modifica el router)"
  cat <<EOF
  1. Prueba primero en la LAN: en Minecraft, conecta a ${LOCAL_IP:-IP_LOCAL}:$SERVER_PORT.
  2. Reserva la IP local de este equipo en el router (DHCP estático).
  3. CGNAT: compara la IP WAN que muestra el router con tu IP pública. Si son
     distintas, o la WAN está en 100.64.0.0/10, estás detrás de CGNAT y el port
     forwarding no funcionará: pide una IP pública a tu operador o usa una VPN/túnel.
  4. Port forwarding MANUAL en el router: TCP $SERVER_PORT → ${LOCAL_IP:-IP_LOCAL}:$SERVER_PORT.
     Solo ese puerto. Nunca el 22 (SSH).
  5. Mantén white-list=true hasta decidir la apertura pública.
EOF
  record_pending "Comprobar CGNAT y, si procede, configurar manualmente el port forwarding TCP $SERVER_PORT en el router."
}
