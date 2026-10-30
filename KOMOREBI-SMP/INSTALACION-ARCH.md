Instalación — KOMOREBI SMP en Arch Linux
1. Objetivo
Instalar y ejecutar Komorebi SMP en una laptop con Arch Linux.
2. Requisitos de hardware
• Intel Core i3 de décima generación (modelo exacto pendiente).
• 8 GB de RAM.
• SSD.
• Wi-Fi.
• Alimentación estable.
• Refrigeración funcional.
3. Software
• Arch Linux.
• OpenJDK 21.
• Paper 1.20.1.
• systemd.
• OpenSSH.
• curl.
• wget.
• jq.
• nano.
• rsync.
• tar.
• Git.
• tmux.
4. Actualizar Arch Linux
bash
sudo pacman -Syu

5. Instalar paquetes
bash
sudo pacman -S \
  jre21-openjdk \
  curl \
  wget \
  jq \
  nano \
  rsync \
  tar \
  git \
  tmux \
  openssh

Comprobar:
bash
java -version
archlinux-java status

Si existen varias instalaciones de Java, seleccionar la versión 21 mediante el nombre exacto que muestre archlinux-java status.
6. Crear usuario
bash
sudo useradd -r -m -U \
  -d /var/lib/minecraft \
  -s /usr/bin/nologin minecraft

Preparar carpeta:
bash
sudo mkdir -p /var/lib/minecraft
sudo chown minecraft:minecraft /var/lib/minecraft

7. Descargar Paper
Objetivo:
text
Minecraft 1.20.1
Paper
Java 21

Descargar una compilación estable desde:
https://papermc.io/downloads/paper
Guardar como:
text
/var/lib/minecraft/paper.jar

Cambiar propietario:
bash
sudo chown minecraft:minecraft \
  /var/lib/minecraft/paper.jar

Verificar la descarga y no utilizar archivos JAR de terceros desconocidos.
8. Primera ejecución
bash
sudo -u minecraft bash -c \
'cd /var/lib/minecraft && \
java -Xms2G -Xmx4G -jar paper.jar --nogui'

Esperar la generación inicial.
Aceptar el EULA solo después de leer y aceptar las condiciones:
bash
sudo -u minecraft nano \
  /var/lib/minecraft/eula.txt

Cambiar:
properties
eula=false

por:
properties
eula=true

9. Servicio systemd
Crear:
bash
sudo nano /etc/systemd/system/minecraft.service

Contenido:
ini
[Unit]
Description=Komorebi SMP Minecraft Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=minecraft
Group=minecraft
WorkingDirectory=/var/lib/minecraft

ExecStart=/usr/bin/java -Xms2G -Xmx4G -jar paper.jar --nogui

Restart=on-failure
RestartSec=10

TimeoutStopSec=120
SuccessExitStatus=0 143

[Install]
WantedBy=multi-user.target

Activar:
bash
sudo systemctl daemon-reload
sudo systemctl enable --now minecraft

Consultar:
bash
sudo systemctl status minecraft

Logs:
bash
sudo journalctl -u minecraft -f

10. Configuración de server.properties
Archivo:
text
/var/lib/minecraft/server.properties

Configuración inicial:
properties
motd=§d木漏れ日 §f| §aKOMOREBI SMP
server-port=25565
online-mode=true
white-list=true
max-players=10
view-distance=7
simulation-distance=5
spawn-protection=16
difficulty=normal
gamemode=survival
pvp=true
allow-flight=false
enable-command-block=false

Mantener online-mode=true.
11. Configuración visual
La estética se implementará mediante:
• Construcciones.
• Resource pack.
• Hologramas.
• NPC.
• Menús.
• Texturas.
• Iluminación.
• Decoración.
No se necesitan paquetes adicionales del sistema operativo para construir la estética.
12. Directorios
text
/var/lib/minecraft/
├── paper.jar
├── server.properties
├── eula.txt
├── plugins/
├── world/
├── world_nether/
├── world_the_end/
├── logs/
└── config/

Los recursos visuales y las configuraciones versionadas se mantendrán en el repositorio de documentación.
13. SSH
Activar:
bash
sudo systemctl enable --now sshd

Consultar IP:
bash
ip -br addr

Desde otro equipo:
bash
ssh usuario@IP_LOCAL

Utilizar claves SSH y proteger el acceso administrativo.
14. Comandos de administración
Iniciar:
bash
sudo systemctl start minecraft

Detener:
bash
sudo systemctl stop minecraft

Reiniciar:
bash
sudo systemctl restart minecraft

Estado:
bash
sudo systemctl status minecraft

Logs:
bash
sudo journalctl -u minecraft -f

15. Pruebas
• Java funciona.
• Paper inicia.
• EULA aceptado.
• systemd funciona.
• El servidor arranca automáticamente.
• Se puede entrar desde la red local.
• Los plugins cargan.
• El servidor se detiene correctamente.
• Se generan los mundos.
• Se pueden restaurar los backups.
16. Rendimiento
Valores iniciales:
• Java: 4 GB máximos.
• View distance: 7.
• Simulation distance: 5.
• 10 jugadores.
• Mundo principal compacto.
• Construcciones y entidades optimizadas.
No instalar shaders ni paquetes de recursos pesados en la laptop del servidor: los recursos visuales se procesarán en los clientes.

───

Objetivo: dejar una instancia estable de KOMOREBI SMP preparada para recibir los primeros jugadores.