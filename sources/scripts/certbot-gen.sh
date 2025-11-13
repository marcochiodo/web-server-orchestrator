#!/bin/sh

# Find WSO installation directory
if [ -d /srv/wso/static/default ]; then
    ROOT_DIR="/srv/wso"
elif [ -d /srv/static/default ]; then
    ROOT_DIR="/srv"
else
    echo "Error: Cannot find WSO installation" >&2
    exit 1
fi

# Verifica che sia stato fornito almeno un argomento
if [ -z "$1" ]; then
    echo "Uso: $0 domain1.com,domain2.com,..."
    exit 1
fi

# Salva la stringa dei domini
domains="$1"

# Costruisce la lista di parametri -d per ogni dominio
domain_args=""
IFS=','
for domain in $domains; do
    domain_args="$domain_args -d $domain"
done
unset IFS

# Esegue il comando docker con tutti i domini
sudo docker run -it --rm --name certbot \
  -v "$ROOT_DIR/data/letsencrypt:/etc/letsencrypt" \
  -v "$ROOT_DIR/data/letsencrypt-lib:/var/lib/letsencrypt" \
  -v "$ROOT_DIR/static/default:/srv/webroot" \
  certbot/certbot certonly --webroot -w /srv/webroot$domain_args
