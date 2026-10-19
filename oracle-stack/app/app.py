"""oracle-app: app minima que usa una base de datos Oracle.

Existe para tener algo real que monitorizar (app + BD, las dos contenedorizadas).
No tiene mas ambicion que esa: demostrar de punta a punta que la app CONSULTA
la base y que, si la base deja de responder, la salud de la app lo refleja.

  GET /health  -> consulta SELECT 1 FROM DUAL. 200 si la BD responde, 500 si no.
  GET /        -> JSON con el numero de latidos guardados y el PDB.

Un hilo de fondo inserta una fila en HEARTBEAT cada 15 s, para que la tabla
tenga datos que mirar y para ejercitar la escritura, no solo la lectura.
"""

import os
import threading
import time

import oracledb
from flask import Flask, Response, jsonify

DB_USER = os.environ.get("DB_USER", "APP")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "app_pass")
DB_DSN = os.environ.get("DB_DSN", "oracle-db:1521/FREEPDB1")

BEAT_SECONDS = 15

app = Flask(__name__)

# Pool de conexiones creado una vez al arrancar. Hasta que no exista, los
# handlers responden 503; el entrypoint no deja llegar aqui antes de que la
# BD este healthy (depends_on), pero el reintento protege del PDB lento.
pool = None


def _log(msg):
    # flush=True: sin esto los prints se quedan en el buffer y no aparecen en
    # `docker logs` ni, por tanto, en el logcollector de Wazuh.
    print(f"[oracle-app] {msg}", flush=True)


def init_pool():
    """Espera a que la BD acepte conexiones y crea el pool."""
    global pool
    while pool is None:
        try:
            pool = oracledb.create_pool(
                user=DB_USER,
                password=DB_PASSWORD,
                dsn=DB_DSN,
                min=1,
                max=4,
                increment=1,
            )
            _log(f"pool creado contra {DB_DSN} como {DB_USER}")
        except Exception as exc:  # noqa: BLE001 - se reintenta sin mas
            _log(f"esperando a Oracle ({DB_DSN}): {exc}")
            time.sleep(5)


def ensure_schema():
    """Crea la tabla HEARTBEAT si es la primera vez."""
    with pool.acquire() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute("SELECT 1 FROM heartbeat WHERE 1 = 0")
            except oracledb.DatabaseError:
                cur.execute(
                    "CREATE TABLE heartbeat ("
                    "  id NUMBER GENERATED ALWAYS AS IDENTITY,"
                    "  ts TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL"
                    ")"
                )
                _log("tabla heartbeat creada")
        conn.commit()


def heartbeat_loop():
    """Inserta un latido cada BEAT_SECONDS, para siempre."""
    while True:
        try:
            with pool.acquire() as conn:
                with conn.cursor() as cur:
                    cur.execute("INSERT INTO heartbeat (ts) VALUES (SYSTIMESTAMP)")
                conn.commit()
        except Exception as exc:  # noqa: BLE001
            _log(f"error insertando latido: {exc}")
        time.sleep(BEAT_SECONDS)


@app.get("/health")
def health():
    """Prueba real de app+BD: una ida y vuelta a la base."""
    if pool is None:
        return Response("pool no listo\n", status=503, mimetype="text/plain")
    try:
        with pool.acquire() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1 FROM DUAL")
                cur.fetchone()
        return Response("ok\n", mimetype="text/plain")
    except Exception as exc:  # noqa: BLE001
        return Response(f"db error: {exc}\n", status=500, mimetype="text/plain")


@app.get("/")
def index():
    if pool is None:
        return jsonify({"app": "oracle-app", "db": "starting"}), 503
    try:
        with pool.acquire() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM heartbeat")
                beats = int(cur.fetchone()[0])
                cur.execute("SELECT SYS_CONTEXT('USERENV', 'CON_NAME') FROM DUAL")
                pdb = cur.fetchone()[0]
        return jsonify(
            {
                "app": "oracle-app",
                "db": "up",
                "user": DB_USER,
                "pdb": pdb,
                "heartbeats": beats,
            }
        )
    except Exception as exc:  # noqa: BLE001
        return jsonify({"app": "oracle-app", "db": "down", "error": str(exc)}), 500


if __name__ == "__main__":
    _log("arrancando")
    init_pool()
    ensure_schema()
    threading.Thread(target=heartbeat_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=8080)
