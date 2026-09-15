#!/bin/bash
# Drives the REAL backup-recency-watch.sh against fixtures, including a replay of
# the 2026-09-05..09-11 outage.
#
# The assertion that matters is not "the watcher works" — it is that it fires on
# the shape that actually happened and that its predecessor did not. So the outage
# fixture is built from the real artifact pattern on the box:
#
#     kanbn/outline/radicale/pm-bot/claudius/minio   fresh every night
#     aiko-island + all five matrix bridges          absent
#
# No network: DRY_RUN=1 makes tg() log instead of POSTing, and HOME is a temp dir
# so state/log files land in the sandbox.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SCRIPT_DIR/watchers/backup-recency-watch.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/backups"; mkdir -p "$FIXTURE"
FAKE_HOME="$WORK/home"; mkdir -p "$FAKE_HOME"

# Run the real script; echo its DRY_RUN log output for this invocation.
run_watcher_once() {
  local before after
  before=$( { wc -l < "$FAKE_HOME/backup-recency-watch.log"; } 2>/dev/null || echo 0)
  HOME="$FAKE_HOME" DRY_RUN=1 BACKUP_DIR="$FIXTURE" bash "$WATCHER" >/dev/null 2>&1
  after=$( { wc -l < "$FAKE_HOME/backup-recency-watch.log"; } 2>/dev/null || echo 0)
  tail -n "$(( after - before ))" "$FAKE_HOME/backup-recency-watch.log" 2>/dev/null
}

fresh() { touch "$FIXTURE/$1-2026-09-11.sql.gz"; }
stale() { touch -d '30 hours ago' "$FIXTURE/$1-2026-09-09.sql.gz" 2>/dev/null \
            || touch -t "$(date -v-30H +%Y%m%d%H%M)" "$FIXTURE/$1-2026-09-09.sql.gz"; }

echo "== REPLAY: the 2026-09-05..09-11 outage shape =="
for s in kanbn outline radicale pm-bot claudius minio; do fresh "$s"; done
# aiko-island and the five bridges deliberately absent — exactly the real pattern.
out=$(run_watcher_once)

if printf '%s' "$out" | grep -q "DRY_RUN"; then
  ok "watcher ALERTED on the outage shape"
else
  no "watcher did not alert on the outage shape" "log: $(printf '%s' "$out" | tr '\n' '|')"
fi
for svc in aiko-island matrix-signal matrix-telegram matrix-whatsapp matrix-discord matrix-relay; do
  printf '%s' "$out" | grep -q "$svc" \
    && ok "names $svc as missing" \
    || no "does not name $svc" "alert text did not mention it"
done
if printf '%s' "$out" | grep -qE "kanbn:|outline:|minio:"; then
  no "false-positives a healthy service" "$(printf '%s' "$out" | tr '\n' '|')"
else
  ok "does not implicate the six services that were working"
fi

echo "== COUNTERFACTUAL: what the predecessor's max-over-directory read would say =="
# The old check: newest file anywhere under the dir, vs a 25h threshold.
newest=0
for f in "$FIXTURE"/*; do
  [ -f "$f" ] || continue
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
  [ "$m" -gt "$newest" ] && newest=$m
done
old_age=$(( ($(date +%s) - newest) / 3600 ))
if [ "$old_age" -lt 25 ]; then
  ok "old ANY-check reads ${old_age}h = HEALTHY on the same fixture (this is the bug it had)"
else
  no "counterfactual" "old check read ${old_age}h — fixture does not reproduce the outage"
fi

echo "== edge-triggered: an unchanged failure set does not re-alert =="
out2=$(run_watcher_once)
if printf '%s' "$out2" | grep -q "no change"; then
  ok "second run with identical state stays quiet"
else
  no "re-alerted on unchanged state" "$(printf '%s' "$out2" | tr '\n' '|')"
fi

echo "== recovery: alerts once when the last failure clears =="
for s in aiko-island matrix-discord matrix-signal matrix-telegram matrix-whatsapp matrix-relay; do fresh "$s"; done
out3=$(run_watcher_once)
printf '%s' "$out3" | grep -qi "healthy" \
  && ok "announces recovery when every service is fresh again" \
  || no "no recovery announcement" "$(printf '%s' "$out3" | tr '\n' '|')"
out4=$(run_watcher_once)
printf '%s' "$out4" | grep -q "no change" \
  && ok "does not repeat the all-clear" \
  || no "repeated the all-clear" "$(printf '%s' "$out4" | tr '\n' '|')"

echo "== a STALE artifact is reported differently from an ABSENT one =="
rm -f "$FIXTURE"/matrix-signal-*; stale matrix-signal
out5=$(run_watcher_once)
printf '%s' "$out5" | grep -qE "matrix-signal:[0-9]+h" \
  && ok "stale service reports an hour count, not 'none'" \
  || no "stale reporting" "$(printf '%s' "$out5" | tr '\n' '|')"

echo "== it does NOT self-disable (standing assertion, not an incident watcher) =="
# COMMAND POSITION, not mere presence. The first version of this grepped for the
# string and matched the watcher's own comment explaining why it does NOT call it —
# the same containing-is-not-calling defect fixed in test-sqlite-dumper.sh earlier
# the same night, written again from scratch here. Recorded rather than quietly
# corrected: knowing that rule did not transfer, so the check has to carry it.
if grep -qE '^[[:space:]]*(if[[:space:]]+!?[[:space:]]*)?(self_disable|run_watcher)([[:space:]]|$|;|\||&)' "$WATCHER"; then
  no "watcher calls self_disable/run_watcher" "a standing backup check must not remove its own cron"
else
  ok "no self_disable or run_watcher call — it keeps asserting after recovery"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
