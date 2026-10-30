# CHANGELOG — Instalador KOMOREBI SMP

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/); versiones con
[SemVer](https://semver.org/lang/es/).

## [1.1.0] — 2026-10-30

Correcciones tras una auditoría crítica previa a la primera prueba en Arch Linux.

### Corregido
- `diffutils` (cmp/diff) no forma parte de `base`: se añade a los paquetes necesarios y la
  comparación de ficheros usa SHA-256 si falta `cmp` (antes se perdía la idempotencia).
- `daemon-reload` también cuando systemd indica `NeedDaemonReload` (p. ej., tras interrumpir una
  ejecución entre escribir una unidad y recargar).
- Un plugin cuya dependencia no llegó a instalarse (descarga fallida) ya no se instala.
- Backups: el archivo parcial se borra antes de reanudar el servidor; se eliminan temporales
  huérfanos de copias interrumpidas; aviso si systemd tuvo que forzar la parada por timeout.
- firewalld: el puerto se abre en la zona de la interfaz de red, no en la zona por defecto.
- Cambiar `BACKUP_ONCALENDAR` reinicia el temporizador para recalcular la próxima ejecución.

### Cambiado
- `komorebi.service` solo se habilita al arranque cuando el EULA está aceptado (antes fallaba en
  cada arranque si el EULA quedaba pendiente). `--eula` habilita el servicio y ofrece arrancarlo.
- La actualización completa con pacman se pregunta con respuesta por defecto **no**, explicando que
  incluye el kernel y recomendando actualizar y reiniciar antes por cuenta propia. `--yes` avisa de
  que usará `--noconfirm`.
- Con reinicio pendiente (kernel actualizado) no se arranca el servidor ni se toca el cortafuegos;
  `--check` y las comprobaciones previas lo detectan.
- ufw: detección de interfaces VPN (Tailscale, WireGuard, ZeroTier, tun/tap) y opción de permitir SSH
  por ellas para no cortar el acceso remoto.

### Documentación
- INSTALADOR.md: cómo cambiar la hora del backup, efecto de `Persistent=true`, corte estimado,
  permisos exactos y advertencias del socket de consola (`Requires=`, activación por socket),
  kernel/reinicio pendiente, restauración fallida, estructura frente a la especificación y nuevas
  entradas de resolución de problemas.
- Pruebas: 66 (antes 56).

## [1.0.0] — 2026-10-30

### Añadido
- `INVESTIGACION.md`: versiones verificadas (Paper 1.20.1 build 196 en Fill v3, `jre21-openjdk-headless`,
  plugins con hash), fuentes oficiales, auditoría de los documentos originales, riesgos y decisiones.
- Instalador modular `installer/install-komorebi.sh` con los modos `--check`, `--dry-run`,
  `--dependencies`, `--paper`, `--plugins`, `--service`, `--backup`, `--eula`, `--firewall`, `--ssh`,
  `--power`, `--power-revert`, `--help`, `--version` y las opciones `--yes`, `--with-monitoring`, `--no-color`.
- Comprobaciones previas e informe de hardware; dependencias con `pacman -Syu --needed` solo si faltan.
- Usuario de sistema `minecraft` (sin shell ni sudo) con auditoría no destructiva si ya existe.
- Descarga de Paper verificada por SHA-256 (API, configuración y fichero), tamaño y firma ZIP.
- EULA nunca aceptado automáticamente; aceptación interactiva escribiendo `ACEPTO`.
- Editor propio de `server.properties` (conserva claves y comentarios, deduplica, escritura atómica).
- Manifiesto de plugins con 8 confirmados, 2 opcionales y spark pendiente; hosts permitidos y hash obligatorio.
- `komorebi.service` endurecido, `komorebi-console.socket` (consola por FIFO sin RCON),
  `komorebi-backup.service` y `komorebi-backup.timer`.
- Scripts `start`, `stop`, `status`, `backup`, `restore`, `healthcheck` y `console`.
- Copias con parada controlada (o `hot` experimental), verificación, `.sha256`, retención y promoción semanal.
- Restauración que conserva la instalación anterior y rechaza archivos manipulados.
- Cortafuegos, SSH y gestión de la tapa opcionales, con confirmación escrita y reversibles.
- `tests/run-tests.sh`: 56 pruebas estáticas y funcionales no destructivas.
- `INSTALADOR.md`, `CHANGELOG.md`, `VERSION`.

### Notas
- Los documentos originales del proyecto se incluyen sin modificaciones.
- Pendiente de validar en un Arch Linux real (ver `INSTALADOR.md` §15).
