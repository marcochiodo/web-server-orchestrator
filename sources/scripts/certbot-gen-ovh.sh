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

# Ensure secrets directory exists
mkdir -p "$ROOT_DIR/data/secrets/certbot"

# Verifica che sia stato fornito almeno un argomento
if [ -z "$1" ]; then
    echo "Uso: $0 domain1.com,domain2.com,..."
    echo ""
    echo "Questo script genera certificati SSL usando OVH DNS-01 challenge."
    echo "Supporta wildcard domains (es: *.chdev.eu)"
    exit 1
fi

# Path del file delle credenziali OVH
OVH_INI_FILE="$ROOT_DIR/data/secrets/certbot/ovh.ini"

# Se il file ovh.ini non esiste, chiedi le credenziali
if [ ! -f "$OVH_INI_FILE" ]; then
    echo ""
    echo "==================================================================="
    echo "OVH API Credentials Setup"
    echo "==================================================================="
    echo ""
    echo "Il file delle credenziali OVH non esiste."
    echo "Per generare certificati wildcard è necessario configurare l'accesso alle API OVH."
    echo ""
    echo "Ottieni le credenziali da:"
    echo "  - Europa: https://eu.api.ovh.com/createToken/"
    echo "  - Nord America: https://ca.api.ovh.com/createToken/"
    echo ""
    echo "Permessi richiesti:"
    echo "  - GET  /domain/zone/*"
    echo "  - PUT /domain/zone/*"
    echo "  - POST /domain/zone/*"
    echo "  - DELETE /domain/zone/*"
    echo ""

    # Ask for OVH endpoint
    echo "Seleziona l'endpoint OVH:"
    echo "  1) ovh-eu (Europe)"
    echo "  2) ovh-ca (North America)"
    printf "Scelta [1]: "
    read ovh_endpoint_choice
    ovh_endpoint_choice=${ovh_endpoint_choice:-1}

    case "$ovh_endpoint_choice" in
        1)
            OVH_ENDPOINT="ovh-eu"
            ;;
        2)
            OVH_ENDPOINT="ovh-ca"
            ;;
        *)
            echo "Scelta non valida. Uso ovh-eu"
            OVH_ENDPOINT="ovh-eu"
            ;;
    esac

    echo ""
    echo "Endpoint selezionato: $OVH_ENDPOINT"
    echo ""

    # Ask for OVH credentials
    printf "Application Key: "
    read OVH_APP_KEY
    printf "Application Secret: "
    read OVH_APP_SECRET
    printf "Consumer Key: "
    read OVH_CONSUMER_KEY

    # Validate that credentials are not empty
    if [ -z "$OVH_APP_KEY" ] || [ -z "$OVH_APP_SECRET" ] || [ -z "$OVH_CONSUMER_KEY" ]; then
        echo "Errore: Tutte le credenziali sono obbligatorie" >&2
        exit 1
    fi

    # Create ovh.ini file
    cat > "$OVH_INI_FILE" <<EOF
# OVH API credentials for certbot-dns-ovh
dns_ovh_endpoint = $OVH_ENDPOINT
dns_ovh_application_key = $OVH_APP_KEY
dns_ovh_application_secret = $OVH_APP_SECRET
dns_ovh_consumer_key = $OVH_CONSUMER_KEY
EOF

    # Set secure permissions (600)
    chmod 600 "$OVH_INI_FILE"
    echo ""
    echo "Credenziali salvate in: $OVH_INI_FILE (permessi: 600)"
    echo ""
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

# Esegue il comando docker con tutti i domini usando DNS-01 challenge
echo "Generazione certificato per:$domain_args"
echo ""

sudo docker run -it --rm --name certbot-ovh \
  -v "$ROOT_DIR/data/letsencrypt:/etc/letsencrypt" \
  -v "$ROOT_DIR/data/letsencrypt-lib:/var/lib/letsencrypt" \
  -v "$ROOT_DIR/data/secrets/certbot:/secrets/certbot:ro" \
  certbot/dns-ovh certonly \
  --dns-ovh \
  --dns-ovh-credentials /secrets/certbot/ovh.ini \
  $domain_args
