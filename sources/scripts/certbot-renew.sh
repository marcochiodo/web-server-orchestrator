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

sudo docker run -it --rm --name certbot \
  -v "$ROOT_DIR/data/letsencrypt:/etc/letsencrypt" \
  -v "$ROOT_DIR/data/letsencrypt-lib:/var/lib/letsencrypt" \
  -v "$ROOT_DIR/static/default:/srv/webroot" \
  certbot/certbot renew
