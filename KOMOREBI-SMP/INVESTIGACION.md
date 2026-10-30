# INVESTIGACIÓN TÉCNICA — Instalador KOMOREBI SMP (木漏れ日)

> Etapa A del proyecto. Este informe se redactó **antes** de escribir el instalador.
> Fecha de la investigación: **2026-10-30** (consultas reales a las APIs y páginas oficiales indicadas).
> Entorno de investigación: contenedor Debian 13 con acceso a Internet. **No es Arch Linux**:
> los datos de Arch proceden de las APIs/páginas oficiales de archlinux.org, no de una máquina Arch.

---

## 0. Resumen ejecutivo

| Tema | Resultado verificado |
|---|---|
| Paper 1.20.1 | Disponible en el servicio oficial **Fill v3**. Última build: **196** (canal `STABLE`, 2023-09-21). Estado de la versión según la API: **`UNSUPPORTED`** (sin parches futuros). |
| API de descargas | La API **v2** (`api.papermc.io/v2`) devuelve **HTTP 410 "sunset"**. Se usa **Fill v3** (`fill.papermc.io/v3`). Exige un `User-Agent` identificable con contacto. |
| Integridad de Paper | Fill v3 publica **SHA-256** y tamaño. Verificado: `paper-1.20.1-196.jar`, 43 230 582 bytes, `sha256 234a9b32…5eaea` (coincide al descargarlo). |
| Java 21 + Paper 1.20.1 | Java mínimo de 1.20.1 = 17 (API Fill). La build **196** incluye el commit upstream *"Add support for Java 21"*; las builds anteriores **no** garantizan Java 21. → Se fija la build 196. |
| Paquete Java en Arch | `jre21-openjdk-headless` (extra, 21.0.13.u1-1). Binario: `/usr/lib/jvm/java-21-openjdk/bin/java`. Es mutuamente excluyente con `jre21-openjdk` y `jdk21-openjdk` (cualquiera de ellos satisface el requisito). |
| Plugins confirmados (1.20.1) | LuckPerms 5.5.71, EssentialsX 2.20.1 (+ EssentialsXSpawn), Vault 1.7.3, CoreProtect 22.4, GriefPrevention 16.18.3, WorldEdit 7.2.15, WorldGuard 7.0.9. |
| Plugins opcionales | PlaceholderAPI 2.11.6 y EssentialsXChat 2.20.1 (compatibles, **desactivados** por defecto). |
| Plugins pendientes | **spark** (no hay publicación Bukkit con checksum ni declaración explícita de 1.20.1; solo CI oficial). |
| RCON | No necesario. `mcrcon` **no existe** en los repos oficiales de Arch. Se diseña una **consola local por FIFO** (systemd socket, solo root, sin red). |

---

## 1. Arquitectura propuesta

```text
                  Jugadores (LAN / Internet vía router, si se publica)
                                      │ TCP 25565
                               ┌──────┴──────┐
                               │   Router    │  (port forwarding MANUAL, nunca automático)
                               └──────┬──────┘
                         Laptop Arch Linux (Wi-Fi o, mejor, Ethernet)
   ┌──────────────────────────────────┴───────────────────────────────────┐
   │ firewall opcional (ufw / firewalld / nftables: se respeta el existente) │
   │                                                                       │
   │  systemd                                                              │
   │   ├─ komorebi-console.socket  → FIFO /run/komorebi/console (root 0600)│
   │   ├─ komorebi.service         → User=minecraft, Java 21, Paper 1.20.1 │
   │   │      stdin = FIFO · stdout/stderr = journal · sandboxing systemd  │
   │   ├─ komorebi-backup.service  → backup-komorebi.sh (root, oneshot)    │
   │   └─ komorebi-backup.timer    → diario 04:30 (Persistent=true)        │
   │                                                                       │
   │  /var/lib/minecraft      (minecraft:minecraft 0750) servidor y mundos │
   │  /var/backups/minecraft  (root 0750) daily/ weekly/ manual/ installer/│
   │  /etc/komorebi           (root) komorebi.conf, manifiesto de plugins  │
   │  /var/log/komorebi       (root 0750) registros del instalador/backups │
   │  /usr/local/lib/komorebi + /usr/local/sbin  scripts de administración │
   │                                                                       │
   │  sshd (opcional, solo LAN/VPN, sin root) · logind (tapa: opcional)    │
   └───────────────────────────────────────────────────────────────────────┘
```

Principios: una única instancia Paper, ningún proceso Java fuera de systemd, Paper nunca como root,
todos los cambios de configuración con copia previa, ninguna acción irreversible sin consentimiento.

---

## 2. Versiones verificadas

### 2.1 PaperMC

Consultas realizadas:

```text
GET https://api.papermc.io/v2/projects/paper
  → 410 {"ok":false,"error":"sunset","message":"This API version has been sunset ..."}

GET https://fill.papermc.io/v3/projects/paper/versions/1.20.1
  → support.status = "UNSUPPORTED"
  → java.version.minimum = 17
  → java.flags.recommended = [ -XX:+AlwaysPreTouch, -XX:+DisableExplicitGC, ... (flags de Aikar) ]
  → builds: 196 … 18  (178 builds; la 85 no existe)

GET https://fill.papermc.io/v3/projects/paper/versions/1.20.1/builds/latest
  → id 196, channel STABLE, time 2023-09-21T16:59:41Z
     downloads["server:default"]:
       name   paper-1.20.1-196.jar
       size   43230582
       sha256 234a9b32098100c6fc116664d64e36ccdb58b5b649af0f80bcccb08b0255eaea
       url    https://fill-data.papermc.io/v1/objects/234a9b32…5eaea/paper-1.20.1-196.jar
```

Comprobación local de la descarga: `sha256sum` coincide; tamaño coincide; `META-INF/MANIFEST.MF`
con `Main-Class: io.papermc.paperclip.Main` (Paperclip, el lanzador oficial).

Mensaje del commit de la build 196 (upstream CraftBukkit): **"Add support for Java 21"**.

La documentación oficial (<https://docs.papermc.io/misc/downloads-service/>) indica:

* Todas las peticiones deben llevar un `User-Agent` que identifique el software, no genérico
  (no `curl`), con URL o correo de contacto.
* No se recomiendan builds inestables ni auto-actualizadores en producción.
* Ejemplo oficial: filtrar `channel == "STABLE"` y usar `downloads."server:default".url`.

### 2.2 Java

| Dato | Valor |
|---|---|
| Java mínimo para Paper 1.20.1 | 17 (API Fill) |
| Java objetivo del proyecto | 21 (LTS) — soportado desde la build 196 |
| Paquete elegido | `jre21-openjdk-headless` 21.0.13.u1-1 (repo `extra`) |
| Alternativas equivalentes | `jre21-openjdk` (incluye GUI/AWT), `jdk21-openjdk` (incluye compilador) |
| Conflictos | Los tres paquetes se declaran en conflicto entre sí; los dos completos *proveen* `jre21-openjdk-headless`. |
| Ruta real | `/usr/lib/jvm/java-21-openjdk/bin/java` (lista de ficheros del paquete en archlinux.org) |
| Gestión de versiones | `archlinux-java` (paquete `java-runtime-common`): `status`, `get`, `set`, `fix`. |

Bytecode de los plugins elegidos (versión *major* máxima en una muestra de clases): 52 (Java 8),
55 (Java 11), 60 (Java 16) y 61 (Java 17). Todos son ejecutables en Java 21 (major 65).

### 2.3 Paquetes de Arch Linux (archlinux.org/packages, consulta JSON)

| Paquete | Repo | Versión | ¿Lo usa el instalador? |
|---|---|---|---|
| `jre21-openjdk-headless` | extra | 21.0.13.0.3.u1-1 | **Sí (obligatorio)** |
| `curl` | core | 8.23.0-1 | Sí (dependencia de pacman; ya presente) |
| `jq` | extra | 1.8.2-1 | **Sí** (parseo de la API de Paper) |
| `tar` | core | 1.35-5 | Sí (backups) |
| `zstd` | core | 1.5.7-3 | Sí (compresión de backups; ya presente por pacman/libarchive) |
| `gzip` | core | 1.15-1 | Sí (compresión alternativa) |
| `lm_sensors` | extra | 3.6.2-1 | Opcional (`--with-monitoring`) |
| `htop` | extra | 3.5.3-1 | Opcional (`--with-monitoring`) |
| `smartmontools` | extra | 7.5-2 | Opcional (`--with-monitoring`) — salud del SSD |
| `openssh` | core | 10.6p1-2 | Solo con `--ssh` |
| `ufw` | extra | 0.36.2-7 | Solo con `--firewall` y si no hay otro cortafuegos activo |
| `nftables` / `firewalld` | extra | 1.1.7-3 / 2.5.2-1 | Se detectan y respetan; no se instalan |
| `wget` | extra | 1.25.0-6 | **No** (redundante con curl) |
| `git` | extra | 2.56.0-1 | **No** (no lo necesita el instalador; útil para versionar docs, instalación manual) |
| `rsync` | extra | 3.5.1-3 | **No** por defecto (backups con tar; útil para copias externas, manual) |
| `tmux` | extra | 3.8-1 | **No** (la consola se resuelve con el FIFO de systemd) |
| `nano` | — | — | **No** (editor a elección del administrador) |
| `mcrcon` | — | **no existe en repos oficiales** | No (sería AUR) |

### 2.4 Plugins (Modrinth API v2, Hangar, GitHub, CI oficial)

Consulta: `GET https://api.modrinth.com/v2/project/<slug>/version?game_versions=["1.20.1"]`.
Todos los JAR se descargaron y su **SHA-512** coincidió con el publicado por Modrinth.

| Plugin | Versión fijada | Fuente | Declaración de compatibilidad | Licencia | Dependencias |
|---|---|---|---|---|---|
| LuckPerms | 5.5.71 (`LuckPerms-Bukkit-5.5.71.jar`) | Modrinth (proyecto oficial de lucko) | `game_versions` incluye 1.20.1; loaders bukkit/paper | MIT | — |
| EssentialsX | 2.20.1 | Modrinth (equipo EssentialsX) | 1.8.8 … **1.20.1** (publicada cuando 1.20.1 era la última) | GPL-3.0 | softdepend Vault, LuckPerms |
| EssentialsXSpawn | 2.20.1 | Modrinth (misma versión) | igual | GPL-3.0 | **Essentials** |
| Vault | 1.7.3 | GitHub `MilkBowl/Vault` release 1.7.3 | API independiente de versión (`api-version: 1.13`) | LGPL-3.0 | — |
| CoreProtect | 22.4 (CE) | Modrinth (PlayPro) | 1.15.2 … 1.20.6 | Artistic-2.0 | softdepend WorldEdit |
| GriefPrevention | 16.18.3 | Modrinth (proyecto oficial) | 1.19 … 1.20.6 | GPL-3.0 | softdepend Vault, WorldGuard… |
| WorldEdit | 7.2.15 (bukkit) | Modrinth (EngineHub) | Changelog: **"Bukkit implementations for 1.16.5 - 1.20.1"** | GPL-3.0 | — |
| WorldGuard | 7.0.9 | Modrinth (EngineHub) | Changelog: **"1.20(.1, .2, .4)"**, no compatible con < 1.20 | LGPL-3.0 | **WorldEdit** |
| PlaceholderAPI | 2.11.6 (opcional) | Modrinth / Hangar (HelpChat) | incluye 1.20.1 | GPL-3.0 | — |
| EssentialsXChat | 2.20.1 (opcional) | Modrinth | incluye 1.20.1 | GPL-3.0 | **Essentials** |
| spark | **pendiente** | spark.lucko.me → ci.lucko.me (Jenkins) | Sin declaración por build para 1.20.1 en Bukkit; Modrinth solo publica fabric/forge para 1.20.1 | GPL-3.0 | — |

Notas por plugin:

* **LuckPerms**: las versiones 5.4.x no declaran 1.20.1 en Modrinth (metadato), las 5.5.x sí. Se fija
  5.5.71 (última que lo declara en la fecha de la investigación). Bytecode Java 11.
* **EssentialsX**: las 2.21.x+ solo dan soporte oficial al último parche de cada versión menor
  (1.20.6 para 1.20); la 2.20.1 es la última que declara 1.20.1 explícitamente. **`/spawn` no está en
  el núcleo**: lo aporta el módulo **EssentialsXSpawn** (omisión en PLUGINS.md). La economía
  ("EssentialsX Economy") está integrada en el núcleo y se expone a otros plugins mediante Vault.
* **Vault**: no está en Modrinth ni Hangar; la release oficial de GitHub no publica checksum
  (`digest: null`). Se fija el SHA-512 calculado sobre el asset oficial descargado el 2026-10-30
  (*trust on first use*, documentado). `aa02af3c…8f6647`, 272 259 bytes.
* **CoreProtect**: 23.x/24.x también declaran 1.20.1, pero se elige 22.4 por ser la rama contemporánea
  de 1.20.x (prioridad de compatibilidad sobre novedad).
* **WorldEdit**: 7.3.x declara 1.20–1.20.6 pero su changelog indica que apunta a Java 21 y a 1.20.5+;
  7.2.15 es la versión cuyo changelog cita explícitamente 1.20.1. WorldGuard 7.0.9 la acepta.
* **spark**: se observó la build CI #546 `spark-1.10.194-bukkit.jar` (sha256 `7a53117c…eb38a`),
  pero el CI no publica checksums firmados y los artefactos pueden purgarse. Queda **pendiente**
  hasta que el administrador lo descargue manualmente desde <https://spark.lucko.me/download>,
  lo valide y añada su hash al manifiesto.

---

## 3. Paquetes disponibles y alternativas de Java

* **Opción elegida**: `jre21-openjdk-headless` — mínimo necesario para `--nogui`, sin dependencias
  gráficas (giflib, libpng…).
* Si ya existe `jre21-openjdk` o `jdk21-openjdk`, **no se instala nada**: `pacman -T
  jre21-openjdk-headless` queda satisfecho por sus `provides` y la ruta del binario es la misma.
* No se instala Java 17 ni otras versiones. No se cambia la versión global (`archlinux-java set`):
  el servicio usa la **ruta explícita** `/usr/lib/jvm/java-21-openjdk/bin/java`.
* Alternativas descartadas: binarios de Adoptium/Oracle descargados a mano (fuera de pacman, sin
  actualizaciones del sistema), paquetes AUR (no oficiales).

---

## 4. Fuentes oficiales consultadas

| Área | Fuente |
|---|---|
| Paquetes Arch | <https://archlinux.org/packages/search/json/?name=…>, listas de ficheros `…/files/json/` |
| Empaquetado OpenSSH Arch | <https://gitlab.archlinux.org/archlinux/packaging/packages/openssh> (PKGBUILD, `99-archlinux.conf`) |
| Wiki Arch | Power management (logind, tapa), Minecraft/Java Edition server, Uncomplicated Firewall, OpenSSH |
| Manuales | man.archlinux.org: `logind.conf(5)`, `systemd-logind.service(8)`, `systemd.socket(5)`, `systemd.service(5)`, `systemd.exec(5)`, `systemd.time(7)` |
| PaperMC | <https://fill.papermc.io/v3/projects/paper>, <https://docs.papermc.io/misc/downloads-service/>, <https://docs.papermc.io/paper/> |
| Plugins | <https://api.modrinth.com/v2/>, <https://hangar.papermc.io/api/v1/>, <https://github.com/MilkBowl/Vault/releases/tag/1.7.3>, <https://spark.lucko.me/download>, <https://ci.lucko.me/job/spark/> |
| EULA Minecraft | <https://aka.ms/MinecraftEULA> (enlace que escribe el propio servidor en `eula.txt`) |

---

## 5. Compatibilidad de plugins — clasificación para el manifiesto

1. **Confirmados (se instalan por defecto)**: LuckPerms, EssentialsX, EssentialsXSpawn, Vault,
   CoreProtect, GriefPrevention, WorldEdit, WorldGuard.
2. **Pendientes de validación (nunca se descargan automáticamente)**: spark.
3. **Opcionales (compatibles, desactivados; se activan editando el manifiesto)**: PlaceholderAPI,
   EssentialsXChat. Los demás candidatos de PLUGINS.md (TAB, DecentHolograms, Citizens,
   DeluxeMenus, ChestShop/QuickShop-Hikari, Jobs Reborn, etc.) **no** se han validado y quedan fuera
   del instalador.

Persistencia por defecto (relevante para backups): LuckPerms → H2 en `plugins/LuckPerms/`;
CoreProtect → SQLite `plugins/CoreProtect/database.db`; EssentialsX (saldos ¥) →
`plugins/Essentials/userdata/*.yml`; GriefPrevention → ficheros en `plugins/GriefPreventionData/`.
Todo queda dentro de `/var/lib/minecraft` y se incluye en el backup.

---

## 6. Dependencias entre componentes

```text
pacman (-Syu --needed) ─► jre21-openjdk-headless, jq
usuario minecraft + directorios ─► paper.jar (propiedad minecraft) ─► eula.txt / server.properties
paper.jar ─► plugins (requiere Paper instalado)
Java 21 + paper.jar + usuario + komorebi.conf ─► komorebi.service (+ komorebi-console.socket)
scripts de administración ─► komorebi-backup.service/.timer
EssentialsXSpawn, EssentialsXChat ─► EssentialsX      WorldGuard ─► WorldEdit
EssentialsX economía ─► Vault (para que otros plugins vean los saldos)
```

El instalador valida estas dependencias en cada modo parcial (`--paper`, `--plugins`, `--service`…)
y se detiene con instrucciones si falta una etapa previa.

---

## 7. Problemas detectados en los documentos originales

Los originales **no se han modificado**. Correcciones recomendadas:

| # | Documento | Problema | Corrección aplicada en el instalador |
|---|---|---|---|
| 1 | INSTALACION-ARCH | Servicio llamado `minecraft.service`; la especificación del instalador pide `komorebi.service`. | Se usa `komorebi.service`. |
| 2 | INSTALACION-ARCH | `ExecStart=/usr/bin/java`: depende de la versión global de `archlinux-java`, que puede no ser 21. | Ruta explícita `/usr/lib/jvm/java-21-openjdk/bin/java`. |
| 3 | INSTALACION-ARCH | `jre21-openjdk` instala dependencias gráficas innecesarias. | `jre21-openjdk-headless` (se acepta cualquiera de los tres ya instalado). |
| 4 | INSTALACION-ARCH | `useradd -r -m`: `-m` copia `/etc/skel` (`.bashrc`…) dentro del directorio del servidor; luego `mkdir -p` redundante. | `useradd --system --no-create-home` + directorios con permisos explícitos. |
| 5 | INSTALACION-ARCH | `pacman -Syu` y `pacman -S` por separado (correcto pero dos transacciones). | Una sola transacción `pacman -Syu --needed <paquetes>`; nunca `-Sy` parcial. |
| 6 | INSTALACION-ARCH | Primera ejecución manual con `sudo -u minecraft bash -c 'java …'` fuera de systemd (riesgo de procesos duplicados). | El instalador crea `eula.txt` y la primera ejecución la hace systemd. |
| 7 | INSTALACION-ARCH | Descarga "desde la web" sin procedimiento de verificación; la API v2 citada habitualmente está retirada (410). | Fill v3 + SHA-256 + tamaño + firma ZIP + `User-Agent` con contacto. |
| 8 | INSTALACION-ARCH | Paper 1.20.1 + Java 21 sin indicar build: solo la **196** incluye soporte Java 21. | Build fijada: 196 (con su SHA-256). |
| 9 | INSTALACION-ARCH | `motd` con `§` y kanji en crudo: `server.properties` se lee como *Java Properties* y la codificación puede corromperlo. | Se escribe con escapes `\u00A7d\u6728\u6F0F\u308C\u65E5 …` (formato que usa el propio servidor). |
| 10 | INSTALACION-ARCH / SEGURIDAD | Sin consola en un servicio systemd sin TTY: imposible ejecutar `whitelist add`/`op` con `white-list=true` y RCON desactivado. | Consola local por FIFO (`console-komorebi.sh`), solo root, sin red. |
| 11 | INSTALACION-ARCH | Sin `ExecStartPre` que compruebe EULA; sin límite de reinicios. | `ExecStartPre` (Java, JAR, `eula=true`), `StartLimitBurst=3/600 s`. |
| 12 | PLUGINS | `/spawn` figura como comando de EssentialsX, pero requiere el módulo **EssentialsXSpawn**. | Incluido como plugin confirmado. |
| 13 | PLUGINS | "EssentialsX Economy" aparece como plugin candidato; es parte del núcleo de EssentialsX. | Documentado; Vault actúa de puente. |
| 14 | PLUGINS | "AureliumSkills" se renombró a **AuraSkills**; "AuctionHouse" y "Clans" son nombres ambiguos (varios proyectos). | Fuera del instalador; revisar antes de la Etapa 4. |
| 15 | PLUGINS | spark: en Paper ≥ 1.21 viene integrado, en 1.20.1 **no**. | Pendiente de validación (ver §2.4). |
| 16 | README / ARQUITECTURA | Estructura `CONFIGURACION/ SCRIPTS/ BACKUPS/` frente a `config/ scripts/ backups/` de la especificación del instalador. | Se usa la estructura de la especificación del instalador. |
| 17 | SEGURIDAD | "No guardar todas las copias en el mismo SSD", pero `/var/backups/minecraft` está en el mismo disco. | Documentado como acción manual: copia externa periódica (USB/NAS con rsync). |
| 18 | ARQUITECTURA | GriefPrevention y WorldGuard protegen terreno a la vez. | Correcto si se separan funciones: GP = claims de jugadores; WG = regiones administrativas (spawn, mercado). Documentado. |
| 19 | README / ARQUITECTURA | `-Xms2G -Xmx4G`; Paper recomienda `Xms = Xmx`. | Se mantiene 2G/4G (petición explícita y laptop compartida con el SO); se documenta subir `Xms` a 4G tras pruebas. |

No se encontraron contradicciones en: Minecraft 1.20.1, Paper, Java 21, usuario `minecraft`,
`/var/lib/minecraft`, `/var/backups/minecraft/{daily,weekly,manual}`, `online-mode=true`,
`white-list=true`, view/simulation distance 7/5, no exponer SSH.

---

## 8. Riesgos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Paper 1.20.1 está **UNSUPPORTED**: sin parches de seguridad ni de rendimiento desde 2023-09. | Alto a medio plazo | `online-mode=true`, whitelist, sin RCON, sandbox systemd. Planificar migración (1.20.4/1.20.6 o 1.21.x) cuando los plugins lo permitan. |
| Java 21 con builds < 196 o plugins antiguos. | Medio | Build 196 fijada; bytecode de plugins verificado ≤ Java 17. Revisar logs en el primer arranque. |
| Wi-Fi: latencia/caídas; IP local cambiante. | Medio | Recomendación de Ethernet; reserva DHCP en el router; healthcheck. |
| CGNAT del proveedor. | Bloquea acceso externo | Comprobación manual (IP WAN del router ≠ IP pública, o rango 100.64.0.0/10). Alternativas: IP pública, VPN (WireGuard/Tailscale) o túnel. |
| Laptop: suspensión al cerrar la tapa / por inactividad; inhibidores de GNOME/KDE. | Alto (servidor caído) | Drop-in opcional de logind (`--power`), reversible; aviso sobre gestores de energía del escritorio. |
| Temperatura con la tapa cerrada; desgaste de batería. | Medio | Ventilación, `sensors`, healthcheck de temperatura, laptop siempre conectada. |
| 8 GB de RAM compartidos con el SO. | Medio | Heap 4 GB máx. (3 GB si hay < 7 GB detectados), `MemoryMax` de systemd. |
| Backup en caliente con plugins que escriben en SQLite/H2. | Medio | Modo por defecto: **parada controlada**. Modo `hot` opcional y documentado como experimental. |
| Copias en el mismo SSD. | Alto ante fallo del disco | Copia externa manual documentada. |
| Artefactos de terceros (Vault sin checksum oficial; spark en CI). | Medio | Vault: hash fijado TOFU desde la release oficial; spark: pendiente/manual. |
| Endurecimiento systemd no probado en Arch real. | Bajo/medio | Directivas estándar; se excluye `MemoryDenyWriteExecute` (rompe el JIT). Relajable con `systemctl edit`. |

---

## 9. Decisiones técnicas

1. **Fill v3** con build fijada (196) y SHA-256 fijado en la configuración; el instalador compara el
   hash de la API con el fijado y con el fichero descargado (tres comprobaciones independientes).
2. **`User-Agent`**: `komorebi-smp-installer/<versión> (+<HTTP_CONTACT>)`; `HTTP_CONTACT` es
   configurable en `/etc/komorebi/komorebi.conf` para cumplir el requisito de contacto de PaperMC.
3. **Java**: `jre21-openjdk-headless`, ruta explícita en el servicio, sin tocar `archlinux-java`.
4. **pacman**: una sola transacción `-Syu --needed`, solo si falta algún paquete; se aborta si existe
   `/var/lib/pacman/db.lck` (nunca se borra el bloqueo automáticamente). *(v1.1.0)* La pregunta tiene
   respuesta por defecto "no", avisa de que incluye el kernel y recomienda actualizar y reiniciar
   antes; con reinicio pendiente no se arranca el servidor ni se configura el cortafuegos.
5. **Usuario `minecraft`**: de sistema, `/usr/bin/nologin`, sin sudo, hogar `/var/lib/minecraft`,
   sin `/etc/skel`. Si existe, se audita (UID de sistema, shell, hogar, grupos) y solo se corrige con
   permiso. Nunca se borra.
6. **Permisos**: servidor `0750 minecraft:minecraft`; backups, logs y configuración propiedad de root;
   `umask 0027` en el servicio; jamás `777`.
7. **EULA**: `eula.txt` con `eula=false` si no existe; aceptación solo escribiendo `ACEPTO` de forma
   interactiva (`--eula`); `--yes` nunca la acepta. `ExecStartPre` impide arrancar sin EULA.
   *(v1.1.0)* El servicio solo se habilita al arranque una vez aceptado el EULA.
8. **server.properties**: editor propio línea a línea (sin `sed`), conserva comentarios y claves
   ajenas, añade las que falten, copia previa + confirmación si hay cambios; escritura atómica.
9. **Plugins**: manifiesto declarativo con URL + SHA-512/SHA-256 fijados; hosts permitidos
   (`cdn.modrinth.com`, `github.com`); nunca "latest"; no se reemplazan versiones distintas ya
   presentes sin permiso; las entradas `pending` jamás se descargan.
10. **systemd**: `Restart=on-failure`, `RestartSec=20`, `StartLimitBurst=3` en 600 s (luego queda en
    `failed` y registrado), `TimeoutStopSec=180`, `SuccessExitStatus=0 143` (SIGTERM = parada
    ordenada de Paper), `MemoryMax = Xmx + 2 GiB` (limitado por la RAM), sandboxing moderado.
    El SIGKILL de systemd solo actúa si se agota `TimeoutStopSec` (salvaguarda, no procedimiento normal).
11. **Consola sin RCON**: `komorebi-console.socket` con `ListenFIFO=/run/komorebi/console`
    (`SocketMode=0600`, root). Paper recibe el FIFO como stdin (`StandardInput=socket`) y
    `StandardOutput=journal` explícito (si no, systemd heredaría el FIFO como salida). Para evitar la
    activación por socket durante paradas, los scripts detienen socket y servicio juntos.
12. **Backups**: parada controlada por defecto (aviso a jugadores por consola, `systemctl stop`,
    comprobación de que no queda Java, `tar` + zstd, rearranque inmediato, verificación de
    integridad y SHA-256, retención por tipo). Modo `hot` opcional con `save-off` / `save-all flush`
    / `save-on` por el FIFO. Timer diario con `Persistent=true`; la copia semanal se promueve
    (enlace duro) desde la diaria del día configurado.
13. **Restauración**: `restore-komorebi.sh` extrae en un directorio temporal, valida rutas del
    archivo, mueve la instalación actual a `/var/lib/minecraft.pre-restore-<fecha>` (no la borra).
14. **Firewall**: detección de ufw / firewalld / nftables / iptables; se modifica solo el gestor activo
    (si hay uno) añadiendo 25565/tcp; con nftables/iptables solo se muestran instrucciones; si no hay
    ninguno se ofrece ufw con confirmación escrita y regla SSH limitada a la LAN para no bloquear la
    sesión. Nunca se desactiva un cortafuegos ni se activan dos.
15. **SSH**: opcional; drop-in `/etc/ssh/sshd_config.d/10-komorebi.conf` (`PermitRootLogin no`),
    `sshd -t` antes de aplicar y reversión automática si falla. `PasswordAuthentication no` solo con
    aprobación explícita y si hay `authorized_keys`. Sin cambios en el router.
16. **Energía**: opcional (`--power`); drop-in `/etc/systemd/logind.conf.d/50-komorebi-server.conf`
    con `HandleLidSwitch*=ignore` e `IdleAction=ignore`, recarga con `SIGHUP` a logind (documentado en
    `systemd-logind.service(8)`); reversible borrando el fichero. No se tocan sysctl, swap ni zram.
17. **Memoria**: `-Xms2G -Xmx4G` si se detectan ≥ 7 000 MiB; 3G entre 5 500 y 7 000; 2G por debajo
    (con aviso). Flags de Aikar tal como los publica la API de Paper.
18. **Modo simulación**: no escribe en el sistema (solo plantillas temporales en `$TMPDIR` que se
    eliminan al salir); sí consulta las APIs para mostrar qué se descargaría. Cada pregunta se
    resuelve con su respuesta por defecto y las confirmaciones escritas (EULA, cortafuegos,
    energía) se omiten.

---

## 10. Plan de instalación

1. Comprobaciones previas (Arch, x86_64, root, pacman libre, systemd, Internet, disco, RAM, CPU, Java,
   puertos, instalación previa) + informe de hardware (`lscpu`, `free`, `lsblk`, `df`, `ip`, `uname`).
2. Dependencias: `pacman -Syu --needed jre21-openjdk-headless jq …` (solo lo que falte, con confirmación).
3. Usuario `minecraft` y directorios con permisos.
4. `/etc/komorebi/komorebi.conf` (memoria calculada según la RAM real) y manifiesto de plugins.
5. Verificación de Java 21 (`java -version`, `archlinux-java status`, ejecución como `minecraft`).
6. Paper 1.20.1 build 196 desde Fill v3 con verificación; `eula.txt` (`false`); `server.properties`.
7. Plugins confirmados del manifiesto, con verificación de hash; informe de pendientes.
8. Scripts de administración, `komorebi.service`, `komorebi-console.socket`, `daemon-reload`, `enable`.
9. Backups: `komorebi-backup.service` + `.timer`.
10. Aceptación interactiva del EULA y primer arranque (opcional).
11. Opcionales con confirmación explícita: firewall, SSH, gestión de la tapa.
12. Resumen: cambios, omisiones, avisos y acciones manuales pendientes.

### Pruebas que **solo** pueden hacerse en el Arch real

* Transacción real de pacman y estado de `archlinux-java`.
* Creación del usuario `minecraft` con `useradd`.
* Arranque real de Paper con el sandboxing de systemd, consola FIFO y parada con SIGTERM.
* Lectura de comandos de consola por Paper desde el FIFO.
* Backup/restauración con el servicio real y conexión de un cliente Minecraft.
* Comportamiento de logind al cerrar la tapa, cortafuegos y SSH reales.
