#!/bin/bash
# QUAD rollback for dreamfinder-avatar: (image AND .env AND compose+override AND worker).
# One rehearsed command — used by BOTH the deploy auto-rollback and the demo-day FREEZE.
# Restores the pre-engine world byte-for-byte from ~/demo-freeze.
set -euo pipefail
APP_DIR="$HOME/apps/dreamfinder-avatar"
FREEZE="$HOME/demo-freeze"
cd "$APP_DIR"

echo "=== QUAD ROLLBACK $(date -u "+%H:%M:%S UTC") ==="
cp "$FREEZE/env.file" .env
cp "$FREEZE/docker-compose.yml" docker-compose.yml
cp "$FREEZE/docker-compose.override.yml" docker-compose.override.yml   # lyra-live needs the key mount
docker tag dreamfinder-avatar-app:pre-engine dreamfinder-avatar-app:latest
docker compose up -d --no-build

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
BOOT_SINCE=$(date -u -d "$(docker inspect -f '{{.State.StartedAt}}' dreamfinder-avatar 2>/dev/null) - 5 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
[ -n "$BOOT_SINCE" ] || { BOOT_SINCE=2m; echo "(could not read container StartedAt — falling back to a 2m wall-clock window, which may miss this boot)"; }
docker logs dreamfinder-avatar --since "$BOOT_SINCE" 2>&1 | grep -i "registered worker" | tail -3 || echo "(no registration line yet — check again in 30s)"
echo "=== rollback complete. VERIFY A SPOKEN TURN NOW (laptop, df.imagineering.cc) ==="
