#!/usr/bin/env bash
# shellcheck shell=bash
# Fichero de definiciones: las variables se usan en los demás módulos.
# shellcheck disable=SC2034
# =============================================================================
#  config.sh — Constantes del instalador KOMOREBI SMP.
#
#  Los valores ajustables por el administrador (memoria, rutas, backups…) se
#  definen en scripts/komorebi-common.sh (k_set_defaults) y se sobrescriben con
#  /etc/komorebi/komorebi.conf si existe. Aquí solo hay constantes propias del
#  instalador. Este fichero no ejecuta acciones.
# =============================================================================

# Rutas del proyecto (INSTALLER_DIR y PROJECT_DIR las define install-komorebi.sh).
TEMPLATES_SYSTEMD_DIR="$PROJECT_DIR/systemd"
TEMPLATES_CONFIG_DIR="$PROJECT_DIR/config"
PROJECT_SCRIPTS_DIR="$PROJECT_DIR/scripts"

# Versión del instalador (fichero VERSION en la raíz del proyecto).
INSTALLER_VERSION="0.0.0"
if [[ -r "$PROJECT_DIR/VERSION" ]]; then
  read -r INSTALLER_VERSION <"$PROJECT_DIR/VERSION" || true
fi
if [[ ! $INSTALLER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?$ ]]; then
  INSTALLER_VERSION="0.0.0"
fi

# Destinos en el sistema.
CONFIG_DIR="/etc/komorebi"
LIB_DIR="/usr/local/lib/komorebi"
BIN_DIR="/usr/local/sbin"
SYSTEMD_UNIT_DIR="/etc/systemd/system"
LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN_FILE="$LOGIND_DROPIN_DIR/50-komorebi-server.conf"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="$SSHD_DROPIN_DIR/10-komorebi.conf"
PLUGINS_MANIFEST_FILE="$CONFIG_DIR/plugins-manifest.conf"
VERSIONS_STATE_FILE="$CONFIG_DIR/installed-versions.txt"

# Java.
JAVA_PACKAGE="jre21-openjdk-headless"
JAVA_REQUIRED_MAJOR=21

# PaperMC (servicio oficial de descargas Fill v3; la API v2 está retirada).
PAPER_PROJECT="paper"
PAPER_API_BASE="https://fill.papermc.io/v3"
PAPER_DOWNLOAD_URL_REGEX='^https://fill-data\.papermc\.io/'
PAPER_MIN_JAVA21_BUILD=196
PAPER_MIN_SIZE_BYTES=20000000
MINECRAFT_EULA_URL="https://aka.ms/MinecraftEULA"

# Plugins: hosts permitidos para descargas (HTTPS obligatorio).
PLUGIN_ALLOWED_URL_REGEX='^https://(cdn\.modrinth\.com|github\.com)/[A-Za-z0-9._~/%+-]+$'

# Paquetes. Solo se instalan los que falten (pacman -T).
# diffutils (cmp/diff) no forma parte de 'base' en Arch: se instala explícitamente.
REQUIRED_PACKAGES=("$JAVA_PACKAGE" curl jq tar gzip zstd diffutils coreutils findutils grep procps-ng util-linux iproute2 shadow)
MONITORING_PACKAGES=(lm_sensors htop smartmontools)

# Directorio de módulos del kernel (detección de reinicio pendiente) y de
# interfaces de red (detección de VPN). Variables para poder probarlas.
KERNEL_MODULES_DIR="/usr/lib/modules"
SYS_NET_DIR="/sys/class/net"

# Requisitos de hardware.
MIN_FREE_DISK_MB=4096
RECOMMENDED_FREE_DISK_MB=15360
MIN_RAM_MB=3072
RECOMMENDED_RAM_MB=6144

# Propiedades del servidor gestionadas por el instalador (orden de escritura).
# El MOTD usa escapes \uXXXX: es el formato con el que el propio servidor
# guarda server.properties y evita problemas de codificación con § y kanji.
#   \u00A7 = §   \u6728\u6F0F\u308C\u65E5 = 木漏れ日
build_server_properties() {
  SERVER_PROPERTIES=(
    'motd=\u00A7d\u6728\u6F0F\u308C\u65E5 \u00A7f| \u00A7aKOMOREBI SMP'
    "server-port=$SERVER_PORT"
    'online-mode=true'
    'white-list=true'
    'enforce-whitelist=true'
    "max-players=$MAX_PLAYERS"
    "view-distance=$VIEW_DISTANCE"
    "simulation-distance=$SIMULATION_DISTANCE"
    'spawn-protection=16'
    'difficulty=normal'
    'gamemode=survival'
    'pvp=true'
    'allow-flight=false'
    'enable-command-block=false'
    'enable-rcon=false'
    'enable-query=false'
  )
}

# Claves de seguridad que deben conservar estos valores (comprobación --check).
SECURITY_PROPERTIES=('online-mode=true' 'enable-rcon=false' 'enable-command-block=false')
