# Oracle Stack

Tercer stack del proyecto y **primer «app que se monitoriza»**: una base de
datos **Oracle Database Free 23ai** y una **app Flask** que la usa, **las dos en
contenedores**. No hay nada fuera de Docker.

Es hermano de `icinga-stack` (el stack de monitorización) y `wazuh-stack`
(SIEM): vive en su propio directorio y su propio proyecto compose, y solo se
cuelga de la red externa `monitoring-net` — el gancho que deja el README de
`icinga-stack` para sumar proyectos sin tocar nada allí.

```
        D:\Docker\
          icinga-stack\     stack de monitorización (Icinga 2, Grafana, ...)
          wazuh-stack\      SIEM (manager, indexer, dashboard)
          oracle-stack\     <-- este: app + base de datos
                            los tres comparten  monitoring-net
```

---

## Puesta en marcha

```powershell
# 1. La red externa (una sola vez por maquina; ya existe si icinga-stack esta vivo)
docker network create monitoring-net

# 2. Levantar
docker compose up -d
```

> **El primer arranque tarda varios minutos.** El entrypoint de Oracle crea la
> base entera (datafiles, redo, PDB `FREEPDB1`, usuario `APP`) antes de aceptar
> consultas. `oracle-app` no arranca hasta que `oracle-db` esta `healthy`
> (`depends_on: service_healthy`), asi que un `docker compose up -d` se queda
> esperando y no devuelve hasta que la base responde. Para seguirlo:
>
> ```powershell
> docker compose logs -f oracle-db
> # ... cuando aparezca "DATABASE IS READY TO USE!" la base esta lista
> ```
>
> A partir de ahi el arranque es casi instantaneo: los datafiles quedan en el
> volumen `oracle_data` y no se vuelven a crear.

---

## Los dos servicios

| Servicio | Contenedor | Que es |
|---|---|---|
| `oracle-db` | `oracle-db` | Oracle Database Free 23ai (`gvenzl/oracle-free:23-slim`). Crea el PDB `FREEPDB1` y el usuario `APP`. |
| `oracle-app` | `oracle-app` | App Flask minima con `python-oracledb` (modo *thin*). Usa la base y publica su salud. |

`gvenzl/oracle-free` es una imagen **comunitaria pero pensada para contenedores**
(a diferencia de la imagen oficial de Oracle, no pide privilegios, ni `ipc:
host`, ni parametros de kernel). Oracle Free es **libre para usar en
produccion, sin mas limite de datos que el propio de la edicion Free**.

### La app: que hace y para que

Es deliberadamente minima, porque no es el objetivo: existe para tener algo
**real** que monitorizar de punta a punta. Hace tres cosas:

- Al arrancar, **espera a la base** y crea un pool de conexiones.
- Crea la tabla `HEARTBEAT` (si no existe) y un **hilo de fondo** que le inserta
  una fila cada 15 s, para que haya escritura real y no solo lectura.
- Publica dos endpoints:

| Ruta | Que hace |
|---|---|
| `GET /health` | Ejecuta `SELECT 1 FROM DUAL` y responde `200 ok` (o `500` si la base no contesta). |
| `GET /` | JSON con el PDB, el usuario y cuantas filas lleva `HEARTBEAT`. |

Se puede mirar desde el navegador en **http://localhost:18081** (publicado solo
en loopback, como el resto de UIs del proyecto).

### Por que `/health` importa

`/health` **no** es un simple "estoy vivo": consulta la base de verdad. Por eso
es la sonda que usan Icinga y `verify.ps1`: si el **proceso** de la app sigue en
pie pero **la base** deja de responder, `/health` devuelve 500 y el servicio de
Icinga se pone CRITICAL. Un chequeo de puerto no veria esa diferencia.

---

## RAM (no es capricho) y memoria de Oracle

El equipo tiene ~7,7 GB dentro de la VM de Docker y el stack de Wazuh ya
reserva ~5,3 GB en *limites*. Oracle 23ai Free necesita bastante memoria, asi
que aqui se le pone un **tope de 2 GB** (`mem_limit`, del que se autoconfigura
el SGA/PGA) y se mapea `shm_size: 1g` (Oracle usa `/dev/shm`; con el default de
Docker, 64 MB, el arranque puede fallar con `ORA-00845`; el tmpfs solo consume
RAM si se usa). La app lleva un tope de 256 MB.

**Si algo empieza a ir justo, este es el primer valor que hay que bajar.**

---

## El gotcha de `ORACLE_DATABASE` (medido, no teorico)

El compose **no** fija `ORACLE_DATABASE`. Parece una buena idea declararlo
(`ORACLE_DATABASE: FREEPDB1`) para no depender de un valor implicito, pero
rompe el arranque:

1. El entrypoint ya crea `FREEPDB1` **por defecto** al construir el CDB.
2. Si ademas declaras `ORACLE_DATABASE=FREEPDB1`, intenta crearla una **segunda**
   vez y falla con `ORA-65012: Pluggable database FREEPDB1 already exists`.
3. El entrypoint aborta esa fase, deja puesto el flag
   `/opt/oracle/hc-pdb-create`, el **healthcheck devuelve 3 (unhealthy) para
   siempre** y **`APP_USER` nunca llega a crearse**.

Sintoma tipico: `FREEPDB1` esta en `READ WRITE` pero el usuario de la app no
existe. Se comprueba con:

```powershell
# APP es un usuario LOCAL del PDB: en cdb_users se ve, en dba_users del root no
echo "select username, common from cdb_users where username='APP';" | docker exec -i oracle-db sqlplus -s / as sysdba
```

**Solucion** si ya ha pasado: `docker compose down -v` (borra el volumen a
medias) y `docker compose up -d` **sin** `ORACLE_DATABASE`.

---

## Vigilado por Icinga

Alta por fichero en `icinga-stack/icinga2-conf/conf.d/oracle.conf` (mismo
patron que Wazuh en la Fase 2). Icinga llega a los contenedores **por nombre**
(estan en `monitoring-net`), sin publicar la BD.

| Host | Servicio | Que prueba |
|---|---|---|
| `oracle-db` | `Oracle DB - Listener (1521)` | El listener acepta conexion (TCP). |
| `oracle-db` | `ping4` | El contenedor responde en la red. |
| `oracle-app` | `Oracle App - HTTP (8080)` | La app contesta en su puerto (TCP). |
| `oracle-app` | `Oracle App - Salud app+BD` | `GET /health` → `200` = app **y** base OK (consulta real). |
| `oracle-app` | `ping4` | El contenedor responde en la red. |

**Lo que NO se comprueba (a proposito):** nada lee el *contenido* de la base
(row counts, tablespaces, sesiones): eso pediria un cliente Oracle dentro del
contenedor de Icinga o un plugin dedicado. La tabla `HEARTBEAT` de la app es el
unico dato que se ejercita, y lo hace `verify.ps1` (seccion 9), que pide el
contador dos veces y comprueba que **crece**.

### Grafana

Tres paneles en el dashboard «Icinga Stack — metricas de los servicios»
(ids 23–25): respuesta HTTP de `/health`, conexion TCP (1521 y 8080) y ping de
los dos contenedores. Llevan su propio filtro `hostname =~ /oracle/` para seguir
viendose aunque el filtro Host del dashboard este puesto en otro stack.

---

## Wazuh (SIEM)

- **Logs:** los contenedores usan el driver `json-file` a proposito, igual que
  los de `icinga-stack`. El agente `icinga-stacks` (logcollector) lee
  `/var/lib/docker/containers/*/*-json.log`, asi que **entran solos**, sin tocar
  su configuracion.
- **Integridad (FIM):** los ficheros declarativos de este proyecto se montan en
  `/mon/oracle-stack` dentro del agente `docker-stacks`, y su ruta esta en
  `<syscheck>` (`wazuh-stack/config/agent/wazuh_agent.conf`). Un cambio en el
  compose o en el codigo de la app genera una alerta.

---

## Copias de seguridad

Dos capas, igual que en los otros stacks:

- **Duplicati** copia **solo la declaracion** (compose, `app/`, README): lo que
  hace falta para reconstruir el stack. Ver `icinga-stack/backup/oracle-stack-backup.json`.
- **`safety-net.ps1`** (en `icinga-stack`) vuelca tambien el volumen
  **`oracle_data`** (los datafiles), pero con **el stack parado**, que es una
  copia **en frio** y por tanto consistente.

> **Ojo con las bases de datos:** copiar los datafiles de una BD **en caliente**
> da una copia inconsistente que puede fallar al restaurar. Por eso Duplicati
> **no** toca `oracle_data` (corre con el stack vivo) y el volcado de la BD se
> reserva a `safety-net.ps1`, que para los stacks antes de copiar.

---

## Verificacion

`verify.ps1` (en `icinga-stack`) tiene una **seccion 9** que solo corre en
produccion:

```powershell
cd D:\Docker\icinga-stack
powershell -ExecutionPolicy Bypass -File .\verify.ps1
# -> ... oracle-db: contenedor healthy                          [OK]
#    ... oracle-db: FREEPDB1 abierta y acepta SQL               [OK]
#    ... oracle-app: /health OK (consulta real a Oracle)        [OK]
#    ... oracle-app: la tabla heartbeat crece (escritura en Oracle)  [OK]
#    ===== TOTAL FALLOS: 0 =====
```

---

## Estructura

```
oracle-stack\
  docker-compose.yml        # los dos servicios, red, limites, healthchecks
  app\
    Dockerfile              # python:3.12-slim + dependencias
    requirements.txt        # Flask, oracledb (thin), cryptography
    app.py                  # la app (heartbeat + /health)
  README.md                 # este fichero
```

## Credenciales (plaintext a proposito, mismo criterio que los otros stacks)

| Que | Valor |
|---|---|
| SYS/SYSTEM de Oracle (`ORACLE_PASSWORD`) | `oracle_root_pw` |
| Usuario de aplicacion (`APP_USER`) | `APP` |
| Contrasena de la app (`APP_USER_PASSWORD`) | `app_pass` |

Los datafiles viven en el volumen **`oracle-stack_oracle_data`**.
