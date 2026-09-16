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
# EVERY probe below can fail, and for every one of them a failed probe yields the
# same empty result as a healthy one. This script is event-driven on CHANGE, so
# that emptiness does not merely hide a problem — the resolved-keys diff reads it
# as RECOVERY and sends a ✅ for something still broken, then clears the state so
# the real breakage can never re-alert.
#
# BLIND maps an issue-key prefix to the reason that sensor could not be read. One
# mechanism for all four sensors, deliberately: the first version of this fix
# insulated docker alone and left df and /proc/meminfo arcing, which is how a
# class fix becomes an instance fix wearing a class fix's commit message.
declare -A blind

# Disk (all real filesystems).
disk_raw=""
if ! disk_raw=$(df -h --output=pcent,target -x tmpfs -x devtmpfs -x overlay 2>&1); then
    blind["disk:"]="df failed: $(printf '%s' "$disk_raw" | tr '\n' ' ' | cut -c1-120)"
    disk_raw=""
fi
while read -r usage mount; do
    pct=${usage%\%}
    if [ "$pct" -gt "$DISK_THRESHOLD" ]; then
        issues["disk:${mount}"]="Disk ${mount}: ${pct}% used (threshold ${DISK_THRESHOLD}%)"
    fi
done < <(printf '%s\n' "${disk_raw:-}" | tail -n +2 | awk '{print $1, $2}')

# Memory + swap. Read /proc/meminfo ONCE and check it: the previous form ran awk
# four times against a path that may be unreadable, and an unreadable procfs made
# mem_total empty -> the `-gt 0` guard never fired -> the memory and swap keys
# silently "recovered". Absent is not zero.
# Path is overridable ONLY so the blindness arm is testable: a sensor whose
# failure mode cannot be induced in a test is a sensor whose guard is unverified,
# which is how the `free` decoy in the first version of the proof let the memory
# probe run against the real host inside a test that believed itself isolated.
MEMINFO_PATH="${HEALTHCHECK_MEMINFO:-/proc/meminfo}"
meminfo=""
if ! meminfo=$(cat "$MEMINFO_PATH" 2>&1); then
    blind["memory"]="cannot read $MEMINFO_PATH: $(printf '%s' "$meminfo" | tr '\n' ' ' | cut -c1-120)"
    blind["swap"]="${blind[memory]}"
    meminfo=""
fi

mem_total=$(printf '%s\n' "$meminfo" | awk '/MemTotal/ {print $2}')
mem_available=$(printf '%s\n' "$meminfo" | awk '/MemAvailable/ {print $2}')
if [ "${mem_total:-0}" -gt 0 ]; then
    mem_used_pct=$(( (mem_total - mem_available) * 100 / mem_total ))
    if [ "$mem_used_pct" -gt "$MEMORY_THRESHOLD" ]; then
        issues["memory"]="Memory: ${mem_used_pct}% used (threshold ${MEMORY_THRESHOLD}%)"
    fi
fi

# Swap.
swap_total=$(printf '%s\n' "$meminfo" | awk '/SwapTotal/ {print $2}')
swap_free=$(printf '%s\n' "$meminfo" | awk '/SwapFree/ {print $2}')
if [ "${swap_total:-0}" -gt 0 ]; then
    swap_used_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    if [ "$swap_used_pct" -gt "$SWAP_THRESHOLD" ]; then
        issues["swap"]="Swap: ${swap_used_pct}% used (threshold ${SWAP_THRESHOLD}%)"
    fi
fi

# Containers: exited (non-allowlisted) or restarting. Known one-shot helpers
# (compose migrate/setup jobs) exit 0 by design and are skipped by name.
ONESHOT_HELPERS_RE='^(imagineering|img)-(kanbn-migrate|outline-minio-setup)$'

# ENUMERATE CONTAINERS WITH THE EXIT STATUS CONSUMED.
#
# This read used to be `done < <(docker ps -a ... 2>/dev/null)`, and its failure
# was not "no alert" — it was a WRONG alert. With the daemon down the process
# substitution yields nothing, the loop body never runs, and `issues` ends with
# zero container:* keys. The resolved_keys diff below then finds every
# previously-active container key missing from `issues` and fires a ✅ RECOVERY
# for each one. A dockerd crash made this script send GOOD NEWS about containers
# that were still broken, once an hour, and clear their state so the real
# breakage could never re-alert.
#
# The repo already had this right twice — lib/resolve-container.sh checks
# `docker ps`'s status before trusting its output, and avatar-deploy rolls back
# rather than trust an unreadable boot anchor. It never reached here.
#
# This records into `blind` rather than acting: the carry-forward it drives cannot
# run until `prev` is loaded, further down. Acting here would iterate an empty
# array and silently do nothing — the same failure-looks-like-success defect this
# block exists to remove.
# SPLIT THE STREAMS. stdout is the roster, stderr is the wound, the exit status is
# the switch. An earlier revision of this fix used `2>&1`, which on a ZERO exit
# folds a daemon warning into the census the `while read` below turns into
# `container:*` keys — a phantom container issue, then a ✅ recovery the hour the
# warning stops. The old `2>/dev/null` discarded that line; `2>&1` PARSED it. The
# same false all-clear, born from the fix for it. (Tesla, cage-match #198.)
container_ps=""
container_ps_err=""
_err_file=$(mktemp)
if ! container_ps=$(docker ps -a --filter "status=exited" --filter "status=restarting" \
        --format "{{.Names}} {{.Status}}" 2>"$_err_file"); then
    container_ps_err=$(tr '\n' ' ' < "$_err_file" | cut -c1-120)
    blind["container:"]="docker ps failed: $container_ps_err"
    container_ps=""
fi
rm -f "$_err_file"
while read -r name status; do
    [ -n "$name" ] || continue
    if [[ "$status" == "Exited (0)"* ]] && [[ "$name" =~ $ONESHOT_HELPERS_RE ]]; then
        continue
    fi
    issues["container:${name}"]="Container <b>${name}</b>: ${status}"
done < <(printf '%s\n' "$container_ps")

# Previous active keys.
declare -A prev
if [ -f "$STATE_FILE" ]; then
    while IFS= read -r k; do [ -n "$k" ] && prev["$k"]=1; done < "$STATE_FILE"
fi

# FAIL CLOSED for every blind sensor, before the diff runs.
#   - raise the blindness itself, because a health check that cannot see is a
#     health problem and should alert once, on change, like anything else;
#   - carry every previous issue under that sensor forward, so the diff below
#     cannot mistake "could not ask" for "recovered".
# Placed here, after `prev` is populated — doing it at probe time would iterate an
# empty array and silently do nothing, which is this file's own defect class.
for pfx in "${!blind[@]}"; do
    issues["healthcheck:${pfx%:}"]="Health check is BLIND on ${pfx%:}: ${blind[$pfx]}"
    for k in "${!prev[@]}"; do
        case "$k" in
            "$pfx"*) [ -n "${issues[$k]:-}" ] || issues["$k"]="<b>${k}</b>: state UNKNOWN (${blind[$pfx]})" ;;
        esac
    done
done

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
