#!/usr/bin/env bash
# Watcher base library — shared helpers + state machine for cron-on-Sydney
# watchers. Source this from each watcher; provides:
#
#   ts()           – ISO8601 UTC timestamp
#   log <msg>      – append timestamped line to $LOG_FILE
#   tg <html-msg>  – fire HTML-mode notification via notify.imagineering.cc
#   self_disable   – remove this watcher's crontab entry (idempotent)
#   run_watcher    – execute the two-phase state machine, dispatching to
#                    phase_a_check / phase_b_check that the watcher defines
#
# Required globals (the watcher must set BEFORE sourcing):
#   WATCHER_NAME   – used for state + log file names
#   CRON_TAG       – trailing comment on the crontab entry to grep for
#
# Provided globals (set by this lib after init):
#   CONFIG_DIR, STATE_FILE, START_FILE, LOG_FILE, CRED_FILE, ELAPSED_HOURS
#
# Conventions:
#   - Watchers run as the user that owns the cron entry (typically `ubuntu`
#     on Sydney). All paths default to that user's $HOME.
#   - Notifications fail silently (logged, never abort the run).
#   - Transient errors should `return 2` from a phase check; the run still
#     exits 0 so cron doesn't treat it as a failure.

set -euo pipefail

# ---------------------------------------------------------------------------
# Init — runs at source-time. The watcher must have set WATCHER_NAME by now.
# ---------------------------------------------------------------------------
: "${WATCHER_NAME:?watcher must set WATCHER_NAME before sourcing watcher-base.sh}"
: "${CRON_TAG:?watcher must set CRON_TAG before sourcing watcher-base.sh}"

CONFIG_DIR="$HOME/.config/imagineering"
STATE_FILE="$CONFIG_DIR/$WATCHER_NAME.state"
START_FILE="$CONFIG_DIR/$WATCHER_NAME.start"
LOG_FILE="$HOME/$WATCHER_NAME.log"
CRED_FILE="$CONFIG_DIR/notify-credentials"

mkdir -p "$CONFIG_DIR"

# Source notify creds if present. Silent no-op if absent — log() still works.
# shellcheck source=/dev/null
[[ -r "$CRED_FILE" ]] && { set -a; . "$CRED_FILE"; set +a; }

# Record first-run epoch for elapsed-time reasoning in checks.
[[ -f "$START_FILE" ]] || date +%s > "$START_FILE"
__START_EPOCH=$(cat "$START_FILE")
__NOW_EPOCH=$(date +%s)
# shellcheck disable=SC2034  # consumed by watcher's phase_*_check functions
ELAPSED_HOURS=$(( (__NOW_EPOCH - __START_EPOCH) / 3600 ))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

# tg <html-message>
#   Fires a notification via notify.imagineering.cc. HTML parse mode by
#   default — caller is responsible for escaping <, >, & in dynamic text.
#   Set DRY_RUN=1 to log the message instead of POSTing — useful while
#   developing/smoke-testing a watcher to avoid Telegram noise.
#   Sends as bot=$TG_BOT (default "infra" → @enspyr_infra_bot). notify's own
#   default is "dreams", so the fleet must pass "infra" explicitly to speak in
#   the right voice; a watcher can override TG_BOT if it ever needs another.
tg() {
    local msg="$1"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "tg [DRY_RUN]: ${msg//$'\n'/ }"
        return 0
    fi
    if [[ -z "${NOTIFY_URL:-}" || -z "${NOTIFY_API_KEY:-}" ]]; then
        log "tg: NOTIFY_URL/NOTIFY_API_KEY not set; skipping"
        return 0
    fi
    local payload
    payload=$(jq -n --arg m "$msg" --arg b "${TG_BOT:-infra}" \
        '{message:$m, parse_mode:"HTML", bot:$b}')
    local result
    if result=$(curl -sS --max-time 10 -X POST "${NOTIFY_URL}/send" \
            -H "Authorization: Bearer ${NOTIFY_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>&1); then
        log "tg: $(echo "$result" | jq -r '"ok=\(.ok) err=\(.description // "-")"' 2>/dev/null || echo "raw=$result")"
    else
        log "tg: curl failed: $result"
    fi
}

# html_escape <text>
#   Escapes &, < and > for HTML-mode Telegram messages. Lives here rather than
#   in lib/diagnose.sh because a watcher that needs only this one helper must
#   not have to source diagnose.sh (which is absent on some hosts and would
#   crash the watcher at startup under set -e).
html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# tg_confirmed <html-message>
#   Like tg(), but returns NON-ZERO unless the send produced a real Telegram
#   delivery receipt. For watchers whose next act is irreversible (self-disable,
#   state advance), where an unnoticed silent drop means the alert is lost
#   forever.
#
#   The receipt test is `"message_id":`, matching scripts/lib/telegram.sh — a
#   bare {"ok":true} is NOT sufficient, because notify's own /health returns
#   exactly that WITHOUT touching Telegram, so a mis-aimed NOTIFY_URL would
#   otherwise read as delivered. That lesson was learned on the alert path
#   (#154) and never reached this fleet's tg(); this is it arriving.
#
#   tg() is deliberately left unchanged: it returns 0 unconditionally and five
#   watchers call it under `set -e`, so making it fail would abort them.
tg_confirmed() {
    local msg="$1"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "tg_confirmed [DRY_RUN]: ${msg//$'\n'/ }"
        return 0
    fi
    if [[ -z "${NOTIFY_URL:-}" || -z "${NOTIFY_API_KEY:-}" ]]; then
        log "tg_confirmed: NOTIFY_URL/NOTIFY_API_KEY not set — cannot confirm delivery"
        return 1
    fi
    local payload body
    payload=$(jq -n --arg m "$msg" --arg b "${TG_BOT:-infra}" \
        '{message:$m, parse_mode:"HTML", bot:$b}')
    if ! body=$(curl -sS --max-time 10 -X POST "${NOTIFY_URL}/send" \
            -H "Authorization: Bearer ${NOTIFY_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>&1); then
        log "tg_confirmed: curl failed: $body"
        return 1
    fi
    case "$body" in
        *'"message_id":'*)
            log "tg_confirmed: delivery receipt received"
            return 0 ;;
        *)
            log "tg_confirmed: NO delivery receipt (message_id) in response — silent drop or /health hit?: $body"
            return 1 ;;
    esac
}

# self_disable
#   Removes any crontab line containing $CRON_TAG (the trailing-comment tag).
#   Idempotent. Operates on the invoking user's crontab.
self_disable() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "self_disable [DRY_RUN]: would remove crontab entry tagged: $CRON_TAG"
        return 0
    fi
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        # `|| true` is load-bearing: when this watcher's line is the LAST one in
        # the crontab, grep -vF matches nothing and exits 1. Under the callers'
        # `set -o pipefail` that kills the script AFTER `crontab -` has already
        # installed the (correctly) empty crontab — so the disable succeeds but
        # the success is never logged and cron reports a failure.
        { crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true; } | crontab -
        log "self-disabled cron entry tagged: $CRON_TAG"
    else
        log "self_disable: no cron entry found for tag: $CRON_TAG (already removed?)"
    fi
}

# run_watcher
#   Drives the two-phase state machine. Calls phase_a_check / phase_b_check
#   that the watcher script defines. Phase functions follow this contract:
#     return 0  → condition met (caller should already have called tg)
#                 → state transitions A→B or B→DONE+self-disable
#     return 1  → still waiting; cron retries next cycle
#     return 2  → transient error (logged); cron retries next cycle
# set_state <phase>
#   Writes the state file, EXCEPT under DRY_RUN. A dry run must not advance the
#   state machine: the README tells operators to smoke-test with DRY_RUN=1, and
#   if the watched condition happens to be true at that moment, tg_confirmed
#   short-circuits to success, phase advances A→B, and the next REAL cron tick
#   runs phase_b_check and self-disables the watcher. A smoke test must not be
#   able to switch off the thing it is testing.
set_state() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "set_state [DRY_RUN]: would set phase=$1 (state file untouched)"
        return 0
    fi
    echo "$1" > "$STATE_FILE"
}

run_watcher() {
    local phase rc
    phase=$(cat "$STATE_FILE" 2>/dev/null || echo "A")

    case "$phase" in
        A)
            log "phase=A"
            rc=0
            phase_a_check || rc=$?
            case "$rc" in
                0) set_state B; [[ "${DRY_RUN:-0}" == "1" ]] || log "A → B" ;;
                1) ;;
                2) ;;
                *) log "phase_a_check returned unexpected rc=$rc; treating as waiting" ;;
            esac
            ;;
        B)
            log "phase=B"
            rc=0
            phase_b_check || rc=$?
            case "$rc" in
                0) set_state DONE; self_disable; [[ "${DRY_RUN:-0}" == "1" ]] || log "B → DONE" ;;
                1) ;;
                2) ;;
                *) log "phase_b_check returned unexpected rc=$rc; treating as waiting" ;;
            esac
            ;;
        DONE)
            log "phase=DONE; cron entry should be removed (running anyway means self_disable failed earlier)"
            self_disable
            ;;
        *)
            log "unknown phase=$phase; resetting to A"
            set_state A
            ;;
    esac
}
