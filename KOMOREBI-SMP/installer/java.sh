#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  java.sh — Verificación de OpenJDK 21.
#
#  No cambia la versión global (archlinux-java set): el servicio usa siempre
#  la ruta explícita JAVA_BIN (/usr/lib/jvm/java-21-openjdk/bin/java).
# =============================================================================

# java_ready — 0 si JAVA_BIN existe y es Java 21.
java_ready() {
  local major
  major=$(java_major_of "$JAVA_BIN" || true)
  [[ $major == "$JAVA_REQUIRED_MAJOR" ]]
}

# verify_java — Comprueba Java 21, informa de archlinux-java y verifica que el
# usuario del servicio puede ejecutarlo.
verify_java() {
  local out line owner def
  section "Java $JAVA_REQUIRED_MAJOR"
  if [[ ! -x $JAVA_BIN ]]; then
    if (( DRY_RUN )); then
      sim "Tras instalar $JAVA_PACKAGE se verificaría $JAVA_BIN."
      return 0
    fi
    die "No se encuentra $JAVA_BIN." "Instala Java con: sudo bash installer/install-komorebi.sh --dependencies"
  fi
  out=$("$JAVA_BIN" -version 2>&1 || true)
  info "$JAVA_BIN -version:"
  while IFS= read -r line; do
    if [[ -n $line ]]; then detail "$line"; fi
  done <<<"$out"
  if ! java_ready; then
    die "$JAVA_BIN no es Java $JAVA_REQUIRED_MAJOR." "Instala $JAVA_PACKAGE: sudo bash installer/install-komorebi.sh --dependencies"
  fi
  ok "Java $JAVA_REQUIRED_MAJOR verificado."
  if command -v pacman >/dev/null 2>&1; then
    owner=$(pacman -Qqo "$JAVA_BIN" 2>/dev/null || true)
    if [[ -n $owner ]]; then
      info "Proporcionado por el paquete: ${owner//$'\n'/ }"
    fi
  fi
  if command -v java >/dev/null 2>&1; then
    out=$(java -version 2>&1 || true)
    info "java -version (versión global del PATH): $(first_line "$out")"
  fi
  if command -v archlinux-java >/dev/null 2>&1; then
    out=$(archlinux-java status 2>&1 || true)
    info "archlinux-java status:"
    while IFS= read -r line; do
      if [[ -n $line ]]; then detail "$line"; fi
    done <<<"$out"
    def=$(archlinux-java get 2>/dev/null || true)
    if [[ $def != java-21-openjdk ]]; then
      info "La versión global es '${def:-ninguna}'. No se modifica: el servicio usa la ruta explícita $JAVA_BIN."
    fi
  fi
  if [[ $EUID -eq 0 ]] && getent passwd "$MC_USER" >/dev/null; then
    if runuser -u "$MC_USER" -- "$JAVA_BIN" -version >/dev/null 2>&1; then
      ok "El usuario $MC_USER puede ejecutar Java."
    else
      die "El usuario $MC_USER no puede ejecutar $JAVA_BIN." "Comprueba los permisos de /usr/lib/jvm."
    fi
  fi
}
