# python:3.12-slim (Debian): los wheels de oracledb/cryptography existen para
# esta plataforma, asi que no hace falta compilador ni Oracle Client.
FROM python:3.12-slim

WORKDIR /app

# Las dependencias primero: asi la capa se cachea y no se reinstala en cada
# cambio de app.py.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080

# -u para que stdout no se bufferice (los logs tienen que llegar al
# logcollector de Wazuh en tiempo real).
CMD ["python", "-u", "app.py"]
