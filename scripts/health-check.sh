#!/bin/bash
# Server health check — EVENT-DRIVEN Telegram alerts via the notify proxy.
#
# Runs hourly via cron. Alerts ONLY on CHANGE:
#   • a newly-appeared issue fires once,
#   • a persisting issue stays SILENT (no hourly re-spam — the thing that made
#     this noisy: a container stopped days ago was re-alerted every hour),
#   • a cleared issue fires a one-time ✅ recovery.
#
# State (the set of currently-active issue KEYS) is kept in $HEALTHCHECK_STATE
# between runs. Keys are STABLE identifiers — container:<name>, disk:<mount>,
# memory, swap — so a drifting detail in the human message (e.g. "Exited (0)
# 5 days ago", whose relative time changes every run) never reads as a new
# issue. A chronic condition is reported once, not once an hour; if you want
# periodic "still broken" reminders, that's a separate digest, deliberately not
# this.
#
# NOTIFY_API_KEY is loaded from /etc/imagineering-secrets/notify.env by the
# shared helper below (never inlined into a world-readable cron entry).
#
# Requires bash 4+ (associative arrays). Both hosts (Sydney, Melbourne) run 5.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/telegram.sh
. "$SCRIPT_DIR/lib/telegram.sh"

DISK_THRESHOLD=80
MEMORY_THRESHOLD=90
SWAP_THRESHOLD=50
STATE_FILE="${HEALTHCHECK_STATE:-$HOME/.cache/health-check-state}"

# NOTE: the downstream-server /api/health data-loss canary lives in the
# downstream repo (health-check-downstream.sh, cron :05). This script keeps the
# shared-host checks (disk/memory/swap/exited-or-restarting containers).

# Current issues as stable-key -> human message.
declare -A issues

# Disk (all real filesystems).
while read -r usage mount; do
    pct=${usage%\%}
    if [ "$pct" -gt "$DISK_THRESHOLD" ]; then
        issues["disk:${mount}"]="Disk ${mount}: ${pct}% used (threshold ${DISK_THRESHOLD}%)"
    fi
done < <(df -h --output=pcent,target -x tmpfs -x devtmpfs -x overlay | tail -n +2 | awk '{print $1, $2}')

# Memory.
mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
if [ "${mem_total:-0}" -gt 0 ]; then
    mem_used_pct=$(( (mem_total - mem_available) * 100 / mem_total ))
    if [ "$mem_used_pct" -gt "$MEMORY_THRESHOLD" ]; then
        issues["memory"]="Memory: ${mem_used_pct}% used (threshold ${MEMORY_THRESHOLD}%)"
    fi
fi

# Swap.
swap_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
swap_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
if [ "${swap_total:-0}" -gt 0 ]; then
    swap_used_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    if [ "$swap_used_pct" -gt "$SWAP_THRESHOLD" ]; then
        issues["swap"]="Swap: ${swap_used_pct}% used (threshold ${SWAP_THRESHOLD}%)"
    fi
fi

# Containers: exited (non-allowlisted) or restarting. Known one-shot helpers
# (compose migrate/setup jobs) exit 0 by design and are skipped by name.
ONESHOT_HELPERS_RE='^(imagineering|xdeca|img)-(kanbn-migrate|outline-minio-setup)$'
while read -r name status; do
    [ -n "$name" ] || continue
    if [[ "$status" == "Exited (0)"* ]] && [[ "$name" =~ $ONESHOT_HELPERS_RE ]]; then
        continue
    fi
    issues["container:${name}"]="Container <b>${name}</b>: ${status}"
done < <(docker ps -a --filter "status=exited" --filter "status=restarting" --format "{{.Names}} {{.Status}}" 2>/dev/null)

# Previous active keys.
declare -A prev
if [ -f "$STATE_FILE" ]; then
    while IFS= read -r k; do [ -n "$k" ] && prev["$k"]=1; done < "$STATE_FILE"
fi

# Diff: what's newly-broken, what just cleared.
new_msgs=()
resolved_keys=()
for k in "${!issues[@]}"; do
    [ -n "${prev[$k]:-}" ] || new_msgs+=("${issues[$k]}")
done
for k in "${!prev[@]}"; do
    [ -n "${issues[$k]:-}" ] || resolved_keys+=("$k")
done

# Persist current active set atomically (temp + rename).
mkdir -p "$(dirname "$STATE_FILE")"
tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
if [ ${#issues[@]} -gt 0 ]; then
    printf '%s\n' "${!issues[@]}" > "$tmp"
else
    : > "$tmp"
fi
mv -f "$tmp" "$STATE_FILE"

now="$(date '+%Y-%m-%d %H:%M:%S')"

# No change since last run → stay silent. This is the whole point.
if [ ${#new_msgs[@]} -eq 0 ] && [ ${#resolved_keys[@]} -eq 0 ]; then
    echo "$now OK - no change (${#issues[@]} active issue(s))"
    exit 0
fi

# Build a change notification (only the new + the resolved).
siren=$'\xF0\x9F\x9A\xA8'   # U+1F6A8 rotating light
check=$'\xE2\x9C\x85'       # U+2705 check mark
body=""
if [ ${#new_msgs[@]} -gt 0 ]; then
    body="${body}
<b>${siren} New:</b>"
    for m in "${new_msgs[@]}"; do body="${body}
- ${m}"; done
fi
if [ ${#resolved_keys[@]} -gt 0 ]; then
    body="${body}
<b>${check} Resolved:</b>"
    for k in "${resolved_keys[@]}"; do body="${body}
- ${k}"; done
fi

if [ -z "$NOTIFY_API_KEY" ]; then
    echo "$now CHANGE but missing NOTIFY_API_KEY"
    printf '%s\n' "$body"
    exit 1
fi

# Issue strings come from docker ps / /proc — no untrusted HTML — and the
# container message deliberately carries literal <b> tags, so concatenate as-is
# (do not telegram_html_escape, which would double-escape the tags).
message="<b>Server Health</b>${body}

@sentientcogs"
send_telegram_alert "$message"
echo "$now Change dispatched: ${#new_msgs[@]} new, ${#resolved_keys[@]} resolved (see stderr for delivery)"
