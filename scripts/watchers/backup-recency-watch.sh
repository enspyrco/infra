#!/usr/bin/env bash
# Backup-freshness watcher — asserts EVERY expected service produced an artifact.
#
# WHAT IT REPLACES, and why the replacement is not a tuning change:
#
# The previous version asked "is the newest file in /tmp/backups younger than 25
# hours". That is an ANY check wearing an ALL check's name. Through the
# 2026-09-05..09-11 outage, seven services produced nothing while four backed up
# perfectly every night, so the newest file in the directory was always ~4h old at
# check time. It would have reported healthy on all seven nights. Verified against
# the artifacts still on disk:
#
#     2026-09-08  kanbn=1  matrix-signal=0  aiko-island=0
#     2026-09-09  kanbn=1  matrix-signal=0  aiko-island=0
#     2026-09-10  kanbn=1  matrix-signal=0  aiko-island=0
#     newest 09-09 artifact: minio-2026-09-09.tar.gz   <- what the old check saw
#
# It also never ran: no cron entry, no state file, no log, on either box account.
# So the seven nights were not a case of a watcher being fooled — nothing was
# watching, and the thing that would have watched was blind anyway.
#
# WHY IT DOES NOT USE run_watcher: that is a two-phase INCIDENT machine — alert,
# confirm recovery, then self_disable and delete its own cron entry. Correct for
# "chase this one problem until it is fixed"; wrong for a standing safety
# assertion, which must still be asserting a year from now. A backup check that
# removes itself after its first recovery is a fire alarm that unhooks itself
# after the first fire. So this drives its own edge-triggered loop and never
# self-disables.
#
# Cron (installed by deploy-to.sh; see scripts/watchers/README.md):
#   0 8 * * * /opt/scripts/watchers/backup-recency-watch.sh
# 08:00 local, four hours after the 04:00 backup window, so a slow run is not
# mistaken for a failed one.

set -euo pipefail

# shellcheck disable=SC2034
WATCHER_NAME="backup-recency-watch"
# shellcheck disable=SC2034
CRON_TAG="backup-recency-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

# diagnose.sh supplies html_escape and tail_backup_log. Dropping it while still
# CALLING html_escape would kill the recovery path under `set -e` — and only the
# recovery path, so the alert would work and the all-clear would silently never
# arrive. Caught before shipping by grepping where the helpers are defined rather
# than assuming they came with watcher-base.
__diag="$(dirname "$0")/lib/diagnose.sh"
[[ -r "$__diag" ]] || __diag="$HOME/lib/diagnose.sh"
# shellcheck disable=SC1090
source "$__diag"
unset __diag

__svc="$(dirname "$0")/../lib/backup-services.sh"
[[ -r "$__svc" ]] || __svc="$HOME/lib/backup-services.sh"
# shellcheck disable=SC1090
source "$__svc"
unset __svc

BACKUP_DIR="${BACKUP_DIR:-/tmp/backups}"
STALE_HOURS="${STALE_HOURS:-25}"

# Local artifacts rather than the GitHub repo, for the reason the previous version
# documented and which still holds: backup.sh runs as `nick` with a deploy key, and
# querying GitHub from the watcher's account would need a second credential. If the
# local artifacts are stale the repo is too — same root cause, one fewer secret.

# Echo one "service:reading" per line for every expected service that is NOT fresh.
# "none" and an hour count are kept DISTINCT deliberately: never-produced points at
# configuration or a service that was removed, an old artifact points at a run that
# started and failed. Collapsing them would hide which question to ask.
failing_services() {
    local svc age
    while IFS= read -r svc; do
        age=$(backup_service_age_hours "$BACKUP_DIR" "$svc")
        if [[ "$age" == "none" ]]; then
            echo "${svc}:none"
        elif [[ "$age" -ge "$STALE_HOURS" ]]; then
            echo "${svc}:${age}h"
        fi
    done < <(backup_services_all)
}

# Edge-triggered: alert when the failing SET changes, not on every run. A watcher
# that re-sends an identical alert every morning trains its reader to filter it,
# which is how a real one gets missed.
main() {
    local current previous
    current=$(failing_services | sort | tr '\n' ' ' | sed 's/ $//')
    previous=$(cat "$STATE_FILE" 2>/dev/null || echo "__unset__")

    log "failing=[${current:-none}] previous=[${previous}]"

    if [[ "$current" == "$previous" ]]; then
        log "no change; staying quiet"
        return 0
    fi

    if [[ -z "$current" ]]; then
        # Only announce recovery if there was something to recover FROM. On a first
        # ever run of a healthy fleet, previous is __unset__ and silence is right.
        if [[ "$previous" != "__unset__" && -n "$previous" ]]; then
            tg "✅ <b>Backups healthy</b> — every expected service has an artifact newer than ${STALE_HOURS}h. Previously failing: <code>$(html_escape "$previous")</code>"
        else
            log "first run, fleet healthy; no alert"
        fi
    else
        local n
        n=$(printf '%s' "$current" | wc -w | tr -d ' ')
        tg "$(printf '🚨 <b>%s of %s backup services stale or missing</b>\n\n<pre>%s</pre>\n\n<code>none</code> = never produced an artifact (config, or a retired service still expected).\nAn hour count = a run started and failed.\n\nDirectory: <code>%s</code>\nLast lines of <code>backup.log</code>:\n<pre>%s</pre>' \
            "$n" "$(backup_services_all | wc -l | tr -d ' ')" \
            "$(html_escape "$(printf '%s' "$current" | tr ' ' '\n')")" \
            "$BACKUP_DIR" \
            "$(html_escape "$(tail_backup_log 2>/dev/null || echo '(unavailable)')")")"
    fi

    printf '%s' "$current" > "$STATE_FILE"
}

main
