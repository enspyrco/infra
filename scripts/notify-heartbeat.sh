#!/bin/bash
# Dead-man's-switch heartbeat emitter — runs on Sydney (hosts notify).
#
# Every ~15 min this sends a REAL message through notify to a dedicated,
# muted heartbeat channel. The point is not the message — it's that a genuine
# send exercises the whole delivery chain (notify → Telegram) and, on success,
# notify refreshes its /heartbeat `last_delivery_ok` timestamp. The Melbourne
# canary polls that timestamp over HTTPS; a stale age means this chain can no
# longer deliver even though the box may be alive. Sending (not a /health poke)
# is required: only a real delivery proves delivery.
#
# It MUST route through notify /send (sendMessage) — that is the path we are
# proving, and the path that updates last_delivery_ok. So each pulse posts a new
# message; the channel accumulates them. That's fine: it's a dedicated muted
# channel nobody reads. disable_notification keeps it silent.
#
# Requires (from /etc/imagineering-secrets/notify.env):
#   NOTIFY_API_KEY     - notify proxy key
#   NOTIFY_URL         - notify base URL (defaults to the local listener)
#   HEARTBEAT_CHAT_ID  - the dedicated heartbeat channel's chat id
set -euo pipefail

# shellcheck source=/dev/null
[ -r /etc/imagineering-secrets/notify.env ] && { set -a; . /etc/imagineering-secrets/notify.env; set +a; }
NOTIFY_URL="${NOTIFY_URL:-http://127.0.0.1:8090}"
: "${NOTIFY_API_KEY:?NOTIFY_API_KEY not set (check /etc/imagineering-secrets/notify.env)}"
: "${HEARTBEAT_CHAT_ID:?HEARTBEAT_CHAT_ID not set — add it to /etc/imagineering-secrets/notify.env}"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# U+1FAC0 ANATOMICAL HEART, written as explicit bytes so it never depends on the
# shell's \uNNNN handling.
heart=$'\xF0\x9F\xAB\x80'
payload=$(printf '{"message":"%s infra heartbeat %s","bot":"infra","chat_id":"%s","disable_notification":true}' \
    "$heart" "$ts" "$HEARTBEAT_CHAT_ID")

# Authorization via process substitution so the key never lands in argv/ps.
resp=$(curl -sS --max-time 10 -w '\n%{http_code}' -X POST "$NOTIFY_URL/send" \
    -H @<(printf 'Authorization: Bearer %s\n' "$NOTIFY_API_KEY") \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>&1) || { echo "$(date '+%F %T') heartbeat: curl failed: $resp" >&2; exit 0; }

code=${resp##*$'\n'}
body=${resp%$'\n'*}
# A real delivery carries a message_id receipt (same discriminator as the alert
# lib). notify refreshes last_delivery_ok only on this; log if it did not.
case "$body" in
    *'"message_id":'*) echo "$(date '+%F %T') heartbeat OK (http $code)" ;;
    *) echo "$(date '+%F %T') heartbeat: no delivery receipt (http $code): $body" >&2 ;;
esac
