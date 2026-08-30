#!/usr/bin/env bash
# run-path-watch — does the repo still describe what actually runs?
#
# WHY THIS EXISTS
# ---------------
# CI cannot answer this question. It validates the bytes in git, and in this
# repo the bytes in git are not what executes: PR #94 merged 2026-08-13 and
# never ran once, because cron invoked watchers from /home/ubuntu while deploys
# landed in /opt/scripts/watchers. Three of five files were byte-identical, so
# every spot-check passed. Over the period that split survived, CI went green
# 40 times out of 40 while eleven real production defects were found by other
# means. A gate that structurally cannot ask the important question will keep
# answering an unimportant one in green.
#
# This is that question, asked on the box, every day, with an alert behind it.
#
# Cron: 40 6 * * * /opt/scripts/watchers/run-path-watch.sh  # run-path-watch
#
# NOT a run_watcher state machine. The two-phase machine is for "wait for X,
# announce it, self-disable" — the disk watcher's shape. Drift is not an
# incident that resolves; it is a standing property that must be re-asked
# forever. So this sources the lib for log()/tg()/CONFIG_DIR and runs its own
# loop, deliberately never calling self_disable.

set -euo pipefail

# shellcheck disable=SC2034  # consumed by watcher-base.sh after sourcing
WATCHER_NAME="run-path-watch"
# shellcheck disable=SC2034
CRON_TAG="run-path-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
if [[ ! -r "$__lib" ]]; then
    echo "run-path-watch: no watcher-base.sh beside $0 (looked for $__lib)" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$__lib"
unset __lib

# Local escaper rather than the lib's html_escape: that helper is added to
# watcher-base.sh by PR #163, and this watcher must not be broken on a branch
# where #163 has not landed. A cross-PR dependency that fails at RUNTIME —
# `html_escape: command not found`, mid-message, no alert sent — is precisely
# the silent failure this watcher exists to detect, and it would have shipped
# looking fine. Collapse this into the lib's version once both have merged.
esc() {
    local v="$1"
    v="${v//&/&amp;}"
    v="${v//</&lt;}"
    v="${v//>/&gt;}"
    printf '%s' "$v"
}

CHECKER="${RUN_PATH_CHECKER:-$(dirname "$0")/../check-run-paths.sh}"
# On the box the "repo side" is the deployed tree: --repo-root /opt maps a
# manifest path like scripts/host/keep-alive.sh onto /opt/scripts/host/...
REPO_ROOT_ARG="${RUN_PATH_REPO_ROOT:-/opt}"
FINGERPRINT_FILE="$CONFIG_DIR/$WATCHER_NAME.fingerprint"

if [[ ! -x "$CHECKER" ]]; then
    log "FATAL: checker not found or not executable at $CHECKER"
    tg "🔧 <b>run-path-watch cannot run</b>: checker missing at <code>$(esc "$CHECKER")</code>. The drift question is going unasked."
    exit 1
fi

out=""; rc=0
out=$("$CHECKER" --local --repo-root "$REPO_ROOT_ARG" 2>&1) || rc=$?

# Strip ANSI so the fingerprint is stable and the Telegram payload is readable.
plain=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')

# ---------------------------------------------------------------------------
# rc=2 is "could not complete the check" — an INSTRUMENT failure, which is a
# finding in its own right and must never be mistaken for "no drift". This
# watcher exists because a green that means "did not look" is exactly how the
# original split survived.
# ---------------------------------------------------------------------------
if [[ "$rc" -eq 2 ]]; then
    if [[ "$(cat "$FINGERPRINT_FILE" 2>/dev/null)" != "BROKEN" ]]; then
        log "checker could not complete (rc=2): ${plain//$'\n'/ }"
        tg "🔧 <b>run-path-watch: the check itself failed</b>
<pre>$(esc "$(printf '%s' "$plain" | tail -5)")</pre>
<i>This is NOT a clean result — the drift question went unanswered.</i>"
        printf 'BROKEN\n' > "$FINGERPRINT_FILE"
    else
        log "checker still failing (rc=2); already alerted, staying quiet"
    fi
    exit 0
fi

# The problem set: every line the checker flags, order-stable.
problems=$(printf '%s\n' "$plain" \
    | grep -E '^[[:space:]]*(DRIFTED|ABSENT-ON-BOX|MISSING-IN-REPO|UNTRACKED|VANISHED|PENDING-RESOLVED)' \
    | sed 's/^[[:space:]]*//' | sort || true)
count=$(printf '%s' "$problems" | grep -c . || true)

previous=$(cat "$FINGERPRINT_FILE" 2>/dev/null || printf 'FIRST-RUN\n')

if [[ "$problems" == "$previous" ]]; then
    # Steady state is SILENT. A watcher that re-reports the same known drift
    # every morning trains its reader to ignore it, and then it is worth
    # nothing on the day the set changes (#156's lesson, learned the hard way
    # on the health-check alerts).
    log "no change: $count problem(s), same as last run"
    exit 0
fi

# Something moved. Say exactly WHAT moved, not just the totals.
appeared=$(comm -13 <(printf '%s\n' "$previous" | sort) <(printf '%s\n' "$problems" | sort) | grep -v '^$' || true)
resolved=$(comm -23 <(printf '%s\n' "$previous" | sort) <(printf '%s\n' "$problems" | sort) | grep -v '^$' || true)

log "CHANGED: $count problem(s); appeared=$(printf '%s' "$appeared" | grep -c . || true) resolved=$(printf '%s' "$resolved" | grep -c . || true)"

msg="🧭 <b>run-path drift changed</b> — $count problem(s) on Sydney"
if [[ "$previous" == "FIRST-RUN" ]]; then
    msg="🧭 <b>run-path-watch is live</b> — baseline: $count problem(s) on Sydney"
fi
[[ -n "$appeared" ]] && msg="$msg

<b>NEW:</b>
<pre>$(esc "$appeared")</pre>"
[[ -n "$resolved" ]] && msg="$msg

<b>RESOLVED:</b>
<pre>$(esc "$resolved")</pre>"
msg="$msg

<i>'orphaned' rows stay red until the schedules move (#3482). Full detail: run scripts/check-run-paths.sh</i>"

tg "$msg"
printf '%s\n' "$problems" > "$FINGERPRINT_FILE"
exit 0
