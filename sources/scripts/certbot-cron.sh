#!/bin/sh

# Find WSO installation directory
if [ -f /srv/wso/scripts/certbot-renew.sh ]; then
    ROOT_DIR="/srv/wso"
elif [ -f /srv/scripts/certbot-renew.sh ]; then
    ROOT_DIR="/srv"
else
    echo "Error: Cannot find WSO installation" >&2
    exit 1
fi

sh "$ROOT_DIR/scripts/certbot-renew.sh"