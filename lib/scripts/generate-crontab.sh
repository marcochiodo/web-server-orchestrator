#!/bin/sh
set -eu

# generate-crontab.sh - Generate crontab from manifest cron_jobs
# Usage: generate-crontab.sh <service-name> <manifest-path> <output-file>
#
# This script reads the 'cron_jobs' array from a WSO manifest and generates
# a crontab file with:
# - Proper cron.d format with user specification (root)
# - Environment variables loaded from /var/lib/wso/secrets/ (root-only readable)
# - Commands executed as deployer user for security
# - Each job with schedule, secrets, and command

log() {
    printf "[generate-crontab] %s\n" "$*" >&2
}

error() {
    printf "[generate-crontab ERROR] %s\n" "$*" >&2
}

die() {
    error "$@"
    exit 1
}

check_yq() {
    if ! command -v yq >/dev/null 2>&1; then
        die "yq is not installed. Install with: sudo dnf install yq"
    fi

    # Detect yq version (Go vs Python)
    if yq --help 2>&1 | grep -q "eval"; then
        YQ_TYPE="go"
    else
        YQ_TYPE="python"
    fi
}

# =============================================================================
# Setup
# =============================================================================

if [ $# -ne 3 ]; then
    cat >&2 <<EOF
Usage: $0 <service-name> <manifest-path> <output-file>

Example:
  $0 myapp-staging /tmp/manifest.yml /tmp/crontab.txt

This script generates crontab from the 'cron_jobs' array in the manifest.
EOF
    exit 1
fi

check_yq

SERVICE_NAME="$1"
MANIFEST_PATH="$2"
OUTPUT_FILE="$3"

# WSO Paths (hardcoded)
readonly SECRETS_DIR="/var/lib/wso/secrets"

if [ ! -f "$MANIFEST_PATH" ]; then
    die "Manifest file not found: $MANIFEST_PATH"
fi

# =============================================================================
# Parse Manifest
# =============================================================================

parse_manifest() {
    if [ "$YQ_TYPE" = "go" ]; then
        yq eval "$1" "$MANIFEST_PATH"
    else
        yq -r "$1" "$MANIFEST_PATH"
    fi
}

log "Parsing manifest: $MANIFEST_PATH"

JOBS_COUNT="$(parse_manifest '.cron_jobs | length')"

if [ "$JOBS_COUNT" = "0" ] || [ "$JOBS_COUNT" = "null" ]; then
    log "No cron jobs defined in manifest"
    # Create empty file
    touch "$OUTPUT_FILE"
    log "Empty crontab created: $OUTPUT_FILE"
    exit 0
fi

log "  Service: $SERVICE_NAME"
log "  Cron jobs: $JOBS_COUNT"

# =============================================================================
# Generate Crontab
# =============================================================================

TEMP_OUTPUT="/tmp/${SERVICE_NAME}-crontab-gen-$$.txt"

# Header
cat > "$TEMP_OUTPUT" <<EOF
# Crontab for service: $SERVICE_NAME
# Generated automatically by WSO from manifest cron_jobs
# Do not edit manually - changes will be overwritten on next deployment
#
# Format: minute hour day month weekday user command

SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

EOF

# =============================================================================
# Generate cron jobs
# =============================================================================

log "Generating cron jobs..."

i=0
while [ $i -lt "$JOBS_COUNT" ]; do
    SCHEDULE="$(parse_manifest ".cron_jobs[$i].schedule")"
    COMMAND="$(parse_manifest ".cron_jobs[$i].command")"
    SECRETS_KEYS="$(parse_manifest ".cron_jobs[$i].secrets | keys | .[]" 2>/dev/null || echo "")"

    if [ -z "$SCHEDULE" ] || [ "$SCHEDULE" = "null" ]; then
        error "Schedule at index $i is empty or null, skipping"
        i=$((i + 1))
        continue
    fi

    if [ -z "$COMMAND" ] || [ "$COMMAND" = "null" ]; then
        error "Command at index $i is empty or null, skipping"
        i=$((i + 1))
        continue
    fi

    log "  Job $((i + 1)): $SCHEDULE"

    # Build secrets loading and export for sudo
    SECRETS_LOAD=""
    SECRETS_EXPORT=""

    if [ -n "$SECRETS_KEYS" ]; then
        for secret_key in $SECRETS_KEYS; do
            SECRET_VALUE="$(parse_manifest ".cron_jobs[$i].secrets.${secret_key}")"

            if [ -z "$SECRET_VALUE" ] || [ "$SECRET_VALUE" = "null" ]; then
                error "  Secret '$secret_key' value is empty, skipping"
                continue
            fi

            log "    - Secret: $secret_key -> $SECRET_VALUE"

            # Build secrets loading (read from file as root)
            SECRET_FILE="${SECRETS_DIR}/${SERVICE_NAME}_${SECRET_VALUE}"
            if [ -z "$SECRETS_LOAD" ]; then
                SECRETS_LOAD="${secret_key}=\$(cat ${SECRET_FILE})"
            else
                SECRETS_LOAD="${SECRETS_LOAD} && ${secret_key}=\$(cat ${SECRET_FILE})"
            fi

            # Build secrets export for sudo (pass env vars)
            if [ -z "$SECRETS_EXPORT" ]; then
                SECRETS_EXPORT="${secret_key}=\"\$${secret_key}\""
            else
                SECRETS_EXPORT="${SECRETS_EXPORT} ${secret_key}=\"\$${secret_key}\""
            fi
        done
    fi

    # Build final command
    # Run as root to load secrets, then switch to deployer for execution
    if [ -n "$SECRETS_LOAD" ]; then
        FULL_COMMAND="sh -c '${SECRETS_LOAD} && sudo -u deployer ${SECRETS_EXPORT} sh -c \"${COMMAND}\"'"
    else
        FULL_COMMAND="sudo -u deployer sh -c \"${COMMAND}\""
    fi

    # Write cron line (user is root to read secrets)
    cat >> "$TEMP_OUTPUT" <<EOF

# Job $((i + 1))
${SCHEDULE} root ${FULL_COMMAND}
EOF

    i=$((i + 1))
done

# Add empty line at end
echo "" >> "$TEMP_OUTPUT"

# =============================================================================
# Save output
# =============================================================================

mv "$TEMP_OUTPUT" "$OUTPUT_FILE" || die "Failed to save output to $OUTPUT_FILE"

log "Crontab generated successfully: $OUTPUT_FILE"
log "Jobs: $JOBS_COUNT"
exit 0
