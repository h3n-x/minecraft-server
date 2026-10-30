#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  plugins.sh — Instalación de plugins desde un manifiesto declarativo.
#
#  Reglas:
#    * Solo entradas 'confirmed' u 'optional' con activo=yes y hash fijado.
#    * Las entradas 'pending' nunca se descargan: se informa del enlace oficial.
#    * URL HTTPS de hosts permitidos (cdn.modrinth.com, github.com).
#    * Hash SHA-512/SHA-256 obligatorio y verificado antes de instalar.
#    * Si ya hay otra versión del mismo plugin, no se instala (sin duplicados).
#    * Nunca se usa "latest": cada entrada fija versión, URL y hash.
# =============================================================================

M_STATUS=() M_ENABLED=() M_NAME=() M_VERSION=() M_FILE=() M_GLOBS=()
M_URL=() M_ALGO=() M_HASH=() M_LICENSE=() M_REQUIRES=() M_PAGE=() M_NOTES=()
PLUGIN_REPORT=()

# load_manifest FICHERO — Carga el manifiesto en arrays paralelos (M_*).
load_manifest() {
  local file=$1 line pipes lineno=0 st en name ver fname globs url algo hash lic req page notes
  M_STATUS=() M_ENABLED=() M_NAME=() M_VERSION=() M_FILE=() M_GLOBS=()
  M_URL=() M_ALGO=() M_HASH=() M_LICENSE=() M_REQUIRES=() M_PAGE=() M_NOTES=()
  [[ -r $file ]] || die "No se puede leer el manifiesto $file."
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    pipes=${line//[^|]/}
    if (( ${#pipes} != 12 )); then
      warn "Manifiesto $file:$lineno: se esperaban 13 campos separados por '|'; línea ignorada."
      continue
    fi
    IFS='|' read -r st en name ver fname globs url algo hash lic req page notes <<<"$line"
    M_STATUS+=("$st") M_ENABLED+=("$en") M_NAME+=("$name") M_VERSION+=("$ver")
    M_FILE+=("$fname") M_GLOBS+=("$globs") M_URL+=("$url") M_ALGO+=("$algo")
    M_HASH+=("$hash") M_LICENSE+=("$lic") M_REQUIRES+=("$req") M_PAGE+=("$page") M_NOTES+=("$notes")
  done <"$file"
}

# validate_manifest_entry ÍNDICE — Imprime el motivo si la entrada no es
# válida para instalarse; no imprime nada si es válida.
validate_manifest_entry() {
  local i=$1 g hash_len
  case ${M_STATUS[i]} in confirmed|optional|pending) ;; *) printf 'estado desconocido "%s"' "${M_STATUS[i]}"; return ;; esac
  case ${M_ENABLED[i]} in yes|no) ;; *) printf 'campo activo debe ser yes/no'; return ;; esac
  [[ ${M_NAME[i]} =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'nombre no válido'; return; }
  [[ ${M_STATUS[i]} == pending ]] && return
  [[ ${M_VERSION[i]} =~ ^[A-Za-z0-9._+-]+$ ]] || { printf 'versión no válida'; return; }
  [[ ${M_FILE[i]} =~ ^[A-Za-z0-9._+-]+\.jar$ ]] || { printf 'nombre de fichero no válido'; return; }
  for g in ${M_GLOBS[i]//,/ }; do
    [[ $g =~ ^[A-Za-z0-9._*+-]+\.jar$ ]] || { printf 'patrón no válido "%s"' "$g"; return; }
  done
  [[ ${M_URL[i]} =~ $PLUGIN_ALLOWED_URL_REGEX ]] || { printf 'URL no permitida (solo HTTPS de cdn.modrinth.com o github.com)'; return; }
  case ${M_ALGO[i]} in sha512) hash_len=128 ;; sha256) hash_len=64 ;; *) printf 'algoritmo de hash no soportado'; return ;; esac
  [[ ${M_HASH[i]} =~ ^[0-9a-f]+$ && ${#M_HASH[i]} -eq $hash_len ]] || { printf 'hash ausente o no válido'; return; }
}

# manifest_index_of NOMBRE — Índice de un plugin por nombre (o vacío).
manifest_index_of() {
  local i
  for i in "${!M_NAME[@]}"; do
    if [[ ${M_NAME[i]} == "$1" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

# plugin_wanted ÍNDICE — 0 si la entrada se debe instalar.
plugin_wanted() {
  local i=$1
  [[ ${M_STATUS[i]} != pending && ${M_ENABLED[i]} == yes ]]
}

# other_versions_present ÍNDICE — Imprime ficheros del mismo plugin con otro nombre.
other_versions_present() {
  local i=$1 g f
  for g in ${M_GLOBS[i]//,/ }; do
    for f in "$MC_DIR/plugins/"$g; do
      [[ -e $f ]] || continue
      if [[ ${f##*/} != "${M_FILE[i]}" ]]; then
        printf '%s\n' "${f##*/}"
      fi
    done
  done
}

# plugin_present ÍNDICE — 0 si el JAR de la entrada (o otra versión del mismo
# plugin) está realmente en plugins/.
plugin_present() {
  local i=$1
  [[ -f $MC_DIR/plugins/${M_FILE[i]} ]] && return 0
  [[ -n $(other_versions_present "$i") ]]
}

# report_row NOMBRE VERSIÓN ESTADO RESULTADO
report_row() {
  PLUGIN_REPORT+=("$(printf '%-18s %-10s %-10s %s' "$1" "$2" "$3" "$4")")
}

# install_one_plugin ÍNDICE — Instala y verifica un plugin.
install_one_plugin() {
  local i=$1 dest tmp cur others reason req j
  local name=${M_NAME[i]} ver=${M_VERSION[i]} st=${M_STATUS[i]}
  dest="$MC_DIR/plugins/${M_FILE[i]}"

  reason=$(validate_manifest_entry "$i")
  if [[ -n $reason ]]; then
    warn "$name: entrada del manifiesto no válida ($reason); no se instala."
    report_row "$name" "$ver" "$st" "OMITIDO (manifiesto no válido)"
    return 0
  fi
  for req in ${M_REQUIRES[i]//,/ }; do
    j=$(manifest_index_of "$req" || true)
    if [[ -z $j ]] || ! plugin_wanted "$j"; then
      warn "$name requiere $req, que no está activo en el manifiesto; no se instala."
      report_row "$name" "$ver" "$st" "OMITIDO (falta dependencia $req)"
      return 0
    fi
    # La dependencia debe estar instalada de verdad (su descarga pudo fallar).
    # En simulación no hay ficheros: basta con que esté activa.
    if (( ! DRY_RUN )) && ! plugin_present "$j"; then
      warn "$name requiere $req, que no está instalado en plugins/; no se instala."
      report_row "$name" "$ver" "$st" "OMITIDO (dependencia $req no instalada)"
      return 0
    fi
  done

  if [[ -f $dest ]]; then
    cur=$(sha_of "${M_ALGO[i]}" "$dest")
    if [[ $cur == "${M_HASH[i]}" ]]; then
      fix_file_perms "$dest" 0640 "$MC_USER" "$MC_GROUP"
      report_row "$name" "$ver" "$st" "YA INSTALADO (hash verificado)"
      return 0
    fi
    warn "$name: existe $dest con un contenido distinto al del manifiesto."
    if ! confirm "¿Reemplazar ${M_FILE[i]} por la versión verificada $ver? (se guarda copia)" n; then
      report_row "$name" "$ver" "$st" "OMITIDO (fichero existente conservado)"
      return 0
    fi
    backup_file "$dest"
  fi
  others=$(other_versions_present "$i")
  if [[ -n $others ]]; then
    warn "$name: ya hay otra versión en plugins/ (${others//$'\n'/, }). No se instala ${M_FILE[i]} para evitar duplicados."
    hint "Con el servidor detenido y tras un backup, retira la versión antigua si quieres usar la $ver."
    report_row "$name" "$ver" "$st" "OMITIDO (otra versión presente)"
    return 0
  fi

  if (( DRY_RUN )); then
    sim "descargar ${M_URL[i]} → $dest y verificar ${M_ALGO[i]}"
    report_row "$name" "$ver" "$st" "SE INSTALARÍA"
    record_change "Plugin $name $ver"
    return 0
  fi
  tmp=$(make_tmp_file "$MC_DIR/plugins")
  register_tmp "$tmp"
  if ! http_download "${M_URL[i]}" "$tmp"; then
    warn "$name: la descarga falló; se continúa con el resto."
    report_row "$name" "$ver" "$st" "ERROR (descarga)"
    rm -f -- "$tmp"
    return 0
  fi
  cur=$(sha_of "${M_ALGO[i]}" "$tmp")
  if [[ $cur != "${M_HASH[i]}" ]]; then
    warn "$name: el hash ${M_ALGO[i]} no coincide; fichero descartado."
    report_row "$name" "$ver" "$st" "ERROR (hash no coincide)"
    rm -f -- "$tmp"
    return 0
  fi
  if ! zip_signature_ok "$tmp"; then
    warn "$name: el fichero descargado no es un JAR; descartado."
    report_row "$name" "$ver" "$st" "ERROR (no es un JAR)"
    rm -f -- "$tmp"
    return 0
  fi
  chown "$MC_USER:$MC_GROUP" -- "$tmp"
  chmod 0640 -- "$tmp"
  mv -f -- "$tmp" "$dest"
  ok "$name $ver instalado (${M_ALGO[i]} verificado)."
  report_row "$name" "$ver" "$st" "INSTALADO"
  record_change "Plugin $name $ver"
}

# install_plugins — Procesa el manifiesto completo e informa.
install_plugins() {
  local manifest i line report_file tmp
  section "Plugins (Paper $MC_VERSION)"
  if [[ ! -f $MC_DIR/paper.jar ]]; then
    if (( DRY_RUN )); then
      sim "Paper aún no está instalado; en una ejecución real se instalaría antes."
    else
      die "Paper no está instalado." "Instálalo primero: sudo bash installer/install-komorebi.sh --paper"
    fi
  fi
  ensure_dir "$MC_DIR/plugins" "$MC_USER" "$MC_GROUP" 0750
  deploy_file "$TEMPLATES_CONFIG_DIR/plugins-manifest.example" "$PLUGINS_MANIFEST_FILE" 0644 root root "Manifiesto de plugins"
  manifest=$PLUGINS_MANIFEST_FILE
  if [[ ! -f $manifest ]]; then
    manifest="$TEMPLATES_CONFIG_DIR/plugins-manifest.example"
  else
    k_check_config_perms "$manifest" || die "El manifiesto $manifest tiene permisos inseguros."
  fi
  info "Manifiesto: $manifest"
  load_manifest "$manifest"
  PLUGIN_REPORT=()
  report_row "PLUGIN" "VERSIÓN" "ESTADO" "RESULTADO"

  for i in "${!M_NAME[@]}"; do
    if [[ ${M_STATUS[i]} == pending ]]; then
      if [[ ${M_ENABLED[i]} == yes ]]; then
        warn "${M_NAME[i]} está marcado 'pending' y activo: las entradas pendientes nunca se descargan."
      fi
      report_row "${M_NAME[i]}" "-" "pending" "PENDIENTE DE VALIDACIÓN"
      record_pending "Plugin pendiente: ${M_NAME[i]} — ${M_NOTES[i]} (${M_PAGE[i]})"
      continue
    fi
    if [[ ${M_ENABLED[i]} != yes ]]; then
      report_row "${M_NAME[i]}" "${M_VERSION[i]}" "${M_STATUS[i]}" "DESACTIVADO (activar en el manifiesto)"
      continue
    fi
    install_one_plugin "$i"
  done

  info "Informe de plugins:"
  for line in "${PLUGIN_REPORT[@]}"; do
    detail "$line"
  done
  if (( ! DRY_RUN )) && [[ -d $LOG_DIR ]]; then
    report_file="$LOG_DIR/plugins-report-$RUN_ID.txt"
    tmp=$(make_tmp_file)
    register_tmp "$tmp"
    {
      printf 'KOMOREBI SMP — informe de plugins (%s)\nManifiesto: %s\n\n' "$(date '+%F %T')" "$manifest"
      printf '%s\n' "${PLUGIN_REPORT[@]}"
      printf '\nEnlaces oficiales:\n'
      for i in "${!M_NAME[@]}"; do
        printf '  %-18s %s\n' "${M_NAME[i]}" "${M_PAGE[i]}"
      done
    } >"$tmp"
    install_file "$tmp" "$report_file" 0640 root root
    info "Informe guardado en $report_file"
  fi
  if k_service_active; then
    record_pending "Reiniciar el servidor para cargar plugins nuevos: sudo systemctl restart $K_SERVICE_UNIT"
  fi
  record_pending "Primer arranque: revisar 'journalctl -u $K_SERVICE_UNIT' por errores de plugins y configurar LuckPerms, EssentialsX (moneda ¥), GriefPrevention y WorldGuard."
}
