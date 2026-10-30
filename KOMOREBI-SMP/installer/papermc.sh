#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  papermc.sh — Descarga verificada de Paper, eula.txt y server.properties.
#
#  Fuente: servicio oficial Fill v3 (https://fill.papermc.io/v3). La API v2
#  responde 410 (retirada) y no se usa.
#  Verificación: canal STABLE, nombre esperado, URL oficial, HTTP 200, tamaño
#  anunciado, SHA-256 de la API == SHA-256 fijado en la configuración ==
#  SHA-256 del fichero descargado, y firma ZIP.
# =============================================================================

PAPER_RESOLVED_BUILD=""
PAPER_RESOLVED_CHANNEL=""
PAPER_RESOLVED_NAME=""
PAPER_RESOLVED_URL=""
PAPER_RESOLVED_SHA256=""
PAPER_RESOLVED_SIZE=""

# resolve_paper_build — Consulta la API y valida los metadatos de la build.
resolve_paper_build() {
  local base json sel apierr support row name_re
  require_cmd curl jq
  base="$PAPER_API_BASE/projects/$PAPER_PROJECT/versions/$MC_VERSION"

  json=$(http_get_json "$base") ||
    die "No se pudo consultar Paper $MC_VERSION en la API oficial." \
        "Comprueba la conexión. Versiones disponibles: $PAPER_API_BASE/projects/$PAPER_PROJECT"
  support=$(jq -r '.version.support.status // "desconocido"' <<<"$json")
  if [[ $support == UNSUPPORTED ]]; then
    warn "PaperMC marca $MC_VERSION como UNSUPPORTED: no recibirá más parches de seguridad. Planifica una migración futura."
  fi

  if [[ $PAPER_BUILD == latest-stable ]]; then
    json=$(http_get_json "$base/builds") || die "No se pudo obtener la lista de builds de Paper $MC_VERSION."
    sel=$(jq -c 'if type == "array" then (map(select(.channel == "STABLE")) | .[0] // empty) else empty end' <<<"$json")
  else
    json=$(http_get_json "$base/builds/$PAPER_BUILD") ||
      die "No se pudo obtener la build $PAPER_BUILD de Paper $MC_VERSION." \
          "Comprueba PAPER_BUILD en $KOMOREBI_CONFIG."
    sel=$json
  fi
  apierr=$(jq -r 'if type == "object" and .ok == false then (.message // "error") else empty end' <<<"$sel" 2>/dev/null || true)
  if [[ -n $apierr ]]; then
    die "La API de Paper devolvió un error: $apierr"
  fi
  if [[ -z $sel ]]; then
    die "No hay builds estables de Paper para $MC_VERSION." "Revisa MC_VERSION/PAPER_BUILD en $KOMOREBI_CONFIG."
  fi

  row=$(jq -r '[.id, .channel, (.downloads["server:default"] | .name, .url, .checksums.sha256, .size)] | map(tostring) | join("\t")' <<<"$sel") ||
    die "Respuesta de la API de Paper con formato inesperado."
  IFS=$'\t' read -r PAPER_RESOLVED_BUILD PAPER_RESOLVED_CHANNEL PAPER_RESOLVED_NAME \
    PAPER_RESOLVED_URL PAPER_RESOLVED_SHA256 PAPER_RESOLVED_SIZE <<<"$row"

  name_re="^paper-${MC_VERSION//./\\.}-${PAPER_RESOLVED_BUILD}\\.jar$"
  [[ $PAPER_RESOLVED_BUILD =~ ^[0-9]+$ ]] || die "Número de build no válido en la respuesta de la API."
  [[ $PAPER_RESOLVED_CHANNEL == STABLE ]] ||
    die "La build $PAPER_RESOLVED_BUILD está en el canal $PAPER_RESOLVED_CHANNEL; solo se instalan builds STABLE."
  [[ $PAPER_RESOLVED_NAME =~ $name_re ]] || die "Nombre de fichero inesperado: $PAPER_RESOLVED_NAME"
  [[ $PAPER_RESOLVED_URL =~ $PAPER_DOWNLOAD_URL_REGEX ]] || die "URL de descarga no oficial: $PAPER_RESOLVED_URL"
  [[ $PAPER_RESOLVED_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "La API no publicó un SHA-256 válido."
  if [[ ! $PAPER_RESOLVED_SIZE =~ ^[0-9]+$ ]] || (( PAPER_RESOLVED_SIZE < PAPER_MIN_SIZE_BYTES )); then
    die "Tamaño anunciado no razonable: $PAPER_RESOLVED_SIZE bytes."
  fi
  if [[ $PAPER_BUILD != latest-stable && -n $PAPER_SHA256 && $PAPER_SHA256 != "$PAPER_RESOLVED_SHA256" ]]; then
    die "El SHA-256 publicado por la API no coincide con el fijado en la configuración." \
        "API: $PAPER_RESOLVED_SHA256" "Configuración: $PAPER_SHA256" \
        "No se descarga nada. Verifica manualmente en https://papermc.io/downloads/paper"
  fi
  if (( PAPER_RESOLVED_BUILD < PAPER_MIN_JAVA21_BUILD )); then
    warn "La build $PAPER_RESOLVED_BUILD es anterior a la $PAPER_MIN_JAVA21_BUILD, la primera con soporte de Java 21."
  fi
  ok "Paper $MC_VERSION build $PAPER_RESOLVED_BUILD ($PAPER_RESOLVED_CHANNEL): $PAPER_RESOLVED_NAME, $(k_human_bytes "$PAPER_RESOLVED_SIZE")"
  detail "sha256 $PAPER_RESOLVED_SHA256"
}

# zip_signature_ok FICHERO — 0 si empieza por la firma ZIP/JAR "PK\x03\x04".
zip_signature_ok() {
  local sig
  sig=$(od -An -tx1 -N4 -- "$1" 2>/dev/null || true)
  [[ ${sig//[[:space:]]/} == 504b0304 ]]
}

# fix_file_perms FICHERO MODO PROPIETARIO GRUPO — Ajusta si difiere.
fix_file_perms() {
  local f=$1 mode=$2 owner=$3 group=$4 cur
  cur=$(stat -c '%U:%G %a' -- "$f")
  if [[ $cur != "$owner:$group ${mode#0}" ]]; then
    run chown "$owner:$group" -- "$f"
    run chmod "$mode" -- "$f"
    info "Permisos ajustados: $f ($owner:$group $mode)"
  fi
}

# install_paper — Instala o verifica /var/lib/minecraft/paper.jar.
install_paper() {
  local dest="$MC_DIR/paper.jar" cur tmp actual_size actual_sha
  section "PaperMC $MC_VERSION"
  if (( ! DRY_RUN )); then
    getent passwd "$MC_USER" >/dev/null || die "No existe el usuario $MC_USER." "Ejecuta la instalación completa."
    [[ -d $MC_DIR ]] || die "No existe $MC_DIR." "Ejecuta la instalación completa."
  fi
  resolve_paper_build

  if [[ -f $dest ]]; then
    cur=$(sha_of sha256 "$dest")
    if [[ $cur == "$PAPER_RESOLVED_SHA256" ]]; then
      ok "paper.jar ya corresponde a la build $PAPER_RESOLVED_BUILD (SHA-256 verificado)."
      fix_file_perms "$dest" 0640 "$MC_USER" "$MC_GROUP"
      record_skip "Paper $MC_VERSION build $PAPER_RESOLVED_BUILD (ya instalado)"
      write_versions_state
      return 0
    fi
    warn "Existe un paper.jar distinto (sha256 ${cur:0:16}…)."
    if k_service_active; then
      die "El servidor está en ejecución; no se reemplaza paper.jar en caliente." \
          "Detén el servidor (sudo stop-komorebi.sh), crea un backup y repite con --paper."
    fi
    if ! confirm "¿Reemplazar paper.jar por la build $PAPER_RESOLVED_BUILD? (se guarda copia del actual)" n; then
      record_skip "paper.jar existente conservado"
      return 0
    fi
    backup_file "$dest"
  fi

  if (( DRY_RUN )); then
    sim "descargar $PAPER_RESOLVED_URL"
    sim "verificar tamaño ($PAPER_RESOLVED_SIZE bytes), SHA-256 y firma ZIP; instalar en $dest ($MC_USER:$MC_GROUP 0640)"
    record_change "Paper $MC_VERSION build $PAPER_RESOLVED_BUILD → $dest"
    return 0
  fi

  tmp=$(make_tmp_file "$MC_DIR")
  register_tmp "$tmp"
  info "Descargando $PAPER_RESOLVED_NAME…"
  http_download "$PAPER_RESOLVED_URL" "$tmp" ||
    die "No se pudo descargar Paper." "Comprueba la conexión y vuelve a intentarlo."
  actual_size=$(stat -c '%s' -- "$tmp")
  if [[ $actual_size != "$PAPER_RESOLVED_SIZE" ]]; then
    die "Tamaño incorrecto: $actual_size bytes (esperado $PAPER_RESOLVED_SIZE)." "Descarga incompleta o alterada; vuelve a intentarlo."
  fi
  actual_sha=$(sha_of sha256 "$tmp")
  if [[ $actual_sha != "$PAPER_RESOLVED_SHA256" ]]; then
    die "SHA-256 incorrecto: $actual_sha" "Esperado: $PAPER_RESOLVED_SHA256. No se instala el fichero."
  fi
  zip_signature_ok "$tmp" || die "El fichero descargado no es un JAR válido."
  chown "$MC_USER:$MC_GROUP" -- "$tmp"
  chmod 0640 -- "$tmp"
  mv -f -- "$tmp" "$dest"
  ok "paper.jar instalado y verificado (HTTP 200, tamaño, SHA-256, firma ZIP)."
  record_change "Paper $MC_VERSION build $PAPER_RESOLVED_BUILD → $dest"
  write_versions_state
}

# write_versions_state — Registro informativo de versiones instaladas.
write_versions_state() {
  local tmp jv
  [[ -d $CONFIG_DIR ]] || return 0
  jv=$("$JAVA_BIN" -version 2>&1 || true)
  tmp=$(make_tmp_file)
  register_tmp "$tmp"
  {
    printf '# Versiones instaladas por el instalador KOMOREBI SMP (informativo).\n'
    printf 'installer=%s\n' "$INSTALLER_VERSION"
    printf 'minecraft=%s\n' "$MC_VERSION"
    printf 'paper_build=%s\n' "$PAPER_RESOLVED_BUILD"
    printf 'paper_sha256=%s\n' "$PAPER_RESOLVED_SHA256"
    printf 'java=%s\n' "$(first_line "$jv")"
  } >"$tmp"
  if same_file "$tmp" "$VERSIONS_STATE_FILE"; then
    return 0
  fi
  install_file "$tmp" "$VERSIONS_STATE_FILE" 0644 root root
}

# -----------------------------------------------------------------------------
# EULA
# -----------------------------------------------------------------------------

# ensure_eula_file — Crea eula.txt con eula=false si no existe. Nunca acepta.
ensure_eula_file() {
  local f="$MC_DIR/eula.txt" tmp
  if [[ -f $f ]]; then
    if k_eula_accepted; then
      ok "EULA de Minecraft aceptado previamente ($f)."
    else
      info "eula.txt existe y el EULA no está aceptado."
      record_pending "Leer y aceptar el EULA de Minecraft: sudo bash installer/install-komorebi.sh --eula"
    fi
    return 0
  fi
  tmp=$(make_tmp_file)
  register_tmp "$tmp"
  cat >"$tmp" <<EOF
#By changing the setting below to TRUE you are indicating your agreement to our EULA ($MINECRAFT_EULA_URL).
# Creado por el instalador de KOMOREBI SMP: el EULA NO se acepta automaticamente.
# Para leerlo y aceptarlo: sudo bash installer/install-komorebi.sh --eula
eula=false
EOF
  install_file "$tmp" "$f" 0640 "$MC_USER" "$MC_GROUP"
  ok "eula.txt creado con eula=false."
  record_change "eula.txt creado (eula=false)"
  record_pending "Leer y aceptar el EULA de Minecraft: sudo bash installer/install-komorebi.sh --eula"
}

# accept_eula — Muestra las condiciones y solicita aceptación explícita.
accept_eula() {
  local f="$MC_DIR/eula.txt" tmp
  section "EULA de Minecraft"
  if [[ ! -f $MC_DIR/paper.jar && $DRY_RUN -eq 0 ]]; then
    die "Paper no está instalado." "Instálalo primero: sudo bash installer/install-komorebi.sh --paper"
  fi
  if [[ -f $f ]] && k_eula_accepted; then
    ok "El EULA ya está aceptado."
    return 0
  fi
  cat <<EOF

  Para ejecutar un servidor de Minecraft debes aceptar el Contrato de Licencia
  de Usuario Final (EULA) de Minecraft de Mojang/Microsoft.

    Texto completo:          $MINECRAFT_EULA_URL
    Directrices de uso:      https://www.minecraft.net/usage-guidelines

  Este instalador no puede aceptarlo por ti ni resumirlo con valor legal.
  Léelo completo antes de continuar (presta atención a las condiciones sobre
  monetización de servidores, ya que KOMOREBI contempla donaciones y rangos).

EOF
  if ! confirm_typed "¿Has leído el EULA de Minecraft y aceptas sus condiciones?" "ACEPTO"; then
    info "EULA no aceptado: el servicio no arrancará (ExecStartPre lo impide)."
    record_pending "Leer y aceptar el EULA de Minecraft: sudo bash installer/install-komorebi.sh --eula"
    return 0
  fi
  backup_file "$f"
  tmp=$(make_tmp_file)
  register_tmp "$tmp"
  cat >"$tmp" <<EOF
#By changing the setting below to TRUE you are indicating your agreement to our EULA ($MINECRAFT_EULA_URL).
# Aceptado de forma interactiva el $(date '+%F %T') por ${SUDO_USER:-root} mediante el instalador de KOMOREBI SMP.
eula=true
EOF
  install_file "$tmp" "$f" 0640 "$MC_USER" "$MC_GROUP"
  ok "EULA aceptado."
  record_change "EULA de Minecraft aceptado explícitamente (eula=true)"
  # Si las unidades ya están instaladas, ahora sí se habilita el servicio.
  enable_service_if_eula
}

# -----------------------------------------------------------------------------
# server.properties (editor propio: sin sed, conserva comentarios y claves
# ajenas, elimina duplicados de claves gestionadas y escribe de forma atómica)
# -----------------------------------------------------------------------------

# Expresión de una línea "clave=valor" o "clave: valor" (Java Properties).
PROP_LINE_RE='^[[:space:]]*([^#![:space:]=:]+)[[:space:]]*[=:][[:space:]]*(.*)$'

# properties_get FICHERO CLAVE — Imprime el valor efectivo (tal cual, con
# escapes). Como en java.util.Properties, si la clave se repite gana la última
# aparición. Devuelve 1 si la clave no existe.
properties_get() {
  local file=$1 key=$2 line k v found=0 val=""
  [[ -f $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ $line =~ $PROP_LINE_RE ]]; then
      k=${BASH_REMATCH[1]}
      v=${BASH_REMATCH[2]}
      if [[ $k == "$key" ]]; then
        val=$v
        found=1
      fi
    fi
  done <"$file"
  (( found )) || return 1
  printf '%s\n' "$val"
}

# properties_render ORIGEN DESTINO CLAVE=VALOR... — Escribe en DESTINO el
# contenido de ORIGEN (si existe) con las claves indicadas actualizadas; las
# que falten se añaden al final en el orden recibido.
properties_render() {
  local src=$1 out=$2 kv key line k
  shift 2
  local -A want=() seen=()
  local order=()
  for kv in "$@"; do
    key=${kv%%=*}
    want[$key]=${kv#*=}
    order+=("$key")
  done
  : >"$out"
  if [[ -f $src ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%$'\r'}
      if [[ $line =~ $PROP_LINE_RE ]]; then
        k=${BASH_REMATCH[1]}
        if [[ -n ${want[$k]+x} ]]; then
          if [[ -z ${seen[$k]:-} ]]; then
            printf '%s=%s\n' "$k" "${want[$k]}" >>"$out"
            seen[$k]=1
          fi
          continue
        fi
      fi
      printf '%s\n' "$line" >>"$out"
    done <"$src"
  else
    printf '#Minecraft server properties\n# Generado por el instalador de KOMOREBI SMP\n' >>"$out"
  fi
  for k in "${order[@]}"; do
    if [[ -z ${seen[$k]:-} ]]; then
      printf '%s=%s\n' "$k" "${want[$k]}" >>"$out"
    fi
  done
}

# configure_server_properties — Crea o actualiza server.properties con los
# valores de KOMOREBI (con copia y consentimiento si el fichero ya existe).
configure_server_properties() {
  local f="$MC_DIR/server.properties" kv key want cur diffs=() tmp
  section "server.properties"
  build_server_properties
  if [[ -f $f ]]; then
    for kv in "${SERVER_PROPERTIES[@]}"; do
      key=${kv%%=*}
      want=${kv#*=}
      cur=$(properties_get "$f" "$key" || printf '%s' '<ausente>')
      if [[ $cur != "$want" ]]; then
        diffs+=("$key: '$cur' -> '$want'")
      fi
    done
    if (( ${#diffs[@]} == 0 )); then
      ok "server.properties ya tiene los valores de KOMOREBI."
      record_skip "server.properties (sin cambios)"
      return 0
    fi
    warn "server.properties existe y difiere en ${#diffs[@]} valores:"
    for kv in "${diffs[@]}"; do detail "$kv"; done
    info "Para cambiar puerto, jugadores o distancias de forma permanente edita $KOMOREBI_CONFIG."
    if ! confirm "¿Aplicar los valores de KOMOREBI? (se guarda copia del fichero actual)" n; then
      record_skip "server.properties existente conservado"
      check_security_properties
      return 0
    fi
    backup_file "$f"
  fi
  if (( DRY_RUN )); then
    sim "escribir $f con: ${SERVER_PROPERTIES[*]}"
    record_change "server.properties configurado"
    return 0
  fi
  tmp=$(make_tmp_file "$MC_DIR")
  register_tmp "$tmp"
  properties_render "$f" "$tmp" "${SERVER_PROPERTIES[@]}"
  chown "$MC_USER:$MC_GROUP" -- "$tmp"
  chmod 0640 -- "$tmp"
  mv -f -- "$tmp" "$f"
  ok "server.properties configurado (online-mode=true, white-list=true, sin RCON ni command blocks)."
  record_change "server.properties configurado"
  if k_service_active; then
    record_pending "Reiniciar el servidor para aplicar server.properties: sudo systemctl restart $K_SERVICE_UNIT"
  fi
}
