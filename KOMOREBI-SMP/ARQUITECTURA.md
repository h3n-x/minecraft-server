Arquitectura técnica — KOMOREBI SMP
1. Objetivo
Definir la arquitectura de software, infraestructura, almacenamiento y comunicación del servidor.
La arquitectura inicial será sencilla, económica y mantenible.
Una laptop ejecutará Arch Linux y alojará una única instancia de Paper.
2. Diagrama general
text
JUGADORES
                     |
                     |
              INTERNET / LAN
                     |
                   ROUTER
                     |
                LAPTOP ARCH
                     |
          +----------+----------+
          |                     |
        SSH ADMIN             FIREWALL
          |                     |
          |                  TCP 25565
          |                     |
          +----------+----------+
                     |
                 ARCH LINUX
                     |
                  SYSTEMD
                     |
                PAPER 1.20.1
                     |
          +----------+----------+
          |          |          |
        PLUGINS    MUNDOS     CONFIGS
          |          |          |
          +----------+----------+
                     |
                 SSD LOCAL
                     |
                   BACKUPS

3. Componentes
Arch Linux
Responsabilidades:
• Administrar recursos.
• Gestionar usuarios.
• Administrar servicios.
• Controlar la red.
• Mantener el sistema actualizado.
Java 21
Ejecutará Paper y los plugins.
Paper
Gestionará:
• Mundos.
• Jugadores.
• Entidades.
• Eventos.
• Bloques.
• Plugins.
systemd
Administrará:
• Inicio automático.
• Detención controlada.
• Reinicio ante fallos.
• Logs.
• Estado del servicio.
SSH
Permitirá administrar el servidor desde otro equipo.
4. Directorios
Ruta principal:
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

Backups:
text
/var/backups/minecraft/
├── daily/
├── weekly/
└── manual/

Documentación y configuraciones versionadas:
text
~/KOMOREBI-SMP/
├── README.md
├── ARQUITECTURA.md
├── PLUGINS.md
├── IDENTIDAD-Y-GAMEPLAY.md
├── INSTALACION-ARCH.md
├── SEGURIDAD-Y-MANTENIMIENTO.md
└── CONFIGURACION/

5. Integración de plugins
text
PAPER
                    |
       +------------+-------------+
       |            |             |
   LuckPerms   EssentialsX    CoreProtect
       |            |
       |           Vault
       |            |
       |       Economy Plugins
       |
   PlaceholderAPI
       |
   TAB / Menus

   WorldEdit
       |
   WorldGuard

   GriefPrevention

Las integraciones se realizarán mediante las APIs y dependencias oficiales de cada proyecto.
No se asumirán dependencias que no estén documentadas.
6. Mundos y ambientación
Mundo principal: Komorebi
Identidad:
• Naturaleza japonesa.
• Montañas.
• Bosques.
• Aldeas.
• Jardines.
• Construcciones comunitarias.
Distrito: Yoru
Zona temática de tecnología y cyberpunk.
Identidad:
• Neones.
• Edificios futuristas.
• Cafeterías.
• Mercados nocturnos.
• Estaciones.
• Carteles luminosos.
Se podrá construir dentro del mundo principal o en una región separada, según el rendimiento y la planificación.
Zona social: Natsukashii
Espacios tranquilos:
• Cafeterías.
• Jardines.
• Miradores.
• Casas tradicionales.
• Lugares para eventos pequeños.
Nether y End
Mantendrán las funciones vanilla, con posibilidad de decoración personalizada en el futuro.
7. Persistencia
Cada plugin tendrá su propio mecanismo de almacenamiento.
Se documentará:
• Archivos YAML.
• Bases de datos SQLite.
• Bases de datos externas.
• Datos de jugadores.
• Configuraciones.
• Backups.
No se incorporará MariaDB ni Redis en la primera etapa.
8. Red
Puerto del juego:
text
25565/TCP

Medidas:
• IP local reservada.
• Preferencia por Ethernet.
• Wi-Fi como alternativa.
• Comprobar CGNAT.
• No exponer SSH directamente.
• Utilizar VPN o túnel seguro cuando sea necesario.
9. Rendimiento
Valores iniciales:

Parámetro
Valor

RAM Java
4 GB máximo

RAM inicial
2 GB

View distance
7

Simulation distance
5

Jugadores
10

Mundos principales
1 + Nether + End


La carga de entidades, redstone, granjas y plugins será evaluada mediante pruebas.
10. Escalabilidad
La primera etapa utilizará una única instancia Paper.
Posibles ampliaciones:
• Velocity.
• Servidor de eventos.
• Mundo de recursos.
• Base de datos externa.
• Panel administrativo.
• Integración con Discord.
• Sitio web.
No se instalarán estos componentes hasta que exista una necesidad concreta.