#!/bin/bash
# OCI auto-provisioning — keeps retrying until it grabs an ARM (Ampere A1)
# instance, then resizes it up to the target size.
#
# Lineage: reconciled 2026-07-28 to match the deployed (no-cloud-init) variant
# that actually provisioned Robin's and Amanda's Melbourne boxes. Instances get
# the OCI-default 'ubuntu' user; SSH keys come from $AUTHORIZED_KEYS_FILE
# (one key per line). The older cloud-init/--user-data-file lineage was dropped
# because it had already diverged from what runs in production.
#
# Strategy:
#   1. Detect the tenancy's ACTUAL A1 allotment. Oracle has reduced the Always
#      Free A1 grant for some newer tenancies from 4 OCPU/24GB to 2 OCPU/12GB,
#      so we never assume 4/24 — the target is capped to what the tenancy
#      genuinely allows, and a warning is logged when that's below the request.
#   2. Try small (1 OCPU/6GB) first — far easier to place when A1 hosts are tight.
#   3. Once a small instance exists, resize it to the (capped) full target.
#   4. When every account is at its full target, disable the cron job.
#   5. Random jitter to avoid a predictable request pattern.

LOG=~/oci-provision.log
LOCK=/tmp/oci-provision.lock
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACCOUNTS_FILE="$SCRIPT_DIR/accounts.yaml"
AUTHORIZED_KEYS_FILE="$SCRIPT_DIR/authorized_keys"

# What we aim for (per-account override via accounts.yaml full_ocpus/full_mem)
SMALL_OCPUS=1
SMALL_MEM=6
DEFAULT_FULL_OCPUS=4
A1_MEM_PER_OCPU=6   # Always Free ratio: 6 GB RAM per OCPU (memory tracks cores)

log() { echo "$(date): $*" >> "$LOG"; }

# Floor-integer count of A1 OCPUs still available in this tenancy/AD (limit
# minus current usage). Region comes from the profile. Empty on query failure,
# in which case callers fall back to the requested size (reactive handling below
# still catches a LimitExceeded).
a1_available_ocpus() {
    local profile="$1" compartment="$2" ad="$3"
    oci limits resource-availability get \
        --profile "$profile" \
        --service-name compute --limit-name standard-a1-core-count \
        --compartment-id "$compartment" --availability-domain "$ad" 2>/dev/null \
        | jq -r '.data.available // empty' | cut -d. -f1
}

# Smaller of two integers
min() { if [ "$1" -le "$2" ]; then echo "$1"; else echo "$2"; fi; }

# ── Prevent two copies running at once ──
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

# ── Random jitter: 0-90 seconds (avoids a predictable request pattern) ──
JITTER=$((RANDOM % 90))
log "Sleeping ${JITTER}s jitter..."
sleep "$JITTER"

# ── Check dependencies ──
if ! command -v yq &> /dev/null; then
    log "ERROR: yq not installed. Run: pip3 install yq"
    exit 1
fi
if ! command -v oci &> /dev/null; then
    log "ERROR: oci CLI not on PATH (expected in ~/bin or ~/.local/bin)."
    exit 1
fi
if [ ! -f "$AUTHORIZED_KEYS_FILE" ]; then
    log "ERROR: authorized_keys file missing at $AUTHORIZED_KEYS_FILE"
    exit 1
fi

all_done=true
NUM_ACCOUNTS=$(yq -r '.accounts | length' "$ACCOUNTS_FILE")

for i in $(seq 0 $((NUM_ACCOUNTS - 1))); do
    NAME=$(yq -r ".accounts[$i].name" "$ACCOUNTS_FILE")
    PROFILE=$(yq -r ".accounts[$i].profile" "$ACCOUNTS_FILE")
    COMPARTMENT_ID=$(yq -r ".accounts[$i].compartment_id" "$ACCOUNTS_FILE")
    SUBNET_ID=$(yq -r ".accounts[$i].subnet_id" "$ACCOUNTS_FILE")
    IMAGE_ID=$(yq -r ".accounts[$i].image_id" "$ACCOUNTS_FILE")
    AVAILABILITY_DOMAIN=$(yq -r ".accounts[$i].availability_domain" "$ACCOUNTS_FILE")
    INSTANCE_NAME=$(yq -r ".accounts[$i].instance_name" "$ACCOUNTS_FILE")
    FULL_OCPUS=$(yq -r ".accounts[$i].full_ocpus // $DEFAULT_FULL_OCPUS" "$ACCOUNTS_FILE")

    if [[ "$COMPARTMENT_ID" == *"REPLACE"* ]] || [[ "$COMPARTMENT_ID" == *"paste"* ]]; then
        log "[$NAME] Skipping - not configured yet"
        continue
    fi

    # ── Detect the tenancy's real A1 allotment (available OCPUs right now) ──
    AVAIL=$(a1_available_ocpus "$PROFILE" "$COMPARTMENT_ID" "$AVAILABILITY_DOMAIN")

    log "[$NAME] Checking for existing instance..."

    INSTANCE_JSON=$(oci compute instance list \
        --profile "$PROFILE" \
        --compartment-id "$COMPARTMENT_ID" \
        --display-name "$INSTANCE_NAME" 2>/dev/null || echo '{"data":[]}')

    RUNNING_ID=$(echo "$INSTANCE_JSON" | jq -r \
        '[.data[] | select(.["lifecycle-state"] == "RUNNING" or .["lifecycle-state"] == "PROVISIONING")] | .[0].id // empty')

    if [ -n "$RUNNING_ID" ]; then
        # ── Instance exists — decide whether it still needs resizing ──
        CURRENT_OCPUS=$(echo "$INSTANCE_JSON" | jq -r \
            "[.data[] | select(.id == \"$RUNNING_ID\")] | .[0][\"shape-config\"].ocpus // 0" | cut -d. -f1)

        # Cap the target to what the tenancy allows: total = available + what
        # this instance already uses. Fall back to the request if the quota
        # query failed.
        if [ -n "$AVAIL" ]; then
            TOTAL_ALLOWED=$((AVAIL + CURRENT_OCPUS))
            EFF_OCPUS=$(min "$FULL_OCPUS" "$TOTAL_ALLOWED")
        else
            EFF_OCPUS=$FULL_OCPUS
        fi
        EFF_MEM=$((EFF_OCPUS * A1_MEM_PER_OCPU))
        if [ "$EFF_OCPUS" -lt "$FULL_OCPUS" ]; then
            log "[$NAME] ⚠️ A1 allotment reduced: tenancy allows ${TOTAL_ALLOWED} OCPU (requested ${FULL_OCPUS}). Capping target to ${EFF_OCPUS}/${EFF_MEM}GB."
        fi

        if [ "$CURRENT_OCPUS" -ge "$EFF_OCPUS" ]; then
            IP=$(oci compute instance list-vnics \
                --profile "$PROFILE" \
                --instance-id "$RUNNING_ID" 2>/dev/null | jq -r '.data[0]["public-ip"] // "pending"')
            log "[$NAME] ✅ Instance running at target (${CURRENT_OCPUS} OCPU) at $IP — nothing to do!"
            continue
        fi

        LIFECYCLE=$(echo "$INSTANCE_JSON" | jq -r \
            "[.data[] | select(.id == \"$RUNNING_ID\")] | .[0][\"lifecycle-state\"]")

        if [ "$LIFECYCLE" = "RUNNING" ]; then
            log "[$NAME] Instance at ${CURRENT_OCPUS} OCPU. Resizing to ${EFF_OCPUS}/${EFF_MEM}GB..."

            RESIZE_OUTPUT=$(oci compute instance update \
                --profile "$PROFILE" \
                --instance-id "$RUNNING_ID" \
                --shape-config "{\"ocpus\": $EFF_OCPUS, \"memoryInGBs\": $EFF_MEM}" \
                --force 2>&1)

            if echo "$RESIZE_OUTPUT" | grep -qi "error\|ServiceError"; then
                log "[$NAME] Resize failed (probably still out of capacity). Will retry next cycle."
                all_done=false
            else
                log "[$NAME] 🎉 Resize initiated! Instance will reboot with ${EFF_OCPUS} OCPU."
            fi
        else
            log "[$NAME] Instance in $LIFECYCLE state, waiting..."
            all_done=false
        fi
        continue
    fi

    # ── No instance yet ──
    all_done=false

    # If the tenancy can't even fit the small size, a retry loop is pointless —
    # this is a quota problem, not a capacity one. Flag it and move on.
    if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$SMALL_OCPUS" ]; then
        log "[$NAME] A1 quota exhausted (available=${AVAIL} OCPU, need ${SMALL_OCPUS}). Request a limit increase in the OCI console (Limits, Quotas and Usage). Skipping."
        continue
    fi

    log "[$NAME] No instance found. Trying ${SMALL_OCPUS} OCPU / ${SMALL_MEM}GB..."

    OUTPUT=$(SUPPRESS_LABEL_WARNING=True oci compute instance launch \
        --profile "$PROFILE" \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --shape "VM.Standard.A1.Flex" \
        --shape-config "{\"ocpus\": $SMALL_OCPUS, \"memoryInGBs\": $SMALL_MEM}" \
        --subnet-id "$SUBNET_ID" \
        --image-id "$IMAGE_ID" \
        --display-name "$INSTANCE_NAME" \
        --assign-public-ip true \
        --ssh-authorized-keys-file "$AUTHORIZED_KEYS_FILE" \
        --boot-volume-size-in-gbs 50 2>&1)

    if echo "$OUTPUT" | grep -qi "Out of capacity\|out of host capacity"; then
        log "[$NAME] Out of capacity — will retry in 5 minutes..."
    elif echo "$OUTPUT" | grep -qi "TooManyRequests"; then
        log "[$NAME] Rate limited (429) — backing off 60s..."
        sleep 60
    elif echo "$OUTPUT" | grep -qi "LimitExceeded"; then
        log "[$NAME] Service limit exceeded even at ${SMALL_OCPUS} OCPU — A1 quota is likely 0. Request a limit increase. Skipping."
    elif echo "$OUTPUT" | grep -qi "error\|failed\|ServiceError"; then
        ERROR_MSG=$(echo "$OUTPUT" | jq -r '.message // empty' 2>/dev/null || echo "$OUTPUT" | head -2)
        log "[$NAME] Error: $ERROR_MSG"
    else
        INSTANCE_ID=$(echo "$OUTPUT" | jq -r '.data.id // empty')
        log "[$NAME] 🎉 Small instance created! (ID: $INSTANCE_ID) — will resize next cycle."
    fi
done

# ── If everything is at its (capped) full target, we're done — disable cron ──
if $all_done; then
    log "All instances at target size! Disabling cron job. 🎊"
    crontab -l | grep -v "retry-provision" | crontab -
fi

log "Provisioning cycle complete."
