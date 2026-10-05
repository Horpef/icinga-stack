#!/bin/sh
# ---------------------------------------------------------------------------
#  Alta idempotente de las copias de seguridad en Duplicati
# ---------------------------------------------------------------------------
#  El servidor Duplicati arranca vacio: no hay ninguna copia definida y
#  configurarlas a mano desde la web no es reproducible (otro `down -v` las
#  perderia). Este script recorre TODOS los ficheros *.json de $PAYLOAD_DIR
#  (./backup en el host, montado read-only) y crea la copia que declare cada
#  uno usando la API REST del servidor, siguiendo el mismo patron que
#  director-init.
#
#  Anadir una copia nueva (por ejemplo la de otro stack) no requiere tocar
#  ni el compose ni este script: se deja el JSON en backup/ y se relanza
#    docker compose up -d duplicati-init
#
#  Idempotente: una copia cuyo nombre ya existe no se toca, para que los
#  cambios hechos a mano desde la web no se sobrescriban en cada arranque.
#  Progreso: `docker compose logs -f duplicati-init`.
# ---------------------------------------------------------------------------
set -u

URL="${DUPLICATI_URL:-http://duplicati:8200}"
PAYLOAD_DIR="${PAYLOAD_DIR:-/payloads}"
DEST_DIR="${DEST_DIR:-/dest}"
DUP_USER="${DUP_USER:-admin}"
DUP_PASSWORD="${DUP_PASSWORD:-icingaadmin123}"

log()  { echo "[duplicati-init] $*"; }
fail() { log "ERROR: $*"; exit 1; }

# 0) ¿hay algo que hacer? (el glob queda literal si no hay coincidencias)
n_json=0
for f in "$PAYLOAD_DIR"/*.json; do
    [ -e "$f" ] && n_json=$((n_json + 1))
done
[ "$n_json" -gt 0 ] || fail "no hay ningun fichero *.json en $PAYLOAD_DIR"
log "payloads: $n_json JSON declarativo(s) en $PAYLOAD_DIR"

# 1) esperar a que el servidor conteste
log "waiting for $URL ..."
i=0
until curl -sf -o /dev/null "$URL/"; do
    i=$((i + 1))
    [ "$i" -ge 100 ] && fail "el servidor no responde tras $((i * 3))s"
    sleep 3
done

# 2) autenticar (el token dura 15 min, suficiente para esta tanda)
LOGIN=$(curl -sS -X POST "$URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    --data-binary "{\"Username\":\"$DUP_USER\",\"Password\":\"$DUP_PASSWORD\"}")
TOKEN=$(printf '%s' "$LOGIN" | sed -n 's/.*"AccessToken":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || fail "login fallido: $LOGIN"
log "authenticated"
AUTH="Authorization: Bearer $TOKEN"

# 3) recorrer los payloads
creadas=0
existian=0

for PAYLOAD in "$PAYLOAD_DIR"/*.json; do
    [ -e "$PAYLOAD" ] || continue

    # El nombre se lee del propio payload para que este script y el JSON no
    # puedan desincronizarse.
    NAME=$(sed -n 's/^[[:space:]]*"Name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PAYLOAD" | head -n 1)
    [ -n "$NAME" ] || fail "no se pudo leer el nombre desde $PAYLOAD"

    LIST=$(curl -sS -X GET "$URL/api/v1/backups" -H "$AUTH")
    if printf '%s' "$LIST" | grep -q "\"Name\":\"$NAME\""; then
        log "already configured: $NAME"
        existian=$((existian + 1))
        continue
    fi

    log "creating $NAME from $PAYLOAD"
    RES=$(curl -sS -X POST "$URL/api/v1/backups" \
        -H "Content-Type: application/json" \
        -H "$AUTH" \
        --data-binary "@$PAYLOAD")
    case "$RES" in
        *'"Error"'*) fail "al crear '$NAME': $RES" ;;
        *'"ID"'*)    log "created: $NAME -> $RES" ;;
        *)           fail "respuesta inesperada para '$NAME': $RES" ;;
    esac

    # comprobar que quedo registrada
    LIST=$(curl -sS -X GET "$URL/api/v1/backups" -H "$AUTH")
    printf '%s' "$LIST" | grep -q "\"Name\":\"$NAME\"" \
        || fail "la copia '$NAME' no aparece tras crearla"
    log "verified: $NAME"

    # --- primera ejecucion -------------------------------------------------
    # Un despliegue recien creado no escribe NADA en el destino hasta la
    # primera planificacion (03:00), y mientras tanto la comprobacion de
    # frescura de Icinga ("Backup - Last upload") estaria CRITICAL sobre un
    # destino que simplemente esta vacio. Por eso la copia se prueba en
    # cuanto se da de alta.
    #
    # Solo si el destino esta vacio. Si ya tiene .zip lo que ha pasado es un
    # `down -v`: Duplicati pierde su base local pero el destino en C: se
    # queda intacto, y ahi copiar seria un error (veria ficheros que no
    # conoce y acabaria en Fatal con RemoteListVerificationException). Lo
    # que arregla eso es restaurar duplicati_config desde la red de seguridad.
    #
    # Si la copia no llega a terminar no se corta el alta: verify.ps1
    # comprueba a fondo la primera copia real, y abortar aqui solo
    # esconderia el motivo (el contenedor quedaria en error y habria que
    # mirar los logs para enterarse).
    ID=$(printf '%s' "$RES" | sed -n 's/.*"ID":"\([^"]*\)".*/\1/p')
    [ -n "$ID" ] || fail "no se pudo leer el ID de '$NAME'"

    if [ -z "$(find "$DEST_DIR" -maxdepth 1 -type f -name 'duplicati-*.zip' 2>/dev/null | head -n 1)" ]; then
        log "first run: $DEST_DIR is empty"
        RUN=$(curl -sS -X POST "$URL/api/v1/backup/$ID/run" \
            -H "Content-Type: application/json" -H "$AUTH" --data-binary '{}')
        case "$RUN" in
            *'"Error"'*) fail "al lanzar la primera copia '$NAME': $RUN" ;;
        esac
        # Mismo criterio que verify.ps1: hasta los 15 s la API puede
        # seguir devolviendo Active:false sin que la copia este considerada
        # activa, y salir a la primera daria un falso "ya termino".
        i=0
        while [ "$i" -lt 600 ]; do
            ACT=$(curl -sS -X GET "$URL/api/v1/backup/$ID/isactive" -H "$AUTH")
            case "$ACT" in
                *'"Active":false'*) [ "$i" -ge 15 ] && break ;;
            esac
            sleep 3
            i=$((i + 3))
        done
        if [ "$i" -ge 600 ]; then
            log "WARNING: la primera copia '$NAME' no termino tras 600 s"
        else
            log "first run finished: $NAME"
        fi
    else
        log "first run skipped: $DEST_DIR already has backups"
    fi

    creadas=$((creadas + 1))
done

log "done: $creadas creada(s), $existian ya existia(n)"
