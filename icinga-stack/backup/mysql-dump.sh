#!/bin/sh
# ---------------------------------------------------------------------------
#  Volcado periodico de MySQL para Duplicati
# ---------------------------------------------------------------------------
#  Por que existe este contenedor:
#
#  Duplicati es una herramienta a nivel de ficheros: lee rutas y las guarda.
#  Hacer `tar` del datadir de MySQL (/var/lib/mysql) con el servidor en
#  marcha produce una copia INCONSISTENTE que falla al restaurarse, porque
#  InnoDB tiene paginas a medias entre el redo log y los ficheros de datos.
#
#  La forma correcta de copiar una base en caliente es `mysqldump
#  --single-transaction`, que abre una transaccion REPEATABLE READ y vuelca
#  un snapshot consistente sin bloquear nada. Ese volcado se escribe en el
#  volumen `backup_staging`, que Duplicati tiene montado como origen.
#
#  Asi que:
#    * este contenedor  ->  produce un dump.sql consistente y fresco
#    * duplicati        ->  respalda ese dump.sql en lugar del datadir
#    * nadie            ->  para MariaDB ni dispara alertas CRITICAL falsas
#                           a las 3 de la manana
#
#  El volcado se renueva cada DUMP_INTERVAL segundos (10 min por defecto),
#  de modo que a la hora programada de la copia tendra como maximo esa
#  antiguedad. Se escribe en un fichero temporal y se renombra con `mv`
#  (operacion atomica) para que Duplicati nunca lea un fichero a medias.
#
#  El healthcheck del servicio marca `unhealthy` si el volcado supera los
#  15 min: el motivo es que el bucle se ha roto y la copia de MySQL dejaria
#  de estar fresca, cosa que hay que ver, no tapar.
# ---------------------------------------------------------------------------
set -u

STAGING="${STAGING:-/staging}"
HOST="${MYSQL_HOST:-mariadb}"
USER="${MYSQL_USER:-root}"
INTERVAL="${DUMP_INTERVAL:-600}"

# Motivo del ultimo fallo, para los mensajes de log (ver dump_once).
DUMP_ERROR=""

log() { echo "[mysql-dump] $*"; }

dump_once() {
    tmp="$STAGING/.dump.sql.tmp"
    # El stderr va FUERA de /staging: ahi dentro solo debe haber lo que
    # Duplicati tiene que respaldar.
    err="/tmp/mysqldump.err"

    # MYSQL_PWD lo aporta el servicio `mariadb` de este compose. No usar -p:
    # dejaria la contrasena visible en la lista de procesos.
    if mysqldump -h "$HOST" -u "$USER" \
        --single-transaction \
        --routines --triggers --events \
        --all-databases > "$tmp" 2> "$err"
    then
        mv -f "$tmp" "$STAGING/dump.sql"
        DUMP_ERROR=""
        log "OK ($(wc -c < "$STAGING/dump.sql") bytes)"
        return 0
    fi

    DUMP_ERROR="$(tr '\n' ' ' < "$err" 2>/dev/null)"
    [ -n "$DUMP_ERROR" ] || DUMP_ERROR="mysqldump sin salida en stderr"
    rm -f "$tmp"
    return 1
}

# Un volcado a medias de una ejecucion anterior no debe llegar a Duplicati.
rm -f "$STAGING/.dump.sql.tmp"

# Arranque: reintentar hasta que MariaDB acepte conexiones. En un volumen
# recien creado tarda ~10 min en estar listo, asi que el error se loguea una
# vez por minuto y no cada 5 s.
log "waiting for $HOST ..."
attempt=0
until dump_once; do
    attempt=$((attempt + 1))
    if [ $((attempt % 12)) -eq 1 ]; then
        log "waiting for $HOST (attempt $attempt): $DUMP_ERROR"
    fi
    if [ "$attempt" -ge 120 ]; then
        log "ERROR: no se pudo volcar tras $attempt intentos: $DUMP_ERROR"
        exit 1
    fi
    sleep 5
done

log "first dump done; refreshing every ${INTERVAL}s"
while :; do
    sleep "$INTERVAL"
    # Si falla se conserva el volcado anterior: sigue siendo valido, y
    # preferible a dejar /staging vacio (Duplicati no respaldaria nada de MySQL).
    dump_once || log "ERROR: keeping previous dump.sql -- $DUMP_ERROR"
done
