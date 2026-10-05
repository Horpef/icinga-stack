FROM icinga/icingaweb2:latest

# The image runs as the unprivileged user `www-data`, therefore everything
# below needs an explicit `USER root` and HTTPS must use an unprivileged
# port (8443 instead of 443).
USER root

# --- self signed TLS certificate ---------------------------------------------
# Apache runs as the unprivileged user `www-data`, so the key must be
# readable by that user and the directory must be traversable for it.
RUN mkdir -p /etc/ssl/private \
 && openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/ssl/private/ssl-cert-snakeoil.key \
      -out /etc/ssl/certs/ssl-cert-snakeoil.pem \
      -subj "/C=DE/ST=Local/L=Local/O=Icinga/OU=Monitoring/CN=localhost" \
 && chmod 711 /etc/ssl/private \
 && chown root:www-data /etc/ssl/private/ssl-cert-snakeoil.key \
 && chmod 640 /etc/ssl/private/ssl-cert-snakeoil.key \
 && chmod 644 /etc/ssl/certs/ssl-cert-snakeoil.pem

# --- Apache: plain HTTP on 8080 + HTTPS on 8443 ------------------------------
# The stock ports.conf also contains `Listen 443` inside <IfModule ssl_module>,
# which would make Apache fail to start as www-data. Replace it completely.
COPY icingaweb2-ssl.conf /etc/apache2/sites-available/icingaweb2-ssl.conf
# Apache runs as www-data and /var/log/apache2 is root owned in the image,
# so the new vhost log files have to be created up front.
RUN a2enmod ssl \
 && a2ensite icingaweb2-ssl \
 && printf 'Listen 8080\nListen 8443\n' > /etc/apache2/ports.conf \
 && touch /var/log/apache2/error-ssl.log /var/log/apache2/access-ssl.log \
 && chown -R www-data:www-data /var/log/apache2

USER www-data
