#!/usr/bin/env bash
# Notify-container CANARY — Melbourne→Sydney, INDEPENDENT alert path.
#
# ─── The invariant this enforces ───────────────────────────────────────────
#   "Sydney's alerting chain can actually deliver."
#   Every cron + watcher on Sydney funnels its alerts through ONE chain:
#       notify container (127.0.0.1:8090) → Telegram Bot API → Nick.
#   That chain cannot announce its OWN death. If Docker is down, the notify
#   container has crashed, or Sydney's egress to api.telegram.org is broken,
#   the alert is POSTed to the corpse and lost — silently. Nick learns Sydney
#   went dark only when he happens to notice. This canary is the outside
#   witness that closes that hole.
#
# ─── System-shape assumptions ──────────────────────────────────────────────
#   1. Melbourne (`enspyr`, 158.179.17.233) is always-on, and its cron is
#      healthy. (It already runs oci-instance-watch-melbourne.sh on the same
#      box; if Melbourne itself dies, Sydney's oci-instance-watch.sh catches
#      Melbourne — mutual peer monitoring. So neither box is its own witness.)
#   2. Melbourne can SSH to Sydney as `ubuntu` (the same key the deploy/peer
#      tooling already uses — Mel→Syd reachability is a standing assumption of
#      the peer-watcher fleet).
#   3. Melbourne holds a Telegram bot token DIRECTLY, in its own dedicated
#      envfile /etc/imagineering-secrets/canary-telegram.env (CANARY_TG_TOKEN
#      + CANARY_TG_CHAT). This is the crux: the canary must NOT route its alert
#      through the very Sydney notify service it is checking. It POSTs to
#      api.telegram.org itself, with its OWN inlined sender (below) — it does
#      NOT use lib/telegram.sh, whose send_telegram_alert() was rerouted through
#      the notify proxy in #74 (i.e. THROUGH the thing this canary watches). The
#      token name is deliberately CANARY_TG_* — never NOTIFY_* — so the two
#      credential paths can't be silently conflated. Spreading the bot token is
#      normally an anti-pattern (that's WHY notify exists) — but the one client
#      that may not depend on notify is the client that watches notify. This is
#      the documented exception.
#
# ─── The probe (why three layers, not one TCP check) ───────────────────────
#   A bare "is :8090 open?" or even a GET /health proves only that the HTTP
#   server process is up — /health returns a static {"ok":true} WITHOUT ever
#   touching Telegram. A green /health with a revoked bot token or blocked
#   egress is a FALSE POSITIVE that defeats the entire canary (we'd report
#   "delivery fine" while every real alert silently vanishes). So the probe,
#   run over a single SSH hop to Sydney, layers:
#
#     L1  notify container is RUNNING & Docker-healthy
#         (`docker inspect` .State.Health.Status == healthy)  → process alive
#     L2  notify answers GET /health on 127.0.0.1:8090 → 200   → HTTP serving
#     L3  Telegram getMe succeeds FROM Sydney's network        → egress + token
#         (proves the delivery chain end-to-end WITHOUT sending Nick a message
#          — getMe is read-only; a test /send would spam Telegram every cycle)
#
#   All three must pass for "delivery-capable". L3 is the one that turns this
#   from a liveness check into a DELIVERY check — it is the boundary the whole
#   canary stands for. If SSH itself fails we can't distinguish "Sydney box
#   down" from "Mel→Syd network blip"; we treat repeated SSH failure as a
#   Phase-A trip too (Sydney unreachable from its witness is itself alarming),
#   but debounce so a single flap doesn't fire.
#
# ─── Shape: recurring threshold-alert (NOT self-disabling) ─────────────────
#   A canary that disabled itself after one recovery would stop guarding. So,
#   like email-health-watch.sh, phase_a_check ALWAYS returns 1 — the state
#   machine never advances to DONE, the cron entry is never removed. Alerts
#   debounce to at most one per failure-episode via a sentinel file, and a
#   recovery ✅ fires once when the probe goes green again, then re-arms.
#
# Cron (Melbourne crontab, as user `ubuntu`):
#   47 */2 * * * /home/ubuntu/notify-canary-melbourne.sh  # notify-canary-melbourne
#   (Every 2 hours, off the hour. Offset to :47 — well clear of the Melbourne
#    oci-watcher's :17 — so the two Mel→Syd probes don't fire simultaneously.)

set -euo pipefail

# shellcheck disable=SC2034  # consumed by watcher-base.sh after sourcing
WATCHER_NAME="notify-canary-melbourne"
# shellcheck disable=SC2034
CRON_TAG="notify-canary-melbourne"

# ── Source the base lib for log()/run_watcher()/state plumbing ─────────────
# NOTE: we use ONLY the state-machine plumbing (log/run_watcher/state), never
# the lib's tg() helper — tg() POSTs through notify.imagineering.cc, i.e.
# through the very Sydney service we're checking. This canary is deliberately
# NOT wired to lib/telegram.sh either: its send_telegram_alert() was rerouted
# through the notify proxy in #74, so it would post our "notify is down" alarm
# to the corpse. Our alert path is the inlined DIRECT sender below.
__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

# ── Independent Telegram credentials (dedicated envfile, NEVER notify's) ────
# CANARY_TG_TOKEN + CANARY_TG_CHAT are held on Melbourne in a file distinct
# from any NOTIFY_* creds, so the two paths cannot be conflated. Absent creds
# make the canary INERT (it logs and sends nothing) — it never falls back to
# notify, because a fallback would silently defeat the independence it exists
# to provide.
CANARY_TG_ENV="${CANARY_TG_ENV:-/etc/imagineering-secrets/canary-telegram.env}"
# shellcheck disable=SC1090
[[ -r "$CANARY_TG_ENV" ]] && { set -a; . "$CANARY_TG_ENV"; set +a; }

# ── Config (override via env if needed) ────────────────────────────────────
SYDNEY_SSH="${SYDNEY_SSH:-149.118.69.221}"      # Sydney public IP
SYDNEY_SSH_USER="${SYDNEY_SSH_USER:-ubuntu}"    # standing peer-fleet user
NOTIFY_CONTAINER="${NOTIFY_CONTAINER:-notify}"  # docker container name
NOTIFY_PORT="${NOTIFY_PORT:-8090}"              # 127.0.0.1-bound on Sydney
SSH_TIMEOUT="${SSH_TIMEOUT:-20}"                # seconds for the whole probe

# Sentinel: present == we are currently in a fired/alerted state. Used to
# debounce (one 🚨 per failure-episode) and to know when to fire the ✅.
ALERT_SENTINEL="$CONFIG_DIR/$WATCHER_NAME.alerted"

# ── Inlined escapers (self-contained — no shared lib whose contract can drift).
# HTML for parse_mode=HTML; JSON for embedding in the sendMessage body.
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
# DRY_RUN=1 logs instead of sending (smoke-testing without Telegram noise).
# POSTs sendMessage straight to Telegram with Melbourne's own bot token — it
# does NOT traverse notify, so it can still fire when notify is the thing that
# died. Fail-closed: missing creds → log + send nothing, NEVER a notify fallback.
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

# ── probe : runs the 3-layer check over ONE ssh hop. ───────────────────────
# Echoes "OK" on full delivery-capable, or "FAIL:<reason>" otherwise.
# Echoes "UNKNOWN:<reason>" when we genuinely can't tell (don't fire on these
# alone — they're transient until they persist; debounce handles persistence).
probe() {
    # The remote script runs ON Sydney. It must use only tools we know are
    # present there (docker, curl, the bot token via the same secrets file).
    # We read the token from Sydney's own notify env so we don't ship it over
    # the wire — getMe is run with Sydney's container token, proving THAT
    # token + Sydney's egress, which is exactly the chain real alerts use.
    local remote
    # The remote script is a single-quoted heredoc with $NOTIFY_CONTAINER /
    # $NOTIFY_PORT spliced in via the close-single/open-double quote dance
    # ('"'"'"$VAR"'"'"'). Shellcheck can't see across that concatenation
    # boundary and flags SC2016 ("won't expand") — but they DO expand at
    # string-build time. The '\'' sequences are literal apostrophes in remote
    # comments/strings. Both are intended; suppress the false positive.
    # shellcheck disable=SC2016
    remote='
set -euo pipefail
C="'"$NOTIFY_CONTAINER"'"
P="'"$NOTIFY_PORT"'"
# L1: container running + Docker-healthy.
state=$(docker inspect -f "{{.State.Status}}" "$C" 2>/dev/null) || { echo "FAIL:container-absent"; exit 0; }
[ "$state" = "running" ] || { echo "FAIL:container-not-running($state)"; exit 0; }
health=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$C" 2>/dev/null || echo "none")
# "none" == no healthcheck defined; tolerate it (older compose) but L2 still gates.
case "$health" in healthy|none) : ;; *) echo "FAIL:container-unhealthy($health)"; exit 0 ;; esac
# L2: /health answers 200 on the loopback bind.
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${P}/health" 2>/dev/null) || code="000"
# A 000 (connect failed) is a transient blip → UNKNOWN (debounced); a real
# non-200 (server returned an error) is deterministic → FAIL.
[ "$code" = "200" ] || { if [ "$code" = "000" ]; then echo "UNKNOWN:health-unreachable"; else echo "FAIL:health-http($code)"; fi; exit 0; }
# L3: Telegram getMe FROM Sydney, using the container'\''s own bot token.
# Read the token out of the running container env (never printed/logged here).
tok=$(docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" "$C" 2>/dev/null | sed -n "s/^TELEGRAM_BOT_TOKEN=//p")
[ -n "$tok" ] || { echo "UNKNOWN:no-token-in-container-env"; exit 0; }
gm=$(curl -s --max-time 8 "https://api.telegram.org/bot${tok}/getMe" 2>/dev/null) || { echo "UNKNOWN:telegram-egress"; exit 0; }
# ok:true → delivery-capable. Otherwise split transient (429 rate-limit / 5xx
# Telegram outage → debounced UNKNOWN) from deterministic (401 revoked token,
# other 4xx → immediate FAIL, the exact thing this canary exists to catch).
case "$gm" in
    *'\''"ok":true'\''*) echo "OK" ;;
    *) ec=${gm#*"error_code":}; ec=${ec%%[!0-9]*}
       case "$ec" in
           429|5??) echo "UNKNOWN:telegram-transient($ec)" ;;
           *)       echo "FAIL:telegram-getme-rejected($ec)" ;;
       esac ;;
esac
'
    local out
    if ! out=$(ssh \
            -o BatchMode=yes \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
            "${SYDNEY_SSH_USER}@${SYDNEY_SSH}" \
            "bash -s" <<< "$remote" 2>/dev/null); then
        # SSH itself failed: Sydney unreachable from its witness. Alarming, but
        # could be a Mel→Syd network blip — surface as UNKNOWN; debounce +
        # episode-persistence (sentinel) decides whether to escalate.
        echo "UNKNOWN:ssh-unreachable"
        return 0
    fi
    # Guard against an empty echo (e.g. remote bash died before printing).
    [[ -n "$out" ]] && echo "$out" || echo "UNKNOWN:empty-probe-output"
}

# Escalation policy: a single UNKNOWN (transient blip) does NOT fire; a second
# consecutive UNKNOWN is treated as a real failure (the blip persisted). FAIL
# fires immediately. We track consecutive-unknown count in a tiny state file.
UNKNOWN_STREAK_FILE="$CONFIG_DIR/$WATCHER_NAME.unknown-streak"

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

The notify alerting chain (container → Telegram) is delivery-capable again. Sydney crons can alert Nick once more.'
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
    alert "$(printf '🚨 <b>Sydney notify chain CANNOT DELIVER</b> (Melbourne canary)

Probe result: <code>%s</code>

This is the path EVERY Sydney cron/watcher alert flows through (notify container → Telegram). It is down, so Sydney alerts are being silently lost. This message reached you via Melbourne'\''s INDEPENDENT Telegram path. Check Sydney: <code>ssh %s@%s</code> then <code>docker ps | grep %s</code>.' \
        "$esc" "$SYDNEY_SSH_USER" "$SYDNEY_SSH" "$NOTIFY_CONTAINER")"
    touch "$ALERT_SENTINEL"
}

# Recurring watcher: phase B is never reached (A never returns 0). Present to
# satisfy the run_watcher() contract.
phase_b_check() {
    return 1
}

run_watcher
