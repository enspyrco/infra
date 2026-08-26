#!/usr/bin/env bash
# Amanda OCI box watcher — pings Telegram the moment amandas-oci lands, then
# self-disables. Companion to the retry provisioner (which does the launching).
set -euo pipefail
CONFIG_DIR="$HOME/.config/imagineering"
CRED_FILE="$CONFIG_DIR/notify-credentials"
LOG_FILE="$HOME/amanda-oci-watch.log"
CRON_TAG="amanda-oci-watch"
# Amanda's tenancy OCID is NOT hardcoded here: this repo is public, and the
# OCID belongs to a third party who did not choose to publish it. It lives in
# a 0600 env file on the box beside the other watcher credentials. Fail closed
# and loud if absent — a watcher that silently reports "not up yet" because it
# lost its tenancy id is worse than one that errors.
OCI_ENV_FILE="$CONFIG_DIR/oci-accounts.env"
# shellcheck source=/dev/null
[ -r "$OCI_ENV_FILE" ] && { set -a; . "$OCI_ENV_FILE"; set +a; }
: "${AMANDA_TENANCY_OCID:?missing AMANDA_TENANCY_OCID (expected in $OCI_ENV_FILE)}"
TENANCY="$AMANDA_TENANCY_OCID"
PROFILE="AMANDA"
REGION="ap-melbourne-1"
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
set -a
# shellcheck source=/dev/null  # must sit on the source line's OWN line: after a
# `set -a;` prefix the directive binds to that command and never reaches source.
source "$CRED_FILE"
set +a
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }
tg() {
    local message="$1" payload
    payload=$(jq -n --arg t "$message" '{message:$t, parse_mode:"HTML"}')
    curl -s -X POST "${NOTIFY_URL}/send" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${NOTIFY_API_KEY}" \
        -d "$payload" | jq -r '"tg-result: ok=\(.ok) err=\(.description // "-")"' >> "$LOG_FILE" 2>&1 || true
}
INSTANCES=$(oci compute instance list --profile "$PROFILE" --region "$REGION" \
    --compartment-id "$TENANCY" --display-name "amandas-oci" \
    --lifecycle-state RUNNING 2>/dev/null || echo '{"data":[]}')
IID=$(echo "$INSTANCES" | jq -r '.data[0].id // empty')
if [ -z "$IID" ]; then
    log "not up yet (no RUNNING amandas-oci)"; exit 0
fi
OCPUS=$(echo "$INSTANCES" | jq -r '.data[0]."shape-config".ocpus')
IP=$(oci compute instance list-vnics --profile "$PROFILE" --region "$REGION" \
    --instance-id "$IID" 2>/dev/null | jq -r '.data[0]."public-ip" // "pending"')
log "LANDED: amandas-oci ${OCPUS} OCPU at ${IP}"
tg "🎉 <b>Amanda's OCI box landed!</b> amandas-oci is RUNNING at <code>${IP}</code> (${OCPUS} OCPU, Melbourne). SSH: <code>ssh ubuntu@${IP}</code> with the enspyr key. Provisioner will resize it up to its 2/12 cap next cycle."
crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
log "self-disabled cron"
