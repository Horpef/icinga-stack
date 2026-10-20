# Roadmap

Plan de crecimiento del stack. Existe porque la primera versión del plan solo
vivía en la conversación: cuando llegó el momento de usarlo había que
reconstruirlo de memoria, que es exactamente lo que este proyecto se ahorra
en todo lo demás. Escrito, versionado y con remoto, ya no se pierde.

Cada fase tiene un **criterio de hecho**, que es lo único que la distingue de
«seguir tocando cosas hasta que se parezca». Y cada fase se activa cuando
hace falta, no antes: la tentación de adelantar trabajo que nadie ha pedido
es la forma más común de estancarse.

**Estado: Fases 1 y 2 completas, más un segundo stack ajeno (app + Oracle).**
La 3 (romper cosas a propósito para calibrar umbrales y tiempos) es la
siguiente; la 4 espera a que el crecimiento la justifique.

---

## Fase 1 · El stack se monitoriza a sí mismo ✅

**Hecho.** Montar el stack de monitorización de punta a punta, declarativo y
verificable, y que vigile también sus propias copias.

- Icinga 2 + Icinga Web 2 + Director, con 6 hosts y 32 servicios
- InfluxDB → Grafana con el dashboard `icinga-stack` (19 paneles)
- Mailpit como buzón de notificaciones — se comprueba de verdad: `verify.ps1`
  envía una notificación y espera verla llegar
- Duplicati con destino en el **otro disco** (`C:`), scheduler propio y
  `duplicati-init` multi-JSON, idempotente
- **Que el monitoreo vigile las copias** (el paso 4): cinco servicios
  `Backup - *`, el plugin `check-backups.sh` con sus cinco pruebas
  (`destino`, `espejo`, `volcado`, `espacio`, `programada`), el heartbeat de
  Icinga DB — el único contenedor sin healthcheck, vigilado desde fuera con
  `mysql_query` — y la red de seguridad `safety-net.ps1`
- **Criterio de hecho alcanzado**: `verify.ps1` → 53 checks, TOTAL FALLOS: 0,
  exit 0, en producción y en clean-test

## Fase 2 · El primer stack real ✅

**Hecho.** Vigilar un stack que no sea el propio, de punta a punta, y que
quede declarativo y verificable como todo lo demás.

El stack elegido es **Wazuh 4.14.8** (`D:\docker\wazuh-stack`), que se cuelga
de `monitoring-net` — que era exactamente el gancho que ya estaba construido.
Se dio de alta por `conf.d` (el otro camino que documenta el README, vía
Director, no hizo falta: los `.conf` montados fichero a fichero conviven con
Director, como ya hacían `hosts.conf` y `stack-monitoring.conf`, y su health
sigue en *everything is fine*).

| Qué toca | Cómo | Estado |
|---|---|---|
| Nuevo `Host` + `apply Service` | `icinga2-conf/conf.d/wazuh.conf`: 3 hosts, 5 servicios, 1 hostgroup | ✅ |
| Darlo de alta | su línea de montaje en el compose + `icinga2 daemon -C` **antes** de recrear | ✅ |
| Notificaciones | sin tocar nada: 49 objetos, los de Wazuh incluidos | ✅ |
| Panel en Grafana | ids 20-22, con filtro propio `hostname =~ /wazuh/` | ✅ |
| Copias | `backup/wazuh-stack-backup.json` + sus 4 montajes + alta idempotente | ✅ |

**Criterio de hecho cumplido** — y comprobado, no deducido:

- **Aparece en Icinga**: 9 hosts y 40 servicios en OK. Los 8 nuevos son API
  del manager esperando **401** (que es la respuesta sana: el daemon contesta
  y rechaza anónimos), TCP 1514 y 1515 por separado, `green` del clúster del
  indexer (200 **y** cuerpo) y **302** del panel, más sus tres `ping4`.
- **Dispara una notificación que acaba en Mailpit**: `send-custom-notification`
  contra `wazuh-manager!Wazuh Manager - API (HTTPS)` → 200 y el mensaje llega.
  Es el chequeo `4b` de `verify.ps1`; el chequeo antiguo mandaba uno contra
  `mariadb`, que es del propio stack, y no bastaba para esto.
- **Tiene su panel en Grafana**: los tres de la fila `y=56`, con consulta
  propia para que sigan viéndose cuando el filtro Host esté en otro stack, y
  los tres hosts apareciendo ya en ese filtro (sale de la etiqueta
  `hostname` de `hostalive`).
- **Copia real**: 4 orígenes, primera ejecución `Success` con 0 errores y 0
  avisos, y restauración comprobada **bit a bit** con SHA256 idéntico
  (`verify.ps1`, chequeos `6.6b` y `6.7b`).

**Lo que NO se hizo, deliberadamente**: ampliar `safety-net.ps1` a los 14
volúmenes de Wazuh y el plugin de copias a los stacks nuevos. Está en la Fase 4
y así se respetó — la tentación de adelantar trabajo que nadie ha pedido es la
forma más común de estancarse, y aquí no lo había. Mientras tanto, los
volúmenes de Wazuh se reconstruyen reinstalando el stack **desde su
configuración, que sí está copiada**; no hace falta la red de seguridad para
eso.

**Criterio de hecho**: un stack ajeno aparece en Icinga, dispara una
notificación que acaba en Mailpit, y tiene su panel en Grafana.

## Stack nuevo #2 · App + Oracle (✅, 2026-10-19)

**Cuándo**: la continuación natural de la Fase 2 — «ir sumando app para
monitorizar». Segunda app ajena, esta vez **con base de datos y todo en
contenedores** (nada fuera de Docker).

Es una **app Flask** mínima + **Oracle Database Free 23ai**
(`D:\docker\oracle-stack`), colgada de `monitoring-net` como Wazuh. El objetivo
no es la app (es deliberadamente tonta) sino tener una **cadena app→BD de
verdad** que monitorizar: `/health` ejecuta un `SELECT 1 FROM DUAL`, de modo que
el servicio se pone CRITICAL si la base cae **aunque el proceso de la app siga
vivo** — la diferencia que un chequeo de puerto no ve.

| Qué toca | Cómo | Estado |
|---|---|---|
| Nuevo stack | `oracle-stack/`: `oracle-db` (gvenzl/oracle-free 23ai *slim*) + `oracle-app` (Flask + `oracledb` thin) | ✅ |
| Darlo de alta en Icinga | `conf.d/oracle.conf`: 2 hosts, 3 servicios (+2 `ping4`) | ✅ |
| Panel en Grafana | ids 23-25, con filtro propio `hostname =~ /oracle/` | ✅ |
| Copias | `backup/oracle-stack-backup.json` (solo declaración) + `oracle_data` en safety-net (en frío) | ✅ |
| Wazuh | FIM `/mon/oracle-stack`; logs por el driver `json-file` (entran solos) | ✅ |
| `verify.ps1` | sección 9: contenedores, `/health` con consulta real y que el `HEARTBEAT` **crezca** | ✅ |

**Criterio de hecho cumplido** — y comprobado, no deducido:

- **Aparece en Icinga**: 11 hosts y 45 servicios; los 5 nuevos (`listener 1521`,
  `HTTP 8080`, `Salud app+BD`, más dos `ping4`) en **OK**.
- **La cadena app→BD es real**: `/health` responde `ok` (hace `SELECT 1 FROM
  DUAL`) y el contador de `HEARTBEAT` **crece** entre dos lecturas separadas
  (la app escribe sola cada 15 s).
- **Copia declarativa**: Duplicati la da de alta sola (ID 3) y la primera
  ejecución termina bien.

**Gotcha medido** (documentado en el compose y en `oracle-stack/README.md`):
fijar `ORACLE_DATABASE: FREEPDB1` hace que el entrypoint intente crear un PDB
que **ya** crea por defecto → `ORA-65012` → healthcheck `3` (unhealthy) para
siempre y `APP_USER` **sin crear**. **No se fija**: el default ya es `FREEPDB1`.

## Fase 3 · Entender a fondo, rompiendo umbrales

**Cuándo**: nada más cerrar la fase 2 — se aprende sobre stack propio, no en
producción de nadie.

No se aprende Icinga leyéndolo: rompiéndolo a propósito y mirando qué pasa.

- Parar un contenedor, cortar la red, llenar el disco, matar el heartbeat de
  Icinga DB, parar `mysql-dump` para ver fallar la prueba `volcado`
- En cada caso: cuánto tarda en pasar a HARD, qué se ve en el dashboard, qué
  llega a Mailpit, y qué NO se ve (el punto ciego de cada prueba)
- **Calibrar umbrales con datos, no con criterio** — que es lo que ya se hizo
  con el heartbeat: 180 s / 600 s contra un periodo real de ~70 s y los
  2,5 min de gracia de `max_check_attempts × retry_interval`

**Criterio de hecho**: sabes de memoria cuánto tarda cada alerta en llegar,
qué haces cuando llega, y qué prueba la está vigilando a ella.

### Medido el 2026-10-20 (parar `oracle-db` a propósito)

`docker compose stop oracle-db` a las 20:04:36 UTC y `start` a las 20:11:47.

| Momento | Qué pasa |
|---|---|
| T+10 s | `Oracle DB - Listener (1521)` → CRITICAL (blando) |
| T+50 s | host `oracle-db` → **DOWN**: `check_ping: Invalid hostname/address - oracle-db` |
| T+60 s | `Oracle App - Salud app+BD` → CRITICAL (`HTTP/1.1 500 INTERNAL SERVER ERROR`) |
| T+118 s | correo **Host … is DOWN!** |
| T+201 s | correo **Salud app+BD … is CRITICAL!** (`HTTP 500`) |
| al arrancar, T+7 s | correo **Host … is UP!** (`PING OK`, 0,78 ms) |
| al arrancar, T+69 s | correo **Salud app+BD … is OK!** (`HTTP 200`, 0,013 s) |

Lo que enseña (y no está en la doc):

1. **El puerto 8080 siguió `OK` todo el rato.** App viva + BD muerta = el check
   de puerto no ve nada; el que avisa es `/health`. Es exactamente el motivo por
   el que ese servicio existe.
2. **El host cae primero, y por DNS**: al parar el contenedor Docker deja de
   resolver `oracle-db`, así que `check_ping` no falla por paquetes perdidos
   sino con `Invalid hostname/address`. Es un DOWN de *resolución*.
3. **El host DOWN silencia los servicios de ese host**: el `Listener` se quedó
   en CRITICAL pero **no envió ni un correo** (0 mensajes con «Listener» en
   Mailpit). Es lo correcto (evita la tormenta), pero deja menos diagnóstico: el
   correo que explica el fallo es el de `/health`, que vive en **otro** host.
4. **La app se recupera sola**: no hubo que reiniciar `oracle-app`; el pool de
   `oracledb` descartó las conexiones muertas y volvió a `OK` en 0,013 s.

## Fase 4 · Crecer

**Cuándo**: solo cuando el número de stacks o de nodos lo justifique.

- **2-3 stacks** → sacar Duplicati a su propio compose. Antes, no: un solo
  trabajo con varios JSON es más fácil de vigilar que dos servicios.
  **Decidido el 2026-10-20 (con 3 stacks): se pospone a propósito** — ver la
  fila correspondiente en «Decisiones ya tomadas»; el coste (volumen
  `duplicati_config` + perder Duplicati en el clean-test) supera al beneficio
  mientras todo viva en un solo host.
- **Swarm / Kubernetes** → solo cuando haya más de un host que mantener.
  Hoy una máquina con 11 contenedores no pide orquestación, pide que los
  backups funcionen.
- Ampliar `safety-net.ps1` a los volúmenes nuevos y el plugin de copias a los
  stacks nuevos: **hecho**. `safety-net` volca ya los **31 volúmenes de los 3
  stacks** (Wazuh y Oracle incluidos) y el plugin vigila las **3 copias**
  declaradas. (Este punto decía «hoy volca los 12 del stack de monitorización»:
  se quedó escrito antes de que existieran los stacks #2 y #3.)
- **La VM ya usa los 4 núcleos del equipo: no hay vCPU que dar.** Medido el
  2026-10-20: el host es un **i3-9100F (4 núcleos / 4 hilos, 15,9 GB)** y Docker
  Desktop ya tiene los 4 y 8 GB, con **~164 MB libres** en la VM (3,4 GB en
  caché): hay **presión de memoria**, que es de donde sale buena parte del
  16 % de `io`. Con los 18 contenedores, `icinga2!load` está en **WARNING
  sostenido** (load 9-11; *scaled* 1.8-2.7; 33 % `usr` / 25 % `sys` / 16 % `io`
  / 19 % `idle`) y llega a **CRITICAL** en los picos (16,7 al reconstruir la
  imagen y reiniciar Oracle), con **6 notificaciones entre las 19:45 y las
  20:18**. El consumidor mayor es **`wazuh-modulesd`** (~31-65 %, detección de
  vulnerabilidades), no los contenedores del stack (todos < 10 %). Salidas, por
  orden: (a) **más RAM a la VM** (8 → 11-12 GB de los 15,9): ataca la causa
  (menos I/O, menos `io`); (b) **calibrar el umbral de `load` con los datos
  medidos** (p. ej. 12/20), porque el 5/10 por defecto es *total*, pensado para
  equipos con más núcleos, y en este genera ruido permanente; (c) bajar el
  apetito de Wazuh (detección de vulnerabilidades). Lo que **no** vale es
  mirar para otro lado: hoy el aviso es cierto.
- Mismo criterio que todo lo demás: declarativo, idempotente, con su check en
  `verify.ps1`. Si no se puede verificar, no se hace.

---

## Decisiones ya tomadas (no reabrirlas sin motivo)

| Decisión | Motivo |
|---|---|
| Red `monitoring-net` externa con nombre estable | los stacks nuevos se cuelgan sin renombrar nada |
| Un trabajo de Duplicati con varios JSON | hasta 2-3 stacks; migrarlo a compose propio después |
| Destino de copias en `C:` (disco distinto) | un fallo de `D:` no puede llevarse datos **y** copias |
| Orígenes montados uno a uno, no `./` entero | por construcción no puede respaldarse a sí mismo |
| Copia plana del proyecto con `project-mirror` | declara**ción** de `icinga-stack/` replicada a otro disco cada 10 min. **OJO desde el monorepo (2026-10-16):** el `.git` subió a `D:\Docker`, así que el mirror **ya no refleja el historial git** (solo los ficheros de `icinga-stack/`); ese historial lo respalda ahora **GitHub** (el remoto `origin`). El mirror tampoco cubre `wazuh-stack/` |
| Sin arranque automático ni `restart: always` | modelo de copia aceptado: catch-up al encender la PC |
| Identidad git **local** | la global sigue sin tocar |
| Datos de Docker (`docker_data.vhdx`) en `E:\DockerDesktopWSL` (SSD SATA) | el HDD de `D:` daba iowait 53% y load pegado al umbral (6.0); tras mover a SSD: iowait ~2%, load ~1.2 y verify en 0 (2026-10-08). `CustomWslDistroDir` + `BasePath` (Lxss) apuntan a E:. El pagefile del sistema se reubicó de E: a C: (NVMe), que además bloqueaba el formateo |
| `SharedAccess` (ICS de Windows) **detenido** (Manual, no arranca solo) | sus rangos de puertos excluidos (bloques de ~100 en 53–55k) impedían el bind del host `55000` del Wazuh API (WSAEACCES 10013) y con ello el arranque del manager. Si un día el manager no levanta al arrancar Docker: `netsh int ipv4 show excludedportrange protocol=tcp` y parar SharedAccess |
| Segundo agente Wazuh `icinga-stacks` (logcollector sobre `/var/lib/docker/containers`) | recoge LO QUE IMPRIMEN los contenedores del icinga-stack (el agente `docker-stacks` solo vigila FICHEROS). La frontera de "no monitorizar a Wazuh a sí mismo" es el **driver de logging**, no una lista de exclusiones: icinga-stack declara `json-file` explícito (→ `*-json.log`, cubierto por el wildcard) y wazuh-stack se queda en el `local` por defecto (→ `local-logs/` binario, fuera del wildcard). Verificado: 13 dirs con `-json.log` vs 5 con `local-logs/` (2026-10-09). Regla propia `100100` (`container-errors`) |
| Regla 100100: **sin paréntesis** en `<match>` y umbral `log_alert_level` | **DOBLE TRAMPA** que silenciaba las alertas: (1) el regex de Wazuh (OSRegex) NO trata `()` como agrupación, los exige como literales, así que `(error\|critical\|…)` exigía un `(` antes de `error` y el contenido `error` caía en la 1002; (2) el manager tiene `<log_alert_level>3</log_alert_level>`, y la 1002 es nivel 2, así que jamás escribe alerta. Ambas juntas anulaban cualquier alerta de contenido pese a que el transporte (logcollector→remoted→analysisd) estaba sano. Fijado el `<match>` sin paréntesis y documentado en los comentarios del XML (2026-10-09). `verify.ps1` sección 8 lo protege con una sonda E2E |
| `monitoring-stack` (Naemon+Thruk+MariaDB+Apache) **descartado y borrado** (2026-10-16) | era código muerto: jamás corrió (sin contenedores, volumes ni imágenes), cero referencias desde verify/safety-net/Duplicati/mk-clean-test, y duplicaba lo que Icinga+Web+Grafana ya dan (Icinga vigila 40 servicios). Además tenía 2 bloqueos (red propia `monitoring_net` aislada de `monitoring-net`; healthcheck de Thruk apuntando a `/var/lib/naemon/rw/live` sin montar `naemon_var`) y chocaba de puertos 8080/8443 con `icinga-web`. El precursor `naemonbox` (tarball 98 MB) ya se había borrado antes. Hoy el proyecto son 2 stacks productivos: `icinga-stack` + `wazuh-stack` |
| `critical/InfluxdbWriter` intermitente (500 "timeout") → `wal-fsync-delay=200ms` | **No era volumen** (la BD pesa 68 MB y tiene ~160 series) sino **latencia de E/S**: el `influxdb.conf` por defecto de la imagen trae `wal-fsync-delay=0s` (un fsync a disco en **cada** escritura) y sobre el SSD SATA sin DRAM (iowait medido 46-75%) algunos writes superaban `[coordinator] write-timeout=10s` → `500` → Icinga **no reintenta** → huecos intermitentes de métricas en Grafana. Mismo origen que el WARNING de load. Fix: `influxdb/influxdb.conf` propio (default generado con `influxd config` + **solo** `wal-fsync-delay=200ms`; en 1.8 la opción se llama así, **NO** `wal-fsync-interval`, que era de versiones previas y no hace nada) montado sobre `/etc/influxdb/influxdb.conf`. Hay que recrear el servicio, no basta `restart`. Trade-off aceptado: hasta 200 ms de métricas perdidas en un corte de luz (se regeneran solas). Verificado 2026-10-16: 0 `critical` en 2 min y writes `204` correctos |
| Repo git **monorepo**: raíz en `D:\Docker` (2026-10-16) | El repo nació como `icinga-stack/.git` y `wazuh-stack/` quedaba **fuera de control de versiones** (su README, la regla 100100 y el compose no se podían commitear). Se movió la raíz a `D:\Docker` reescribiendo el historial con `git filter-branch` (anteponiendo `icinga-stack/` a todas las rutas → **todos los hashes cambiaron**; el historial previo, con los hashes viejos, está respaldado en `C:\docker-backups\icinga-pre-monorepo.bundle` y en el remoto antes del force-push). `wazuh-stack/` pasa a versionarse (26 ficheros). La `.gitignore` sube a la raíz para cubrir ambos stacks. **Efecto en `project-mirror`**: al subir el `.git`, el mirror de `icinga-stack/` ya no incluye el historial git → lo respalda GitHub. Se usó `filter-branch` porque `git filter-repo` no está instalado (requiere Python, ausente en la máquina). `data/` está vacío, no se trackea |
| `safety-net.ps1` ampliado a **ambos stacks** (30 volúmenes) | Antes solo volcaba `icinga-stack`. Ahora volca los 12 de icinga + los 18 de wazuh en **una sola ventana** (se paran los dos stacks juntos, sin `-v`, para que el snapshot sea consistente y no haya cruces de alertas Icinga↔Wazuh). Trato especial para `wazuh_queue`: contiene los feeds CVE de Vulnerability Detector en `vd/` + `vd_updater/` (**12,5 GB**) que el updater vuelve a bajarse solos cada 60 min (`feed-update-interval=60m`); se vuelcan con `tar --exclude=vd --exclude=vd_updater` → tar de 13 MB en vez de 12 GB (verificado con el volumen real). Los `.tar` se nombran sin el prefijo de proyecto (`db_data.tar`, `wazuh_etc.tar`, …); los dos stacks no comparten nombres lógicos, así que no hay colisión. Verificado 2026-10-16: 30 `.tar`, 514 MB, ambos stacks healthy tras el arranque |
| UIs solo en **`127.0.0.1`** (2026-10-16) | Grafana (3000), Duplicati (8200), Mailpit (8025 panel + 1025 SMTP), Icinga Web (8080/8443) y Wazuh Dashboard (5601) pasan de `0.0.0.0` a `127.0.0.1`: son **paneles para el operador local**, no servicios de red; exponerlos a `0.0.0.0` los abría a toda la LAN sin necesidad. Siguen en `0.0.0.0` los puertos de **servicio**: 5665 (API de Icinga, la usa verify.ps1) y 1514/1515/55000 (Wazuh). verify.ps1 accede por `localhost` → sigue pasando. Si algún día se necesita la UI desde otro equipo, hay que quitar el `127.0.0.1` de ese puerto |
| Check **8c** de `verify.ps1` endurecido (2026-10-17) | El check contaba las líneas `Analyzing file` del `ossec.log` del agente, pero `logrotate` hace **copytruncate** a medianoche UTC (no deja ni `.1`) y se las lleva, aunque el logcollector siga trabajando → `0/13` y **falso FALLO** (salió al verificar el 2026-10-17 tras reiniciar Docker; la **sonda E2E ya probaba** que el logcollector funcionaba). Se comprobó que **SIGHUP NO re-emite** (`kill -HUP` al logcollector deja el conteo igual), pero **`wazuh-control reload` sí** (reinicia logcollector/syscheckd/modulesd/execd **sin tocar `agentd`** → el agente no se desconecta; 13→26). El check ahora fuerza ese reload y sondea el conteo (tope 25 s) antes de evaluar. Validado truncando el `ossec.log` a 0: el check se recupera solo |
| Stack nuevo #2 (`oracle-stack`): app + Oracle, **todo en contenedores** (2026-10-19) | Tercera pata del proyecto. Icinga la ve por `monitoring-net` (**sin publicar la BD**); la app sí publica su HTTP en `127.0.0.1:18081` (para verla en el navegador y para que `verify.ps1` la sondee con `curl.exe` — pasar código Python por `docker exec` se rompe con las comillas de PowerShell). Oracle se acota con `mem_limit: 2g` + `shm_size: 1g` porque la VM tiene ~7,7 GB y Wazuh ya reserva ~5,3 GB en límites. Su copia en Duplicati es **solo la declaración**: los datafiles de una BD **no** se copian en caliente (copia inconsistente); el volumen `oracle_data` lo vuelca `safety-net.ps1`, que **para los stacks** (copia en frío). `safety-net.ps1` pasa así a **3 stacks (31 volúmenes)** |
| El gotcha de `ORACLE_DATABASE` (documentado, 2026-10-19) | `ORACLE_DATABASE: FREEPDB1` **rompe** el arranque: el entrypoint ya crea `FREEPDB1` por defecto y, declarado, intenta una segunda creación que falla con `ORA-65012`; deja el flag `/opt/oracle/hc-pdb-create` → healthcheck **`3` (unhealthy) para siempre** y `APP_USER` **sin crear**. Síntoma: el PDB está en `READ WRITE` pero `select username from cdb_users where username='APP'` sale vacío (ojo: `dba_users` del root tampoco lo lista, es un usuario **local** del PDB). Se deja el default. Ver `oracle-stack/README.md` |
| `verify.ps1`: en clean-test los stacks ajenos entran como **objetos** pero se **excluyen del «todos en OK»** (2026-10-19) | Los `.conf` de Wazuh/Oracle se copian enteros en el clean-test (y deben: así se valida que parsean en `icinga2 daemon -C`), pero sus contenedores viven en `monitoring-net`, red que el clean-test **no comparte** → sus checks caen siempre y no es un fallo del stack que se prueba. Los recuentos suben a **11 hosts / 45 servicios** (iguales en los dos modos, porque los `.conf` se cargan en ambos) y, **solo en clean-test**, se filtran esos 5 hosts del «todos en OK». Además, sus checks **ni resuelven ni emiten *perfdata*** (no están en la red), así que esos hosts no pueden aparecer en InfluxDB: los 2 comprobadores de la variable `Host` de Grafana (que los busca en `hostalive`) son **también de producción** → la diferencia entre modos queda en **15 comprobadores** (81 en producción / 66 en clean-test) |
| Montar un fichero que aún no existe → Docker crea un **directorio** (2026-10-19) | Al montar `D:/docker/oracle-stack/README.md` en Duplicati **antes** de crear el fichero, Docker creó un **directorio** con ese nombre en el host; el montaje quedó «pegado» a un directorio y al escribir el fichero el contenedor ya no arrancaba (`not a directory`). Moraleja: **crear el fichero antes** de declarar su `volumes:`/`Sources`, o recrear el contenedor con `--force-recreate` (el `up -d` normal reutiliza el contenedor viejo y sigue fallando) |
| **Fase 4: Duplicati NO se saca (aún) a su propio compose** (2026-10-20) | El criterio escrito decía «2-3 stacks → sacar Duplicati a su propio compose», y con `oracle-stack` se cumplió (3). Se **pospone a propósito** porque el coste no compensa todavía: (1) el volumen `duplicati_config` guarda los **3 trabajos**; moverlo obliga a renombrar el volumen (o fijar su `name:` externo) y un error ahí se lleva por delante la única copia de la configuración de las copias; (2) sacar Duplicati de `icinga-stack` lo saca también del **clean-test**, y con él las **~20 comprobaciones** más valiosas del sistema (restauración con SHA256, retención, planificación, orígenes): mantenerlas exigiría levantar **dos composes** en la red aislada, más maquinaria que beneficio; (3) en **un solo host** la independencia de ciclo de vida no aporta nada operativo. Criterio para hacerlo: **cuando haya un segundo host** (ahí sí importa que las copias tengan vida propia y el clean-test se puede partir en dos) |
| `mk-clean-test.ps1` **sin listas a mano** (2026-10-19) | El clean-test llevaba tiempo **roto sin que nadie lo viera** (no se había vuelto a lanzar desde el endurecimiento de las UIs): (1) los puertos del compose son `"127.0.0.1:8200:8200"` pero el mapa buscaba `'"8200:8200"'` — **con comilla delante** — así que `.Replace` no casaba y **todos** los puertos quedaban iguales a producción (`up` moría con `Bind for 127.0.0.1:1025 failed`); (2) la lista de ficheros a copiar no incluía `influxdb/`, Docker creaba un directorio vacío en su lugar y el contenedor no arrancaba (`not a directory`). Peor: la guarda que debía avisar buscaba esas mismas cadenas ya obsoletas, así que era **ciega**. Arreglo doble: el mapa usa el **texto exacto** del compose y la guarda se **autovalida recorriendo su propio mapa**; y la lista de copia se **deriva de los montajes `./…` del compose** (con `throw` si un montaje no existe). Así no puede volver a quedarse desactualizado en silencio. Verificado 2026-10-19: clean-test levanta (12 contenedores) y `verify.ps1 -CleanTest` → **TOTAL FALLOS: 0** en **66 comprobadores** |

## Qué hay que ampliar cuando entre un stack nuevo

1. **`safety-net.ps1`** — la lista de volúmenes a volcar es del stack actual
2. **`verify.ps1`** — hosts, servicios y paneles mínimos esperados
3. **`docker-compose.yml` + `backup/*.json`** — si el proyecto gana ficheros
   de primer nivel, recuerda que el alta en Duplicati es idempotente: hacen
   falta el `volumes:` **y** el `Sources` **y** un `PUT /api/v1/backup/{id}`
   contra el servidor
4. **`mk-clean-test.ps1`** — la lista de ficheros que copia; si falta uno,
   Docker crea en su lugar un directorio vacío y los orígenes se rompen
5. **`icinga2-conf/conf.d/<stack>.conf`** — su línea de montaje (fichero a
   fichero) en el compose de `icinga-stack`, y validar con
   `icinga2 daemon -C` **antes** de recrear el contenedor. Los servicios del
   stack ajeno, en **clean-test**, hay que excluirlos del «todos en OK» (ver
   `verify.ps1`, sección 2): existen como objetos, pero sus contenedores no
   están en la red del clean-test
6. **OJO con montar ficheros que aún no existen**: al declarar el `volumes:` de
   Duplicati para un fichero de primer nivel, **créalo antes** — Docker crea en
   su lugar un **directorio** con ese nombre y el montaje se queda roto
   (`not a directory`); el `up -d` normal reutiliza el contenedor viejo, hace
   falta `--force-recreate`
