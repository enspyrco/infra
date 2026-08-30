#!/usr/bin/env bash
# run-path-watch is only worth having if it is EVENT-driven. A watcher that
# re-reports the same known drift every morning trains its reader to ignore it,
# and is then worth nothing on the day the set actually changes — the lesson
# that cost 33 days of silent alert loss on the health-check path (#156).
#
# So the arms that matter are the QUIET ones: steady state must produce no
# alert, and a persistent instrument failure must alert once, not daily.
#
# The checker is stubbed, so nothing touches the box. DRY_RUN makes tg() log
# instead of sending, and the assertions read that log.
#
# Run: scripts/watchers/test-run-path-watch.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/lib" "$SANDBOX/.config/imagineering"
cp "$REPO/scripts/watchers/lib/watcher-base.sh" "$SANDBOX/lib/"
cp "$REPO/scripts/watchers/run-path-watch.sh" "$SANDBOX/"

# Stubbed checker: emits whatever $STUB_OUT holds and exits $STUB_RC.
cat > "$SANDBOX/checker.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$STUB_OUT"
exit "${STUB_RC:-0}"
STUB
chmod +x "$SANDBOX/checker.sh"

# tick <name> <stub-out> <stub-rc> <want-alert: yes|no> [must-contain]
tick() {
    local name="$1" out="$2" rc="$3" want="$4" contains="${5:-}"
    : > "$SANDBOX/run-path-watch.log"
    STUB_OUT="$out" STUB_RC="$rc" \
      HOME="$SANDBOX" DRY_RUN=1 \
      RUN_PATH_CHECKER="$SANDBOX/checker.sh" RUN_PATH_REPO_ROOT=/opt \
      bash "$SANDBOX/run-path-watch.sh" >/dev/null 2>&1

    local alerted=no
    grep -q 'tg \[DRY_RUN\]' "$SANDBOX/run-path-watch.log" 2>/dev/null && alerted=yes

    local ok=1
    [ "$alerted" = "$want" ] || ok=0
    if [ -n "$contains" ] && ! grep -qF "$contains" "$SANDBOX/run-path-watch.log" 2>/dev/null; then ok=0; fi

    if [ "$ok" = 1 ]; then
        printf '  PASS  %-48s alert=%s\n' "$name" "$alerted"; PASS=$((PASS+1))
    else
        printf '  FAIL  %-48s alert=%s (want %s)\n' "$name" "$alerted" "$want"; FAIL=$((FAIL+1))
        sed 's/^/          /' "$SANDBOX/run-path-watch.log" | head -4
    fi
}

TWO=' DRIFTED       /home/ubuntu/email-health-watch.sh (orphaned)
 UNTRACKED      /home/nick/apps/live-game/server.mjs
2 problem(s)'
THREE="$TWO
 UNTRACKED      /home/nick/apps/new-thing.sh"
ONE=' UNTRACKED      /home/nick/apps/live-game/server.mjs
1 problem(s)'

echo "=== the point: steady state must be SILENT ==="
tick "first run: baseline announced"              "$TWO"   0 yes "is live"
tick "same problems again: NO alert"              "$TWO"   0 no
tick "same problems a third time: still NO alert" "$TWO"   0 no

echo
echo "=== changes must speak, and say WHAT changed ==="
tick "a new untracked path appears"               "$THREE" 0 yes "new-thing.sh"
tick "unchanged again after the change"           "$THREE" 0 no
tick "problems resolve"                           "$ONE"   0 yes "RESOLVED"

echo
echo "=== instrument failure is a finding, not a pass — and alerts ONCE ==="
tick "checker exits 2: alerts"                    "FATAL: no sudo" 2 yes "check itself failed"
tick "checker still exits 2: stays quiet"         "FATAL: no sudo" 2 no
tick "recovers after a break: speaks again"       "$TWO"   0 yes

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
