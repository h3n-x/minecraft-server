#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  dependencies.sh — Paquetes del sistema mediante pacman.
#
#  * Solo se instala lo que falta (pacman -T, que también reconoce "provides":
#    jre21-openjdk o jdk21-openjdk satisfacen jre21-openjdk-headless).
#  * Nunca se hace una actualización parcial (-Sy): se usa una única
#    transacción `pacman -Syu --needed <paquetes>`.
#  * No se ejecuta pacman de forma concurrente: se aborta si existe db.lck.
# =============================================================================

# missing_packages PAQUETE... — Imprime los paquetes no satisfechos.
missing_packages() {
  local out
  out=$(pacman -T "$@" 2>/dev/null || true)
  printf '%s\n' "$out"
}

# install_dependencies MONITORIZACIÓN(0|1) — Instala dependencias necesarias.
install_dependencies() {
  local with_monitoring=${1:-0} pkgs=() missing=() out p args
  section "Dependencias del sistema (pacman)"
  if ! command -v pacman >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      sim "pacman no disponible: se omitiría la instalación de paquetes."
      return 0
    fi
    die "pacman no está disponible." "Este instalador solo funciona en Arch Linux."
  fi
  pkgs=("${REQUIRED_PACKAGES[@]}")
  if (( with_monitoring )); then
    pkgs+=("${MONITORING_PACKAGES[@]}")
  fi
  out=$(missing_packages "${pkgs[@]}")
  for p in $out; do
    missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    ok "Todos los paquetes necesarios están instalados: ${pkgs[*]}"
    record_skip "Paquetes del sistema (ya instalados)"
    return 0
  fi
  info "Paquetes que faltan: ${missing[*]}"
  cat <<EOF

  Arch Linux no admite actualizaciones parciales: para instalar estos paquetes
  hay que actualizar TODO el sistema en la misma operación (pacman -Syu),
  incluido el kernel si hay versión nueva (en ese caso habrá que reiniciar).

  Recomendado si la laptop lleva tiempo sin actualizarse:
    1. Cancela aquí (respuesta por defecto: no).
    2. Ejecuta tú:  sudo pacman -Syu   y reinicia si se actualizó el kernel.
       Si falla por firmas PGP:  sudo pacman -Sy archlinux-keyring && sudo pacman -Su
    3. Vuelve a lanzar el instalador.
  No interrumpas pacman (Ctrl+C) mientras instala: podría dejar el sistema a medias.

EOF
  if [[ -e /var/lib/pacman/db.lck ]]; then
    die "pacman está bloqueado (/var/lib/pacman/db.lck)." \
        "Espera a que termine la otra operación. Si no hay ningún pacman activo (pgrep -a pacman), elimina el bloqueo manualmente."
  fi
  if (( DRY_RUN )); then
    sim "Se preguntaría si actualizar todo el sistema (respuesta por defecto: no). Si se acepta:"
    run pacman -Syu --needed "${missing[@]}"
    record_change "Paquetes (si se acepta la actualización completa): ${missing[*]}"
    return 0
  fi
  if ! confirm "¿Actualizar todo el sistema e instalar los paquetes ('pacman -Syu --needed ${missing[*]}')?" n; then
    die "No se instalaron las dependencias (no se ha modificado nada)." \
        "Actualiza el sistema (sudo pacman -Syu), reinicia si cambió el kernel y repite;" \
        "o instálalas tú: sudo pacman -Syu --needed ${missing[*]}"
  fi
  args=(-Syu --needed)
  if (( ASSUME_YES )); then
    warn "--yes: pacman se ejecutará con --noconfirm (sin revisar la transacción)."
    args+=(--noconfirm)
  fi
  run pacman "${args[@]}" "${missing[@]}"
  if (( ! DRY_RUN )); then
    out=$(missing_packages "${missing[@]}")
    if [[ -n ${out//[[:space:]]/} ]]; then
      die "Siguen faltando paquetes tras pacman: $out" "Revisa la salida de pacman y vuelve a intentarlo."
    fi
  fi
  ok "Paquetes instalados: ${missing[*]}"
  record_change "Paquetes instalados con pacman: ${missing[*]} (con actualización completa -Syu)"
  if [[ " ${missing[*]} " == *" lm_sensors "* ]]; then
    record_pending "Detectar sensores de temperatura (interactivo): sudo sensors-detect"
  fi
  check_reboot_needed
}

# check_reboot_needed — Si el kernel en ejecución ya no tiene módulos en disco
# (se actualizó el paquete linux), recomienda reiniciar.
check_reboot_needed() {
  if (( DRY_RUN )); then
    return 0
  fi
  if reboot_pending; then
    warn "El kernel se ha actualizado: reinicia el equipo antes de poner el servidor en producción."
    record_pending "Reiniciar el sistema (kernel actualizado por pacman -Syu)."
  fi
}
