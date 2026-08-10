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

# --- leg 0: PREFLIGHT every input before mutating anything ---
# Matches rollback-dreamfinder-avatar.sh. Previously leg 1 moved the live tree
# FIRST and legs 2/3 were soft (`[ -f … ] && cp`), so a freeze missing env.file
# produced PREV tree + CURRENT env + CURRENT compose — a fourth topology nobody
# has ever run, assembled during an incident, while the banner still said "QUAD".
# Soft-restoring an input is only kind if the caller can tell it was skipped; here
# it was silent. Check everything, then commit to the whole rollback or none of it.
PREV=$(cat "$FREEZE/PREV_SHA" 2>/dev/null || true)
MISSING=""
[ -n "$PREV" ] || MISSING="$MISSING PREV_SHA"
[ -f "$FREEZE/env.file" ] || MISSING="$MISSING env.file"
[ -f "$FREEZE/docker-compose.yml" ] || MISSING="$MISSING docker-compose.yml"
# LFS AVAILABILITY is preflighted here, before the tree moves, so the one half of
# the LFS risk that CAN be checked in advance is checked in advance. Whether a pull
# will succeed cannot be — that depends on the network and the LFS endpoint at the
# moment it runs — which is why leg 1 warns and continues rather than aborting
# mid-rollback. Named tradeoff, not an oversight: two reviewers wanted opposite
# behaviours here. A DEPLOY may refuse to proceed on a bad pull; a ROLLBACK is
# already an incident response, and stopping it halfway leaves the old process
# serving the release you are escaping. Landing incomplete beats not landing.
if git -C "$SRC_DIR" ls-files 2>/dev/null | grep -q . && [ -f "$SRC_DIR/.gitattributes" ] \
   && grep -q 'filter=lfs' "$SRC_DIR/.gitattributes" 2>/dev/null \
   && ! command -v git-lfs >/dev/null 2>&1; then
  MISSING="$MISSING git-lfs(repo tracks LFS files but no client installed)"
fi
[ -n "$PREV" ] && { git -C "$SRC_DIR" cat-file -e "${PREV}^{commit}" 2>/dev/null || MISSING="$MISSING PREV_SHA($PREV)-not-in-src-repo"; }
if [ -n "$MISSING" ]; then
  echo "FATAL: rollback inputs missing -$MISSING"
  echo "       Nothing has been changed. Restore $FREEZE before rolling back."
  exit 1
fi

# --- leg 1: the src TREE (the thing the container actually runs) ---
git -C "$SRC_DIR" checkout -q "$PREV"
# Materialise LFS blobs, exactly as the deploy path does after it pins a SHA.
# Without this the rollback restores POINTER FILES: /api/health goes green, the
# mesh 404s, and the spoken turn fails — the same soft lie as a stale log window,
# one layer down. The deploy swept this class; the rollback half was missed.
# Not currently load-bearing (neither repo has .gitattributes yet) — which is
# exactly why it must go in now rather than the day LFS is switched on.
# NOTE the deliberate asymmetry with the DEPLOY path, which fails closed here.
# This point is AFTER the first live mutation (the tree has already moved) and
# BEFORE the cutover. Exiting here — which is what the first version of this fix
# did — leaves the disk at PREV while the old process keeps serving the release
# you are trying to escape, under a banner reading "FATAL". A rollback that stops
# halfway is not a safe failure; the whole value of the QUAD is that it completes.
# So: warn as loudly as possible and press on to the cutover. A deploy may refuse
# to proceed; a rollback must land.
if command -v git-lfs >/dev/null 2>&1; then
  git -C "$SRC_DIR" lfs pull \
    || echo "!! git lfs pull FAILED during rollback — the tree may hold POINTER FILES. Continuing to the cutover anyway (a half-rollback is worse). Health may go green with assets missing; check a real spoken turn."
else
  echo "(git-lfs not installed — skipping lfs pull)"
fi
echo "leg 1 src -> $(git -C "$SRC_DIR" log -1 --oneline)"

# --- leg 2: image ---
if docker image inspect lyra-avatar-app:pre-traversal-fix >/dev/null 2>&1; then
  docker tag lyra-avatar-app:pre-traversal-fix lyra-avatar-app:latest
  echo "leg 2 image -> pre-traversal-fix"
else
  echo "leg 2 image: no pre-traversal-fix anchor — leaving image as-is"
fi

# --- leg 3: env + compose (existence already asserted in leg 0) ---
cp "$FREEZE/env.file" .env                                  && echo "leg 3a .env restored"
cp "$FREEZE/docker-compose.yml" docker-compose.yml          && echo "leg 3b compose restored"

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
