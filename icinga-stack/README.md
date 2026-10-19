# Icinga Stack

Monitorización completa de la propia infraestructura del stack, sobre
**Icinga 2 + Icinga Web 2**, todo contenedorizado en Docker Compose
(Docker Desktop / WSL2 en Windows 11).

```
                        ┌──────────────────────────────────────────┐
  notificaciones ──────►│ mailpit        SMTP 1025 / UI 8025       │◄── tú
                        └──────────────────────────────────────────┘
                                  ▲ msmtp (.msmtprc)
                                  │
 ┌────────────┐  API 5665  ┌──────┴──────┐   features    ┌───────────┐
 │ icinga-web │───────────►│   icinga2   │──────────────►│   MySQL   │
 │ Icinga Web │            │  (master)   │  ido-mysql    │  icinga2  │
 │    + Dir.  │◄───────────│             │  icingadb     └─────┬─────┘
 └─────┬──────┘            └──────┬──────┘                     │
       │ director-init            │ Redis                      │
       │ (one-shot)               ▼                            │
       │                    ┌────────────┐                     │
       └───────────────────►│  icingadb  │ (daemon: Redis ──►  │
            director DB     │  replicador│  MySQL `icingadb`)  │
                            └────────────┘                     │
                                          ┌────────────────────┘
                                          ▼
                                   MySQL `director`
```

El camino de las métricas (`icinga2 → influxdb → grafana`) está en la sección
**Gráficas**, más abajo.

| Contenedor        | Imagen                       | Rol                                                        |
|-------------------|------------------------------|------------------------------------------------------------|
| `mariadb`         | `mysql:8.0`                  | Servidor MySQL: `icinga2` (IDO + config Icinga Web), `icingadb`, `director` |
| `redis`           | `redis:7-alpine`             | Cache y transporte de Icinga DB                             |
| `icingadb`        | `icinga/icingadb`            | Daemon que copia Redis → MySQL `icingadb` (Icinga DB)       |
| `icinga2`         | `icinga/icinga2`             | Motor de monitorización (master, API 5665)                 |
| `icinga-web`      | `icinga-stack-web` (build)   | Icinga Web 2 + Director (HTTP 8080 / HTTPS 8443)           |
| `mailpit`         | `axllent/mailpit`            | SMTP de prueba: captura todas las notificaciones            |
| `influxdb`        | `influxdb:1.8`               | Base de series temporales: recibe el perfdata de cada check |
| `grafana`         | `grafana/grafana:11.2.0`     | Dashboards con las gráficas (HTTP 3000)                    |
| `director-init`   | `icinga-stack-web` (build)   | One-shot: esquema + kickstart + deploy del Director         |

## Puesta en marcha

```powershell
docker network create monitoring-net      # UNA sola vez (red transversal)
New-Item -ItemType Directory -Path C:\docker-backups -Force   # destino (otro disco)
docker compose up -d --build
docker compose logs -f director-init     # progreso del bootstrap del Director
```

> `monitoring-net` es **externa**: no la crea ni la borra compose, porque es
> un recurso compartido con cualquier otro stack que quieras monitorizar
> (una red compartida comparte vida con quien la usa, no con quien la
> declaró). Si falta, `up -d` avisa con claridad: *"declared as external, but
> could not be found"*. En el clean-test esa opción se quita, para que la
> copia tenga su propia red.

> `C:\docker-backups` es el **destino de las copias, el espejo del proyecto y
> la red de seguridad**, y está en `C:` por el mismo motivo por el que la red
> es externa: no depende de este stack ni comparte disco con los datos. Docker
> lo crearía solo si falta, pero declararlo explícito deja constancia de que
> es una decisión, no un accidente.

Enlaces:

| Qué                     | URL / dato                                   |
|-------------------------|----------------------------------------------|
| Icinga Web 2            | <http://localhost:8080/>                     |
| Icinga Web 2 (HTTPS)    | <https://localhost:8443/>                    |
| **Grafana** (gráficas)  | <http://localhost:3000/>                     |
| Mailpit                 | <http://localhost:8025/>                     |
| **Duplicati** (copias)  | <http://localhost:8200/>                     |
| API de Icinga 2         | <https://localhost:5665/v1>                  |
| **Web**                 | `admin` / `icingaadmin123`                   |
| **Grafana**             | `admin` / `icingaadmin123`                   |
| **Duplicati**           | `admin` / `icingaadmin123`                   |
| **API**                 | `icingaweb` / `icingaweb123`                 |
| **MySQL**               | `icinga` / `icinga_pass`                     |
| **MySQL root**          | `icinga_root`                                |

> La dirección de la web es **`/`**. Icinga Web 2 no soporta instalarse bajo
> un prefijo (deriva su URL base del nombre del script, así que
> `/icingaweb2/...` lo hace fallar el enrutador interno); no se añade ningún
> `Alias` y esa ruta responde 404.

## Qué monitoriza

La definición vive en `icinga2-conf/conf.d/stack-monitoring.conf` (los seis
hosts del propio stack), en `icinga2-conf/conf.d/wazuh.conf` (los tres del
stack ajeno de la Fase 2) y en `icinga2-conf/conf.d/oracle.conf` (los dos del
stack nuevo #2):

* **11 hosts**: `icinga2`, `icinga-web`, `icingadb`, `mariadb`, `redis`,
  `mailpit`; viniendo de otro proyecto, `wazuh-manager`, `wazuh-indexer` y
  `wazuh-dashboard`; y del stack nuevo #2, `oracle-db` y `oracle-app`
* **45 servicios**: ping/TCP de cada servicio, HTTP y HTTPS de la web
  (esperan 302, que es lo que devuelve el login), API de Icinga 2 (200 con
  auth), UI de Mailpit, conexión/uptime/uso de MySQL, disco, carga, procesos…,
  el **heartbeat de Icinga DB** (ver la sección propia), los **5
  `Backup - *`** descritos más abajo, los **8 de Wazuh**: API en 55000
  (espera 401, que es la respuesta sana), TCP 1514 y 1515, salud del clúster
  del indexer (200 **y** cuerpo `green`) y página de acceso del panel (302); y
  los **3 del stack nuevo #2**: listener de Oracle en 1521, HTTP de la app en
  8080 y **salud app+BD** (`/health`, que hace una consulta real).
* **10 hostgroups**: `stack-database`, `stack-cache`, `stack-monitoring`,
  `stack-web`, `stack-mail`, `stack-wazuh`, `stack-oracle`, `stack-all`…

Cualquier servicio en fallo dispara una notificación por correo a los
miembros de `icingaadmins`, que aterriza en Mailpit.

### Icinga DB: el daemon que no se puede sondear

`icingadb` es el único contenedor del stack **sin healthcheck**, y no es un
descuido: la imagen `icinga/icingadb` es *distroless* — no lleva `sh`, ni
`curl`, ni `wget`, y su binario solo ofrece `--version`, `-c` y
`--database-auto-import`. Tampoco publica ningún puerto (6666, 8080, 8086,
9090 y 9981, sondeados desde `monitoring-net`: los cinco cerrados). Un `ping`
era todo lo que lo vigilaba: alcanza para ver el contenedor caído, pero es
**ciego ante un daemon colgado**, justo el fallo que dejaría Icinga Web
sirviendo datos viejos con todo lo demás en verde.

Se mide desde fuera, por MySQL, con el comando stock `mysql_query`:

| Servicio | Mide | Aviso | Crítico |
|---|---|---|---|
| `Icinga DB - Heartbeat` | segundos desde la última latida en `icingadb_instance.heartbeat` | 180 s | 600 s |

Por qué ese campo y no otro. Medido sobre un stack sano durante 75 s,
`host_state.last_update`, `service_state.last_update` y
`state_history.event_time` **no se movieron ni un segundo**: solo avanzan con
un cambio de estado, no con cada check, así que se pondrían rojos en
cualquier media hora en blanco. El `heartbeat` sí late solo, cada ~70 s. Los
tres estados se probaron con el plugin antes de tocar la configuración
(`SELECT 250` → WARNING, `SELECT 5000` → CRITICAL).

Que sea Icinga DB quien escribe ese campo no es una suposición:
`information_schema.PROCESSLIST` muestra las seis conexiones con `db=icingadb`
saliendo todas de `172.19.0.2`, que es el contenedor, mientras que Icinga 2
solo tiene abierta una con `db=icinga2`. Si el daemon se cuelga, esas
conexiones siguen ahí pero dejan de ejecutar la escritura, y el latido
envejece.

Los umbrales van contra ese periodo real (un latido perdido de más no llega
a los 180 s) y contra los parámetros del stack: los servicios corren con 5
intentos y `retry_interval` de 30 s, así que hay **2,5 min de gracia antes de
que algo pase a HARD** — más de lo que Icinga DB tarda en latir tras un
arranque. Encender la PC después de una noche apagada se autocorrige sin
notificar.

### Las copias, vigiladas en continuo

Cinco servicios miden el estado de las copias; todos corren sobre el mismo
comando propio, `backup/check-backups.sh`, con un `--test` distinto:

| Servicio | Mide | Aviso | Crítico |
|---|---|---|---|
| `Backup - Last upload` | segundos desde el `duplicati-*.zip` más reciente del destino | 26 h | 50 h |
| `Backup - Free space` | GB libres en `C:\docker-backups` | < 20 GB | < 5 GB |
| `Backup - Project mirror` | segundos desde `project/.last-sync` | 45 min | 3 h |
| `Backup - MySQL dump` | segundos desde `staging/dump.sql` | 20 min | 45 min |
| `Backup - Scheduled run` | segundos desde la última vez que **disparó el programador** | 30 h | 36 h |

> **Por qué hay dos checks de «última copia» y no uno.**
> `Backup - Last upload` mide *«¿cuándo fue la última copia?»*, y eso se
> responde mirando el disco. Pero `verify.ps1` lanza una copia cada vez que
> se ejecuta, así que **ese check se queda en verde aunque el programador
> diario esté muerto**: solo estaría diciendo que alguien ha estado pulsando
> el botón. Lo que separa *«corrió a la hora»* de *«corrió porque se lo
> pidieron»* es `Schedule.LastRun`, y **solo lo escribe el programador**:
> una ejecución hecha por la API actualiza `Metadata.LastBackupStarted` y
> deja `Schedule.LastRun` intacto (comprobado, con 7 minutos de
> separación). Por eso `programada` no mira el disco, sino la API — que es
> además lo único que distingue una copia de otra.
>
> Los umbrales son 30 h / 36 h y no los 26 h / 50 h de `Last upload`,
> porque un trabajo sano dispara **cada 24 h**: cualquier valor por debajo
> de un día sonaría sobre un trabajo que solo está esperando su turno. Con
> este PC apagado a las 03:00 la ranura nunca llega a tiempo y Duplicati
> recupera la deuda al arrancar — eso es una ejecución normal; lo anormal
> es no ejecutar.

> **Por qué hay un plugin propio y no uno stock.** Los que trae la imagen
> (`check_file_age`, `check_disk`) responden sobre **un** fichero o sobre el
> sistema de ficheros; la pregunta de las copias es *«¿cuál es el fichero
> **más reciente** de esta carpeta?»*, y eso solo lo resuelve mirar el
> directorio. El script usa exclusivamente `find`, `stat`, `date`, `df`,
> `sort`, `tail` y `awk` con sintaxis POSIX, y se lanza con `/bin/sh` para no
> depender del bit de ejecución de un fichero montado desde Windows. La única
> excepción es `programada`, que necesita `curl` para hablar con la API de
> Duplicati — `curl` ya viene en la imagen, y no escribe nada en disco: el
> token vive solo en una variable.

> **Sin estos dos montajes nada de esto funciona**: `icinga2` recibe
> `C:/docker-backups:/backups:ro` y `backup_staging:/staging:ro`, ambos de
> **solo lectura**. Icinga mira, no toca. `programada` es la excepción: no
> monta nada, necesita en cambio `DUP_API`/`DUP_USER`/`DUP_PASSWORD`/`BACKUP_NAME`
> como variables de entorno del servicio, porque no mira ficheros.

Por qué importa cada uno: `Last upload` es el que convierte *«las copias se
pararon»* de algo que descubres durante el desastre en un correo a la mañana
siguiente (la programación corre a las 03:00, así que 26 h ya es una copia
perdida). `MySQL dump` es el más tramposo: si se rompe el bucle de
`mysql-dump`, Duplicati sigue copiando encantado el volcado viejo que
encuentra y nada falla en voz alta, mientras la copia «actual» deja de
contener datos actuales. `Scheduled run` es el que vigila **al vigilante**:
comprueba que la cosa que debería arrancar sola sigue arrancando, que es
exactamente lo que ningún otro check es capaz de ver porque todos miden
consecuencias, no intenciones.

La **red de seguridad** (`safety-net.ps1`) no es un servicio de Icinga: es
una herramienta del host que se refresca a mano y que una copia limpia no
tiene. La vigila `verify.ps1` en modo producción (3 comprobaciones), porque
acoplarla al clean-test la ligaría al estado de producción.

## Notificaciones por correo

Icinga 2 llama a `msmtp`, configurado por la variable `MSMTPRC` del
servicio `icinga2`. La cuenta **tiene que llamarse `default`**: `msmtp` se
invoca sin `--account` y las versiones ≥ 1.8 ya no hacen *fallback* a la
única cuenta del archivo.

Prueba de notificación (misma forma que usa `verify.ps1`; el JSON va en un
archivo porque PowerShell y las comillas anidadas no se llevan bien):

```powershell
$body = '{"service":"mariadb!ping4","type":"PROBLEM","severity":"CRITICAL","author":"prueba","comment":"prueba","text":"hola desde Icinga","force":true}'
[System.IO.File]::WriteAllText("$env:TEMP\n.json", $body)
curl.exe -sk -u icingaweb:icingaweb123 -H "Content-Type: application/json" `
  -X POST https://localhost:5665/v1/actions/send-custom-notification `
  --data-binary "@$env:TEMP\n.json"
```

El mensaje aparece en segundos en <http://localhost:8025>.

## Director

`director-init` ejecuta, de forma idempotente, cuatro pasos:

1. `director migration run` — crea el esquema (120 tablas).
2. `director kickstart run` — importa 1 endpoint, 3 zonas, 1 apiuser y
   **254 comandos de chequeo**. Es la parte lenta del arranque.
3. `director config deploy` — empuja la config generada a Icinga 2
   (**sin** `--wait`, que se agota aunque el *push* haya funcionado).
4. `director config deploymentstatus` — confirma que Icinga 2 **llegó a
   arrancar** con esa config. Sin este paso el Director se queda en
   *"The last Deployment … is still pending"* durante una hora.

Comprobación:

```powershell
docker exec icinga-web icingacli director health
# Icinga Director: everything is fine
```

Para cambiar configuración desde la UI: **Configuration → Borradores**,
aplicar los cambios y pulsar **Deploy**.

## Gráficas (InfluxDB + Grafana)

Icinga Web 2 no grafica por sí solo: para eso hace falta guardar las
métricas a lo largo del tiempo. Aquí lo hace la feature **`influxdb`**
(`InfluxdbWriter`), que en cada resultado de check envía el *performance
data* a InfluxDB 1.8, y **Grafana** que lo dibuja:

```
  cada check ──► Icinga 2 (InfluxdbWriter) ──HTTP 8086──► influxdb ──► grafana :3000
                                                  │                     panel por
                                     features-enabled/influxdb.conf     defecto
```

El dashboard **«Icinga Stack — métricas de los servicios»** (carpeta *Icinga*)
es la página de inicio de Grafana. Trae 25 paneles: carga por núcleo con los
umbrales 1,5/3,0, estado de hosts y servicios, RTT y pérdida de paquetes por
host, HTTP/TCP, disco, swap, procesos, latencia y duración de checks de
Icinga 2, tráfico del API y MySQL (consultas/s, conexiones, hilos), la edad
del último latido de **Icinga DB** (su fila propia, en `y=48`), más una fila
de **copias**: antigüedad de la última copia, frescura del volcado y del
espejo, espacio libre en el destino y última ejecución del programador. El
filtro **Host** del encabezado aplica a todos los paneles.

La fila de abajo del todo (ids 20-22, `y=56`) es la del **stack de Wazuh**:
respuesta HTTP de sus tres contenedores, tiempo de conexión a los puertos de
agentes (1514/1515) y ping de los tres. Van con filtro propio
`hostname =~ /wazuh/` y **no** con `$host`: son su panel y tienen que seguir
viéndose cuando el filtro Host esté puesto en otro stack.

Y una fila más (ids 23-25, `y=64`) es la del **stack nuevo #2**: respuesta HTTP
de `/health` (la que consulta la base), tiempo de conexión a 1521 y 8080 y ping
de sus dos contenedores. Mismo criterio: filtro propio
`hostname =~ /oracle/`, independiente del filtro Host.

### Esquema en InfluxDB (ojo, no es el evidente)

Cada punto de perfdata se guarda así:

| Parte | Contenido | Ejemplo |
|-------|-----------|---------|
| *measurement* | `check_command` del objeto | `load`, `disk`, `ping4`, `http`, `tcp`, `mysql`, `backup_health` |
| *tag* `hostname` | nombre del host | `icinga2` |
| *tag* `service` | nombre del servicio (no existe en los hosts) | `disk /` |
| *tag* `metric` | **nombre de la métrica** | `scaled_load1`, `rta`, `time` |
| *field* `value` | el número | `0.71` |
| *field* `unit` | unidad, si el plugin la indicó | `seconds`, `bytes`, `percent` |

Es decir: **el nombre de la métrica es una *tag*, no el nombre del *field***.
La tentación de escribir `SELECT mean("scaled_load1") FROM "load"` no
funciona; lo correcto es:

```sql
SELECT mean("value") FROM "load"
WHERE "metric" = 'scaled_load1' AND "hostname" =~ /^$host$/ AND $timeFilter
GROUP BY time($__interval) fill(null)
```

Las mediciones disponibles son `hostalive`, `ping4`, `ping6`, `load`, `disk`,
`swap`, `users`, `procs`, `http`, `tcp`, `mysql`, `mysql_query` e `icinga`
(esta última es la métrica interna del propio Icinga 2: `num_hosts_up`,
`num_services_critical`, `avg_latency`, `sum_bytes_sent_per_second`…).

Consulta rápida desde la línea de comandos:

```powershell
docker exec influxdb influx -database icinga2 -execute "SHOW MEASUREMENTS"
docker exec influxdb influx -database icinga2 -execute 'SELECT * FROM "load" ORDER BY time DESC LIMIT 5'
```

### Provisionado

Nada se configura a mano en la UI:

* `grafana/provisioning/datasources/influxdb.yml` — el datasource
  `icinga-influx` → `http://influxdb:8086`, base `icinga2` (sin autenticación:
  el contenedor **no publica puerto en el host**, solo se llega desde la red de
  compose).
* `grafana/provisioning/dashboards/dashboards.yml` — carga todo `*.json` de
  `grafana/dashboards/` y **lo relee cada 30 s**, así que editar un panel no
  obliga a reiniciar nada.

Un volumen nuevo de Grafana sale ya con el datasource y el dashboard listos.

### Añadir un panel nuevo

1. Copia un bloque `panels` de `grafana/dashboards/icinga-stack.json`.
2. Ajusta `title`, `gridPos` (cuadrícula de 24 columnas), `unit` y la query.
3. En ~30 s Grafana lo carga. Si no, `docker compose restart grafana`.

## Volúmenes

| Volumen                  | Contenido                                    |
|--------------------------|----------------------------------------------|
| `db_data`                | MySQL (datos, `mysql-init` solo en el 1.er arranque) |
| `icinga2_data`           | `/etc/icinga2` (certificados CA/nodo, zonas)  |
| `icinga2_lib`            | `/var/lib/icinga2` (estado, `.msmtprc`)      |
| `icinga2_cache`          | `/var/cache/icinga2`                         |
| `icinga2_spool`          | `/var/spool/icinga2` (comandos pendientes)   |
| `icinga_web_data`        | `/data` de Icinga Web + config del Director  |
| `redis_data`             | AOF de Redis                                 |
| `mailpit_data`           | Mensajes capturados (`MP_DATABASE`)          |
| `influxdb_data`          | Series temporales de las métricas            |
| `grafana_data`           | Base de Grafana (usuarios, preferencias)     |
| `backup_staging`         | `dump.sql` que produce `mysql-dump`          |
| `duplicati_config`       | Base SQLite de Duplicati (historial de copias) |

```powershell
docker compose down            # para, conserva los datos
docker compose down -v         # destruye TODO (el stack se rehace solo)
```

`icinga2_cache` y `icinga2_spool` no se respaldan: son cachés que Icinga 2
regenera. Tampoco el volumen anónimo que la imagen de `icinga2` crea en
`/data`, que solo contiene restos de la propia imagen y logs (`/etc/icinga2`
y `/var/lib/icinga2` son *symlinks* a `/data/...`, así que los volúmenes con
nombre de arriba ya están montados dentro).

## Copias de seguridad (Duplicati)

[<img src="https://img.shields.io/badge/Duplicati-2.4.0.0-blue">](https://duplicati.com)

**Duplicati** toma una copia diaria a las **03:00** (hora local del contenedor)
de los volúmenes del stack y de los ficheros del proyecto, con retención
`14D:0s,8W:7D,1Y:30D` (todas las de los últimos 14 días, luego una al día,
luego una a la semana) y **sin cifrado** (el destino es local y las
credenciales ya están en claro en `docker-compose.yml`).

| | |
|---|---|
| Interfaz | <http://localhost:8200/> (`admin` / `icingaadmin123`) |
| Destino | **`C:\docker-backups\icinga-stack\`** (otro disco físico) |
| Tamaño por versión | ~7,6 MiB comprimido a partir de ~123 MiB de origen |
| Config declarativa | `backup/icinga-stack-backup.json` |
| Alta automática | `backup/duplicati-bootstrap.sh` (contenedor `duplicati-init`) |

> **El destino está en `C:`, a propósito.** Los datos (el `docker_data.vhdx`
> con todos los volúmenes) viven en `E:` (SSD SATA) y el proyecto en `D:`;
> las copias tenían que ir a un **disco físico distinto**, o un fallo de
> disco se llevaría datos *y* copias a la vez:
>
> ```
> E: (SSD SATA 112 GB)  datos (docker_data.vhdx en E:\DockerDesktopWSL)
> D: (HDD 1 TB)         proyecto (este repositorio)
> C: (NVMe 256 GB)      destino de las copias + espejo del proyecto + red de seguridad
> ```
>
> El VHDX se movió de D: (HDD, cuello de botella: iowait 53%) a E: (SSD);
> ver `roadmap.md` (decisión de almacenamiento).
>
> `mk-clean-test.ps1` reescribe esa ruta a `./backups` en su copia, para que
> el clean-test escriba dentro de `_clean-test/` y nunca en el destino real.
> La ruta se declara en `docker-compose.yml` (servicio `duplicati`), no en un
> fichero aparte, para que se vea de un vistazo.

### Por qué hay un contenedor `mysql-dump`

Duplicati es una herramienta **a nivel de ficheros**: lee rutas y las guarda.
Hacer una copia del datadir de MySQL (`/var/lib/mysql`) con el servidor
encendido produce algo **inconsistente** que falla al restaurarse, porque
InnoDB tiene páginas a medias entre el redo log y los ficheros de datos.

La forma correcta de copiar una base en caliente es
`mysqldump --single-transaction`, que abre una transacción `REPEATABLE READ`
y vuelca un snapshot consistente sin bloquear nada. Por eso `mysql-dump`
(misma imagen `mysql:8.0`, ya presente) vuelca `/all-databases` a
`backup_staging/dump.sql` **cada 10 minutos**, y Duplicati respalda ese
fichero en lugar de `db_data`:

```
mysqldump ──► backup_staging/dump.sql ──► Duplicati ──► C:\docker-backups\
(mariadb)         (cada 10 min)          (03:00)        (disco distinto)
```

Dos detalles que no son decorativos:

- El volcado se escribe a `.dump.sql.tmp` y se renombra con `mv`
  (**atómico**), así que Duplicati nunca lee un fichero a medias.
- El healthcheck lo marca `unhealthy` si el volcado tiene **más de 15 min**:
  si el bucle se rompe, la copia de MySQL dejaría de estar fresca y habría
  que avisarlo, no taparlo.

Nadie para `mariadb`, `redis`, `icinga2` ni `icinga-web` durante la copia:
pararlos dispararía alertas `CRITICAL` falsas a las 3 de la mañana.

### Origen y destino

| Origen (dentro de Duplicati) | Volumen / fichero real | Por qué |
|---|---|---|
| `/sources/volumes/mysql-dump` | `backup_staging` | el volcado consistente |
| `/sources/volumes/icinga2-etc` | `icinga2_data` | certificados CA/nodo, zonas |
| `/sources/volumes/icinga2-lib` | `icinga2_lib` | estado, `.msmtprc` |
| `/sources/volumes/icinga-web` | `icinga_web_data` | config de Icinga Web + Director |
| `/sources/volumes/redis` | `redis_data` | AOF de Redis |
| `/sources/volumes/influxdb` | `influxdb_data` | histórico de métricas |
| `/sources/volumes/grafana` | `grafana_data` | usuarios y preferencias |
| `/sources/volumes/mailpit` | `mailpit_data` | mensajes capturados |
| `/sources/project/…` | `backup/`, `docker-compose.yml`, `grafana/`, `icinga2-conf/`, `mysql-init/`, `web/`, `README.md`, `safety-net.ps1`, `verify.ps1`, `mk-clean-test.ps1` | el propio proyecto |
| ~~`db_data`~~ | **no está** | se respalda el volcado, no el datadir |
| ~~`icinga2_cache` / `icinga2_spool`~~ | **no están** | cachés regenerables |

> Se monta **entrada por entrada** y no el directorio `./` entero. El destino
> ya no está dentro de `./` (se fue a `C:`), pero la regla se mantiene porque
> así es imposible **por construcción** que una copia se respalde a sí misma,
> sin depender de dónde esté el destino hoy, y porque los origenes tienen que
> coincidir con los `Sources` de `backup/icinga-stack-backup.json`. Si añades
> un fichero o carpeta nueva al proyecto, apúntala en el `volumes:` de
> `duplicati` **y** en `Sources` del JSON (`tmp/` y `_clean-test/` no).

### Probar que funciona de verdad

`verify.ps1` hace **36 comprobaciones de copias** (81 en total), incluida una
**restauración** que compara el SHA256 de `README.md` y de `safety-net.ps1`
recuperados con el original, **otra restauración de la copia de Wazuh** que
hace lo mismo con su `docker-compose.yml` y su `wazuh.yml`, más el espejo del
proyecto y la red de seguridad:

```powershell
.\verify.ps1            # 81 checks, TOTAL FALLOS: 0
```

A mano:

```powershell
docker compose logs -f mysql-dump      # volcado cada 10 min
docker compose logs -f duplicati-init  # alta de la copia (idempotente)
docker compose logs -f project-mirror  # espejo del proyecto cada 10 min
docker compose up -d                   # duplicati-init sale en seguida
```

Desde la propia web (<http://localhost:8200/>) se puede **"Run now"**,
inspeccionar el historial y probar la restauración con
*Restore → Direct restore from backup*.

> `verify.ps1` dispara **una copia a mano** (línea con `.../run`) antes de
> comprobarla: por eso cada ejecución añade ~3 ficheros al destino. Es
> intencionado, no una fuga.

> El planificador de Duplicati solo dispara si el contenedor está levantado a
> las 03:00; si el equipo estuvo apagado, lanza **"Run now"** a mano.

### Recuperar desde cero (probado, no teórico)

> Este procedimiento se ejecutó de verdad sobre producción el 4-oct-2026:
> `docker compose down -v`, levantamiento limpio y restauración completa.
> Resultado: **`verify.ps1` → TOTAL FALLOS: 0**. (El recuento de checks
> crece con el tiempo — eran 44 en esa primera ejecución; hoy son 81.)

**Qué borra y qué sobrevive** a un `docker compose down -v`:

| | ¿Sobrevive? |
|---|---|
| Volúmenes (datos, catálogo de Duplicati) | ❌ se borran |
| Contenedores | ❌ |
| Red `monitoring-net` | ✅ es externa |
| `C:\docker-backups\` (copias, espejo, red de seguridad) | ✅ otro disco |
| `D:\docker\icinga-stack\` (proyecto) | ✅ no es volumen |

**Procedimiento:**

```powershell
docker compose down -v
docker compose up -d
# espera a que director-init y duplicati-init terminen (~10 min)
.\verify.ps1
```

**Lo que se recuperó, y de dónde:**

| Qué | Origen | Resultado |
|---|---|---|
| Hosts, servicios, Director, Icinga Web | *se reconstruyen solos* | 9 hosts / 40 servicios sin restaurar nada |
| `README.md` (y todo el proyecto) | Duplicati | SHA256 idéntico al original |
| Histórico de métricas | Duplicati → `influxdb_data` | 21 ficheros; `ping4` 51 → **2050** puntos |
| Histórico de MySQL | Duplicati → `dump.sql` | notificaciones 0 → **58**, grants intactos |
| Catálogo de Duplicati | red de seguridad → `duplicati_config` | 36 ficheros reconocidos |

**Tres cosas que solo se aprenden haciéndolo:**

1. **La restauración funciona sin base de datos local de Duplicati**, pero
   solo con **rutas de fichero exactas**. Pasar un *directorio*
   (`/sources/volumes/influxdb`) devuelve `200 OK` y **no restaura nada**;
   hay que enumerar los ficheros (por ejemplo con `tar -tf` sobre el
   `.tar` de la red de seguridad) y pasarlos uno a uno.

2. **Duplicati se niega a hacer copias con ficheros desconocidos en el
   destino** y no los borra:

   ```
   RemoteListVerificationException: Found 33 remote files that are not
   recorded in local storage ... you can use repair to delete the unknown files
   ```

   Es el comportamiento correcto: prefiere fallar en ruido antes que borrar
   tu única copia. Dos salidas:
   - **Restaurar `duplicati_config` desde la red de seguridad** → el
     catálogo vuelve a reconocer los `.zip` y las copias siguen con todo el
     historial. **Es lo que hay que hacer**, siempre que el catálogo esté
     fresco (ver *`safety-net.ps1`* abajo: `-SoloCatalogo` lo mantiene
     cuadrado). Si está atrasado, reconoce los que conocía y se queja solo
     de los demás.
   - `repair` en la web → **borra** los ficheros desconocidos. Solo si no
     tienes la red de seguridad y ya has restaurado lo que necesitabas.

3. **El volcado de MySQL incluye la base de sistema `mysql`** (con
   `CREATE DATABASE` y `DROP TABLE` sobre `mysql.user` y `mysql.db`).
   Se importa con los consumidores parados y los usuarios salen intactos —
   pero es la parte con más riesgo del procedimiento, y por eso
   `db_data.tar` de la red de seguridad existe.

**Importar el volcado** (PowerShell no soporta `<`, y `docker cp` no copia
entre contenedores; se pasa por el host):

```powershell
docker cp icinga-duplicati:/tmp/rtest/dump.sql $env:TEMP\dr-dump.sql
docker compose stop icinga2 icingadb icinga-web
docker cp $env:TEMP\dr-dump.sql icinga-db:/tmp/dump.sql
docker exec icinga-db sh -c "mysql -uroot -picinga_root < /tmp/dump.sql"
docker compose start icinga2 icingadb icinga-web
```

### `safety-net.ps1`: la red de seguridad

Copia los 31 volúmenes (los **tres** stacks) como **`.tar` crudos** (se
restauran con cualquier `tar -xf`, sin Duplicati) y el catálogo de Duplicati,
que es lo que permite retomar las copias sin borrar el historial:

```powershell
.\safety-net.ps1
# C:\docker-backups\safety-net\  ->  31 .tar  (~3,5 GB)
```

> El grueso es **`oracle_data`** (~3 GB, los datafiles de la base). El resto de
> volúmenes (configuración y datos pequeños, sin los feeds CVE regenerables de
> `wazuh_queue`) suma ~0,5 GB. Ver `Volume-TarArgs` en el script.

Para el el stack 2-3 minutos. Ejecútala **antes de cualquier operación
destructiva**.

```powershell
.\safety-net.ps1 -SoloCatalogo    # ~15 s, solo para Duplicati
```

**El catálogo (`duplicati_config`) es el único `.tar` que envejece**: cada
copia nueva añade ficheros al destino, y si el catálogo guardado aquí no los
conoce, al restaurarlo Duplicati se quejará de *unknown files*. Con
`-SoloCatalogo` refrescarlo no cuesta nada (15 s, sin parar el stack): hazlo
tras cada `verify.ps1` (que lanza copias) o, como mínimo, con la misma
frecuencia que los cambios importantes del stack.

`verify.ps1` lo vigila en modo producción con 3 comprobaciones: que el
destino de copias se lea del `compose`, que haya al menos 31 `.tar` (los
volúmenes de los tres stacks) y que `duplicati_config.tar` tenga menos de 7
días. Si alguna sale en FAIL, la vuelta es `.\safety-net.ps1 -SoloCatalogo` y
volver a lanzar `verify`.
No está en el clean-test a propósito: `safety-net.ps1` es una herramienta
del host y una copia limpia no la tiene.

No es un sustituto de Duplicati (que es la copia diaria programada), es la
herramienta que permite *ensayar* una restauración sin miedo a no tener
vuelta atrás.

El propio `safety-net.ps1` **es origen de la copia de Duplicati**: además de
vivir en git y en el espejo, se restaura desde el fileset. Ojo con el precio
de añadirlo: el fichero de origen se monta **entrada por entrada** en
`docker-compose.yml`, así que hacen falta las dos mitades — el `volumes:` de
`duplicati` **y** el `Sources` de `backup/icinga-stack-backup.json` — y, como
el alta en Duplicati es idempotente, aplicar el cambio en el servidor a mano:

```powershell
# 1. la fuente en el servidor (Duplicati solo acepta GET/POST en /backups,
#    pero /api/v1/backup/1 si admite PUT; el JSON se edita y se reenvia)
#    -> y en el contenedor, el bind mount de docker-compose.yml
docker compose up -d duplicati
# 2. una copia real para que el fichero entre en el fileset
# 3. safety-net.ps1 -SoloCatalogo  (el catálogo refleja la config nueva)
```

## Primer arranque

Un arranque desde cero (`docker compose down -v` seguido de) :

```powershell
docker compose down -v
docker compose up -d --build
```

tarda en esta máquina (Windows 11, 4 núcleos, WSL2) aproximadamente:

| Fase | Tiempo |
|------|--------|
| `mysqld --initialize` (crea el data directory) | 3 min 38 s |
| Carga de `mysql-init/` (bases + esquema IDO de 67 tablas) | 4 min 53 s |
| Apagado del servidor temporal + arranque con red | 1 min 20 s |
| **MySQL → `healthy`** | **10 min 17 s** |
| Icinga Web (esquema) + Icinga 2 (PKI + node setup) | ~1 min |
| `director-init` (migración + **254 comandos** + deploy + confirmación) | **6 min 38 s** |
| **Total `up -d` → stack completamente operativo** | **~18 min** |

Las cifras de arriba **no son las que da MySQL por defecto**. Antes de
ajustarlo, el mismo arranque desde cero medía **34,5 min**:

| | Stock | Este stack |
|---|---|---|
| `--initialize` | 4–8,5 min | 3 min 38 s |
| Esquema IDO | 7,5 min | 4 min 53 s |
| MySQL → healthy | 12,5 min | 10 min 17 s |
| `director-init` (kickstart) | 21 min | 6 min 38 s |
| **Total** | **34,5 min** | **~18 min** |

### Por qué el servicio `mariadb` lleva `command:`

Medido en este equipo: `fsync()` cuesta **~440 ms** en vez de los <1 ms de
costumbre, porque la ext4 de la VM WSL2 está encima de NTFS. MySQL hace dos
*fsync* por transacción (redo log + binlog), es decir **441 ms por COMMIT**,
y todo lo que escribe fila a fila se vuelve inutilizable. El benchmark del
propio servidor (`INSERT` en bucle con autocommit) da:

```
stock (flush=1, sync_binlog=1):   441 ms/commit
ajustado (flush=2, sync=0):         8 ms/commit   <- 55x
```

`--innodb-flush-log-at-trx-commit=2` escribe el redo log en la caché del
sistema en cada COMMIT y lo vacía una vez por segundo: ante un **corte
duro** se pierde como mucho el último segundo de datos. Un
`docker compose down` es una parada limpia y no pierde nada.

Se pasa como argumentos de línea de comandos y no como `.cnf` porque el
*entrypoint* de la imagen reenvía `"$@"` tanto a `--initialize-insecure`
como al servidor temporal de importación y al servidor final: el ajuste ya
está activo mientras se construye el volumen nuevo.

### Por qué el healthcheck de MySQL es TCP y `start_period: 1800s`

En un volumen nuevo MySQL arranca primero un servidor **temporal con
`--skip-networking`** (`port: 0`) para ejecutar `mysql-init/`:

* `mysqladmin ping -h localhost` usa el socket, responde *"vivo"* durante
  esa fase y sale con **0**. Compose marcaría MySQL como `healthy` antes de
  que exista el puerto 3306, arrancaría `icinga-web`, y éste se quedaría en
  bucle con `SQLSTATE[HY000] [2002] Connection refused` hasta que el
  `docker compose up` aborte con *"dependency failed to start"*. Por eso el
  check usa `-h 127.0.0.1 -P 3306`.
* El *data directory* tarda ~10 minutos en estar listo, de modo que
  `start_period` tiene que ser mayor que eso (**1800 s**). Un fallo dentro
  de `start_period` deja el estado en `starting` y no en `unhealthy`, así
  que `depends_on: service_healthy` sigue esperando. **No retrasa un arranque
  bueno**: el primer chequeo con éxito marca `healthy` al instante, aunque
  esté dentro del periodo.

### Por qué `director-init` tiene cuatro pasos y no tres

El paso 4 existe porque desplegar la configuración **no** deja constancia de
que Icinga 2 llegó a arrancar con ella: `stage_collected` y
`startup_succeeded` siguen en `NULL` hasta que algo llama a
`ConditionalDeployment::refresh()` o a `config deploymentstatus`. Sólo lo
hacen un **segundo** `config deploy`, la página de despliegues del Director
o su demonio. Un proceso de un solo disparo que despliega exactamente una
vez dejaba el stack en *"[WARNING] The last Deployment … is still pending"*
durante una hora entera.

### Por qué la carga usa umbrales por núcleo

Los valores por defecto de la ITL son **absolutos** (`-w 5,4,3 -c 10,6,4`),
así que `load15 > 4` es CRITICAL: en este host de 4 núcleos equivale a una
media de apenas una tarea ejecutable por núcleo. El check llegó a estar en
CRITICAL con el CPU al 13 %. Con `load_percpu` el plugin divide por el número
de núcleos, de modo que los umbrales de `hosts.conf` se leen **por núcleo**
(1,5 de aviso / 3,0 crítico). Se comprueba en la perfdata del servicio:
`scaled_load15=0.983;1.500;3.000;0;`.

## Verificación

`verify.ps1` comprueba todo de una pasada y devuelve el número de fallos
(login con credenciales reales, 11 hosts / 45 servicios en OK — incluidos los
cinco `Backup - *`, los ocho de Wazuh y los tres del stack nuevo #2 —, los
cuatro test del Director, dos notificaciones que tienen que acabar en Mailpit
— una de `mariadb` y otra de un servicio de Wazuh —, que InfluxDB esté
recibiendo métricas y Grafana tenga el datasource, el dashboard y los seis
paneles de los stacks ajenos (tres de Wazuh, tres de Oracle) provisionados, y
**36 comprobaciones de copias de seguridad** — volcado, alta declarativa,
historial de Duplicati, lanzar una copia real, restaurar tres ficheros para
compararlos, restaurar la copia de Wazuh y comparar los suyos, el espejo del
proyecto y la red de seguridad):

```powershell
powershell -ExecutionPolicy Bypass -File .\verify.ps1              # 81 checks
powershell -ExecutionPolicy Bypass -File .\verify.ps1 -CleanTest   # 68 checks
# ===== TOTAL FALLOS: 0 =====
```

> La diferencia de 13 son los comprobadores que **solo corren en producción**:
> los 3 de **`safety-net`** (es una herramienta del host, y una copia limpia no
> la tiene), los 5 de **Wazuh** y los 5 de la **app + Oracle** (son stacks
> aparte y `mk-clean-test` no los clona). Además, en clean-test los hosts de
> esos dos stacks existen como **objetos** (sus `.conf` se copian, y deben
> parsear) pero sus contenedores no están en la red del clean-test, así que
> aparecen siempre caídos: `verify.ps1` los **excluye del «todos en OK»** —sin
> dejar de comprobar que su configuración se carga— solo en ese modo.

> **Tras un reinicio del stack** los checks que se apoyan en `Uptime`
> necesitan más de 60 s de vida del contenedor **y** un ciclo de chequeo
> posterior antes de volver a OK — Icinga devuelve WARNING mientras tanto
> aunque todo esté bien. `verify.ps1` espera hasta 3 minutos a que los
> servicios se asienten antes de comprobarlos, así que no hace falta dormir
> el script a mano después de un `docker compose up -d`.

`.\verify.ps1` a secas puede fallar con *"la ejecución de scripts está
deshabilitada"*: es la política de ejecución de PowerShell, no el stack.

### Desde cero sin tocar producción

`mk-clean-test.ps1` copia el stack a `_clean-test/` con prefijo `ct-` en los
contenedores, tag de imagen propio y puertos
18080/18443/15665/18025/11025/13000/18200, de modo que puede levantarse en
paralelo y con volúmenes vacíos. También **reescribe el destino**
(`C:/docker-backups` → `./backups`) y la red externa, y luego **comprueba el
resultado**: si un rewrite fallara, el clean-test estaría escribiendo en el
destino real de producción. Es la comprobación de que el stack se rehace
solo después de `down -v`:

```powershell
.\mk-clean-test.ps1
docker compose -p clean-test -f .\_clean-test\docker-compose.yml up -d --build
docker compose -p clean-test -f .\_clean-test\docker-compose.yml logs -f director-init
.\verify.ps1 -CleanTest
docker compose -p clean-test -f .\_clean-test\docker-compose.yml down -v
Remove-Item -Recurse -Force .\_clean-test
```

> **Ese orden es obligatorio, no una sugerencia.** `mk-clean-test.ps1` borra
> y vuelve a crear `_clean-test/` entero. Si la copia ya está corriendo,
> sus montajes (`./backups`, `/src`) quedan apuntando a un directorio que ya
> no existe: los contenedores siguen en `healthy` porque el healthcheck mira
> **dentro** del contenedor, pero el host ya no ve nada. Síntoma típico:
> `Backup - Project mirror` en CRITICAL con *the file to measure is missing*
> mientras `docker logs ct-icinga-project-mirror` dice que ha sincronizado
> hace un minuto. Solo hay remedio: `down -v`, borrar `_clean-test/` y
> repetir el ciclo desde `mk`.
>
> Del mismo modo, **nunca se ejecuta `mk` mientras haya contenedores `ct-*`
> vivos**. Comprobarlo antes de empezar:
>
> ```powershell
> docker ps -a --filter "name=ct-" --format "{{.Names}}"   # tiene que salir vacío
> ```

## Añadir otro stack (monitoreo + copias)

Esta plataforma es **transversal**: el stack de monitorización y la capa de
copias son servicios que usan los demás proyectos, no al revés. Por eso la
red es externa y `duplicati-init` recorre todos los JSON que encuentra en
`backup/`: **conectar un proyecto nuevo no exige tocar nada de este stack**.

### 1. Monitoreo

En el `docker-compose.yml` del otro proyecto:

```yaml
services:
  mi-app:
    image: ...
    networks: [monitoring-net]

networks:
  monitoring-net:
    external: true
    name: monitoring-net
```

Con eso Icinga 2 ve sus contenedores **por nombre** desde dentro, igual que
hoy ve `mariadb` o `redis`. Si en vez de unirte a la red solo quieres mirar
un servicio que **publica puerto en el host**, usa
`address = "host.docker.internal"` y ese puerto (Docker Desktop lo resuelve;
en Linux no, y ahí conviene la red compartida).

Después se da de alta el host. Dos caminos, y conviven:

| Cómo | Dónde queda | Cuándo conviene |
|---|---|---|
| **Director** (interfaz) | base `director`, incluida en el volcado | alta rápida, sin tocar ficheros |
| **Fichero `.conf`** | `icinga2-conf/conf.d/` **+ su montaje en el compose** | infraestructura que debe reconstruirse desde cero |

Ojo con la segunda fila: los ficheros de `conf.d` se montan **uno a uno**, así
que un `.conf` nuevo necesita su línea en el `volumes:` de `icinga2`.

Ejemplo, con el patrón que ya usan `stack-monitoring.conf`:

```ruby
object Host "mi-app-web" {
  import "generic-host"
  display_name = "Mi App - Web"
  address = "mi-app_web"              # resuelve en monitoring-net
  vars.stack_role = "mi-app"
  vars.notification["mail"] = { groups = [ "icingaadmins" ] }
}

apply Service "Mi App - HTTP" {
  import "generic-service"
  check_command = "http"
  vars.http_uri = "/"
  vars.http_port = 80
  vars.http_expect = "200"
  assign where host.name == "mi-app-web"
}
```

En cuanto el host existe, **las alertas por correo llegan solas** (el grupo
`icingaadmins` ya está configurado) y las métricas del check van a InfluxDB.
Lo único manual es añadir los paneles nuevos al dashboard de Grafana.

Esto no es teórico: se ha aplicado **dos veces** y el resultado está versionado.
La Fase 2, al stack de Wazuh (`icinga2-conf/conf.d/wazuh.conf`: tres hosts y
cinco servicios, con `address` apuntando a `wazuh.manager` / `wazuh.indexer` /
`wazuh.dashboard`, que son los nombres que llevan sus certificados TLS), en los
paneles 20-22. Y después, al **stack nuevo #2**, una app + Oracle
(`icinga2-conf/conf.d/oracle.conf`: dos hosts y tres servicios, con `address`
por nombre de servicio, `oracle-db` y `oracle-app`), en los paneles 23-25. En
los dos casos, lo que importa no es «¿responde el puerto?» sino «¿responde la
aplicación **usando su base de datos**?»: la sonda HTTP pega en un endpoint que
consulta la BD de verdad.

`verify.ps1` no se entera: comprueba `>= 11 hosts` y `>= 45 servicios`, o sea
**mínimos**, no valores exactos. Además mira **por nombre** los tres hosts y
los cinco servicios de Wazuh (y los dos hosts y tres servicios de Oracle),
porque solo con el recuento bastaría con que desapareciera uno y entrara otro
distinto.

### 2. Copias

Cada copia se declara en un JSON dentro de `backup/`, con la misma forma que
`icinga-stack-backup.json`:

```json
{
  "Backup": {
    "Name": "mi-app",
    "TargetURL": "file:///dest/mi-app",
    "Sources": [ "/sources/otros/mi-app" ],
    "Settings": [
      { "Name": "--no-encryption", "Value": "true" },
      { "Name": "retention-policy", "Value": "14D:0s,8W:7D,1Y:30D" }
    ]
  },
  "Schedule": {
    "Time": "2026-10-05T04:00:00",
    "Repeat": "1D",
    "AllowedDays": ["mon","tue","wed","thu","fri","sat","sun"]
  }
}
```

Y la ruta que hay que respaldar se monta en el servicio `duplicati`
(**entrada por entrada**, no el directorio entero): así el JSON y el compose
dicen exactamente lo mismo, y arrastras solo lo que quieres respaldar en vez
de `tmp/`, `.git` y lo que haya:

```yaml
      - D:/docker/mi-app/data:/sources/otros/mi-app:ro
```

Ojo: el **destino** de esas copias tiene que ir en un **disco físico distinto**
al de los datos del stack nuevo. Si lo dejas en el mismo sitio, la copia
protege contra borrados y corrupción, pero no contra un fallo de disco.

Después:

```powershell
docker compose up -d duplicati-init
docker compose logs duplicati-init
```

`duplicati-init` recorre **todos** los `backup/*.json`, crea los que falten y
no toca los que ya existen. Y `verify.ps1` añade un chequeo de que **todos**
los JSON declarados aparecen dados de alta en el servidor.

Cada copia tiene su horario y su retención propios, así que una que falle o
que crezca mucho no arrastra a las demás.

### 3. Ojo con las bases de datos

> **Nunca se copia un datadir de MySQL en caliente.** Sale una copia
> inconsistente que falla al restaurarse. El patrón es el de
> `backup/mysql-dump.sh`: un sidecar que vuelca cada 10 minutos con
> `--single-transaction` y sustituye el fichero con `mv` atómico, y lo que se
> respalda es **el volcado**, no el volumen. Si el stack nuevo tiene una base
> de datos, se replica ese sidecar.

> **Con Oracle** (stack nuevo #2) no hay `mysqldump`, así que el patrón se
> invierte: en Duplicati se respalda **solo la declaración** (compose y app),
> y los datafiles (`oracle_data`, ~3 GB) van **en frío**, en
> `safety-net.ps1`, que para los tres stacks antes de copiar. Copiar un
> datafile en caliente es el mismo error que copiar un datadir de MySQL en
> caliente: la copia no sirve para restaurar.

### 4. Qué pasa cuando esto crezca

Con uno o dos stacks extra, lo de arriba basta. Cuando ya sean varios,
conviene **sacar Duplicati de este stack** a su propio compose. Hoy el
destino ya está en `C:` (otro disco), así que el riesgo que queda no es de
datos sino de **disponibilidad**: mientras el stack de monitorización esté
parado, las copias de los demás stacks no corren. Es una migración barata de
hacer pronto y cara de hacer tarde — y nada de lo anterior se rehace: se
mueve el servicio y se reapuntan los mismos JSON.

Misma idea para `safety-net.ps1` y `project-mirror`: hoy cuelcan de este
stack y de `C:\docker-backups`. Con varios proyectos conviene mover el
destino a algo compartido (NAS, disco externo) y dejar aquí solo lo que es
propiamente de este stack.

> Ese plan, con sus fases 2-4 y su criterio de hecho, está escrito en
> [`roadmap.md`](roadmap.md) — no en la conversación, que es donde se
> perdía.

## Estructura

```
docker-compose.yml                 11 servicios + los 2 one-shot
                                    (director-init, duplicati-init)
                                    red externa `monitoring-net`
README.md                          este archivo
roadmap.md                         fases 2-4: cuando toque crecer, con que
                                    criterio de hecho y que hay que ampliar
verify.ps1                         comprobacion end-to-end
mk-clean-test.ps1                  genera el proyecto aislado _clean-test/
safety-net.ps1                     volcado plano de los 31 volumenes de los
                                   tres stacks a .tar
.gitattributes                     finales de linea: LF en .sh/.conf/.yml/
                                   Dockerfile, CRLF en .ps1 (ver "Repositorio
                                   git": autocrlf=true los romperia). Hay una
                                   copia en la raiz del monorepo, que cubre
                                   tambien wazuh-stack/ y oracle-stack/
.gitignore                         lo que no se versiona: _clean-test/, tmp/,
                                   backups/ y los artefactos de herramientas

backup/                            copias de seguridad (Duplicati)
  mysql-dump.sh                    bucle de mysqldump -> backup_staging
  duplicati-bootstrap.sh           alta de TODOS los *.json via API REST
                                   (y primera copia si el destino esta vacio)
  project-mirror.sh                espejo en plano del proyecto, cada 10 min
  check-backups.sh                 plugin propio de Icinga: los 5 servicios
                                   "Backup - *" (ver "Las copias, vigiladas
                                   en continuo")
  icinga-stack-backup.json         la copia de este stack (fuentes, retencion, plan)
  wazuh-stack-backup.json          la copia del stack de Wazuh (Fase 2): su compose,
                                   sus certificados TLS y su configuracion
  oracle-stack-backup.json         la copia del stack nuevo #2: SOLO la declaracion
                                   (compose y app); los datafiles van en la red de
                                   seguridad, en frio (ver "Copias de seguridad")

C:\docker-backups\                 DESTINO (OTRO DISCO FISICO, en C:)
  icinga-stack/                    dlist / dblock / dindex .zip  (Duplicati)
  wazuh-stack/                     lo mismo para el stack de Wazuh (Fase 2)
  oracle-stack/                    lo mismo para el stack nuevo #2 (app + Oracle)
  project/                         espejo legible del proyecto (project-mirror)
  safety-net/                      31 .tar crudos + el catalogo de Duplicati.
                                   Los volumenes de los TRES stacks (el de
                                   Wazuh incluye sus certificados y su cola;
                                   el de Oracle, sus datafiles)

mysql-init/                        solo en el primer arranque de un volumen
  00-mysql-settings.sql            log_bin_trust_function_creators
  01-databases.sql                 icingadb + director + grants
  03-ido-schema.sql                esquema IDO (67 tablas)

icinga2-conf/                      montado en /etc/icinga2 (read-only)
  conf.d/hosts.conf                objeto Host NodeName + umbrales de carga
  conf.d/api-users.conf            ApiUser `icingaweb` con permisos "*"
  conf.d/stack-monitoring.conf     los 6 hosts y 32 servicios del propio stack,
                                   10 hostgroups (stack-all ya incluye los
                                   roles wazuh y oracle)
  conf.d/wazuh.conf                Fase 2: los 3 hosts y 5 servicios del stack
                                   de Wazuh + hostgroup stack-wazuh. Montado
                                   con su propia linea en el compose: conf.d
                                   se monta fichero a fichero, un .conf nuevo
                                   sin montaje no aparece en el contenedor.
  conf.d/oracle.conf               stack nuevo #2: los 2 hosts y 3 servicios de
                                   la app + Oracle + hostgroup stack-oracle.
                                   Mismo patron de montaje fichero a fichero.
  features-enabled/icingadb.conf   Icinga 2 -> Redis
  features-enabled/ido-mysql.conf  Icinga 2 -> MySQL `icinga2`
  features-enabled/influxdb.conf   Icinga 2 -> InfluxDB (perfdata)

web/
  Dockerfile                       HTTPS en 8443 como www-data
  icingaweb2-ssl.conf              vhost HTTPS
  director-bootstrap.sh            los 4 pasos del servicio director-init

grafana/
  provisioning/datasources/        datasource InfluxDB (uid icinga-influx)
  provisioning/dashboards/         donde se mira para cargar dashboards
  dashboards/icinga-stack.json     el dashboard provisionado (25 paneles, los 6
                                   ultimos de los stacks ajenos: 3 de Wazuh y
                                   3 del stack nuevo #2)

tmp/                               sondas y benchmarks descartables
```

## Repositorio git

El proyecto está versionado en git, rama `main`, con remoto en **GitHub**:
`Horpef/icinga-stack` (**privado** — y tiene que serlo, porque el repo lleva
credenciales en claro en `docker-compose.yml`, `verify.ps1` y `web/`). La
identidad se guardó en la configuración **local** del repo, así que la global
sigue sin tocar:

```powershell
git -C D:\docker\icinga-stack log --oneline
git -C D:\docker\icinga-stack remote -v            # origin -> GitHub, sin token en la URL
git -C D:\docker\icinga-stack config user.name     # cambiar: --local o --global
git -C D:\docker\icinga-stack status --ignored     # que ignora y que no
```

El push va con un Personal Access Token (alcance `repo`) guardado en el
**Almacenamiento de credenciales de Windows** bajo `git:https://github.com`,
a través de `credential.helper = manager` que ya traía el Git de Windows. El
token **no** está en la URL de `origin` ni en `.git/config`, que es justo lo
que hay que evitar: `.git/config` lo copia el espejo del proyecto a
`C:\docker-backups\project\` y acabaría en la copia. Si el token caduca, el
siguiente `git push` abre la ventana del gestor de credenciales para poner
uno nuevo; no hay que tocar nada más.

Se versiona **declaración, no resultado**. Todo lo que se puede regenerar
con un script del propio proyecto queda fuera (`.gitignore`):
`_clean-test/` (lo que crea `mk-clean-test.ps1`), `tmp/` (sondas y restos
de depuración), `backups/` y los `*.tar` / `*.zip` / `*.dlist` del destino
de copias. Es el mismo criterio con el que `project-mirror.sh` excluye su
espejo, así que lo que se versiona y lo que se espeja coincide.

El repositorio acaba también en **otro disco** sin que nadie haga nada:
el espejo de `project-mirror` no excluye `.git`, así que a los 10 minutos
`C:\docker-backups\project\` ya lleva el historial.

### Por qué existe `.gitattributes`

El Git de Windows de esta máquina trae **`core.autocrlf=true` a nivel de
sistema** (se ve en `C:\Program Files\Git\etc\gitconfig`), que convierte
LF → CRLF al hacer checkout. Para los `.sh` eso es letal: se ejecutan con
`/bin/sh` dentro de contenedores Linux montados desde aquí, y dash los
rechaza con `sh: 1: ...: \r: command not found`.

Una regla explícita de `.gitattributes` manda sobre `autocrlf`, así que
fija **LF** en `.sh`, `.conf`, `.yml`, `.json`, `.sql`, `.md`, `.py` y el
`Dockerfile` — que no lleva extensión, así que autocrlf no lo trata como
texto y lo pasaría a CRLF sin más, con las líneas `RUN` dentro — y
**CRLF** en los `.ps1`, que es lo habitual en Windows.

El repositorio es un **monorepo**: cuando entraron `wazuh-stack` (con su
`regen-dashboard-cert.sh`) y `oracle-stack` (con su `Dockerfile`), las mismas
reglas se pusieron **también en la raíz** (`\.gitattributes`), que es la que
cubre a los tres stacks. La copia de `icinga-stack/` se conserva porque el
fichero más específico es el que manda, y las dos coinciden.

La prueba no es leerse el fichero, es clonar y mirar los bytes:

```powershell
git clone D:\docker\icinga-stack $env:TEMP\clone-prueba
git -C $env:TEMP\clone-prueba check-attr eol -- backup/check-backups.sh   # eol: lf
# .. abrir $env:TEMP\clone-prueba\backup\check-backups.sh y confirmar LF
Remove-Item -Recurse -Force $env:TEMP\clone-prueba
```

## Solución de problemas

**`docker compose up` aborta con `dependency failed to start: container X is
unhealthy`.**
En un volumen nuevo MySQL tarda minutos en abrir el puerto 3306. El
healthcheck tiene que ser **TCP** (`-h 127.0.0.1`, no `-h localhost`: el
de socket responde *vivo* durante la fase de inicialización con
`--skip-networking`) y necesitar un `start_period` grande (1800 s). Un fallo
dentro de `start_period` deja el estado en `starting`, y `depends_on:
service_healthy` sigue esperando.

**`up -d` aborta con `network monitoring-net declared as external, but could
not be found`.**
Falta la red transversal: se crea una sola vez con
`docker network create monitoring-net` (ver *Puesta en marcha*). No la crea
compose a propósito — es un recurso compartido con otros stacks y tiene que
sobrevivir a un `down` de este proyecto.

**`down` dice que la red está en uso y no la borra.**
Esperado si hay otro stack conectado a `monitoring-net`: la comparten, así
que no le corresponde borrarla a este proyecto. Para parar solo este stack
usa `docker compose stop`.

**La copia falla con `RemoteListVerificationException: Found N remote files
that are not recorded in local storage`.**
Aparece tras un `down -v`: se perdió el catálogo de Duplicati
(`duplicati_config`) pero los `.zip` siguen en el destino, y Duplicati no
reconoce ficheros que no están en su base local. **No los borra** — falla en
ruido antes que destruir tu única copia. Solución: restaurar
`duplicati_config` desde `C:\docker-backups\safety-net\` (ver *Recuperar
desde cero*). El `repair` de la web también lo arregla, pero **borra** los
ficheros desconocidos: solo si no tienes la red de seguridad.

**La restauración responde `200 OK` pero no aparece ningún fichero.**
Se pidió un **directorio** (`/sources/volumes/influxdb`). Sin base de datos
local Duplicati no puede expandir un directorio, pero sí resolver rutas de
fichero exactas. Pasa las rutas una a una (para enumerarlas:
`tar -tf <volumen>.tar` sobre la red de seguridad).

**El número de ficheros del destino baja y me asusto.** Es normal: Duplicati
**compacta** (reescribe los bloques en menos `.dblock` y elimina los
redundantes) después de cada copia. Ir de 42 a 19 ficheros no significa que
se haya perdido nada — las versiones viejas siguen restaurando. La medida de
la salud de una copia no es el recuento del destino, es
`verify.ps1 → [OK] Duplicati: restauracion con README.md y dump.sql`.

**`ConvertTo-Json` sobre un `Get-Content` produce objetos con `PSPath`,
`PSChildName`… en vez de cadenas.**
Capricho de PowerShell 5.1: los strings que salen del proveedor de ficheros
llevan propiedades añadidas y `ConvertTo-Json` las serializa todas, así que
el JSON sale corrupto y la API devuelve `400`. Solución: pasar por
`[IO.File]::ReadAllLines()` o hacer el cast `[string]`. Aviso relacionado:
PowerShell **no soporta** la redirección `<` en comandos nativos (para
importar el volcado: `docker exec icinga-db sh -c "mysql ... < /tmp/x.sql"`).

**Director dice `still pending`.**
Mira el paso 4 de `director-bootstrap.sh` y ejecuta
`icingacli director config deploymentstatus`.

**`account default not found`.**
La cuenta de `MSMTPRC` no se llama `default`.

**El endpoint sale con el hostname aleatorio del contenedor.**
Define `ICINGA_CN: icinga2` (lo hace el compose) para que `icinga api setup`
genere el certificado con CN estable. Si ya tienes un volumen viejo, el
kickstart del Director no encontrará `endpoint=icinga2`.

**`check_mysql` / `check_mysql_query` fallan.**
El usuario necesita `SESSION_VARIABLES_ADMIN, SYSTEM_VARIABLES_ADMIN` y
`log_bin_trust_function_creators=1` (ya están en `mysql-init/`).

**La comprobación de login da CRITICAL en vez de OK.**
`/authentication/login` devuelve **302** (control de cookies), no 200.

**Los paneles de Grafana están vacíos.**
Comprueba que la feature está activa y que hay datos frescos:

```powershell
docker exec icinga2 icinga2 feature list        # debe aparecer "influxdb"
docker exec influxdb influx -database icinga2 -execute "SHOW MEASUREMENTS"
```

Si `SHOW MEASUREMENTS` sale vacío, mira los errores del writer con
`docker logs icinga2 --since 5m | Select-String influx`. El error típico en
un volumen nuevo es que la base `icinga2` no existe: la crea el propio
contenedor de InfluxDB con `INFLUXDB_DB=icinga2` **solo en el primer
arranque**.

**`duplicati-init` sale con `Invalid hostname: duplicati` (403).**
Duplicati valida el header `Host` contra
`DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES`. Sin `duplicati` en esa lista la
llamada desde dentro de la red del compose recibe un 403 y la copia nunca se
da de alta sola, mientras que el navegador en `localhost:8200` sí funciona:
eso es justo lo que hace que cueste de ver.

**Duplicati devuelve `{"Error":"Missing passphrase"}` al crear la copia.**
La opción es `--no-encryption` **con los dos guiones**: el validador del
servidor solo mira ese nombre exacto (`Connection.ValidateBackup`), no
`no-encryption`. El JSON declarativo ya los usa bien.

**`Unsupported compression module: gzip`.**
Módulos de compresión: `zip` (el que viene por defecto) y ya está; `gzip` es
una extensión de fichero, no un módulo. No hace falta tocar
`compression-module`.

**`docker compose up` se queda esperando en `icinga-duplicati`.**
El orden es `mariadb → mysql-dump → duplicati → duplicati-init`, y las dos
primeras esperan a que MariaDB esté `healthy` (~10 min en un volumen nuevo).
Mira el avance con `docker logs -f icinga-mysql-dump`.

**He editado `backup/icinga-stack-backup.json` y no cambia nada.**
El alta es idempotente: si ya existe una copia con ese nombre no se toca nada
(para no pisar cambios hechos desde la web). Fuerza la recreación:

```powershell
docker compose up -d --force-recreate duplicati-init
docker compose logs duplicati-init
```

**Los servicios `Backup - *` no existen o están en UNKNOWN.**
Son los cinco que vigilan las copias. Cuatro dependen de dos montajes del
compose en el servicio `icinga2`: `C:/docker-backups:/backups:ro` y
`backup_staging:/staging:ro`, más `backup/check-backups.sh` colocado en
`PluginDir`; el quinto (`Scheduled run`) en cambio necesita las variables
`DUP_API`/`DUP_USER`/`DUP_PASSWORD`/`BACKUP_NAME` del mismo servicio, porque
consulta la API de Duplicati y no toca el disco. Tras editar el `compose`
hace falta **recrear** el contenedor (`docker compose up -d icinga2`):
reiniciarlo no basta: ni los montajes ni las variables de entorno se aplican
si no se recrea. La validación:

```powershell
docker exec icinga2 icinga2 daemon -C          # exit 0, "Instantiated 32 Services"
docker exec -u 5665 icinga2 /bin/sh /usr/lib/nagios/plugins/check-backups.sh `
  --test destino --warn 93600 --crit 180000
docker exec -u 5665 icinga2 /bin/sh /usr/lib/nagios/plugins/check-backups.sh `
  --test programada --warn 108000 --crit 129600
```

La segunda línea es exactamente lo que Icinga ejecuta, **como el usuario
`icinga` (uid 5665)**. Si da OK a mano y el servicio sigue en CRITICAL, el
problema está en la configuración; si falla a mano, en el script o en los
montajes.

**`Backup - Last upload` en CRITICAL recién creado el stack.**
El destino está vacío, y es normal: Duplicati no escribe nada hasta la
primera planificación (03:00). Por eso `duplicati-init` lanza ahora la
primera copia cuando detecta que el destino no tiene ningún `.zip` (monta el
destino en solo lectura justo para poder mirarlo), así que en un despliegue
nuevo se arregla solo. Si persiste, un *Run now* desde
<http://localhost:8200/> lo resuelve — y si falla ahí, el problema es de la
copia y no del monitoreo.

**`Backup - Scheduled run` en CRITICAL.**
Es el único que no mira el disco: consulta `Schedule.LastRun` en la API de
Duplicati, campo que **solo escribe el programador** — una copia lanzada a
mano (por `verify.ps1`, por un *Run now*) no lo toca. Si marca CRITICAL, el
programador lleva más de 36 h sin disparar. Primero se descarta que sea la
API y no el programador:

```powershell
docker exec -u 5665 icinga2 /bin/sh /usr/lib/nagios/plugins/check-backups.sh `
  --test programada --warn 108000 --crit 129600
```

* `cannot authenticate …` / `cannot read …` → no responde la API de
  Duplicati, no el programador: `docker logs icinga-duplicati`. También
  aparece durante los ~15 s en que `safety-net.ps1 -SoloCatalogo` detiene
  Duplicati para volcar su `config.tar`; sale UNKNOWN y se solo-limpia.
* `the backup job … is not registered` → `duplicati-init` no ha dado de alta
  el trabajo: `docker compose logs duplicati-init`.
* `has never fired and its slot … overdue` → el trabajo existe pero el
  programador no arranca. Un *Run now* **no** lo arregla: es manual y no toca
  `Schedule.LastRun`, por eso mismo el check no se deja engañar. Lo que lo
  arregla es reiniciar `icinga-duplicati` — su arranque recoge la ranura
  vencida y la ejecuta.
* `last run of the Duplicati scheduler: …` → es la lectura literal: mira la
  edad que pone y decide si es o no un fallo.

Con este PC apagado a las 03:00 es lo normal que la ranura no salga a tiempo;
lo esperado es que Duplicati la recupere al arrancar, y eso cuenta como
ejecución.

**`Backup - Free space` o `Backup - MySQL dump` dicen `… is missing`.**
El fichero que hay que medir no está: `project/.last-sync` aparece con la
primera sincronización de `project-mirror` y `dump.sql` con el primer volcado
de `mysql-dump`. Esos dos contenedores tienen healthcheck propio, así que el
sitio por el que mirar primero es `docker inspect icinga-project-mirror
--format '{{.State.Health.Status}}'` y `docker logs icinga-mysql-dump`.

**Un script falla con `sh: 1: ...: \r: command not found`.**
Los finales de línea se fueron a CRLF y el `\r` viaja dentro de la línea
hasta que dash intenta ejecutarla. Aquí solo puede pasar si alguien toca
`.gitattributes` o clona con `autocrlf` forzado por encima de él:

```powershell
git check-attr eol -- backup/check-backups.sh   # tiene que decir: eol: lf
git add --renormalize .
git commit -m "renormaliza finales de linea"
```

Ojo con cómo se detecta: **`git status` en el repositorio original no se
entera de nada**, porque los ficheros en disco ya estaban en LF y la
corrupción solo aparece en el checkout de otro sitio. Lo que vale es la
prueba del apartado *Repositorio git*: clonar a un directorio limpio y
mirar los bytes. Hécha y superada en el commit inicial.
