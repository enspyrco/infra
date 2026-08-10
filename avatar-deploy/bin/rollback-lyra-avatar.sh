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

# --force-recreate is REQUIRED here, not optional tidiness. Leg 1 moved the src
# TREE, and compose bind-mounts ./src:/app — but compose decides whether to
# recreate a container from the IMAGE and config, which this rollback does not
# change. Without it, a rollback can leave the old node process running the old
# code in memory while the disk says PREV_SHA: every gate below then samples a
# process the rollback never actually rolled back. Same class as the wall-clock
# log window — an instrument measuring something adjacent to the claim.
docker compose up -d --no-build --force-recreate

# --- leg 4: gates (health, then exactly-one worker) ---
echo "--- health gate ---"
for _ in $(seq 1 30); do curl -sf "localhost:$PORT/api/health" >/dev/null && break; sleep 2; done
curl -sf "localhost:$PORT/api/health" >/dev/null || { echo "ROLLBACK HEALTH GATE FAILED"; exit 1; }
echo "health OK"
sleep 8
# Same wall-clock-proxy defect the deploy scripts were fixed for on 2026-08-10,
# missed in that sweep because it lives in the rollback half. `--since 2m` is a
# proxy for "this boot" that goes false the moment the container is not recreated
# — and a rollback via `up -d --no-build` is exactly that case. It cannot trigger
# an auto-rollback here (the check below only warns), but it reports 0 to a human
# mid-rehearsal, which reads as a failed rollback. Anchor to the container's boot.
# Guarded: this tail is INFORMATIONAL, and under `set -euo pipefail` a bare
# assignment from a failing command substitution aborts the script. By this point
# every leg has already run and the health gate has already passed, so an abort
# here would report a SUCCESSFUL rollback as a failure — the worst possible signal
# mid-incident. Fall back to a wall-clock window rather than dying.
#
# Capture the inspect result on its OWN line and test it before handing it to
# date. Interpolating it straight into the date expression does NOT fail closed:
# `date -u -d " - 5 seconds"` is a VALID GNU date expression meaning now-5s, so an
# empty inspect silently yields a FIVE-SECOND wall-clock window presented to the
# operator as the boot anchor. Verified on the box — it exits 0 and prints a
# timestamp. That is the same instrument-vs-claim defect this whole file is about.
STARTED_AT=$(docker inspect -f '{{.State.StartedAt}}' lyra-avatar 2>/dev/null || true)
BOOT_SINCE=""
[ -n "$STARTED_AT" ] && BOOT_SINCE=$(date -u -d "$STARTED_AT - 5 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
if [ -n "$BOOT_SINCE" ]; then
  WINDOW_DESC="since container boot ($BOOT_SINCE)"
else
  BOOT_SINCE=2m
  WINDOW_DESC="last 2m (FALLBACK — could not read container StartedAt; this window is a wall-clock proxy and may miss or over-count)"
fi
REG=$(docker logs lyra-avatar --since "$BOOT_SINCE" 2>&1 | grep -c '"msg":"registered worker"' || true)
echo "leg 4 worker registrations $WINDOW_DESC: $REG (expect exactly 1)"
[ "$REG" -le 1 ] || echo "!! GHOST WORKER after rollback — dispatch will load-balance across duplicates"
# ZERO is absence, not health. Only the upper bound was warned on, so a rolled-back
# container that never registered a worker printed a bare "0" next to an
# "expect exactly 1" echo and said nothing — the soft lie that lets an operator
# mid-rehearsal read a FAILED rollback as a finished one.
[ "$REG" -ge 1 ] || echo "!! NO WORKER REGISTERED after rollback — the site is up but will not answer a spoken turn. Do NOT walk away from this."

cat <<'EOF'
=== ROLLBACK COMPLETE. It is NOT verified until a human does a real spoken ===
=== turn at lyra.imagineering.cc.                                          ===

  The traversal fix is NOT lost by this rollback. The tree anchor in
  lyra-freeze/PREV_SHA is the security-fix commit itself, and lyra runs the
  TREE (compose bind-mounts ./src:/app), so leg 1 restores code that already
  carries the fix. Verified against the box on 2026-08-10.

  This block previously warned the opposite — that rolling back REOPENED the
  unauthenticated-read hole. That was true of an older anchor and became false
  when the anchor advanced; nothing updated the warning, because it lived only
  in an untracked file. It is left recorded here rather than silently deleted,
  because the failure it represents is the point: a rollback script that tells
  an operator at 3am that the safe action is dangerous will stop them taking it.

  Still re-probe with --path-as-is from a NON-LOOPBACK address afterwards, so
  you know from measurement rather than inference which state production is in.
  lib/scope.js grants LOCALHOST_IPS base scope, so a probe from the box returns
  200 for everything and reads as a false green.
EOF
