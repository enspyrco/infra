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
  # `git checkout -- .` restores the worktree from the INDEX, so it clears
  # unstaged edits but leaves STAGED ones in place — and the `git checkout $SHA`
  # below then refuses to run on a dirty index. The stated purpose of this block
  # is "preserve the edits, then don't let checkout die on them"; it only ever
  # delivered that for the unstaged half. `reset --hard HEAD` clears both, and the
  # archive above is taken against HEAD so it already captured staged + unstaged.
  # This fails CLOSED either way (the deploy aborts before any cutover), but a
  # hand-edit silently blocking a deploy is precisely what froze dreamfinder for
  # weeks — so it should abort with THIS script's loud message, not git's.
  git reset --hard HEAD
  # Untracked files are deliberately left alone: they are not in the archive
  # (git diff HEAD does not see them) and destroying an operator's un-added file
  # to make a deploy proceed is not this script's call. They only block a checkout
  # if the incoming tree would overwrite them, in which case git says so plainly.
fi
PREV_SHA=$(git rev-parse HEAD)
# Rollback anchor for the TREE. Only advance it when the tree actually MOVES.
# Re-running a deploy at the same SHA (a no-op, and the normal shape of a retry)
# would otherwise overwrite the anchor with the target itself, leaving a rollback
# that restores the very release you are trying to escape. Same reason the image
# anchor below is guarded — an anchor you can silently overwrite is not an anchor.
if [ "$PREV_SHA" != "$SHA" ]; then
  echo "$PREV_SHA" > "$FREEZE/PREV_SHA"
  echo "rollback anchor -> $PREV_SHA"
else
  echo "rollback anchor unchanged ($(cat "$FREEZE/PREV_SHA" 2>/dev/null || echo none)) — tree already at target"
fi
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
# --force-recreate is REQUIRED for lyra specifically. The deploy unit here is the
# src TREE (compose bind-mounts ./src:/app), but compose decides whether to
# recreate from the IMAGE and config. A src-only change with a fully cached build
# leaves the image id identical, so a bare `up -d` is a NO-OP: the old node
# process keeps serving the old code from memory while the checkout says $SHA.
# Every gate below would then sample the previous release and pass green, and
# deployed.txt would record a release that never started — a false GREEN, where
# the 2026-08-10 incident was a false RED. Anonymous volumes (node_modules) are
# preserved across a recreate; only --renew-anon-volumes would discard them.
docker compose up -d --force-recreate

rollback() { echo "GATE FAILED: $1 — rolling back"; "$HOME/bin/rollback-lyra-avatar.sh"; exit 1; }

# --- 4. gate 1: health ---
ok=""
for _ in $(seq 1 30); do curl -sf "localhost:$PORT/api/health" >/dev/null && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] || rollback "health"
echo "gate 1/5 health OK"

# --- 5. gate 2: boot-banner contract (exact line, from THIS boot) ---
sleep 10

# Anchor the log window to the lyra-avatar'S OWN boot, not the wall clock.
# A wall-clock window (`--since 3m`) is only a PROXY for "this boot", and it stops being one the moment
# `docker compose up -d` is a no-op: an identical cached image means no recreate,
# so the banner was printed at the PREVIOUS boot and the window returns empty.
# On 2026-08-10 that false negative failed gate 2 on a perfectly good dreamfinder
# deploy, and the auto-rollback then restored the pre-engine image — reopening a
# live unauthenticated-read hole. A freshness check keyed to the wall clock rather
# than to the thing whose freshness it asserts is a rollback waiting to happen.
# StartedAt is correct whether or not the container was recreated.
# Failure of the anchor routes through rollback(), not through `set -e` — see the
# matching note in deploy-dreamfinder-avatar.sh. The cutover is already live here,
# so a silent abort would leave an unverified release running with no rollback
# armed. Captured on its own line because `date -u -d " - 5 seconds"` is valid GNU
# date (= now-5s, exit 0) and would otherwise fail OPEN into a 5-second window.
STARTED_AT=$(docker inspect -f '{{.State.StartedAt}}' lyra-avatar 2>/dev/null || true)
BOOT_SINCE=""
[ -n "$STARTED_AT" ] && BOOT_SINCE=$(date -u -d "$STARTED_AT - 5 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
[ -n "$BOOT_SINCE" ] || rollback "cannot read lyra-avatar StartedAt — the boot anchor is unavailable, so gates 2-5 cannot be trusted"
echo "log window anchored to container boot: $BOOT_SINCE"
BANNER=$(docker logs lyra-avatar --since "$BOOT_SINCE" 2>&1 | grep -F "$CONTRACT" | tail -1 || true)
[ -n "$BANNER" ] || { echo "expect: [$CONTRACT]"; docker logs lyra-avatar --since "$BOOT_SINCE" 2>&1 | head -12; rollback "boot-banner contract"; }
echo "gate 2/5 contract OK: $BANNER"

# --- 6. gate 3: container env (printenv, never the .env file) ---
for V in AUTH_PASSWORD AUTH_SECRET LIVEKIT_API_KEY LIVEKIT_API_SECRET OPENAI_API_KEY LYRA_SSH_HOST LYRA_SSH_KEY; do
  VAL=$(docker exec lyra-avatar printenv "$V" 2>/dev/null || true)
  [ -n "$VAL" ] || rollback "printenv $V empty"
done
docker exec lyra-avatar test -r /app/.ssh/lyra-deploy || rollback "brain-hop key not readable in container"
echo "gate 3/5 printenv OK"

# --- 7. gate 4: exactly-one worker registered ---
REG=$(docker logs lyra-avatar --since "$BOOT_SINCE" 2>&1 | grep -c '"msg":"registered worker"' || true)
[ "$REG" -ge 1 ] || rollback "no worker registration in logs"
[ "$REG" -le 1 ] || rollback "GHOST WORKER: $REG registrations — dispatch will load-balance across duplicates"
echo "gate 4/5 exactly one worker registered"

# --- 8. gate 5: deployed-artifact assert on the auth-bypass allowlist.
#         Runs the pure predicate inside the container against the traversal
#         vectors that were live in production. A loopback HTTP probe cannot do
#         this (see header). Fails closed if the module is missing entirely.
# Fed via HEREDOC, not `-e '...'`. A single-quoted shell argument cannot contain
# an apostrophe, and prose comments inside the assert naturally do — that broke
# the block mid-string on the first run and bash tried to execute `//` as a
# command. A quoted heredoc passes the payload through verbatim.
docker exec -i lyra-avatar node --input-type=module <<'ASSERT' || rollback "deployed-artifact allowlist assert"
import { isRendererAsset } from "/app/lib/renderer-assets.js";
// Written out by hand and NOT derived from the module's own exported constants:
// deriving them would only assert that the module agrees with itself, and a
// verifier sharing a representation with the thing it verifies is blind to bugs
// in that shared layer. The cost is that they must be updated DELIBERATELY when
// the allowlist layout moves. That cost is real — the engine-subtree extraction
// moved the renderer's own assets to /engine/..., and the pre-extraction version
// of this list failed 3 of 5 allow-vectors, i.e. it would have rolled back a
// good deploy. Verified against lib/renderer-assets.js at 4a04138 before install.
const mustDeny = [
  "/avatars/../server.js", "/avatars/../lib/scope.js", "/avatars/../package.json",
  "/avatars/../data/last-night.json", "/avatars/%2e%2e/package.json",
  "/avatars/..%2fpackage.json", "/avatars/%252e%252e/server.js",
  "/engine/headaudio/../../server.js", "/avatars/..\\server.js",
  "/avatars//../server.js", "/avatars/./../server.js",
  // moved-prefix regressions: these must NOT be public any more
  "/headaudio/headaudio.min.mjs", "/engine/README.md", "/engine/character.js",
];
const mustAllow = [
  "/avatar", "/engine/avatar-renderer.html", "/engine/avatar-renderer.js",
  "/engine/sparks.js", "/avatars/lyra.glb", "/engine/headaudio/headaudio.min.mjs",
];
const bad = mustDeny.filter(p => isRendererAsset(p));
const broke = mustAllow.filter(p => !isRendererAsset(p));
if (bad.length) { console.error("ALLOWLIST STILL MATCHES TRAVERSAL: " + bad.join(", ")); process.exit(1); }
if (broke.length) { console.error("ALLOWLIST NOW DENIES LEGITIMATE ASSETS: " + broke.join(", ")); process.exit(1); }
console.log("allowlist: " + mustDeny.length + " denied, " + mustAllow.length + " allowed");
ASSERT
echo "gate 5/5 allowlist assert OK"

# --- 9. record release identity + preserve the forward image ---
IMG=$(docker inspect --format "{{.Image}}" lyra-avatar)
docker tag lyra-avatar-app:latest lyra-avatar-app:post-traversal-fix
# prev_sha reads the ANCHOR FILE, not the $PREV_SHA variable: on a re-run at the
# same SHA those differ, and this file is what a human reads to find the rollback
# target. Keep each field on its own line — the previous version put that
# explanation as a trailing `#` comment on the prev_sha line, which swallowed the
# rest of the physical line (`echo "image=$IMG"; \`, backslash included, so not
# even a continuation) and silently dropped image= from every lyra release record.
ANCHOR=$(cat "$FREEZE/PREV_SHA" 2>/dev/null || echo unknown)
{
  echo "sha=$SHA"
  echo "prev_sha=$ANCHOR"
  echo "image=$IMG"
  echo "env_md5=$(md5sum .env | cut -d" " -f1)"
  echo "container=$(docker ps -qf name=lyra-avatar)"
  echo "date=$(date -u +%FT%TZ)"
} > "$FREEZE/deployed.txt"
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
