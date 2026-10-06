# Roadmap

Plan de crecimiento del stack. Existe porque la primera versión del plan solo
vivía en la conversación: cuando llegó el momento de usarlo había que
reconstruirlo de memoria, que es exactamente lo que este proyecto se ahorra
en todo lo demás. Escrito, versionado y con remoto, ya no se pierde.

Cada fase tiene un **criterio de hecho**, que es lo único que la distingue de
«seguir tocando cosas hasta que se parezca». Y cada fase se activa cuando
hace falta, no antes: la tentación de adelantar trabajo que nadie ha pedido
es la forma más común de estancarse.

**Estado: Fase 1 completa.** Fases 2-4 esperan a que haya algo que monitorizar
y a que el crecimiento lo justifique.

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

## Fase 2 · El primer stack real

**Cuándo**: en cuanto haya un segundo stack que quieras vigilar de verdad.

Hoy el stack se vigila a sí mismo: los 6 hosts y los 32 servicios son del
propio proyecto. El salto es monitorizar algo que no lo sea, y el gancho ya
está construido — `monitoring-net` es `external: true` con nombre estable, así
que cualquier stack nuevo solo tiene que colgarse de esa red.

| Qué toca | Cómo |
|---|---|
| Nuevo `Host` + `apply Service` | en `conf.d/`, siguiendo el patrón de `stack-monitoring.conf` |
| Darlo de alta | Director → *deploy* (los cuatro test del Director ya funcionan) |
| Notificaciones | ya llegan a Mailpit, sin tocar nada |
| Panel en Grafana | la variable `$host` del dashboard ya existe; solo añadir panel |
| Copias | `duplicati-init` ya acepta un JSON por stack en `backup/` |

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
| Copia plana del proyecto con `project-mirror` | historial git replicado a otro disco cada 10 min |
| Sin arranque automático ni `restart: always` | modelo de copia aceptado: catch-up al encender la PC |
| Identidad git **local** | la global sigue sin tocar |

## Qué hay que ampliar cuando entre un stack nuevo

1. **`safety-net.ps1`** — la lista de volúmenes a volcar es del stack actual
2. **`verify.ps1`** — hosts, servicios y paneles mínimos esperados
3. **`docker-compose.yml` + `backup/*.json`** — si el proyecto gana ficheros
   de primer nivel, recuerda que el alta en Duplicati es idempotente: hacen
   falta el `volumes:` **y** el `Sources` **y** un `PUT /api/v1/backup/{id}`
   contra el servidor
4. **`mk-clean-test.ps1`** — la lista de ficheros que copia; si falta uno,
   Docker crea en su lugar un directorio vacío y los orígenes se rompen
