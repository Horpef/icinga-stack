# Monitorización en Docker — monorepo

Tres stacks de Docker Compose que comparten una red externa (`monitoring-net`):
uno **monitoriza**, otro **vigila la seguridad** y el tercero es una **app de
ejemplo con base de datos** que se monitoriza. Todo es declarativo, todo está
versionado y todo se comprueba con un script; nada vive fuera de Docker.

```
D:\Docker\
  icinga-stack\    monitorizacion: Icinga 2 + Icinga Web 2 + Director,
                   InfluxDB + Grafana, y la capa de copias (Duplicati)
  wazuh-stack\     SIEM: Wazuh (manager + indexer + dashboard) + 2 agentes
  oracle-stack\    app de ejemplo (Flask) + Oracle Database Free 23ai
                   los tres comparten la red externa  monitoring-net
```

| Stack | Qué es | Documentación |
|---|---|---|
| **`icinga-stack`** | Monitorización del conjunto y capa de copias. También es el que crea la red `monitoring-net`. | [`icinga-stack/README.md`](icinga-stack/README.md) |
| **`wazuh-stack`** | SIEM y seguridad: FIM sobre la declaración de los tres proyectos y recolección de los logs de los contenedores. | [`wazuh-stack/README.md`](wazuh-stack/README.md) |
| **`oracle-stack`** | La aplicación monitorizada: una app Flask mínima y una base de datos Oracle, las dos en contenedores. | [`oracle-stack/README.md`](oracle-stack/README.md) |

## Cómo está montado

- **La red es el gancho.** `icinga-stack` crea la red externa `monitoring-net`;
  los otros dos se cuelgan de ella, y así Icinga los ve **por nombre de
  servicio**, sin publicar puertos de servicio ni tocar nada del stack de
  monitorización. Añadir un stack nuevo es un fichero `.conf` más.
- **La monitorización es transversal.** Icinga 2 vigila los tres stacks (11
  hosts, 45 servicios) y avisa por correo —capturado en Mailpit— cuando algo
  cae. Un servicio de la app consulta la base de datos de verdad, así que
  distingue «el proceso vive» de «la base contesta».
- **Las copias son transversales.** Duplicati (dentro de `icinga-stack`)
  respalda la **declaración** de los tres proyectos; `safety-net.ps1` vuelca los
  **volúmenes** en frío (con los stacks parados), incluidos los datafiles de
  Oracle, que no se pueden copiar en caliente. El destino está en **otro disco
  físico** (`C:\docker-backups`), no en el de los datos.
- **Todo se verifica.** `verify.ps1` (en `icinga-stack`) recorre el conjunto de
  punta a punta —incluidas restauraciones reales de las copias— y devuelve
  `TOTAL FALLOS: 0`.

## Puesta en marcha

El orden importa: el primero crea la red.

```powershell
cd icinga-stack; docker network create monitoring-net; docker compose up -d
cd ..\wazuh-stack;  docker compose up -d     # el indexer tarda ~5 min en estar healthy
cd ..\oracle-stack; docker compose up -d     # la 1ª vez crea la BD: ~3 min
```

Cada stack tiene su propio README con el detalle: por qué cada límite de
memoria, cada healthcheck y cada decisión (incluidas las trampas que costó
descubrir).

## Verificación

```powershell
cd icinga-stack
powershell -ExecutionPolicy Bypass -File .\verify.ps1
# ===== TOTAL FALLOS: 0 =====
```

## Requisitos

Docker Desktop con WSL2. El conjunto pide **~8 GB de RAM**; va justo, así que
cada stack lleva sus `mem_limit` puestos a conciencia (ver los READMEs antes de
subirlos). Los datos de los stacks viven en volúmenes de Docker; las copias, en
`C:\docker-backups` (otro disco).

## Plan y decisiones

El porqué de cada cosa —y qué queda por hacer— está en
[`icinga-stack/roadmap.md`](icinga-stack/roadmap.md), no en la conversación.
