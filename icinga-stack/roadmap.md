# Roadmap

Plan de crecimiento del stack. Existe porque la primera versión del plan solo
vivía en la conversación: cuando llegó el momento de usarlo había que
reconstruirlo de memoria, que es exactamente lo que este proyecto se ahorra
en todo lo demás. Escrito, versionado y con remoto, ya no se pierde.

Cada fase tiene un **criterio de hecho**, que es lo único que la distingue de
«seguir tocando cosas hasta que se parezca». Y cada fase se activa cuando
hace falta, no antes: la tentación de adelantar trabajo que nadie ha pedido
es la forma más común de estancarse.

**Estado: Fases 1 y 2 completas.** La 3 (romper cosas a propósito para
calibrar umbrales y tiempos) es la siguiente; la 4 espera a que el crecimiento
la justifique.

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

## Fase 4 · Crecer

**Cuándo**: solo cuando el número de stacks o de nodos lo justifique.

- **2-3 stacks** → sacar Duplicati a su propio compose. Antes, no: un solo
  trabajo con varios JSON es más fácil de vigilar que dos servicios.
- **Swarm / Kubernetes** → solo cuando haya más de un host que mantener.
  Hoy una máquina con 11 contenedores no pide orquestación, pide que los
  backups funcionen.
- Ampliar `safety-net.ps1` a los volúmenes nuevos (hoy volca los 12 del stack
  de monitorización) y el plugin de copias a los stacks nuevos.
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

## Qué hay que ampliar cuando entre un stack nuevo

1. **`safety-net.ps1`** — la lista de volúmenes a volcar es del stack actual
2. **`verify.ps1`** — hosts, servicios y paneles mínimos esperados
3. **`docker-compose.yml` + `backup/*.json`** — si el proyecto gana ficheros
   de primer nivel, recuerda que el alta en Duplicati es idempotente: hacen
   falta el `volumes:` **y** el `Sources` **y** un `PUT /api/v1/backup/{id}`
   contra el servidor
4. **`mk-clean-test.ps1`** — la lista de ficheros que copia; si falta uno,
   Docker crea en su lugar un directorio vacío y los orígenes se rompen
