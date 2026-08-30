#!/bin/bash
# Shared alert helper, sourced by infra cron scripts.
#
# Requires: bash (arrays, ${var//pat} pattern substitution, and process
# substitution `-H @<(...)`). This lib is sourced, so it runs in the CALLER's
# shell, not under this shebang — a #!/bin/sh consumer will fail at send-time,
# not at source-time. Source it only from a bash script.
#
# Provides:
#   telegram_html_escape <string>      -> echoes input with &, <, > escaped for HTML mode
#   send_telegram_alert <html_message> -> POST to the notify proxy with parse_mode=HTML
#
# Alerts are delivered via the local notify service (the `notify` container
# on 127.0.0.1:8090, publicly notify.imagineering.cc), which forwards to
# Telegram with its own bot token. This replaced direct Telegram Bot API
# calls as gremlin_xdeca_bot: that bot is muted in its target group (status
# "restricted", can_send_messages=false), so every alert was silently
# dropped (claude-tasks#441). Routing through notify gives crons the same
# alert path the watcher fleet already uses, landing in Nick's personal
# chat.
#
# The default NOTIFY_URL is deliberately the LOCAL listener, not the public
# Caddy-fronted hostname: health-check alerts fire precisely when Caddy or
# containers are down, so the alert path must not depend on Caddy.
#
# NARROWED FAILURE MODEL (known, accepted): the notify container is itself
# a container on this host. If Docker or notify is down, the alert is lost
# (stderr breadcrumb in the cron log only) — this path cannot announce the
# death of its own transport. Mitigations: the docker-watchdog cron
# restarts dead containers, and host-level liveness is watched externally
# (Melbourne peer watcher). A direct-Telegram fallback was considered and
# rejected: the only other bot creds on this box belong to a bot that is
# muted in its target group, which is the silent-drop failure this lib
# exists to fix.
#
# Configuration: NOTIFY_API_KEY (required), NOTIFY_URL (optional, defaults
# to the local listener). If not already in the environment, this lib tries
# to source /etc/imagineering-secrets/notify.env (root:nick 0640) so the key
# never has to be inlined into world-readable cron entries.
#
# Silent no-op if creds are missing — a missing-secret deploy shouldn't turn
# every cron into a stderr spammer.
#
# Why HTML, not MarkdownV2: MarkdownV2 requires escaping ~16 punctuation
# characters in *all* text (including dynamic data). One stray dot or paren
# from a stack frame breaks the message and Telegram silently 400s exactly
# when we most need the alert. HTML mode requires escaping only `&`, `<`,
# `>` — much smaller failure surface.

# Source the secrets file if present and the key isn't already set.
# Done at source-time, not at function-call-time, so each script only pays
# the cost once (and behavior is predictable in `set -u` consumers).
if [ -z "${NOTIFY_API_KEY:-}" ] && [ -r /etc/imagineering-secrets/notify.env ]; then
  # shellcheck disable=SC1091
  . /etc/imagineering-secrets/notify.env
fi

# Default exports so consumers can use `${VAR:-}` or `set -u` safely.
NOTIFY_API_KEY="${NOTIFY_API_KEY:-}"
NOTIFY_URL="${NOTIFY_URL:-http://127.0.0.1:8090}"

# Escape &, <, > for Telegram HTML mode. Order matters: & must be first so
# the literal ampersands inserted by &lt; / &gt; aren't double-escaped.
# `${1:-}` so the function is safe to call under `set -u`.
telegram_html_escape() {
  local s=${1:-}
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

# Escape a string for embedding inside a JSON string literal. Pure bash +
# tr (no jq dependency — this runs from cron, where a missing binary would
# silently kill the alert path). Handles the characters that realistically
# appear in alert text: backslash, double-quote, newline, carriage return,
# tab. Any remaining ASCII control chars (rare — e.g. from a binary log
# tail) are stripped rather than \u-encoded: losing an unprintable byte
# from an alert is fine; breaking the JSON is not.
notify_json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# Send an alert via the notify proxy. Silent no-op if creds are not
# configured (the common dev/test path); but if creds ARE present and the
# send fails, log to stderr — a silent communication failure for a
# system-critical alert is exactly the failure mode we don't want.
# Argument is the message body in Telegram HTML format. Caller is
# responsible for escaping any dynamic content via telegram_html_escape.
send_telegram_alert() {
  local message="$1"
  if [ -z "$NOTIFY_API_KEY" ]; then
    echo "Telegram alert skipped (NOTIFY_API_KEY not set)"
    return 0
  fi
  # bot=infra so alerts arrive as the Enspyr Infra identity, not the dreams
  # bot notify defaults to. notify falls back to dreams if infra creds aren't
  # deployed, so this is safe even before the infra bot is wired everywhere.
  local payload
  payload=$(printf '{"message": "%s", "parse_mode": "HTML", "bot": "infra"}' \
    "$(notify_json_escape "$message")")
  # Capture curl output. On non-zero exit, emit a one-line stderr message
  # so the cron job's log carries a breadcrumb for the post-mortem.
  # The Authorization header is fed via process substitution (-H @file)
  # rather than argv, so the API key never appears in `ps` output or
  # /proc/*/cmdline while the send is in flight. The payload stays in
  # argv — alert text is operational, not secret.
  # Append the HTTP status as a trailing line (-w) so we can gate on it too.
  local curl_out curl_rc
  curl_out=$(curl -sS --max-time 10 -w '\n%{http_code}' -X POST "$NOTIFY_URL/send" \
    -H @<(printf 'Authorization: Bearer %s\n' "$NOTIFY_API_KEY") \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1) || curl_rc=$?
  curl_rc=${curl_rc:-0}
  if [ "$curl_rc" -ne 0 ]; then
    echo "send_telegram_alert: curl failed (rc=$curl_rc): $curl_out" >&2
    return 0  # don't propagate — caller is in an alert path already
  fi
  # Split the trailing %{http_code} line from the response body.
  local http_code body
  http_code=${curl_out##*$'\n'}
  body=${curl_out%$'\n'*}
  # curl exits 0 for an HTTP 4xx/5xx too (it got *a* response), so a rejection
  # would otherwise pass silently — the exact silent-drop this alert path exists
  # to avoid. A bare `"ok":true` glob is NOT enough: notify's own /health
  # returns a static {"ok": true} WITHOUT touching Telegram, so a mis-aimed
  # NOTIFY_URL (or a wrapped {"ok":true,"telegram":{"ok":false}}) could pass.
  # Require BOTH a 200 AND a real delivery receipt — Telegram's relayed
  # `message_id`, which only a genuine sendMessage carries. Matching the
  # colon-terminated key alone is enough: the value (and json.dumps' space
  # after the colon) is absorbed by the trailing glob. (Plain glob, no jq dep.)
  if [ "$http_code" != "200" ]; then
    echo "send_telegram_alert: notify returned HTTP $http_code (not 200): $body" >&2
    return 0  # don't propagate — caller is already in an alert path
  fi
  case "$body" in
    *'"message_id":'*) : ;;  # real Telegram delivery receipt
    *)
      echo "send_telegram_alert: no delivery receipt (message_id) in response — silent drop or /health hit? : $body" >&2
      return 0  # still don't propagate — caller is already in an alert path
      ;;
  esac
}
