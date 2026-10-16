# Wazuh Stack

**Wazuh 4.14.8 (single node)** — SIEM y seguridad: FIM sobre la declaracion de
los dos proyectos, y recoleccion de lo que imprimen los contenedores del
icinga-stack.

Es el **primer stack ajeno** al de monitorizacion (la "Fase 2" del roadmap de
`icinga-stack`). Se separa en directorio y proyecto propios (`D:\docker\wazuh-stack`)
y solo se cuelga de la red externa `monitoring-net`, que es el gancho que deja
preparado `icinga-stack` para conectar proyectos nuevos **sin tocar nada alla**.

Basado en el compose oficial de `wazuh/wazuh-docker` tag **v4.14.8** (ultima
estable; la v5.0.0 es release candidate). Cada diferencia con lo oficial esta
comentada una a una en `docker-compose.yml`: aqui no se toca nada sin motivo.

---

## Puesta en marcha

```bash
# 1. La red externa (una sola vez por maquina; ya existe si icinga-stack esta vivo)
docker network create monitoring-net

# 2. Generar los certificados TLS (si config/wazuh_indexer_ssl_certs/ esta vacio)
docker compose -f generate-indexer-certs.yml run --rm generator
#    -> escribe root-ca, indexer, dashboard, manager y admin en
#       config/wazuh_indexer_ssl_certs/. El CN de cada cert tiene que coincidir
#       con el hostname del servicio (wazuh.indexer, wazuh.dashboard, ...), que
#       es por lo que los hostnames llevan punto y NO se renombran.

# 3. Levantar
docker compose up -d

# 4. Dar por su creido el arranque: el indexer (JVM) tarda ~3 min en estar
#    healthy (start_period: 180s) y el dashboard otros ~3 detras de el.
docker compose ps
```

Si se regeneran certificados, hay que recrear los servicios que los usan
(`--force-recreate`), no basta con `restart`: los PEM se copiaron al contenedor
en su arranque.

---

## Los cinco servicios

| Servicio | Contenedor | Puerto | Rol |
|---|---|---|---|
| `wazuh.manager` | `wazuh-manager` | 1514, 1515, 55000 | analizador: reglas, FIM, logcollector, API |
| `wazuh.indexer` | `wazuh-indexer` | *(interno 9200)* | OpenSearch: guarda las alertas |
| `wazuh.dashboard` | `wazuh-dashboard` | 5601 | interfaz web |
| `wazuh.agent` | `wazuh-agent` | *(ninguno)* | agente **FIM** (nombre: `docker-stacks`) |
| `wazuh.agent.icinga` | `wazuh-agent-icinga` | *(ninguno)* | agente de **LOGS** (nombre: `icinga-stacks`) |

**Por que `wazuh.indexer` no publica 9200**: es un servicio interno — lo usan el
manager (via filebeat) y el dashboard, y lo comprueba Icinga desde
`monitoring-net`. Publicarlo expondria el indice (y su autenticacion) a la red
local sin ninguna necesidad. Solo `1514/1515` (agentes) y `55000` (API, para
`verify.ps1` desde el host) salen al host; `5601` es el panel.

**`514/udp` (syslog) NO se publica a proposito**: solo haria falta si algo de
fuera de Docker manda logs, y un puerto syslog abierto en el host es puerta de
entrada para inyectar eventos falsos. Los contenedores de `monitoring-net`
llegan por la red sin publicar nada.

### RAM (no es capricho)

El equipo tiene 15,9 GB y Docker ve ~7,7 GB, de los que icinga-stack ya ocupa
~1,3 GB. Sin limites, el indexer (JVM) se come el presupuesto y **el primero en
resbalar seria Icinga, que es el que avisa**. Por eso todo va acotado:

| Contenedor | `mem_limit` | heap JVM |
|---|---|---|
| indexer | 2560m | `-Xms1g -Xmx1g` |
| manager | 1280m | — |
| dashboard | 1024m | — |
| agente logs | 256m | — |
| agente FIM | 192m | — |

Wazuh recomienda 4 GB minimo y 16 GB para el indexer; aqui se le dan 2,5 GB de
tope, **por debajo de ese minimo**. Para un lab con pocos agentes y volumen bajo
aguanta, y es lo primero que se toca si se queda corto.

---

## Los dos agentes: dos jurisdicciones distintas

Wazuh tiene dos agentes y **no se pisan**: cada uno vigila algo distinto.

| Agente | Nombre | Vigila | Daemon |
|---|---|---|---|
| `wazuh.agent` | `docker-stacks` | LOS **FICHEROS** de ambos proyectos (`/mon/icinga-stack`, `/mon/wazuh-stack`) | syscheck (FIM) |
| `wazuh.agent.icinga` | `icinga-stacks` | LO QUE LOS **CONTENEDORES IMPRIMEN** (stdout) | logcollector |

* **`docker-stacks`** (FIM): el ojo de seguridad sobre el codigo declarativo.
  Deja registro de **quien** cambia una linea de la infraestructura y **cuando**.
  `check_all=yes` + `report_changes=yes` sobre los dos arboles de proyecto.

* **`icinga-stacks`** (logs): lee `/var/lib/docker/containers/*/*-json.log` con
  `log_format=json` y sigue el puntero de cada fichero en vivo (lo que un
  contenedor imprima **despues** de arrancar el agente tambien se recoge).
  `syscheck` va **desactivado a proposito** (`<disabled>yes</disabled>`): si
  ambos vigilaran `/mon/icinga-stack`, un cambio de fichero generaria **dos**
  alertas (una por agente) y el ruido enmascaria la senal.

### La frontera es el DRIVER de log, no una lista de exclusiones

Un riesgo obvio: si el agente `icinga-stacks` leyera los logs del **propio
Wazuh**, cada alerta escribiria un log que generaria otra alerta -> **bucle sin
fin**. La solucion aqui **no es una lista de exclusiones** sino el tipo de
driver de logging:

* `icinga-stack` declara **`json-file` explicito** en su compose (con rotacion
  10m x3). Cada contenedor escribe UN fichero `*-json.log` -> el wildcard del
  logcollector los cubre a todos.
* `wazuh-stack` se queda en el driver **por defecto** del daemon (`local`), que
  escribe en su subdir `local-logs/` en formato **binario** y **NO** casa con
  `*-json.log`.

Resultado: los contenedores de Wazuh quedan **fuera del wildcard sin tocar
ninguna lista**, y no hay bucle de retroalimentacion. Verificado: 13 dirs con
`*-json.log` (icinga) vs 5 con `local-logs/` (wazuh).

> **OJO si alguien pasa `wazuh-stack` a `json-file`**: el globo pasaria a
> recogerse a si mismo. Revisar entonces reglas o driver antes de hacerlo.

### La montana rusa del bind `/var/lib/docker/containers`

Parece imposible montar desde Windows (el directorio vive dentro del filesystem
ext4 de la VM de Docker Desktop). Pero **quien resuelve el bind mount es el
daemon de dentro de la VM, y ese SI lo ve**. Verificado con un
`docker run -v /var/lib/docker/containers:... ls` antes de montarlo. No hace
falta compartir nada en *Docker Desktop > Settings > Resources > File sharing*.

---

## La regla propia: `100100` (container-errors)

`config/wazuh_cluster/rules/container-errors.xml`. Sin regla propia, los eventos
que manda `icinga-stacks` **NO generan alerta** (Wazuh descarta lo que no casa
con ninguna regla) y el dashboard quedaria vacio, pareciendo que la ingesta no
funciona. La regla es el minimo para que un error visible en la consola de un
contenedor acabe en `wazuh-alerts`.

```xml
<rule id="100100" level="5">
  <decoded_as>json</decoded_as>
  <match>error|critical|fatal|panic|exception|traceback|denied|refused</match>
  <description>Contenedor del icinga-stack: linea de error en su salida estandard</description>
  <group>container_error,</group>
</rule>
```

`<decoded_as>json</decoded_as>` acota a los eventos decodados por el decoder
`json` (los del logcollector). Excluye de paso los eventos **FIM** de
`docker-stacks` (`decoded_as syscheck`), cuyos diffs de codigo podrian contener
la palabra "error" y generarian alertas dobles.

### Las DOS trampas que silenciaban las alertas (2026-10-09)

Hubo un periodo en que **logcollector leia y enviaba todo correctamente pero no
habia ni una alerta**. Eran **dos** configuraciones juntas, no un problema de
transporte:

1. **`OSRegex` no agrupa con `()`**. El patron original estaba envuelto en
   parentesis: `(error|critical|...|refused)`. El regex engine de Wazuh los
   trata como **literales**, asi que exigia un `(` antes de `error` y un `)`
   despues de `refused`. Verificado con `wazuh-logtest`: `"aaa error bbb"` NO
   casaba (y `"foo (error) bar"` SI), mientras que las alternativas intermedias
   (`fatal`, `panic`, `denied`) casaban siempre. -> el contenido `error` caia en
   la regla **1002**.
2. **`<log_alert_level>3</log_alert_level>`** en el `ossec.conf` del manager
   descarta cualquier alerta de **level < 3**. La 1002 es **level 2**, asi que
   jamas escribia alerta.

Juntas: contenido `error` -> cae en la 1002 (por los parentesis) -> la 1002 esta
silenciada (por el umbral) -> **cero alertas**. Fijado el `<match>` **sin
parentesis** y documentado en los comentarios del XML. `verify.ps1` lo protege
con una **sonda E2E** (seccion 8).

### Otras dos trampas documentadas en el XML

* **NUNCA usar `<field name="log">...</field>`**. Suena mas "tipado" (las claves
  del JSON se exponen como campos), pero en 4.14.8 produjo
  `Syntax error on tag 'log'` + `Error loading the rules` y **analysisd se
  SALIO**: el manager quedo `unhealthy`. **Una regla mal formada no se ignora,
  tumba el servicio entero.**
* **NUNCA usar `<hostname>wazuh-agent-icinga</hostname>`** como filtro de
  alcance. Pese a que el hostname del agente ES ese (verificado en
  `/etc/hostname`), con el filtro puesto la regla **NUNCA caso** ni con eventos
  json ni con syslog; sin el filtro, empezo a alertar al instante. El
  acotamiento efectivo es `<decoded_as>json</decoded_as>`.

### Actualizar la regla

La imagen copia desde `/wazuh-config-mount/etc/rules/` **solo al ARRANCAR** el
contenedor. Un `docker restart` **NO** vuelve a copiar. Para actualizar reglas:

```bash
docker compose up -d --force-recreate wazuh.manager
```

`wazuh_manager.conf` ya declara `<rule_dir>etc/rules</rule_dir>` (bloque
*User-defined ruleset*), asi que no hay que tocar nada mas. IDs propios:
**>= 100000** para no pisar la numeracion del ruleset por defecto.

### Si un contenedor truena alertas a lo bestia

Un servicio critico de Icinga puede escribir `"critical"` en cada check (cada
30 s) y generara una alerta por linea: es **correcto** (hay algo roto). Si el
ruido molesta, de menor a mayor impacto:

* `<frequency>300</frequency>` -> minimo una alerta cada 5 min por evento
  similar, en vez de una por linea.
* Subir el `level` a 10 -> solo alerta si las reglas normalizan a >= 10.
* Acotar el patron (quitar `critical` y dejar solo fatales).

No se ha puesto `frequency` por defecto **a proposito**: en un sistema de
monitorizacion, ver TODO lo que un contenedor grita es la gracia.

---

## Copias de seguridad

`backup/wazuh-stack-backup.json` (declarado en `icinga-stack/docker-compose.yml`,
junto a los demas). Es un **trabajo de Duplicati aparte** del de icinga-stack.

**4 origenes**, montados desde `icinga-stack/docker-compose.yml`:

```yaml
- D:/docker/wazuh-stack/docker-compose.yml:/sources/otros/wazuh-stack/docker-compose.yml:ro
- D:/docker/wazuh-stack/config:/sources/otros/wazuh-stack/config:ro
- D:/docker/wazuh-stack/generate-indexer-certs.yml:/sources/otros/wazuh-stack/generate-indexer-certs.yml:ro
- D:/docker/wazuh-stack/regen-dashboard-cert.sh:/sources/otros/wazuh-stack/regen-dashboard-cert.sh:ro
```

**Lo que se respalda es la CONFIGURACION, no los datos.** Los volumenes de
Wazuh (indice, estado de agentes, etc.) **no** entran en la copia. Es
deliberado y esta documentado en el roadmap: los volumenes se reconstruyen
**reinstalando el stack desde su configuracion, que si esta copiada**. `verify.ps1`
comprueba la restauracion **bit a bit** (SHA256 identico) de compose y
`wazuh.yml`.

Para ampliar `safety-net.ps1` a los 14 volumenes de Wazuh, ver la **Fase 4**
del roadmap de `icinga-stack` (todavia no se ha hecho a proposito).

---

## Vigilado por Icinga

`icinga-stack/icinga2-conf/conf.d/wazuh.conf` da de alta el stack en el
monitorizacion principal: **3 hosts + 5 servicios + 1 hostgroup**
(`stack-wazuh`), todo via `monitoring-net` sin publicar de mas.

| Servicio | Que comprueba | Por que ese expect |
|---|---|---|
| `Wazuh Manager - API (HTTPS)` | `GET :55000/security/user/authenticate` | **401 es la respuesta sana**: prueba que el daemon sirve Y que no acepta anonimos |
| `Wazuh Manager - Agentes` | TCP 1514 | donde se conectan los agentes |
| `Wazuh Manager - Alta de agentes` | TCP 1515 | enrollment: puerto y modo de fallo separados (los agentes siguen en 1514 mientras nadie nuevo puede registrar) |
| `Wazuh Indexer - Salud del cluster` | `GET :9200/_cluster/health` (espera `green`) | TLS + basic auth + OpenSearch + estado de cluster de una vez. Timeout **20 s**: en su primer arranque esta maquina (disco HDD entonces) tardo 15-20 s en publicar estado, y 10 s habria llorado lobo en cada reinicio |
| `Wazuh Dashboard - Pagina de acceso` | `GET :5601/` | **302** es lo que recibe una peticion sin auth (redirect a `/app/login`); **503** es lo que recibe cuando el dashboard ha perdido el indexer |

---

## Verificacion

`icinga-stack/verify.ps1`, **seccion 8** (solo en produccion, no en clean-test:
`mk-clean-test.ps1` no clona `wazuh-stack`). Copia de verdad del feature de
logs, cinco comprobaciones:

1. **API JWT obtenida** — la API de Wazuh exige token (login con
   `wazuh-wui`/`icingaweb123`).
2. **Agentes `docker-stacks` e `icinga-stacks` en `active`.**
3. **Regla `100100` cargada** — `GET /rules?rule_ids=100100` ->
   `total_affected_items >= 1` (ojo: `/rules` usa `total_affected_items`, no
   `total` como `/agents`).
4. **Logcollector analiza todos los `*-json.log` del daemon** — cuenta los
   `"Analyzing file"` (nivel INFO, no depende del debug) y los compara con los
   json en disco.
5. **Sonda E2E** — inyecta una linea con `ERROR` en un contenedor via
   `/proc/1/fd/1` (que si entra en el log del daemon; el stdout de
   `docker exec`, no) y espera ver la **alerta 100100** en `alerts.log`. Es la
   regresion del bug de los parentesis: si el `<match>` volviera a exigir
   `"(error"` literal, o si la regla cayera en la 1002 (level 2, descartada por
   `log_alert_level=3`), la sonda dejaria de alertar.

```bash
cd icinga-stack
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
# -> ... Wazuh: sonda E2E con 'error' vuelve como alerta 100100  [OK]
#    ===== TOTAL FALLOS: 0 =====
```

---

## Solucion de problemas

| Sintoma | Causa | Arreglo |
|---|---|---|
| Agente no arranca, `ossec.conf` con `CHANGE_MANAGER_IP` literal | variable `WAZUH_MANAGER` en vez de **`WAZUH_MANAGER_SERVER`** (en 4.14.8 el init lee esa) | usar `WAZUH_MANAGER_SERVER` en el compose |
| `Duplicate agent name` al recrear | nombre de agente por defecto (`wazuh-agent-$HOSTNAME`) cambia al recrear | `WAZUH_AGENT_NAME` fijo (ya esta) + volumen propio con `client.keys` |
| `(1230): Invalid element ... 'logcollector'` | la etiqueta XML es **`<localfile>`**, no `<logcollector>` | renombrar la seccion |
| `(1235): Invalid value` y muere el logcollector | `log_format="plain"` **no existe** en `<localfile>` (solo `syslog`/`json`/`utf-8`/`multipleline`) | usar `json`; `plain` SI vale dentro de `<logging>` (elemento distinto) |
| Regla con `<field name="log">` -> manager `unhealthy` | `Syntax error on tag 'log'` tumba analysisd | usar `<match>` + `<decoded_as>json</decoded_as>` |
| Regla con `<hostname>` -> nunca casa | el filtro de hostname no rellena `lf->hostname` en eventos de agente (4.14.8) | quitar `<hostname>`; acotar con `<decoded_as>` |
| Sin alertas pese a logcollector leyendo | doble trampa: parentesis en `<match>` + `<log_alert_level>3` silenciando la 1002 | `<match>` sin parentesis; subir level o revisar umbral |
| Regla nueva no aplica tras `restart` | la init solo copia `/wazuh-config-mount` al **arrancar** | `docker compose up -d --force-recreate wazuh.manager` |
| `client.keys` vacio / agente unhealthy | alta con el manager no completada (o clave perdida y entrada vieja choca) | volumen `wazuh-agent-*-etc` propio por agente (dos agentes nunca comparten clave) |
| filebeat no valida cert | el hostname del manager tiene que coincidir con el **CN del cert** | no renombrar `hostname:` (wazuh.manager, con punto) |

---

## Estructura

```
wazuh-stack/
├── docker-compose.yml              # los 5 servicios + volumenes + red
├── generate-indexer-certs.yml      # generador de TLS (wazuh-certs-generator)
├── regen-dashboard-cert.sh         # regenera el cert del dashboard
├── config/
│   ├── certs.yml                   # entradas del generador de certs
│   ├── agent/
│   │   ├── wazuh_agent.conf        # agente FIM (docker-stacks)
│   │   └── wazuh_agent_logs.conf   # agente logs (icinga-stacks)
│   ├── wazuh_cluster/
│   │   ├── wazuh_manager.conf      # ossec.conf del manager
│   │   └── rules/
│   │       └── container-errors.xml  # regla propia 100100
│   ├── wazuh_dashboard/
│   │   ├── opensearch_dashboards.yml
│   │   └── wazuh.yml
│   ├── wazuh_indexer/
│   │   ├── wazuh.indexer.yml
│   │   └── internal_users.yml
│   └── wazuh_indexer_ssl_certs/    # PEMs generados (root-ca, indexer, dashboard, manager, admin)
└── tmp/
    └── agent-conf-bisect.sh        # diagnostico del bisect de ossec.conf
```

### Credenciales (plaintext a proposito, mismo criterio que icinga-stack)

| Uso | Usuario | Password |
|---|---|---|
| Indexer / admin | `admin` | `icingaadmin123` |
| Wazuh API | `wazuh-wui` | `icingaweb123` |
| Dashboard (login web) | `kibanaserver` | `icingaadmin123` |

Es un lab en maquina local; la seguridad esta en el perimeter (que solo
`1514/1515/55000/5601` salgan al host y el 9200 no salga de `monitoring-net`),
no en esconder credenciales en el repo.
