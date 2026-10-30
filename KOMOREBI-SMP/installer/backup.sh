#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  backup.sh — Unidades systemd de las copias de seguridad programadas.
#  La lógica de copia está en scripts/backup-komorebi.sh.
# =============================================================================

# install_backup_units — Instala komorebi-backup.service/.timer y ofrece
# activar el temporizador diario.
install_backup_units() {
  local out state
  section "Copias de seguridad programadas"
  if (( ! DRY_RUN )) && [[ ! -x $BIN_DIR/backup-komorebi.sh ]]; then
    install_admin_scripts
  fi
  if command -v systemd-analyze >/dev/null 2>&1; then
    if out=$(systemd-analyze calendar "$BACKUP_ONCALENDAR" 2>&1); then
      info "Programación BACKUP_ONCALENDAR='$BACKUP_ONCALENDAR':"
      while IFS= read -r state; do
        if [[ $state == *"Next elapse"* ]]; then detail "$state"; fi
      done <<<"$out"
    else
      die "BACKUP_ONCALENDAR='$BACKUP_ONCALENDAR' no es una expresión válida de systemd." "Corrígela en $KOMOREBI_CONFIG."
    fi
  fi
  unit_render_args
  UNITS_CHANGED=0
  deploy_unit komorebi-backup.service "$K_BACKUP_SERVICE_UNIT"
  deploy_unit komorebi-backup.timer "$K_BACKUP_TIMER_UNIT"
  reload_units_if_needed "$K_BACKUP_SERVICE_UNIT" "$K_BACKUP_TIMER_UNIT"
  verify_units "$K_BACKUP_SERVICE_UNIT" "$K_BACKUP_TIMER_UNIT"
  info "Modo de backup: $BACKUP_MODE · retención diaria=$BACKUP_KEEP_DAILY semanal=$BACKUP_KEEP_WEEKLY manual=$BACKUP_KEEP_MANUAL (0 = sin límite)"
  # Un temporizador activo debe reiniciarse para recalcular la próxima ejecución
  # tras cambiar OnCalendar.
  if (( UNITS_CHANGED )) && systemctl is-active --quiet -- "$K_BACKUP_TIMER_UNIT" 2>/dev/null; then
    run systemctl restart -- "$K_BACKUP_TIMER_UNIT"
    record_change "Temporizador reiniciado con la nueva programación ($BACKUP_ONCALENDAR)"
  fi
  state=$(systemctl is-enabled -- "$K_BACKUP_TIMER_UNIT" 2>/dev/null || true)
  if [[ $state == enabled ]]; then
    ok "El temporizador de backups ya está activo."
    return 0
  fi
  if confirm "¿Activar las copias de seguridad diarias automáticas ($BACKUP_ONCALENDAR)?" s; then
    run systemctl enable --now -- "$K_BACKUP_TIMER_UNIT"
    record_change "Backups diarios activados ($K_BACKUP_TIMER_UNIT)"
  else
    record_pending "Activar backups automáticos: sudo systemctl enable --now $K_BACKUP_TIMER_UNIT"
  fi
  record_pending "Probar una restauración: sudo backup-komorebi.sh && sudo restore-komorebi.sh --list"
}
