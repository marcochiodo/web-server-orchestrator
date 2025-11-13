#!/bin/sh
set -eu

# Find WSO installation directory
if [ -d /srv/wso/services ]; then
    ROOT_DIR="/srv/wso"
elif [ -d /srv/services ]; then
    ROOT_DIR="/srv"
else
    echo "Error: Cannot find WSO installation" >&2
    exit 1
fi

# Percorso base dei servizi
BASE="$ROOT_DIR/services"

# 1) Verifica presenza parametro
if [ $# -lt 1 ]; then
  printf "Uso: %s <project> [args...]\n" "$(basename "$0")" >&2
  printf "Esempio: %s myapp staging\n" "$(basename "$0")" >&2
  exit 1
fi

project="$1"
shift  # Rimuove il primo parametro, lasciando gli altri in $@

# 2) Valida il nome progetto: solo lettere, numeri, trattino e underscore (niente slash o ..)
case "$project" in
  *[!/0-9A-Za-z_-]*|""|*/*|*..*)
    echo "Nome progetto non valido." >&2
    exit 1
    ;;
esac

# 3) Costruisci percorso script di deploy del progetto
target="$BASE/$project/deploy.sh"

# 4) Controlla che esista ed è leggibile/eseguibile
if [ ! -f "$target" ]; then
  echo "Script non trovato: $target" >&2
  exit 1
fi

# 5) Esporta ROOT_DIR per lo script di deploy
export ROOT_DIR

# 6) Esegue lo script passando tutti i parametri rimanenti
if [ ! -x "$target" ]; then
  # Se non è eseguibile, prova tramite sh mantenendo sicurezza
  exec /bin/sh "$target" "$@"
else
  exec "$target" "$@"
fi
