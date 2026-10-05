#!/bin/sh
# ---------------------------------------------------------------------------
# project-mirror: copia en plano del proyecto al otro disco fisico.
# ---------------------------------------------------------------------------
# POR QUE EXISTE
#   El proyecto ya es fuente de Duplicati (9 entradas), asi que esta dentro
#   de los .zip del destino. El problema es circular: para leer esas copias
#   hace falta Duplicati, y para arrancar Duplicati hace falta el compose.
#   Este espejo rompe el ciclo: es el proyecto tal cual, en texto, en el
#   otro disco, legible con el Bloc de notas y sin Docker.
#
#   Si muere el disco D: (datos + proyecto), en C:\docker-backups quedan:
#     project\       -> este espejo: compose y configuracion, en claro
#     icinga-stack\  -> los .zip de Duplicati: los datos
#
# COMO FUNCIONA
#   Copia incremental cada 10 min con tar (viene en la imagen, sin `apk`).
#   NO usa --delete: un fichero borrado del proyecto se queda en el espejo,
#   que es lo que conviene en un espejo de recuperacion (nunca se sabe).
#
# EXCLUSIONES
#   tmp/            probes descartables del proyecto.
#   _clean-test/    la copia aislada generada por mk-clean-test.ps1.
#   backups/        el propio destino. Dentro del clean-test el espejo cae
#                   DENTRO de /src, y sin esta exclusion se copiaria a si
#                   mismo en bucle infinito.
set -u

SRC=/src
DEST=/dest
STAMP=/dest/.last-sync
EXCLUDES='--exclude=./tmp --exclude=./_clean-test --exclude=./backups'

mkdir -p "$DEST"

sync_project() {
    echo "[project-mirror] $(date '+%Y-%m-%d %H:%M:%S') $SRC -> $DEST"
    tar -C "$SRC" $EXCLUDES -cf - . | tar -C "$DEST" -xf -
    # marca de agua que lee el healthcheck: si no se renueva en 30 min,
    # el bucle esta roto.
    touch "$STAMP"
}

sync_project

while true; do
    sleep 600
    sync_project
done
