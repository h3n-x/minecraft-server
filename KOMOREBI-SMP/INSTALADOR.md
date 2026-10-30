# INSTALADOR — KOMOREBI SMP (木漏れ日)

Manual del instalador automatizado de **Minecraft Paper 1.20.1 + OpenJDK 21 + systemd** para
**Arch Linux**. Versión del instalador: ver `VERSION` (1.1.0).

> Estado de las pruebas: el instalador se validó con pruebas estáticas y funcionales en un
> contenedor **Debian 13** (no Arch), con root simulado y `systemctl` simulado. **No se ha
> ejecutado todavía en un Arch Linux real.** Consulta la sección "Pruebas pendientes en Arch" (§17).

---

## 1. Requisitos

| Requisito | Detalle |
|---|---|
| Sistema | Arch Linux x86_64 actualizado, con systemd como init |
| Acceso | Usuario con `sudo` |
| Red | Salida HTTPS a `archlinux.org`, `fill.papermc.io`, `fill-data.papermc.io`, `cdn.modrinth.com`, `github.com` |
| Disco | Mínimo 4 GiB libres en `/var` (recomendado ≥ 15 GiB para mundos y copias) |
| RAM | Mínimo 3 GiB; previsto para 8 GiB (heap 4 GiB) |
| Proyecto | La carpeta `KOMOREBI-SMP/` completa (el instalador usa `systemd/`, `config/` y `scripts/`) |

El instalador comprueba todo esto antes de tocar nada y se detiene si falta algo crítico.

## 2. Instalación rápida

**Recomendado antes de empezar** (sobre todo si la laptop lleva tiempo sin actualizarse):

```bash
sudo pacman -Syu        # actualización completa hecha por ti, revisando la transacción
# si falla por firmas PGP: sudo pacman -Sy archlinux-keyring && sudo pacman -Su
sudo reboot             # solo si se actualizó el kernel (paquete linux)
```

Después:

```bash
cd ~/KOMOREBI-SMP
bash installer/install-komorebi.sh --check        # diagnóstico, sin root, solo lectura
sudo bash installer/install-komorebi.sh --dry-run # simulación: qué haría
sudo bash installer/install-komorebi.sh           # instalación completa e interactiva
```

La instalación completa:

1. Comprueba el sistema e imprime el informe de hardware (`lscpu`, `free`, `lsblk`, `df`, `ip`, `uname`).
2. Instala solo los paquetes que falten. Si falta alguno, explica que hay que actualizar **todo el
   sistema** (`pacman -Syu --needed`, posible kernel nuevo) y pregunta con respuesta por defecto **no**.
3. Crea el usuario de sistema `minecraft` y los directorios con sus permisos.
4. Genera `/etc/komorebi/komorebi.conf` con la memoria ajustada a la RAM detectada.
5. Verifica Java 21.
6. Descarga Paper 1.20.1 build 196 y lo verifica; crea `eula.txt` (`eula=false`) y `server.properties`.
7. Instala los 8 plugins confirmados con verificación de hash.
8. Instala los scripts de administración y las unidades systemd. Habilita el socket de consola; el
   servicio solo se habilita al arranque cuando el EULA está aceptado (sin EULA fallaría en cada arranque).
9. Instala el temporizador de copias y pregunta si activarlo.
10. Te muestra el EULA y pide que escribas `ACEPTO`. Solo entonces habilita el servicio y ofrece
    arrancarlo (no lo arranca si hay un reinicio pendiente por kernel nuevo).
11. Ofrece (por defecto "no") cortafuegos, SSH y gestión de la tapa.
12. Muestra un resumen: cambios, omisiones, avisos y **acciones manuales pendientes**.

Ejecutarlo de nuevo es seguro: lo que ya está bien se deja igual y lo que difiere se muestra y se
pregunta (con copia previa).

## 3. Modos y opciones

| Comando | Qué hace | Requiere |
|---|---|---|
| `sudo bash installer/install-komorebi.sh` | Instalación completa | root |
| `… --dry-run` | Simulación sin efectos (combinable con cualquier modo) | — |
| `bash installer/install-komorebi.sh --help` | Ayuda | — |
| `bash installer/install-komorebi.sh --check` | Diagnóstico de solo lectura (no escribe ni registros ni bloqueo) | — |
| `… --dependencies` | Paquetes + verificación de Java 21 | root |
| `… --paper` | Usuario, directorios, `komorebi.conf`, Paper, `eula.txt`, `server.properties` | root |
| `… --plugins` | Plugins del manifiesto | root + Paper instalado |
| `… --service` | Scripts + `komorebi.service` + socket de consola + unidades de backup | root + Java 21 + Paper |
| `… --backup` | Unidades de backup y activación del temporizador | root |
| `… --eula` | Lectura y aceptación explícita del EULA; después habilita el servicio y ofrece arrancarlo | root + Paper |
| `… --firewall` | Abre TCP 25565 en el cortafuegos activo o propone ufw | root |
| `… --ssh` | OpenSSH seguro (drop-in validado) | root |
| `… --power` / `--power-revert` | Evitar / restaurar la suspensión por tapa e inactividad | root |
| `--yes` / `-y` | "Sí" a confirmaciones ordinarias (pacman, reemplazos con copia). **Nunca** acepta el EULA ni toca cortafuegos, SSH o energía | — |
| `--with-monitoring` | Añade `lm_sensors`, `htop`, `smartmontools` | — |
| `--no-color` | Sin colores (también `NO_COLOR=1`) | — |

Dependencias entre etapas: `--dependencies` → `--paper` → `--plugins` → `--service`. Cada modo
comprueba lo que necesita y, si falta una etapa previa, se detiene indicando el comando a ejecutar.
Solo se admite un modo por ejecución.

## 4. Directorios, usuario y permisos

| Ruta | Propietario | Modo | Contenido |
|---|---|---|---|
| `/var/lib/minecraft` | minecraft:minecraft | 0750 | Servidor, mundos, `plugins/`, `config/` |
| `/var/lib/minecraft/paper.jar`, `plugins/*.jar` | minecraft:minecraft | 0640 | JAR verificados |
| `/var/backups/minecraft/{daily,weekly,manual}` | root:root | 0750 | Copias `.tar.zst` + `.sha256` (0600) |
| `/var/backups/minecraft/installer` | root:root | 0700 | Copias de ficheros que el instalador reemplazó |
| `/etc/komorebi` | root:root | 0755 | `komorebi.conf`, `plugins-manifest.conf`, `installed-versions.txt` |
| `/var/log/komorebi` | root:root | 0750 | `install-*.log`, `backup.log`, informes de plugins |
| `/usr/local/lib/komorebi` + enlaces en `/usr/local/sbin` | root | 0755 | Scripts de administración |
| `/etc/systemd/system/komorebi*.{service,socket,timer}` | root | 0644 | Unidades |

Usuario `minecraft`: de sistema (`useradd --system`), shell `/usr/bin/nologin`, sin `sudo`, hogar
`/var/lib/minecraft`, sin ficheros de `/etc/skel`. Si ya existe se audita (UID, shell, hogar,
grupos `wheel/sudo/adm/root`, contraseña utilizable) y cualquier corrección se pregunta. Nunca se borra.
Nunca se usa `chmod 777`.

## 5. Java

* Paquete: `jre21-openjdk-headless` (si ya tienes `jre21-openjdk` o `jdk21-openjdk`, valen y no se
  instala nada: los tres son excluyentes y comparten ruta).
* Ruta usada por el servicio: `/usr/lib/jvm/java-21-openjdk/bin/java`.
* No se ejecuta `archlinux-java set`: la versión global del sistema no cambia. El instalador muestra
  `java -version` y `archlinux-java status` como información.

## 6. Paper

* Fuente: servicio oficial **Fill v3** (`https://fill.papermc.io/v3`). La API v2 está retirada (HTTP 410).
* Build fijada: **196** (última de 1.20.1 y primera con soporte de Java 21), SHA-256
  `234a9b32098100c6fc116664d64e36ccdb58b5b649af0f80bcccb08b0255eaea`.
* Verificaciones: canal `STABLE`, nombre `paper-1.20.1-196.jar`, URL de `fill-data.papermc.io`,
  HTTP 200, tamaño anunciado, SHA-256 de la API = fijado = descargado, firma ZIP.
* No reemplaza un `paper.jar` distinto sin preguntar ni con el servidor en marcha.
* **Aviso**: PaperMC marca 1.20.1 como `UNSUPPORTED` (sin parches nuevos). Ver INVESTIGACION.md §8.
* PaperMC pide un `User-Agent` con contacto: rellena `HTTP_CONTACT` en `/etc/komorebi/komorebi.conf`.

### EULA

`eula.txt` se crea con `eula=false`. El servidor no arranca sin `eula=true` (`ExecStartPre` lo impide).
Para aceptarlo: `sudo bash installer/install-komorebi.sh --eula`, leer
<https://aka.ms/MinecraftEULA> y escribir `ACEPTO`.

### server.properties

Valores gestionados: `motd` (木漏れ日 | KOMOREBI SMP, escrito con escapes `\uXXXX`), `server-port=25565`,
`online-mode=true`, `white-list=true`, `enforce-whitelist=true`, `max-players=10`,
`view-distance=7`, `simulation-distance=5`, `spawn-protection=16`, `difficulty=normal`,
`gamemode=survival`, `pvp=true`, `allow-flight=false`, `enable-command-block=false`,
`enable-rcon=false`, `enable-query=false`. El resto de claves se conservan. Si el fichero existe y
difiere, se muestran las diferencias y se pregunta (copia previa). Ejemplo: `config/server.properties.example`.
Para cambiar puerto, jugadores o distancias de forma permanente edita `komorebi.conf` y ejecuta `--paper`.

## 7. Plugins

Manifiesto: `/etc/komorebi/plugins-manifest.conf` (copia de `config/plugins-manifest.example`).

| Estado | Plugins |
|---|---|
| Confirmados (se instalan) | LuckPerms 5.5.71, EssentialsX 2.20.1, EssentialsXSpawn 2.20.1, Vault 1.7.3, CoreProtect 22.4, GriefPrevention 16.18.3, WorldEdit 7.2.15, WorldGuard 7.0.9 |
| Opcionales (desactivados) | PlaceholderAPI 2.11.6, EssentialsXChat 2.20.1 |
| Pendiente | spark (sin checksum oficial ni declaración de 1.20.1 para Bukkit) |

* Para activar un opcional: cambia su campo `activo` a `yes` y ejecuta `--plugins`.
* Para añadir spark: descárgalo de <https://spark.lucko.me/download>, verifica, súbelo a un host
  permitido o colócalo a mano en `plugins/`. Las entradas `pending` nunca se descargan.
* Si ya hay otra versión del mismo plugin en `plugins/`, no se instala la del manifiesto (sin duplicados).
* Tras instalar, reinicia el servidor y revisa el registro. La configuración interna de cada plugin
  (rangos de LuckPerms, moneda ¥ de EssentialsX, claims, regiones) es manual.

## 8. systemd

* `komorebi.service`: `User=minecraft`, `WorkingDirectory=/var/lib/minecraft`, Java 21 explícito,
  `-Xms2G -Xmx4G` (3G/2G si la RAM es menor) y flags oficiales de Paper; `Restart=on-failure`,
  `RestartSec=20`, máximo 3 arranques en 10 min (después queda `failed` y registrado);
  `TimeoutStopSec=180`; parada por SIGTERM (Paper guarda y sale con 143, aceptado como éxito);
  `MemoryMax = Xmx + 2 GiB`; sandboxing (`ProtectSystem=strict`, `NoNewPrivileges`, etc.).
  No se usa `MemoryDenyWriteExecute` porque rompe el JIT de Java.
* `komorebi-console.socket`: FIFO `/run/komorebi/console` conectado a la entrada de Paper.
  Permite comandos de consola sin RCON y sin red. Permisos (definidos en la unidad):
  `SocketUser=root`, `SocketGroup=root`, `SocketMode=0600`, `DirectoryMode=0750`, `RemoveOnStop=yes`.
  Esperado: `drwxr-x--- root root /run/komorebi` y `prw------- root root /run/komorebi/console`
  (compruébalo con `stat -c '%A %U:%G %n' /run/komorebi /run/komorebi/console`).
  Cualquier usuario con `sudo` puede usar la consola; el proceso de Paper recibe el descriptor y
  podría escribirse a sí mismo (no es una escalada de privilegios).

  **Cuidado con systemctl a mano** (por eso existen los scripts):
  - `komorebi.service` tiene `Requires=komorebi-console.socket`: parar el socket **para el servidor**.
  - Es activación por socket: si el servidor está parado pero el socket activo y alguien escribe en
    la consola, **el servidor arranca**. `stop-komorebi.sh` y las copias paran servicio y socket juntos;
    un `systemctl stop komorebi` deja el socket activo.
  - No envíes `stop` por la consola (systemd lo tomaría como salida normal); `console-komorebi.sh` lo rechaza.
* Ajustes locales: `sudo systemctl edit komorebi.service` (drop-in). No edites la unidad: se regenera
  con `--service`.
* Cambiar memoria: edita `JVM_XMS`/`JVM_XMX` en `komorebi.conf`, ejecuta `--service` y reinicia.

### Scripts de administración (en `/usr/local/sbin`)

| Script | Uso |
|---|---|
| `start-komorebi.sh [--wait]` | Arranca vía systemd; se niega si ya corre, si hay un Paper fuera de systemd o sin EULA |
| `stop-komorebi.sh [--warn N]` | Parada ordenada (avisa N segundos antes) |
| `status-komorebi.sh [--lines N]` | Estado, PID, memoria, puerto, último backup, registro |
| `console-komorebi.sh "CMD"` | Comando de consola: `"whitelist add Steve"`, `"op Steve"`, `"list"` |
| `backup-komorebi.sh` | Copia manual (ver §11) |
| `restore-komorebi.sh ARCHIVO` | Restauración segura |
| `healthcheck-komorebi.sh [--quiet]` | Salud: 0 OK, 1 avisos, 2 crítico |

`restore-komorebi.sh` y `console-komorebi.sh` son extras sobre la especificación (ver §16).
Registro en vivo: `journalctl -fu komorebi`.

## 9. Cortafuegos

`sudo bash installer/install-komorebi.sh --firewall`

* Detecta ufw, firewalld, nftables e iptables. Si hay **más de uno activo**, no toca nada y avisa.
* Si hay un **reinicio pendiente** (kernel actualizado), no hace nada: los módulos de netfilter
  podrían no cargarse. Reinicia y repite.
* ufw activo: añade solo TCP 25565 (con confirmación).
* firewalld activo: abre TCP 25565 en la **zona de la interfaz de red** (NetworkManager puede poner
  el Wi-Fi en `home` o `public`), no en la zona por defecto.
* nftables / iptables: muestra la regla para añadirla a mano (no edita su configuración).
* Ninguno activo: propone instalar ufw (`deny incoming`, `allow 25565/tcp` y SSH **solo desde la
  LAN** detectada para no cortar tu sesión). Requiere escribir `SI`. Si detecta interfaces de VPN
  (`tailscale*`, `wg*`, `zt*`, `tun*`, `tap*`) avisa y pregunta si permitir SSH también por ellas;
  si no, las conexiones SSH nuevas por la VPN quedarían bloqueadas.
* Nunca desactiva un cortafuegos ni toca el router.

Acceso desde Internet (manual): reserva la IP local en el router, comprueba **CGNAT** (si la IP WAN
del router no coincide con tu IP pública o está en `100.64.0.0/10`, el port forwarding no funcionará),
y redirige solo **TCP 25565** a la IP local. Nunca el 22.

## 10. SSH

`sudo bash installer/install-komorebi.sh --ssh`

* Instala `openssh` si falta (con confirmación).
* Crea `/etc/ssh/sshd_config.d/10-komorebi.conf` con `PermitRootLogin no` (Arch incluye ese
  directorio al inicio de `sshd_config`; no se modifica el fichero principal).
* Solo si apruebas escribiendo `SI` **y** tu usuario tiene `~/.ssh/authorized_keys`, añade
  `PasswordAuthentication no`.
* Valida con `sshd -t`; si falla, revierte el drop-in y no recarga sshd.
* Conexión desde la LAN: `ssh usuario@IP_LOCAL`. Para administrar desde fuera, usa una VPN.

## 11. Copias de seguridad

* Manual: `sudo backup-komorebi.sh` → `manual/` (sin borrado automático por defecto).
* Programada: `komorebi-backup.timer` (diaria 04:30 + hasta 10 min aleatorios) → `daily/`; el día
  `BACKUP_WEEKLY_DAY` (domingo) se enlaza también en `weekly/`.
* `Persistent=true`: si la laptop estaba apagada a la hora prevista, la copia se hace **al
  encenderla**, aunque sea en plena tarde (habrá 1–3 min de corte).

#### Cambiar la hora de la copia diaria

1. Edita `/etc/komorebi/komorebi.conf`:
   ```
   BACKUP_ONCALENDAR="*-*-* 05:30:00"
   BACKUP_STOP_WARNING=120
   ```
   (sintaxis `OnCalendar` de systemd; ejemplos: `"Mon..Sun 06:00"`, `"*-*-* 04,16:00:00"`).
   Comprueba la expresión con `systemd-analyze calendar "*-*-* 05:30:00"`.
2. Aplica: `sudo bash installer/install-komorebi.sh --backup` (muestra el cambio, valida la expresión,
   recarga systemd y reinicia el temporizador para recalcular la próxima ejecución).
3. Verifica: `systemctl list-timers komorebi-backup.timer`.

* Corte estimado por copia en modo `stop` (sin medir en la laptop): aviso de `BACKUP_STOP_WARNING`
  segundos (se sigue jugando) + guardado (5–20 s) + compresión + arranque de Paper (30–60 s en un i3):
  normalmente **1–3 minutos** sin servidor. El registro indica el tiempo real ("sin servicio durante N s").
* Si Paper no termina en `STOP_TIMEOUT` segundos, systemd fuerza la parada y la copia avisa de que
  puede contener datos sin guardar (sube `STOP_TIMEOUT` si ocurre).
* **Modo `stop` (por defecto)**: avisa a los jugadores (60 s), detiene el servidor de forma ordenada,
  comprueba que no queda Java, copia, **rearranca enseguida** y después verifica. Copia 100 % consistente.
* Modo `hot` (experimental, `--mode hot`): `save-off` + `save-all flush` por la consola, copia,
  `save-on`. Los mundos quedan consistentes, pero las bases de datos de plugins (CoreProtect, LuckPerms)
  pueden seguir escribiendo.
* Incluye: mundos, `plugins/` (economía, permisos, claims, registros), configuraciones, `paper.jar`.
  Excluye cachés regenerables (`cache`, `libraries`, `versions`) y `logs`.
* Verificación: test del compresor, lectura completa del tar, presencia de `level.dat`,
  `server.properties` y `eula.txt`, y fichero `.sha256`.
* Si la copia falla o se interrumpe, el archivo parcial se borra **antes** de reanudar el servidor
  (para no arrancar con el disco lleno) y el servidor se rearranca igualmente. Los temporales que
  deje un corte de luz se eliminan al empezar la siguiente copia.
* Retención (`komorebi.conf`): 7 diarias, 4 semanales, manuales sin límite. Solo se borran ficheros
  con el patrón exacto `komorebi-<tipo>-AAAAMMDD-HHMMSS.tar.*`.
* Listar: `sudo backup-komorebi.sh --list`. Registro: `/var/log/komorebi/backup.log`.
* **Haz copias externas** (USB/NAS) de `/var/backups/minecraft`: el mismo SSD no protege ante su fallo.

### Restauración

```bash
sudo restore-komorebi.sh --list
sudo restore-komorebi.sh --dry-run /var/backups/minecraft/daily/komorebi-daily-AAAAMMDD-HHMMSS.tar.zst
sudo restore-komorebi.sh /var/backups/minecraft/daily/komorebi-daily-AAAAMMDD-HHMMSS.tar.zst
```

Comprueba el `.sha256` y que todas las rutas estén dentro de `minecraft/`, detiene el servidor (con
confirmación), extrae en un temporal y mueve la instalación actual a
`/var/lib/minecraft.pre-restore-<fecha>` (**no se borra**). Hay que escribir `RESTAURAR`. Cuando
confirmes que todo va bien, borra a mano el directorio `pre-restore`.

Si la restauración falla a mitad, el servidor **queda detenido** a propósito (para que revises qué
pasó): la instalación original sigue en `/var/lib/minecraft` o, si ya se había movido, en
`/var/lib/minecraft.pre-restore-<fecha>` (devuélvela con `sudo mv`). Arráncalo con `sudo start-komorebi.sh`.

## 12. Energía (laptop)

`sudo bash installer/install-komorebi.sh --power` crea
`/etc/systemd/logind.conf.d/50-komorebi-server.conf` con `HandleLidSwitch`, `HandleLidSwitchExternalPower`,
`HandleLidSwitchDocked` e `IdleAction` en `ignore`, y recarga logind con SIGHUP (sin cerrar sesiones).
Requiere escribir `SI`. Revertir: `--power-revert`. Si usas GNOME/KDE/Xfce, ajusta también su gestor
de energía. Mantén la laptop enchufada, ventilada y vigila `sensors`. No se tocan sysctl, swap ni zram.

## 13. Kernel actualizado y reinicio pendiente

Si `pacman -Syu` actualiza el kernel, el que está en ejecución pierde sus módulos en disco hasta
reiniciar. Java y Paper funcionan, pero falla todo lo que necesite cargar un módulo nuevo:
cortafuegos (netfilter), discos USB para copias externas y, a veces, el Wi-Fi tras reconectar.

El instalador lo detecta (`/usr/lib/modules/$(uname -r)` ausente), también en `--check`, y entonces:
no arranca el servidor, no configura el cortafuegos y añade "Reiniciar" a las acciones pendientes.
Tras reiniciar, el servidor arranca solo (si el EULA está aceptado). Si tienes instalado
`kernel-modules-hook`, esta detección no funciona: reinicia igualmente tras actualizar el kernel.

Para futuras actualizaciones del sistema: detén antes el servidor (`sudo stop-komorebi.sh`); actualizar
Java con la JVM en marcha puede tumbarla.

## 14. Desinstalación (manual, sin borrar mundos)

```bash
sudo stop-komorebi.sh
sudo systemctl disable --now komorebi-backup.timer komorebi.service komorebi-console.socket
sudo rm /etc/systemd/system/komorebi.service /etc/systemd/system/komorebi-console.socket \
        /etc/systemd/system/komorebi-backup.service /etc/systemd/system/komorebi-backup.timer
sudo systemctl daemon-reload
sudo rm /usr/local/sbin/{start,stop,status,backup,restore,healthcheck,console}-komorebi.sh
sudo rm -r /usr/local/lib/komorebi
# Opcionales, solo si se aplicaron:
sudo bash installer/install-komorebi.sh --power-revert
sudo rm /etc/ssh/sshd_config.d/10-komorebi.conf && sudo systemctl reload sshd
sudo ufw delete allow 25565/tcp
```

Los datos **no** se borran: `/var/lib/minecraft`, `/var/backups/minecraft`, `/etc/komorebi`,
`/var/log/komorebi` y el usuario `minecraft`. Elimínalos tú solo cuando tengas copias externas
(`sudo userdel minecraft`, `sudo rm -r …`). Los paquetes de pacman se pueden quitar con `pacman -Rs`.

## 15. Resolución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| "No se instalaron las dependencias" | Respondiste "no" (es el valor por defecto) | Actualiza tú: `sudo pacman -Syu`, reinicia si cambió el kernel y repite |
| Errores de firma PGP en pacman | `archlinux-keyring` antiguo | `sudo pacman -Sy archlinux-keyring && sudo pacman -Su` |
| "Reinicio pendiente" | Kernel actualizado | `sudo reboot` |
| "pacman está bloqueado" | Otra operación o bloqueo huérfano | Espera; si `pgrep -a pacman` no muestra nada, `sudo rm /var/lib/pacman/db.lck` |
| "Sistema no compatible" | No es Arch Linux | El instalador es solo para Arch |
| "Sin conexión HTTPS" | Red, DNS u hora del sistema | `ping archlinux.org`, `timedatectl` |
| "SHA-256 no coincide" | Descarga alterada o build distinta | No se instala nada; reintenta y revisa `PAPER_BUILD`/`PAPER_SHA256` |
| El servicio no arranca, `ExecStartPre` falla | EULA no aceptado, falta Java o `paper.jar` | `--eula`, `--dependencies`, `--paper` |
| `start-limit-hit` | 3 fallos en 10 min | `journalctl -u komorebi -e`; corrige; `sudo systemctl reset-failed komorebi` |
| Paper termina por memoria | `MemoryMax` o heap insuficiente | Revisa `JVM_XMX`; `--service`; reinicia |
| Un plugin no carga | Incompatibilidad o dependencia | Detén, retira el JAR, revisa el registro, restaura configuración |
| La consola no responde | Socket detenido | `systemctl status komorebi-console.socket` |
| La consola no ejecuta comandos aunque el socket esté activo | La consola de Paper no lee bien un FIFO (no probado en Arch real) | Añade `-Dterminal.jline=false` a `JVM_FLAGS` en `komorebi.conf`, ejecuta `--service` y reinicia |
| El servicio no se habilita al arranque | EULA sin aceptar (comportamiento previsto) | `sudo bash installer/install-komorebi.sh --eula` |
| Un endurecimiento de systemd bloquea algo | Directiva de sandbox | `sudo systemctl edit komorebi.service` y relaja solo esa directiva; `systemd-analyze security komorebi` |
| No se conecta desde Internet | CGNAT, router o cortafuegos | §9; prueba primero en la LAN |
| La laptop se suspende | logind o el escritorio | `--power` y ajustes de energía del escritorio |

Registros: `/var/log/komorebi/install-*.log`, `/var/log/komorebi/backup.log`, `journalctl -u komorebi`.

## 16. Estructura del proyecto y diferencias con la especificación

Además de la estructura pedida, se añadieron estos ficheros (todos documentados en este manual):

| Fichero | Motivo |
|---|---|
| `installer/system.sh` | Comprobaciones previas, informe de hardware, usuario, directorios y energía (separado de `functions.sh` para que este solo tenga utilidades). |
| `scripts/komorebi-common.sh` | Biblioteca común: valores por defecto y lector seguro de `komorebi.conf` para instalador y scripts. |
| `scripts/restore-komorebi.sh` | Restaurar copias de forma segura (§11). |
| `scripts/console-komorebi.sh` + `systemd/komorebi-console.socket` | Consola sin RCON para `whitelist`/`op` (§8). Sin ella no habría forma de añadir jugadores a la whitelist. |
| `systemd/komorebi-backup.timer` | Ejecutar las copias diarias (§11). |
| `config/komorebi.conf.example` | Plantilla de `/etc/komorebi/komorebi.conf`. |
| `tests/run-tests.sh` | Pruebas (§17). |
| `.gitignore`, `logs/.gitkeep`, `backups/.gitkeep` | Conservar las carpetas vacías en el repositorio. |

## 17. Pruebas

```bash
bash tests/run-tests.sh                       # completo (usa red)
KOMOREBI_TEST_OFFLINE=1 bash tests/run-tests.sh
SHELLCHECK=/ruta/a/shellcheck bash tests/run-tests.sh
```

Las pruebas trabajan en un directorio temporal con root simulado (`unshare -r`) y sustitutos de
`systemctl`, `journalctl`, `pgrep` y `pacman`; nunca modifican el sistema.

Resultado en el entorno de desarrollo (Debian 13, 2026-10-30, v1.1.0): **66/66 correctas**, incluidas
`bash -n`, ShellCheck 0.11.0, `systemd-analyze verify`, `--check`, `--dry-run`, detección de root,
descarga real y verificación de Paper y de un plugin, idempotencia, backups (parado, activo, fallo
con parcial borrado antes de rearrancar, temporales huérfanos, retención y semanal), restauración
(incluido el rechazo de archivos manipulados), EULA antes de habilitar, `NeedDaemonReload`, pacman
con "no" por defecto, reinicio pendiente, zona de firewalld, detección de VPN y dependencias de plugins.

### Pruebas pendientes en Arch Linux real

* Transacción real `pacman -Syu --needed` y `archlinux-java status`.
* `useradd` del usuario `minecraft` y auditoría de un usuario existente.
* Arranque real de Paper con el sandboxing, consola por FIFO, parada por SIGTERM y `MemoryMax`.
* Copia en modo `stop` y `hot` con el servidor real; compresión **zstd** (en el entorno de pruebas
  no había `zstd` y se probó con gzip).
* Cortafuegos, SSH y logind reales; conexión de un cliente Minecraft en la LAN.
