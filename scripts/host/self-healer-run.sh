#!/usr/bin/env bash
# self-healer cron wrapper (deploy #49). Sources env, runs the on-box healer,
# keeps the latest JSON verdict + a capped human-readable log.
set -uo pipefail
STATE=/home/nick/apps/self-healer-state
mkdir -p "$STATE"
cd /home/nick/apps/imagineering-infra/self-healer || exit 3
set -a; . /home/nick/apps/self-healer.env; set +a
ts=$(date -Is)
echo "=== $ts run ===" >> "$STATE/healer.log"
node src/healer.mjs > "$STATE/last-verdict.json" 2>> "$STATE/healer.log"
ec=$?
echo "[$ts] healer exit=$ec" >> "$STATE/healer.log"
# basic rotation: keep last 2000 log lines
tail -n 2000 "$STATE/healer.log" > "$STATE/healer.log.tmp" 2>/dev/null && mv "$STATE/healer.log.tmp" "$STATE/healer.log"
exit $ec
