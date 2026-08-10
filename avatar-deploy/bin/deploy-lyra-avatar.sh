#!/bin/bash
# Gated deploy for lyra-avatar (imagineering-cc/lyra-avatar, pinned SHA).
#
# Sibling of ~/bin/deploy-dreamfinder-avatar.sh, but NOT a copy — lyra differs in
# two ways that change the shape of both deploy and rollback:
#
#   1. compose bind-mounts ./src:/app. The running code IS the checked-out tree,
#      not a layer baked into the image. So the deploy unit is the SRC SHA, and
#      rollback must restore the TREE, not just retag an image.
#   2. there is no BRAIN/STT/TTS selector matrix — lyra-live is the only mode.
#      The env contract is correspondingly different (her brain-hop ssh key is
#      load-bearing and unconditional).
#
# Gates: health -> boot-banner contract -> printenv contract -> worker
# registration -> deployed-artifact assert on the auth-bypass allowlist.
# ANY gate failure auto-runs ~/bin/rollback-lyra-avatar.sh.
#
# NOTE ON GATE 5. The traversal fix cannot be verified over HTTP from this box:
# lib/scope.js grants LOCALHOST_IPS base scope, so a loopback probe returns 200
# for everything and reads as a false green. That exact mistake was made on this
# exact boundary. Gate 5 therefore calls the pure predicate inside the running
# container instead. The end-to-end proof is a NON-LOOPBACK probe, printed as the
# closing instruction — it is not, and cannot be, automated from here.
set -euo pipefail
APP_DIR="$HOME/apps/lyra-avatar"
SRC_DIR="$APP_DIR/src"
REPO_URL="git@github-lyra:imagineering-cc/lyra-avatar.git"
FREEZE="$HOME/lyra-freeze"
PORT=3017
mkdir -p "$FREEZE"
cd "$APP_DIR"

SHA=$(cat "$APP_DIR/DEPLOY_SHA")          # pinned — never a floating branch
CONTRACT=$(cat "$APP_DIR/BOOT_CONTRACT")  # exact expected auth banner line
[ -n "$SHA" ] && [ -n "$CONTRACT" ] || { echo "DEPLOY_SHA / BOOT_CONTRACT missing"; exit 1; }

echo "=== Deploying lyra-avatar @ $SHA ==="
date -u "+%Y-%m-%d %H:%M:%S UTC"

# --- 1. src: fetch + pin. Canonicalise the remote (repo was renamed from
#         embodied-lyra) and preserve any hand-applied local edits rather than
#         letting checkout die on them. A stale hand-edit on the box blocked the
#         dreamfinder deploy for weeks; find out here, loudly, not at checkout.
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone "$REPO_URL" "$SRC_DIR"
fi
cd "$SRC_DIR"
git remote set-url origin "$REPO_URL"
if ! git diff --quiet || ! git diff --cached --quiet; then
  STAMP=$(date -u +%Y%m%d%H%M%S)
  echo "!! local modifications on the box — archiving to $FREEZE/local-mods-$STAMP.patch"
  git diff HEAD > "$FREEZE/local-mods-$STAMP.patch"
  git --no-pager diff --stat HEAD
  git checkout -- .
fi
PREV_SHA=$(git rev-parse HEAD)
echo "$PREV_SHA" > "$FREEZE/PREV_SHA"     # rollback anchor for the TREE
git fetch origin
git checkout -q "$SHA"
command -v git-lfs >/dev/null 2>&1 && git lfs pull || echo "(git-lfs not configured — skipping lfs pull)"
echo "src: $PREV_SHA -> $(git log -1 --oneline)"
cd "$APP_DIR"

# --- 2. idempotent rollback anchors (never clobber an existing anchor) ---
docker image inspect lyra-avatar-app:pre-traversal-fix >/dev/null 2>&1 \
  || docker tag lyra-avatar-app:latest lyra-avatar-app:pre-traversal-fix
[ -f "$FREEZE/env.file" ]           || cp .env "$FREEZE/env.file"
[ -f "$FREEZE/docker-compose.yml" ] || cp docker-compose.yml "$FREEZE/docker-compose.yml"

# --- 3. build. MANDATORY even though ./src is bind-mounted: ENV and CMD come
#         from the image, node_modules is an anon volume seeded from the image,
#         and a dependency change would otherwise ship a tree the image cannot run.
docker compose build --pull
docker compose up -d

rollback() { echo "GATE FAILED: $1 — rolling back"; "$HOME/bin/rollback-lyra-avatar.sh"; exit 1; }

# --- 4. gate 1: health ---
ok=""
for i in $(seq 1 30); do curl -sf "localhost:$PORT/api/health" >/dev/null && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] || rollback "health"
echo "gate 1/5 health OK"

# --- 5. gate 2: boot-banner contract (exact line, from THIS boot) ---
sleep 10
BANNER=$(docker logs lyra-avatar --since 3m 2>&1 | grep -F "$CONTRACT" | tail -1 || true)
[ -n "$BANNER" ] || { echo "expect: [$CONTRACT]"; docker logs lyra-avatar --since 3m 2>&1 | head -12; rollback "boot-banner contract"; }
echo "gate 2/5 contract OK: $BANNER"

# --- 6. gate 3: container env (printenv, never the .env file) ---
for V in AUTH_PASSWORD AUTH_SECRET LIVEKIT_API_KEY LIVEKIT_API_SECRET OPENAI_API_KEY LYRA_SSH_HOST LYRA_SSH_KEY; do
  VAL=$(docker exec lyra-avatar printenv "$V" 2>/dev/null || true)
  [ -n "$VAL" ] || rollback "printenv $V empty"
done
docker exec lyra-avatar test -r /app/.ssh/lyra-deploy || rollback "brain-hop key not readable in container"
echo "gate 3/5 printenv OK"

# --- 7. gate 4: exactly-one worker registered ---
REG=$(docker logs lyra-avatar --since 3m 2>&1 | grep -c '"msg":"registered worker"' || true)
[ "$REG" -ge 1 ] || rollback "no worker registration in logs"
[ "$REG" -le 1 ] || rollback "GHOST WORKER: $REG registrations — dispatch will load-balance across duplicates"
echo "gate 4/5 exactly one worker registered"

# --- 8. gate 5: deployed-artifact assert on the auth-bypass allowlist.
#         Runs the pure predicate inside the container against the traversal
#         vectors that were live in production. A loopback HTTP probe cannot do
#         this (see header). Fails closed if the module is missing entirely.
docker exec lyra-avatar node --input-type=module -e '
import { isRendererAsset } from "/app/lib/renderer-assets.js";
const mustDeny = [
  "/avatars/../server.js", "/avatars/../lib/scope.js", "/avatars/../package.json",
  "/avatars/../data/last-night.json", "/avatars/%2e%2e/package.json",
  "/avatars/..%2fpackage.json", "/headaudio/../../server.js", "/avatars/..\\server.js",
  "/avatars//../server.js", "/avatars/./../server.js", "/avatars/%00/../server.js",
];
const mustAllow = ["/avatar", "/avatar-renderer.js", "/sparks.js", "/avatars/lyra.glb", "/headaudio/a.wav"];
const bad = mustDeny.filter(p => isRendererAsset(p));
const broke = mustAllow.filter(p => !isRendererAsset(p));
if (bad.length) { console.error("ALLOWLIST STILL MATCHES TRAVERSAL: " + bad.join(", ")); process.exit(1); }
if (broke.length) { console.error("ALLOWLIST NOW DENIES LEGITIMATE ASSETS: " + broke.join(", ")); process.exit(1); }
console.log("allowlist: " + mustDeny.length + " traversal vectors denied, " + mustAllow.length + " real assets allowed");
' || rollback "deployed-artifact allowlist assert"
echo "gate 5/5 allowlist assert OK"

# --- 9. record release identity + preserve the forward image ---
IMG=$(docker inspect --format "{{.Image}}" lyra-avatar)
docker tag lyra-avatar-app:latest lyra-avatar-app:post-traversal-fix
{ echo "sha=$SHA"; echo "prev_sha=$PREV_SHA"; echo "image=$IMG"; \
  echo "env_md5=$(md5sum .env | cut -d" " -f1)"; \
  echo "container=$(docker ps -qf name=lyra-avatar)"; echo "date=$(date -u +%FT%TZ)"; } > "$FREEZE/deployed.txt"
cat "$FREEZE/deployed.txt"

cat <<'EOF'
=== DEPLOY GREEN — but NOT verified. Two things remain, both off-box: ===
  1. TRAVERSAL PROBE from a NON-LOOPBACK address. Loopback gets base scope in
     lib/scope.js, so probing from here returns 200 and lies. From a laptop:
       for p in /avatars/../server.js /avatars/%2e%2e/package.json /avatars/..%2fpackage.json; do
         curl -s --path-as-is -o /dev/null -w "%{http_code} $p\n" "https://lyra.imagineering.cc$p"
       done
     Expect 303 on every line. Use --path-as-is: curl strips ../ client-side
     without it, so the probe silently tests a different URL and reads green.
  2. VOICE CANARY — a real spoken turn at lyra.imagineering.cc, then a rollback
     rehearsal (~/bin/rollback-lyra-avatar.sh). Requires a human.
EOF
