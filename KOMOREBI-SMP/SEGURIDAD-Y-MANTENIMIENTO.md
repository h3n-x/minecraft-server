Seguridad y mantenimiento — KOMOREBI SMP
1. Objetivo
Proteger la infraestructura, los mundos, los datos de los jugadores y la información administrativa.
2. Seguridad de Arch Linux
Minecraft se ejecutará bajo:
text
minecraft

Nunca utilizar root para ejecutar Paper.
Mantener:
• Sistema actualizado.
• Usuarios controlados.
• Servicios innecesarios desactivados.
• Firewall configurado.
• Acceso SSH protegido.
3. Seguridad SSH
• Utilizar claves SSH.
• Deshabilitar acceso root.
• Evitar contraseñas débiles.
• Restringir acceso administrativo.
• No exponer SSH directamente a Internet.
• Preferir una VPN para administración remota.
4. Seguridad de Minecraft
Mantener:
properties
online-mode=true
white-list=true

Durante las pruebas.
Antes de abrir el servidor, decidir si se mantiene whitelist o se permite acceso público.
Utilizar LuckPerms para los permisos.
No compartir:
• Credenciales.
• Tokens.
• Contraseñas.
• Archivos sensibles.
• Información administrativa.
5. Firewall
Puerto del servidor:
text
25565/TCP

SSH:
text
22/TCP

El acceso SSH debe quedar restringido a la red local o VPN.
No abrir puertos que no se utilicen.
6. Backups
Elementos que deben respaldarse:
• Mundo principal.
• Nether.
• End.
• Plugins.
• Configuraciones.
• Inventarios.
• Economía.
• Permisos.
• Archivos importantes.
Frecuencia

Backup
Frecuencia

Diario
Cada día

Semanal
Cada semana

Manual
Antes de cambios

Externo
Periódicamente


No guardar todas las copias en el mismo SSD.
Probar periódicamente la restauración.
7. Actualizaciones
Antes de actualizar Paper o cualquier plugin:
1. Comprobar compatibilidad.
2. Revisar cambios.
3. Crear backup.
4. Detener Paper.
5. Actualizar.
6. Iniciar.
7. Revisar logs.
8. Probar funciones.
No actualizar automáticamente la versión de Minecraft durante una temporada activa.
8. Monitorización
Memoria
bash
free -h

CPU
bash
htop

Disco
bash
df -h

Temperatura
bash
sensors

Instalar sensores:
bash
sudo pacman -S lm_sensors

Registros
bash
sudo journalctl -u minecraft -n 100

Utilizar spark para analizar el rendimiento de Paper.
9. Protección física
• Mantener la laptop conectada a la corriente.
• Evitar cerrar la tapa si provoca suspensión.
• Mantener ventilación.
• Limpiar ventiladores.
• Vigilar temperaturas.
• Comprobar salud del SSD.
• Utilizar Ethernet cuando sea posible.
10. Acceso externo
Antes de publicar el servidor:
1. Reservar IP local.
2. Comprobar Wi-Fi.
3. Medir velocidad de subida.
4. Comprobar latencia.
5. Identificar CGNAT.
6. Configurar acceso externo seguro.
Si existe CGNAT:
• Solicitar IP pública.
• Utilizar una VPN.
• Evaluar un túnel de acceso.
No publicar información privada de la red.
11. Recuperación ante fallos
Paper no inicia
• Revisar Java.
• Revisar JAR.
• Comprobar permisos.
• Consultar logs.
• Revisar plugins.
Plugin defectuoso
• Detener Paper.
• Identificar plugin.
• Retirarlo.
• Restaurar configuración.
• Reiniciar.
• Comprobar.
Mundo dañado
• Detener servidor.
• Conservar copia del mundo dañado.
• No sobrescribirla.
• Restaurar backup verificado.
Apagado inesperado
• Comprobar logs.
• Revisar sistema de archivos.
• Comprobar estado del SSD.
• Comprobar temperatura.
• Restaurar si fuera necesario.
12. Rutina de mantenimiento
Diaria
• Revisar estado.
• Comprobar backups.
• Revisar errores.
Semanal
• Revisar memoria.
• Revisar disco.
• Comprobar temperaturas.
• Revisar plugins.
• Revisar permisos.
Mensual
• Probar restauración.
• Revisar actualizaciones.
• Comprobar seguridad.
• Evaluar rendimiento.
• Revisar conectividad.
13. Protección de datos de jugadores
Los datos de los jugadores deben conservarse y protegerse.
No recopilar información innecesaria.
No compartir datos personales.
No exponer logs administrativos públicamente.
14. Criterios de apertura
No abrir KOMOREBI SMP al público hasta contar con:
• Backups funcionales.
• Permisos correctos.
• Protección de terrenos.
• Autenticación.
• Moderación.
• Firewall.
• Conexión externa probada.
• Plan de recuperación.
15. Objetivo final
KOMOREBI SMP debe ser un servidor seguro, estable y mantenible, con una estética japonesa y una comunidad tranquila.
La protección de los jugadores y sus construcciones es una prioridad.