#!/bin/bash
# Gated deploy for dreamfinder-avatar (DF repo, pinned SHA).
# Gates: health -> boot-banner contract -> printenv contract -> worker registration.
# ANY gate failure auto-runs the QUAD rollback (~/bin/rollback-dreamfinder-avatar.sh).
set -euo pipefail
APP_DIR="$HOME/apps/dreamfinder-avatar"
SRC_DIR="$APP_DIR/src"
REPO_URL="git@github-dreamfinder:imagineering-cc/dreamfinder-avatar.git"
FREEZE="$HOME/demo-freeze"
cd "$APP_DIR"

SHA=$(cat "$APP_DIR/DEPLOY_SHA")          # pinned — never a floating branch
CONTRACT=$(cat "$APP_DIR/BOOT_CONTRACT")  # exact expected [voice] contract line
[ -n "$SHA" ] && [ -n "$CONTRACT" ] || { echo "DEPLOY_SHA / BOOT_CONTRACT missing"; exit 1; }

echo "=== Deploying dreamfinder-avatar @ $SHA ==="
date -u "+%Y-%m-%d %H:%M:%S UTC"

# --- 1. src: one-time swap from the old embodied-lyra clone to the DF repo ---
if [ -d "$SRC_DIR/.git" ] && git -C "$SRC_DIR" remote get-url origin | grep -q "embodied-lyra"; then
  echo "one-time: backing up old lyra src tree"
  mv "$SRC_DIR" "$APP_DIR/src-lyra-2ba90a4-backup"
fi
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone "$REPO_URL" "$SRC_DIR"
fi
cd "$SRC_DIR"
git fetch origin
git checkout -q "$SHA"
git lfs pull
echo "src at: $(git log -1 --oneline)"
cd "$APP_DIR"

# --- 2. idempotent rollback anchor (never clobber an existing anchor) ---
docker image inspect dreamfinder-avatar-app:pre-engine >/dev/null 2>&1 \
  || docker tag dreamfinder-avatar-app:latest dreamfinder-avatar-app:pre-engine

# --- 3. build while the old container still serves ---
docker compose -f docker-compose.next.yml build --pull

# --- 4. ATOMIC cutover: env + compose + override flip together, then one up -d ---
[ -f .env.next ] && [ -f docker-compose.next.yml ] || { echo "staged .env.next / docker-compose.next.yml missing"; exit 1; }
grep -q "^BRAIN=" .env.next && grep -q "^STT=" .env.next && grep -q "^TTS=" .env.next && grep -q "^BRAIN_MODEL=" .env.next \
  || { echo ".env.next missing selector lines"; exit 1; }
cp .env.next .env
cp docker-compose.next.yml docker-compose.yml
# override becomes opt-in again (its true name); BRAIN=oauth must not carry the lyra key
[ -f docker-compose.override.yml ] && mv docker-compose.override.yml docker-compose.lyra.yml.was-override
docker compose up -d

rollback() { echo "GATE FAILED: $1 — rolling back"; "$HOME/bin/rollback-dreamfinder-avatar.sh"; exit 1; }

# --- 5. gate: health ---
ok=""
for i in $(seq 1 30); do curl -sf localhost:3015/api/health >/dev/null && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] || rollback "health"
echo "gate 1/4 health OK"

# --- 6. gate: boot-banner contract (exact line, from THIS boot) ---
sleep 10
BANNER=$(docker logs dreamfinder-avatar --since 3m 2>&1 | grep -F "[voice] contract:" | tail -1 | sed "s/^.*\[voice\] contract: //" || true)
[ "$BANNER" = "$CONTRACT" ] || { echo "banner: [$BANNER]"; echo "expect: [$CONTRACT]"; rollback "boot-banner contract"; }
echo "gate 2/4 contract OK: $BANNER"

# --- 7. gate: container env (printenv, never the .env file) ---
for V in VOICE_MODE BRAIN STT TTS BRAIN_MODEL CLAUDE_CODE_OAUTH_TOKEN; do
  VAL=$(docker exec dreamfinder-avatar printenv "$V" 2>/dev/null || true)
  [ -n "$VAL" ] || rollback "printenv $V empty"
done
echo "gate 3/4 printenv OK"

# --- 8. gate: exactly-one worker registered as dreamfinder ---
REG=$(docker logs dreamfinder-avatar --since 3m 2>&1 | grep -ci "registered worker" || true)
[ "$REG" -ge 1 ] || rollback "no worker registration in logs"
echo "gate 4/4 worker registered (lines: $REG)"

# --- 9. record release identity + preserve the forward image ---
IMG=$(docker inspect --format "{{.Image}}" dreamfinder-avatar)
docker tag dreamfinder-avatar-app:latest dreamfinder-avatar-app:post-engine
{ echo "sha=$SHA"; echo "image=$IMG"; echo "env_md5=$(md5sum .env | cut -d" " -f1)"; echo "container=$(docker ps -qf name=dreamfinder-avatar)"; echo "date=$(date -u +%FT%TZ)"; } > "$FREEZE/deployed.txt"
cat "$FREEZE/deployed.txt"
echo "=== DEPLOY GREEN. NOW: voice canary (laptop spoken turn at df.imagineering.cc), then phone/cellular, then rollback rehearsal. ==="
