#!/bin/bash
# QUAD rollback for dreamfinder-avatar: (image AND .env AND compose+override AND worker).
# One rehearsed command — used by BOTH the deploy auto-rollback and the demo-day FREEZE.
# Restores the pre-engine world byte-for-byte from ~/demo-freeze.
set -euo pipefail
APP_DIR="$HOME/apps/dreamfinder-avatar"
FREEZE="$HOME/demo-freeze"
cd "$APP_DIR"

echo "=== QUAD ROLLBACK $(date -u "+%H:%M:%S UTC") ==="

# PREFLIGHT every input BEFORE mutating anything. These are sequential `cp`s under
# `set -e`: previously, a missing docker-compose.override.yml in the freeze aborted
# the script AFTER .env and docker-compose.yml had already been overwritten. A
# half-restored site is not "the old release" and not "the new release" — it is a
# third topology nobody has ever run, produced at the exact moment someone is
# trying to escape an outage. Check all four, then commit.
MISSING=""
for f in env.file docker-compose.yml docker-compose.override.yml; do
  [ -f "$FREEZE/$f" ] || MISSING="$MISSING $f"
done
docker image inspect dreamfinder-avatar-app:pre-engine >/dev/null 2>&1 \
  || MISSING="$MISSING image:pre-engine"
if [ -n "$MISSING" ]; then
  echo "FATAL: rollback inputs missing -$MISSING"
  echo "       Nothing has been changed. Restore the freeze before rolling back."
  exit 1
fi

cp "$FREEZE/env.file" .env
cp "$FREEZE/docker-compose.yml" docker-compose.yml
cp "$FREEZE/docker-compose.override.yml" docker-compose.override.yml   # lyra-live needs the key mount
docker tag dreamfinder-avatar-app:pre-engine dreamfinder-avatar-app:latest
# --force-recreate for the same reason lyra needs it, one layer along: this
# rollback works by RETAGGING, and if pre-engine and latest already resolve to the
# same digest (a never-advanced or poisoned anchor — the known ratchet) then the
# retag is a no-op, `up -d --no-build` is a no-op, and the health gate below
# cheerfully reports OK about the release you were trying to escape.
docker compose up -d --no-build --force-recreate

echo "--- health gate ---"
for _ in $(seq 1 30); do curl -sf localhost:3015/api/health >/dev/null && break; sleep 2; done
curl -sf localhost:3015/api/health >/dev/null || { echo "ROLLBACK HEALTH GATE FAILED"; exit 1; }
echo "health OK"
sleep 8
echo "--- worker registration (expect agentName dreamfinder, exactly one) ---"
# Anchored to the container's own boot, not the wall clock — see the note in
# rollback-lyra-avatar.sh. Informational here, but a spurious empty window during
# a rollback rehearsal is exactly the wrong moment to mislead the operator.
# Guarded — see the matching note in rollback-lyra-avatar.sh. This tail is
# informational and runs AFTER the rollback has already succeeded; under
# `set -euo pipefail` an unguarded assignment here would abort and report a
# completed rollback as a failure.
# Inspect captured on its own line and tested BEFORE date sees it — see the note
# in rollback-lyra-avatar.sh. `date -u -d " - 5 seconds"` is valid GNU date
# (= now-5s, exit 0), so interpolating a failed inspect fails OPEN into a
# five-second window wearing the boot anchor's name.
STARTED_AT=$(docker inspect -f '{{.State.StartedAt}}' dreamfinder-avatar 2>/dev/null || true)
BOOT_SINCE=""
[ -n "$STARTED_AT" ] && BOOT_SINCE=$(date -u -d "$STARTED_AT - 5 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
[ -n "$BOOT_SINCE" ] || { BOOT_SINCE=2m; echo "(could not read container StartedAt — falling back to a 2m wall-clock window, which may miss this boot)"; }
docker logs dreamfinder-avatar --since "$BOOT_SINCE" 2>&1 | grep -i "registered worker" | tail -3 || echo "(no registration line yet — check again in 30s)"
echo "=== rollback complete. VERIFY A SPOKEN TURN NOW (laptop, df.imagineering.cc) ==="
