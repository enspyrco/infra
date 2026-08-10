#!/bin/bash
# QUAD rollback for lyra-avatar: (src tree AND image AND .env+compose AND worker).
# One rehearsed command — used by BOTH the deploy auto-rollback and by a human.
#
# Differs from dreamfinder's QUAD in its FIRST leg. dreamfinder bakes source into
# the image, so retagging the image restores the code. lyra bind-mounts ./src:/app,
# so the image carries only deps/ENV/CMD — retagging it would leave the NEW source
# running under the OLD image and roll back nothing that matters. The tree is the
# first leg here, and it is the one that actually undoes a bad deploy.
set -euo pipefail
APP_DIR="$HOME/apps/lyra-avatar"
SRC_DIR="$APP_DIR/src"
FREEZE="$HOME/lyra-freeze"
PORT=3017
cd "$APP_DIR"

echo "=== QUAD ROLLBACK lyra-avatar $(date -u "+%H:%M:%S UTC") ==="

# --- leg 1: the src TREE (the thing the container actually runs) ---
PREV=$(cat "$FREEZE/PREV_SHA" 2>/dev/null || true)
[ -n "$PREV" ] || { echo "FATAL: no $FREEZE/PREV_SHA anchor — refusing to guess a target"; exit 1; }
git -C "$SRC_DIR" checkout -q "$PREV"
echo "leg 1 src -> $(git -C "$SRC_DIR" log -1 --oneline)"

# --- leg 2: image ---
if docker image inspect lyra-avatar-app:pre-traversal-fix >/dev/null 2>&1; then
  docker tag lyra-avatar-app:pre-traversal-fix lyra-avatar-app:latest
  echo "leg 2 image -> pre-traversal-fix"
else
  echo "leg 2 image: no pre-traversal-fix anchor — leaving image as-is"
fi

# --- leg 3: env + compose ---
[ -f "$FREEZE/env.file" ]           && cp "$FREEZE/env.file" .env                     && echo "leg 3a .env restored"
[ -f "$FREEZE/docker-compose.yml" ] && cp "$FREEZE/docker-compose.yml" docker-compose.yml && echo "leg 3b compose restored"

docker compose up -d --no-build

# --- leg 4: gates (health, then exactly-one worker) ---
echo "--- health gate ---"
for i in $(seq 1 30); do curl -sf "localhost:$PORT/api/health" >/dev/null && break; sleep 2; done
curl -sf "localhost:$PORT/api/health" >/dev/null || { echo "ROLLBACK HEALTH GATE FAILED"; exit 1; }
echo "health OK"
sleep 8
REG=$(docker logs lyra-avatar --since 2m 2>&1 | grep -c '"msg":"registered worker"' || true)
echo "leg 4 worker registrations in last 2m: $REG (expect exactly 1)"
[ "$REG" -le 1 ] || echo "!! GHOST WORKER after rollback — dispatch will load-balance across duplicates"

cat <<'EOF'
=== ROLLBACK COMPLETE. It is NOT verified until a human does both: ===
  1. a real spoken turn at lyra.imagineering.cc
  2. NOTE: rolling back the traversal fix REOPENS the unauthenticated-read hole.
     This is a deliberate trade — a broken avatar is louder than a quiet leak —
     but do not leave it here. Re-probe with --path-as-is from a non-loopback
     address so you know exactly which state production is in.
EOF
