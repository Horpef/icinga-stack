#!/bin/sh
# ---------------------------------------------------------------------------
# check-backups.sh - plugin de Icinga 2: salud de las copias de seguridad
# ---------------------------------------------------------------------------
#  Por que hace falta un plugin propio: los plugins que ya trae la imagen
#  (check_file_age, check_disk) responden sobre UN fichero o sobre el
#  sistema de ficheros, y la pregunta de las copias es "cual es el fichero
#  MAS RECIENTE de una carpeta". Eso solo lo resuelve mirar el directorio.
#  El script usa exclusivamente lo que trae la imagen (find, stat, date,
#  df, sort, tail, awk) y sintaxis POSIX.
#
#  Se ejecuta como el usuario `icinga` (uid 5665). Los origenes llegan
#  montados EN SOLO LECTURA desde docker-compose.yml:
#
#      /backups  <-  C:\docker-backups   destino de Duplicati + project/
#      /staging  <-  volumen backup_staging   dump.sql de mysql-dump
#
#  Uso:  check-backups.sh --test <prueba> --warn <umbral> --crit <umbral>
#
#    --test destino   segundos desde el ultimo fichero `duplicati-*` del
#                     destino: la ultima copia que Duplicati ha subido
#    --test espejo    segundos desde /backups/project/.last-sync
#    --test volcado   segundos desde /staging/dump.sql
#    --test espacio   gigabytes libres en /backups (INVERTIDO: menos es peor)
#    --test programada segundos desde la ultima vez que disparo el
#                     PROGRAMADOR de Duplicati, no desde la ultima copia
#
#    --warn/--crit    segundos en las cuatro pruebas de edad; gigabytes en
#                     `espacio`, donde hay aviso si libre < warn y critico
#                     si libre < crit (por eso ahi warn > crit).
#
#  Por que `programada` no puede mirar el disco: `destino` mide "cuando fue
#  la ultima copia", y verify.ps1 lanza copias al ejecutarse, de modo que
#  ese check se queda en OK aunque el programador diario este muerto. La
#  unica senal que distingue "corrio a la hora" de "corrio porque alguien lo
#  pidio" es el campo `Schedule.LastRun` de la API, que solo escribe el
#  programador (comprobado: una ejecucion manual actualiza
#  `Metadata.LastBackupStarted` pero NO `Schedule.LastRun`).
#
#  Requiere, en el servicio `icinga2` de docker-compose.yml:
#
#      DUP_API       endpoint de la API (por defecto http://duplicati:8200/api/v1)
#      DUP_USER      usuario de la API de Duplicati (por defecto admin)
#      DUP_PASSWORD  clave de ese usuario (por defecto icingaadmin123)
#      BACKUP_NAME   nombre del trabajo que hay que mirar (icinga-stack)
# ---------------------------------------------------------------------------
#
#  Codigos Nagios: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN. La salida lleva
#  datos de rendimiento (`clave=valor;aviso;critico`) para que InfluxDB y
#  Grafana grafiquen la edad y el espacio libres.
# ---------------------------------------------------------------------------
set -u

# --- parametros ---------------------------------------------------------

TEST="" WARN="" CRIT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --test)
            [ $# -ge 2 ] || { echo "UNKNOWN: --test sin valor"; exit 3; }
            TEST="$2"; shift 2 ;;
        --warn)
            [ $# -ge 2 ] || { echo "UNKNOWN: --warn sin valor"; exit 3; }
            WARN="$2"; shift 2 ;;
        --crit)
            [ $# -ge 2 ] || { echo "UNKNOWN: --crit sin valor"; exit 3; }
            CRIT="$2"; shift 2 ;;
        *)
            echo "UNKNOWN: parametro desconocido '$1' (ver la cabecera del script)"
            exit 3 ;;
    esac
done

if [ -z "$TEST" ] || [ -z "$WARN" ] || [ -z "$CRIT" ]; then
    echo "UNKNOWN: hacen falta --test, --warn y --crit (ver la cabecera del script)"
    exit 3
fi
case "${WARN}${CRIT}" in
    *[!0-9]*|"") echo "UNKNOWN: los umbrales tienen que ser enteros (warn=$WARN crit=$CRIT)"; exit 3 ;;
esac

DESTINO=/backups/icinga-stack
ESPACIO=/backups
ESPEJO=/backups/project
VOLCADO_DIR=/staging
VOLCADO_NOMBRE=dump.sql

# Configuracion de la prueba `programada` (API de Duplicati). Los mismos
# nombres y los mismos valores por defecto que duplicati-bootstrap.sh, para
# que el plugin funcione aunque el compose no los declare.
DUP_API=${DUP_API:-http://duplicati:8200/api/v1}
DUP_USER=${DUP_USER:-admin}
DUP_PASSWORD=${DUP_PASSWORD:-icingaadmin123}
BACKUP_NAME=${BACKUP_NAME:-icinga-stack}
# Un trabajo recien creado puede tener su ranura ya vencida y el programador
# sin disparar todavia. Se tolera un dia completo antes de acusarlo: ni la
# creacion del trabajo ni un arranque reciente deben sonar como alarma.
SIN_DISPARAR=86400

# --- utilidades ---------------------------------------------------------

# Imprime el resultado y sale. $1=codigo  $2=texto  $3=clave de rendimiento
# $4=valor  $5=umbral de aviso  $6=umbral critico
salir() {
    case "$1" in
        0) nivel="OK" ;;
        1) nivel="WARNING" ;;
        2) nivel="CRITICAL" ;;
        *) nivel="UNKNOWN" ;;
    esac
    echo "$nivel: $2 | $3=$4;$5;$6"
    exit "$1"
}

# Segundos desde epoch del fichero mas reciente de $1 cuyo nombre cumple el
# patron $2 (-name, sin recursion). Vacia si no hay ninguno.
#
# Ojo con `-H`: por defecto find NO sigue el symlink del propio argumento,
# de modo que sobre un enlace simbolico (`find /etc/icinga2 -maxdepth 1`)
# no bajaria a sus hijos y devolveria vacio. `-H` lo sigue solo en la linea
# de comando, sin perseguir los enlaces de dentro del arbol.
mas_reciente() {
    [ -d "$1" ] || { echo ""; return; }
    find -H "$1" -maxdepth 1 -type f -name "$2" -exec stat -c "%Y" {} + 2>/dev/null \
        | sort -n | tail -n 1
}

# "1 d 4 h" / "2 h 13 min" / "7 min"
legible() {
    if   [ "$1" -ge 86400 ]; then echo "$(( $1 / 86400 )) d $(( ($1 % 86400) / 3600 )) h"
    elif [ "$1" -ge 3600  ]; then echo "$(( $1 / 3600 )) h $(( ($1 % 3600) / 60 )) min"
    else                          echo "$(( $1 / 60 )) min"
    fi
}

# --- prueba de espacio --------------------------------------------------

# `-P` garantiza una linea por sistema de ficheros, asi que el cuarto campo
# de la ultima linea es siempre "Available". Kilobytes -> gigabytes.
if [ "$TEST" = "espacio" ]; then
    kb=$(df -Pk "$ESPACIO" 2>/dev/null | tail -n 1 | awk '{print $4}')
    case "$kb" in
        ""|*[!0-9]*)
            salir 2 "cannot read free space of $ESPACIO" free_gb -1 "$WARN" "$CRIT" ;;
    esac
    gb=$(( kb / 1024 / 1024 ))
    if   [ "$gb" -lt "$CRIT" ]; then salir 2 "only $gb GB left in the backup destination (critical < $CRIT GB)" free_gb "$gb" "$WARN" "$CRIT"
    elif [ "$gb" -lt "$WARN" ]; then salir 1 "only $gb GB left in the backup destination (warning < $WARN GB)" free_gb "$gb" "$WARN" "$CRIT"
    else                             salir 0 "$gb GB left in the backup destination" free_gb "$gb" "$WARN" "$CRIT"
    fi
fi

# --- prueba `programada` -------------------------------------------------

# Pregunta a la API de Duplicati cuando disparo el programador. No escribe
# nada en disco: el token se queda en una variable, que es suficiente y
# evita tener que dejar ficheros temporales corriendo como uid 5665.
if [ "$TEST" = "programada" ]; then
    token="" intento=0
    while [ "$intento" -lt 2 ] && [ -z "$token" ]; do
        intento=$(( intento + 1 ))
        login=$(curl -s -m 8 -X POST "$DUP_API/auth/login" \
                    -H 'Content-Type: application/json' \
                    -d "{\"Username\":\"$DUP_USER\",\"Password\":\"$DUP_PASSWORD\"}" 2>/dev/null)
        token=$(printf '%s' "$login" | sed -n 's/.*"AccessToken":"\([^"]*\)".*/\1/p')
        [ -z "$token" ] && [ "$intento" -lt 2 ] && sleep 2
    done
    [ -n "$token" ] || salir 3 "cannot authenticate against the Duplicati API ($DUP_API)" age_s -1 "$WARN" "$CRIT"

    lista=$(curl -s -m 8 "$DUP_API/backups" -H "Authorization: Bearer $token" 2>/dev/null)
    [ -n "$lista" ] || salir 3 "cannot read $DUP_API/backups" age_s -1 "$WARN" "$CRIT"

    # /backups devuelve un array con un elemento por trabajo. Se trocea
    # entre elementos y se queda con el que lleva nuestro nombre, para que
    # otro trabajo de la misma instancia no se cuele en la respuesta.
    trabajo=$(printf '%s' "$lista" | sed 's/},{"Backup"/\
/g' | grep -F "\"Name\":\"$BACKUP_NAME\"" | head -n 1)
    [ -n "$trabajo" ] || salir 2 "the backup job '$BACKUP_NAME' is not registered in Duplicati" age_s -1 "$WARN" "$CRIT"

    ultima=$(printf '%s' "$trabajo" | sed -n 's/.*"LastRun":"\([^"]*\)".*/\1/p')
    ranura=$(printf '%s' "$trabajo" | sed -n 's/.*"Time":"\([^"]*\)".*/\1/p')

    ep_ranura=$(date -u -d "$ranura" +%s 2>/dev/null)
    case "$ep_ranura" in
        ""|*[!0-9]*)
            salir 3 "the schedule of '$BACKUP_NAME' has no readable next slot" age_s -1 "$WARN" "$CRIT" ;;
    esac

    ahora=$(date +%s)
    retraso=$(( ahora - ep_ranura ))

    # El programador no ha disparado todavia. En la practica un trabajo
    # recien creado recoge su ranura vencida en cuanto se da de alta, pero
    # por si tarda (o si nunca lo hace) se tolera un dia completo antes de
    # acusarlo: pasado ese dia la ranura seguia sin recogerse y ya no hay
    # excusa que valga.
    case "$ultima" in
        ""|0001-01-01*)
            if [ "$retraso" -le 0 ]; then
                salir 0 "first scheduled run pending (slot $ranura)" age_s 0 "$WARN" "$CRIT"
            fi
            if [ "$retraso" -le "$SIN_DISPARAR" ]; then
                salir 0 "the scheduler has not fired yet (slot $ranura, $(legible "$retraso") ago)" age_s "$retraso" "$WARN" "$CRIT"
            fi
            salir 2 "the scheduler has never fired and its slot ($ranura) is $(legible "$retraso") overdue" age_s "$retraso" "$WARN" "$CRIT" ;;
    esac

    ep=$(date -u -d "$ultima" +%s 2>/dev/null)
    case "$ep" in
        ""|*[!0-9]*)
            salir 3 "unreadable last scheduled run '$ultima'" age_s -1 "$WARN" "$CRIT" ;;
    esac

    edad=$(( ahora - ep ))
    [ "$edad" -lt 0 ] && edad=0
    que="last run of the Duplicati scheduler"
    if   [ "$edad" -gt "$CRIT" ]; then salir 2 "$que: $(legible "$edad") ago (critical > $(legible "$CRIT"))" age_s "$edad" "$WARN" "$CRIT"
    elif [ "$edad" -gt "$WARN" ]; then salir 1 "$que: $(legible "$edad") ago (warning > $(legible "$WARN"))" age_s "$edad" "$WARN" "$CRIT"
    else                               salir 0 "$que: $(legible "$edad") ago" age_s "$edad" "$WARN" "$CRIT"
    fi
fi

# --- pruebas de edad ----------------------------------------------------

case "$TEST" in
    destino)
        momento=$(mas_reciente "$DESTINO" "duplicati-*")
        que="last upload in the backup destination" ;;
    espejo)
        momento=$(mas_reciente "$ESPEJO" ".last-sync")
        que="project mirror" ;;
    volcado)
        momento=$(mas_reciente "$VOLCADO_DIR" "$VOLCADO_NOMBRE")
        que="MySQL dump" ;;
    *)
        salir 3 "unknown test '$TEST'" age_s -1 "$WARN" "$CRIT" ;;
esac

if [ -z "$momento" ]; then
    salir 2 "no $que found (the file to measure is missing)" age_s -1 "$WARN" "$CRIT"
fi

ahora=$(date +%s)
edad=$(( ahora - momento ))
[ "$edad" -lt 0 ] && edad=0

if   [ "$edad" -gt "$CRIT" ]; then salir 2 "$que: $(legible "$edad") ago (critical > $(legible "$CRIT"))" age_s "$edad" "$WARN" "$CRIT"
elif [ "$edad" -gt "$WARN" ]; then salir 1 "$que: $(legible "$edad") ago (warning > $(legible "$WARN"))" age_s "$edad" "$WARN" "$CRIT"
else                               salir 0 "$que: $(legible "$edad") ago" age_s "$edad" "$WARN" "$CRIT"
fi
