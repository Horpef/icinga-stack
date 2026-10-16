#!/usr/bin/env bash
# =============================================================================
# Regenera SOLO el certificado del panel con localhost en las SAN
# =============================================================================
# Por que existe: la herramienta oficial (wazuh-certs-tool.sh) mete UN SOLO
# SAN por certificado -- mira la linea 347 de esa herramienta:
#
#     cert_generateCertificateconfiguration "${dashboard_node_name}" \
#                                           "${dashboard_node_ips[i]}"
#
# es decir, solo la primera `ip:` de la entrada. En config/certs.yml eso da
# `DNS:wazuh.dashboard`, que sirve para las conexiones internas (el manager y
# Icinga hablan con wazuh.dashboard y ahi el nombre CUADRA), pero no para
# abrir el panel desde el navegador del host tecleando
# https://localhost:5601, que daria ERR_CERT_COMMON_NAME_INVALID.
#
# Este script no toca la CA ni los demas certificados: firma con el mismo
# root-ca.key y solo amplia el subjectAltName a:
#
#     DNS:wazuh.dashboard   el nombre del nodo (el que ya usaba)
#     DNS:localhost         lo que teclea el usuario en el navegador
#     IP:127.0.0.1          por si se abre por IP
#
# El resto de la extension es CALCO del template del script oficial
# (lineas 246-250), para que el certificado sea igual salvo por las SAN.
#
# DOS peculiaridades de esta superficie de montaje, sin las cuales el script
# no funciona:
#
#   1. Los .pem estan en modo 400 con UID 1000 y el contenedor corre como
#      root. Aqui root NO obvia el permiso del fichero existente: se LEEN
#      bien, pero openssl no puede truncarlos para reescribirlos. Por eso
#      todo se genera primero en /tmp y solo despues se copia encima.
#   2. El directorio si es de root y escribible, asi que crear ficheros
#      nuevos funciona; por eso borrar y reemplazar si sale.
#
# Uso (desde D:\docker\wazuh-stack):
#   docker run --rm --user 0 --entrypoint bash ^
#     -v D:/docker/wazuh-stack/config/wazuh_indexer_ssl_certs:/certs ^
#     -v D:/docker/wazuh-stack/regen-dashboard-cert.sh:/regen.sh:ro ^
#     wazuh/wazuh-certs-generator:0.0.4 /regen.sh
#
# Tras regenerarlo hay que reiniciar el panel (docker restart wazuh-dashboard):
# el certificado esta montado por bind y el proceso lo lee al arrancar.
# =============================================================================
set -euo pipefail

cd /certs

SAN="DNS:wazuh.dashboard,DNS:localhost,IP:127.0.0.1"

echo "  CA del stack:"
openssl x509 -in root-ca.pem -noout -subject -dates | sed 's/^/    /'
echo "  certificado actual:"
openssl x509 -in wazuh.dashboard.pem -noout -subject -ext subjectAltName 2>/dev/null | sed 's/^/    /'

# --- 1. todo en /tmp, donde si se puede escribir -----------------------------
openssl req -new -nodes -newkey rsa:2048 \
  -keyout /tmp/dashboard-key.pem \
  -out /tmp/dashboard.csr \
  -subj "/C=US/L=California/O=Wazuh/OU=Wazuh/CN=wazuh.dashboard" \
  -addext "subjectAltName=${SAN}"

# Mismas extensiones que el template oficial + las SAN ampliadas
cat > /tmp/dashboard.ext <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints = CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = ${SAN}
EOF

openssl x509 -req -in /tmp/dashboard.csr \
  -CA root-ca.pem -CAkey root-ca.key -CAcreateserial \
  -out /tmp/dashboard.pem -days 3650 \
  -extfile /tmp/dashboard.ext

# --- 2. guardas antes de tocar nada que este en uso --------------------------
# Firma por nuestra CA: si no, el panel dejaria de validar contra el root-ca.
iss=$(openssl x509 -in /tmp/dashboard.pem -noout -issuer)
case "${iss}" in
  *Wazuh*) : ;;
  *)       echo "  FALLO: issuer inesperado: ${iss}"; exit 1 ;;
esac
# Que la clave y el certificado formen pareja: si no, el TLS no arranca.
ck_pub=$(openssl x509 -in /tmp/dashboard.pem   -noout -pubkey | openssl md5)
ck_key=$(openssl pkey  -in /tmp/dashboard-key.pem -pubout | openssl md5)
if [ "${ck_pub}" != "${ck_key}" ]; then
  echo "  FALLO: la clave nueva no corresponde al certificado nuevo"
  exit 1
fi

# --- 3. reemplazo ------------------------------------------------------------
rm -f wazuh.dashboard-key.pem wazuh.dashboard.pem
cp /tmp/dashboard-key.pem wazuh.dashboard-key.pem
cp /tmp/dashboard.pem     wazuh.dashboard.pem

# Restaura dueno y permisos: UID 1000 (el del contenedor del panel) y modo
# 400, exactamente como los dejaba wazuh-certs-tool.sh. Si se queda en root
# 600 el panel no puede leer su propia clave.
chown 1000:1000 wazuh.dashboard-key.pem wazuh.dashboard.pem
chmod 400 wazuh.dashboard-key.pem wazuh.dashboard.pem

echo "  certificado nuevo:"
openssl x509 -in wazuh.dashboard.pem -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/    /'
ls -l wazuh.dashboard.pem wazuh.dashboard-key.pem | sed 's/^/    /'
echo "  OK"
