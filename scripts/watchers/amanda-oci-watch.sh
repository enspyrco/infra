#!/usr/bin/env bash
# Amanda OCI box watcher — pings Telegram the moment amandas-oci lands, then
# self-disables. Companion to the retry provisioner (which does the launching).
#
# Cron: */10 * * * * /opt/scripts/watchers/amanda-oci-watch.sh  # amanda-oci-watch

set -euo pipefail

# shellcheck disable=SC2034  # consumed by watcher-base.sh after sourcing
WATCHER_NAME="amanda-oci-watch"
# shellcheck disable=SC2034
CRON_TAG="amanda-oci-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090  # dynamic path; resolved at runtime
source "$__lib"
unset __lib

# Amanda's tenancy OCID is NOT hardcoded: this repo is public, and the OCID
# belongs to a third party who did not choose to publish it. It lives in a 0600
# env file beside the other watcher credentials. Fail closed and loud if absent
# — a watcher that silently reports "not up yet" because it lost its tenancy id
# is worse than one that errors.
OCI_ENV_FILE="$CONFIG_DIR/oci-accounts.env"
# shellcheck source=/dev/null
[[ -r "$OCI_ENV_FILE" ]] && { set -a; . "$OCI_ENV_FILE"; set +a; }
: "${AMANDA_TENANCY_OCID:?missing AMANDA_TENANCY_OCID (expected in $OCI_ENV_FILE)}"

TENANCY="$AMANDA_TENANCY_OCID"
PROFILE="${AMANDA_OCI_PROFILE:-AMANDA}"
REGION="${AMANDA_OCI_REGION:-ap-melbourne-1}"
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

# phase_a_check — has amandas-oci landed WITH a reachable address?
#
#   0 → landed, alert delivery CONFIRMED (state advances; B then self-disables)
#   1 → genuinely not up yet (an OCI call that succeeded and returned no instance)
#   2 → transient: we could not tell. Retry next cycle, never self-disable.
#
# Return 2 is doing real work here. The previous version ran the OCI call as
# `oci ... 2>/dev/null || echo '{"data":[]}'`, which rendered expired
# credentials, a missing AMANDA profile, `oci` absent from cron's PATH, a wrong
# region, and a 401/403 all IDENTICAL to "no RUNNING instance" — the watcher
# would log "not up yet" forever while nothing was actually being watched. Only
# a SUCCESSFUL call returning zero instances may mean "not up yet".
phase_a_check() {
    local instances rc=0
    instances=$(oci compute instance list --profile "$PROFILE" --region "$REGION" \
        --compartment-id "$TENANCY" --display-name "amandas-oci" \
        --lifecycle-state RUNNING 2>&1) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        log "oci list FAILED (rc=$rc) — cannot distinguish 'not up' from broken creds/PATH/region: ${instances//$'\n'/ }"
        return 2
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$instances"; then
        log "oci list returned non-JSON — treating as transient: ${instances//$'\n'/ }"
        return 2
    fi

    local iid
    iid=$(jq -r '.data[0].id // empty' <<<"$instances")
    if [[ -z "$iid" ]]; then
        log "not up yet (successful query, no RUNNING amandas-oci)"
        return 1
    fi

    local ocpus ip vnics
    ocpus=$(jq -r '.data[0]."shape-config".ocpus // "?"' <<<"$instances")
    vnics=$(oci compute instance list-vnics --profile "$PROFILE" --region "$REGION" \
        --instance-id "$iid" 2>&1) || {
        log "instance $iid is RUNNING but list-vnics failed — retrying for the address"
        return 2
    }
    ip=$(jq -r '.data[0]."public-ip" // empty' <<<"$vnics" 2>/dev/null || true)
    # RUNNING-with-no-address is a PHASE, not a destination. The address is the
    # whole point of the alert, so firing on a placeholder would announce
    # `ssh ubuntu@pending` and then self-disable, never to fire again.
    if [[ -z "$ip" || "$ip" == "pending" || "$ip" == "null" ]]; then
        log "instance $iid RUNNING but public IP not assigned yet — waiting"
        return 2
    fi

    # Only advance once the alert is CONFIRMED delivered. An unconfirmed send
    # followed by self-disable is the silent-loss failure this watcher exists to
    # prevent: the box lands, the message is dropped, the watcher switches
    # itself off, and nobody ever learns.
    if tg_confirmed "🎉 <b>Amanda's OCI box landed!</b> amandas-oci is RUNNING at <code>$(html_escape "$ip")</code> (${ocpus} OCPU, ${REGION}). SSH: <code>ssh ubuntu@$(html_escape "$ip")</code> with the enspyr key. Provisioner will resize it up to its 2/12 cap next cycle."; then
        log "LANDED: amandas-oci ${ocpus} OCPU at ${ip} (alert delivery confirmed)"
        return 0
    fi
    log "LANDED: amandas-oci at ${ip}, but alert delivery NOT confirmed — retrying, staying enabled"
    return 2
}

# Single-phase watcher: phase A is the whole job, so B is a no-op that lets the
# base state machine advance to DONE and self-disable on the next tick.
phase_b_check() { return 0; }

run_watcher
