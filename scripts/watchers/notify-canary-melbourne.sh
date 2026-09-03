#!/usr/bin/env bash
# Notify delivery CANARY — Melbourne watches Sydney, INDEPENDENT alert path.
#
# ─── The invariant this enforces ───────────────────────────────────────────
#   "Sydney's alerting chain can actually DELIVER."
#   Every cron + watcher on Sydney funnels its alerts through ONE chain:
#       notify container → Telegram Bot API → Nick.
#   That chain cannot announce its OWN death: if notify has crashed, the bot
#   token was revoked, or Sydney's egress to Telegram is blocked, the alert is
#   POSTed to the corpse and lost — silently, while the BOX stays alive. Peer
#   liveness monitoring (oci-instance-watch, both directions) confirms the box
#   breathes; it cannot confirm the box can SCREAM. This canary closes that gap.
#
# ─── Design: DEAD-MAN'S-SWITCH, not a component probe ──────────────────────
#   Sydney proves it can deliver by ACTUALLY DELIVERING: a heartbeat cron there
#   sends a real message through notify every ~15 min, and notify records the
#   epoch of its last Telegram-accepted delivery, exposed at GET /heartbeat.
#   This canary polls that timestamp. Two failure modes, both caught:
#     • unreachable  → notify/Sydney is down (curl fails)          → UNKNOWN
#     • stale age    → notify is up but delivery has stopped        → FAIL
#                      (token revoked, egress blocked, bot muted…),
#                      OR the Sydney heartbeat emitter itself died.
#   Testing the REAL delivery path (a genuine send, receipt-confirmed) beats
#   probing proxies (docker healthy / /health 200 / getMe) that can all be
#   green while delivery still silently fails. And it needs NO ssh to Sydney —
#   just an HTTPS GET — so there is no cross-box shell trust to establish.
#
# ─── System-shape assumptions ──────────────────────────────────────────────
#   1. Melbourne (nick-mel, 158.179.17.233) is always-on and its cron is
#      healthy. If Melbourne itself dies, Sydney's oci-instance-watch.sh catches
#      it (mutual peer monitoring) — neither box is its own witness. While
#      Melbourne is down this canary is silent, an accepted limitation.
#   2. Melbourne holds a Telegram bot token DIRECTLY, in its own dedicated
#      envfile /etc/imagineering-secrets/canary-telegram.env (CANARY_TG_TOKEN
#      + CANARY_TG_CHAT). The crux: the canary must NOT route its alarm through
#      the very notify service it is checking. It POSTs to api.telegram.org
#      itself, with its OWN inlined sender (below) — never lib/telegram.sh,
#      whose send_telegram_alert() routes through notify (#74). The token name
#      is deliberately CANARY_TG_* — never NOTIFY_* — so the two credential
#      paths can't be silently conflated. Spreading the bot token is normally an
#      anti-pattern (that's WHY notify exists) — but the one client that may not
#      depend on notify is the client that watches notify.
#   3. NOTIFY_API_KEY (to authenticate the /heartbeat GET) is provided by
#      watcher-base.sh, which sources ~/.config/imagineering/notify-credentials.
#
# ─── Shape: recurring threshold-alert (NOT self-disabling) ─────────────────
#   phase_a_check ALWAYS returns 1 — the state machine never advances to DONE,
#   so the cron entry is never removed. Alerts debounce to one 🚨 per failure
#   episode via a sentinel file; a recovery ✅ fires once when it goes green.
#
# Cron (Melbourne crontab, as user `ubuntu`):
#   */15 * * * * /home/ubuntu/notify-canary-melbourne.sh  # notify-canary-melbourne
#   (Every 15 min — more often than the staleness threshold, so a real outage is
#    caught within one debounce window.)

set -euo pipefail

# shellcheck disable=SC2034  # consumed by watcher-base.sh after sourcing
WATCHER_NAME="notify-canary-melbourne"
# shellcheck disable=SC2034
CRON_TAG="notify-canary-melbourne"

# ── Source the base lib for log()/run_watcher()/state plumbing + NOTIFY_API_KEY.
# We use ONLY the state-machine plumbing (log/run_watcher/state) and the notify
# creds it loads — NEVER the lib's tg() helper, which POSTs through the very
# notify service we're checking. The alarm path is the inlined DIRECT sender
# below; notify is only ever READ from here (GET /heartbeat), never used to send.
__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

# ── Independent Telegram credentials (dedicated envfile, NEVER notify's) ────
# Absent creds make the canary INERT (it logs and sends nothing) — it never
# falls back to notify, because a fallback would silently defeat the very
# independence it exists to provide.
CANARY_TG_ENV="${CANARY_TG_ENV:-/etc/imagineering-secrets/canary-telegram.env}"
# shellcheck disable=SC1090
[[ -r "$CANARY_TG_ENV" ]] && { set -a; . "$CANARY_TG_ENV"; set +a; }

# ── Config (override via env if needed) ────────────────────────────────────
NOTIFY_HEARTBEAT_URL="${NOTIFY_HEARTBEAT_URL:-https://notify.imagineering.cc/heartbeat}"
STALE_THRESHOLD="${STALE_THRESHOLD:-2400}"   # seconds; 40 min ≈ 2.5 missed 15-min pulses
HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"           # seconds for the GET

# Sentinel: present == we are currently in a fired/alerted state. Used to
# debounce (one 🚨 per failure-episode) and to know when to fire the ✅.
ALERT_SENTINEL="$CONFIG_DIR/$WATCHER_NAME.alerted"
UNKNOWN_STREAK_FILE="$CONFIG_DIR/$WATCHER_NAME.unknown-streak"

# ── Inlined escapers (self-contained — no shared lib whose contract can drift).
_html_escape() {
    local s=${1:-}
    s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}
    printf '%s' "$s"
}
_json_escape() {
    local s=${1:-}
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# ── alert <html-message> : INDEPENDENT path, DIRECT to api.telegram.org ─────
# DRY_RUN=1 logs instead of sending. POSTs sendMessage straight to Telegram with
# Melbourne's own bot token — it does NOT traverse notify, so it can still fire
# when notify is the thing that died. Fail-closed: missing creds → log + send
# nothing, NEVER a notify fallback.
alert() {
    local msg="$1"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "alert [DRY_RUN]: ${msg//$'\n'/ }"
        return 0
    fi
    if [[ -z "${CANARY_TG_TOKEN:-}" || -z "${CANARY_TG_CHAT:-}" ]]; then
        log "alert: CANARY_TG_TOKEN/CANARY_TG_CHAT unset ($CANARY_TG_ENV) — canary INERT; refusing to fall back to notify (would defeat independence)"
        return 0
    fi
    # Token is unavoidably in the URL path (Telegram Bot API has no header auth),
    # so it appears in this short-lived curl's argv. Acceptable on a single-tenant
    # box; the alternative (route via notify to keep it out of argv) is the exact
    # coupling this canary must not have.
    local payload out rc=0
    payload=$(printf '{"chat_id":"%s","text":"%s","parse_mode":"HTML"}' \
        "$CANARY_TG_CHAT" "$(_json_escape "$msg")")
    out=$(curl -sS --max-time 10 \
        "https://api.telegram.org/bot${CANARY_TG_TOKEN}/sendMessage" \
        -H 'Content-Type: application/json' -d "$payload" 2>&1) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        log "alert: DIRECT Telegram curl failed (rc=$rc): $out"
        return 0
    fi
    case "$out" in
        *'"ok":true'*) log "alert: dispatched DIRECT to api.telegram.org (independent of Sydney notify)" ;;
        *) log "alert: Telegram rejected the direct send: $out" ;;
    esac
}

# ── probe : GET the dead-man's-switch heartbeat, judge freshness. ───────────
# Echoes "OK", "FAIL:<reason>" (deterministic — notify up but delivery stale),
# or "UNKNOWN:<reason>" (can't tell — transient until it persists; debounced).
probe() {
    if [[ -z "${NOTIFY_API_KEY:-}" ]]; then
        echo "UNKNOWN:no-notify-key"   # misconfig on THIS box; debounce, don't false-alarm
        return 0
    fi
    local out rc=0
    out=$(curl -sS --max-time "$HTTP_TIMEOUT" -w '\n%{http_code}' \
        -H "Authorization: Bearer ${NOTIFY_API_KEY}" "$NOTIFY_HEARTBEAT_URL" 2>&1) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        # Curl failed → notify/Sydney unreachable from the witness. Could be a
        # Mel→internet blip or a real Sydney outage — UNKNOWN, debounce decides.
        echo "UNKNOWN:unreachable"
        return 0
    fi
    local http_code body age
    http_code=${out##*$'\n'}
    body=${out%$'\n'*}
    if [[ "$http_code" != "200" ]]; then
        # 401 (key drift on this box) / 5xx (notify erroring) — deterministic-ish
        # but debounce anyway; a persistent non-200 escalates via the streak.
        echo "UNKNOWN:http-$http_code"
        return 0
    fi
    age=$(printf '%s' "$body" | sed -n 's/.*"age_seconds":[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    if [[ -z "$age" ]]; then
        echo "UNKNOWN:unparseable-heartbeat"
        return 0
    fi
    if (( age > STALE_THRESHOLD )); then
        echo "FAIL:stale-heartbeat(${age}s>${STALE_THRESHOLD}s)"
    else
        echo "OK"
    fi
}

phase_a_check() {
    local result reason
    result=$(probe)
    log "probe: $result"

    case "$result" in
        OK)
            rm -f "$UNKNOWN_STREAK_FILE"
            # Recovery: if we had previously alerted, fire ✅ once and re-arm.
            if [[ -f "$ALERT_SENTINEL" ]]; then
                alert '✅ <b>Sydney notify delivery RESTORED</b> (Melbourne canary)

The notify alerting chain (notify → Telegram) is delivering again — its heartbeat is fresh. Sydney crons can alert Nick once more.'
                rm -f "$ALERT_SENTINEL"
            fi
            return 1   # recurring watcher: never advance to DONE
            ;;
        FAIL:*)
            reason="${result#FAIL:}"
            rm -f "$UNKNOWN_STREAK_FILE"
            _fire_failure "$reason"
            return 1
            ;;
        UNKNOWN:*)
            reason="${result#UNKNOWN:}"
            local streak
            streak=$(cat "$UNKNOWN_STREAK_FILE" 2>/dev/null || echo 0)
            streak=$(( streak + 1 ))
            echo "$streak" > "$UNKNOWN_STREAK_FILE"
            if (( streak >= 2 )); then
                _fire_failure "persistent-$reason (x$streak)"
            else
                log "UNKNOWN streak=$streak; one more before escalating ($reason)"
            fi
            return 1
            ;;
        *)
            log "probe returned unrecognized result: $result"
            return 1
            ;;
    esac
}

# _fire_failure <reason> : fire 🚨 ONCE per failure-episode (debounced by the
# sentinel), via the INDEPENDENT Telegram path. Escapes the dynamic reason.
_fire_failure() {
    local reason esc
    reason="$1"
    if [[ -f "$ALERT_SENTINEL" ]]; then
        log "failure persists ($reason); already alerted this episode — debounced"
        return 0
    fi
    esc=$(_html_escape "$reason")
    alert "$(printf '🚨 <b>Sydney notify chain heartbeat FAILING</b> (Melbourne canary)

Detector: <code>%s</code>

This watches the path EVERY Sydney cron/watcher alert flows through (notify → Telegram). Its heartbeat has gone stale or unreachable — so Sydney alerts may be silently lost, OR the Sydney heartbeat emitter itself stopped. Either way infra alerting is degraded. This message reached you via Melbourne'\''s INDEPENDENT Telegram path. Check Sydney notify + notify-heartbeat.' "$esc")"
    touch "$ALERT_SENTINEL"
}

# Recurring watcher: phase B is never reached (A never returns 0). Present to
# satisfy the run_watcher() contract.
phase_b_check() {
    return 1
}

run_watcher
