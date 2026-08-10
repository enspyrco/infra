#!/bin/bash
# Gated deploy for dreamfinder-avatar (DF repo, pinned SHA).
# Gates: health -> boot-banner contract -> printenv contract -> worker
# registration -> deployed-artifact assert on the auth-bypass allowlist.
# ANY gate failure auto-runs the QUAD rollback (~/bin/rollback-dreamfinder-avatar.sh).
#
# NOTE ON GATE 5. The traversal fix cannot be verified over HTTP from this box:
# lib/scope.js grants LOCALHOST_IPS base scope, so a loopback probe returns 200 for
# everything and reads as a false green. That exact mistake was made on this exact
# boundary, on THIS host — df.imagineering.cc/avatars/../server.js served 200 with
# full source for ~10 minutes on 2026-08-10. Gate 5 therefore calls the pure
# predicate inside the running container. The end-to-end proof is a NON-LOOPBACK
# probe, printed as the closing instruction — it is not, and cannot be, automated
# from here.
set -euo pipefail
APP_DIR="$HOME/apps/dreamfinder-avatar"
SRC_DIR="$APP_DIR/src"
REPO_URL="git@github-dreamfinder:imagineering-cc/dreamfinder-avatar.git"
FREEZE="$HOME/demo-freeze"
# mkdir -p, matching lyra. Without it the deploy can pass all five gates and then
# die on the record step, leaving a green release with no identity file — a
# scaffolding failure after live mutation, the class this script keeps meeting.
mkdir -p "$FREEZE"
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
# Guarded to match deploy-lyra-avatar.sh: an ABSENT client is skippable, an
# INSTALLED one that fails must fail closed. A bare `git lfs pull` under `set -e`
# turns a missing binary into a hard deploy stop, which is the opposite of the
# sibling's behaviour on the same substrate.
if command -v git-lfs >/dev/null 2>&1; then
  git lfs pull
else
  echo "(git-lfs not installed — skipping lfs pull)"
fi
echo "src at: $(git log -1 --oneline)"
cd "$APP_DIR"

# --- 2. idempotent rollback anchor (never clobber an existing anchor) ---
docker image inspect dreamfinder-avatar-app:pre-engine >/dev/null 2>&1 \
  || docker tag dreamfinder-avatar-app:latest dreamfinder-avatar-app:pre-engine

# --- 3. build while the old container still serves ---
docker compose -f docker-compose.next.yml build --pull

# rollback() is defined BEFORE the cutover, not after it, so that everything from
# the first live mutation onward has a recovery path in scope. `trap - ERR` inside
# it disarms the trap armed below, so a failure DURING the rollback cannot re-enter
# rollback and recurse.
rollback() {
  trap - ERR
  echo "GATE FAILED: $1 — rolling back"
  "$HOME/bin/rollback-dreamfinder-avatar.sh"
  exit 1
}

# PREFLIGHT THE FREEZE before the cutover. rollback-dreamfinder-avatar.sh
# hard-requires env.file, docker-compose.yml, docker-compose.override.yml and the
# pre-engine image, and exits 1 having changed NOTHING if any is absent. Without
# this check the sequence is: cutover goes live -> a gate fails -> the auto-rollback
# refuses to run -> the bad release stays up, while the script header promises QUAD
# recovery. An auto-rollback is a switch; this makes sure the breaker behind it is
# actually installed. Seed-if-absent first (matching lyra), since the correct freeze
# content IS the pre-cutover state we are standing in right now.
[ -f "$FREEZE/env.file" ]                       || cp .env "$FREEZE/env.file"
[ -f "$FREEZE/docker-compose.yml" ]             || cp docker-compose.yml "$FREEZE/docker-compose.yml"
# The override is the awkward one: every green deploy RENAMES it to
# docker-compose.lyra.yml.was-override (step 4 below), so after the first cutover
# the file this seeds from no longer exists under that name. Wipe ~/demo-freeze
# once and the deploy would refuse forever while its only seed source sat under
# the other name — a refusal with no path out, written by the same script that
# renamed it. Accept either name.
if [ ! -f "$FREEZE/docker-compose.override.yml" ]; then
  if [ -f docker-compose.override.yml ]; then
    cp docker-compose.override.yml "$FREEZE/docker-compose.override.yml"
  elif [ -f docker-compose.lyra.yml.was-override ]; then
    cp docker-compose.lyra.yml.was-override "$FREEZE/docker-compose.override.yml"
  fi
fi
FREEZE_MISSING=""
for f in env.file docker-compose.yml docker-compose.override.yml; do
  [ -f "$FREEZE/$f" ] || FREEZE_MISSING="$FREEZE_MISSING $f"
done
docker image inspect dreamfinder-avatar-app:pre-engine >/dev/null 2>&1 \
  || FREEZE_MISSING="$FREEZE_MISSING image:pre-engine"
if [ -n "$FREEZE_MISSING" ]; then
  echo "FATAL: the rollback freeze is incomplete -$FREEZE_MISSING"
  echo "       Refusing to cut over: the auto-rollback armed below could not run,"
  echo "       so a gate failure would leave the new release live with no recovery."
  echo "       Nothing has been changed."
  exit 1
fi

# --- 4. ATOMIC cutover: env + compose + override flip together, then one up -d ---
[ -f .env.next ] && [ -f docker-compose.next.yml ] || { echo "staged .env.next / docker-compose.next.yml missing"; exit 1; }
grep -q "^BRAIN=" .env.next && grep -q "^STT=" .env.next && grep -q "^TTS=" .env.next && grep -q "^BRAIN_MODEL=" .env.next \
  || { echo ".env.next missing selector lines"; exit 1; }
# ARM the rollback at dreamfinder's FIRST PRODUCTION MUTATION — the env/compose
# flip below, not after `up -d`. Same invariant as lyra, different first mutation:
# the trap must cover exactly the window in which production is mutated but not yet
# verified. dreamfinder bakes source into the image, so its tree checkout above is
# genuinely staging and must NOT be covered; the flip of .env and docker-compose.yml
# is where production starts changing.
#
# Armed only after `up -d`, a partial or failed compose cutover — the command most
# likely to stop and recreate the live container — exited under `set -e` with no
# rollback, which is precisely the window the comments claimed to close.
trap 'rollback "unhandled failure at line $LINENO"' ERR

cp .env.next .env
cp docker-compose.next.yml docker-compose.yml
# override becomes opt-in again (its true name); BRAIN=oauth must not carry the lyra key
[ -f docker-compose.override.yml ] && mv docker-compose.override.yml docker-compose.lyra.yml.was-override
# --force-recreate, matching lyra's deploy and both rollbacks. The log window was
# taught to stop proxying "this boot"; the CUTOVER was still proxying "this
# release". When compose elects a no-op (cached image, config that happens to
# match), the container is never recreated and gates 2-4 sample the PREVIOUS
# incarnation under a fresh contract narrative — a false GREEN, the mirror image
# of the false RED that caused the 2026-08-10 regression. Forcing the recreate
# makes "a new process started" a fact rather than an inference.
docker compose up -d --force-recreate


# --- 5. gate: health ---
ok=""
for _ in $(seq 1 30); do curl -sf localhost:3015/api/health >/dev/null && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] || rollback "health"
echo "gate 1/5 health OK"

# --- 6. gate: boot-banner contract (exact line, from THIS boot) ---

# Anchor the log window to the dreamfinder-avatar'S OWN boot, not the wall clock.
# A wall-clock window (`--since 3m`) is only a PROXY for "this boot", and it stops being one the moment
# `docker compose up -d` is a no-op: an identical cached image means no recreate,
# so the banner was printed at the PREVIOUS boot and the window returns empty.
# On 2026-08-10 that false negative failed gate 2 on a perfectly good dreamfinder
# deploy, and the auto-rollback then restored the pre-engine image — reopening a
# live unauthenticated-read hole. A freshness check keyed to the wall clock rather
# than to the thing whose freshness it asserts is a rollback waiting to happen.
# StartedAt is correct whether or not the container was recreated.
# Route a FAILURE of the anchor itself through rollback(), not through `set -e`.
# The cutover has already happened by this point. An unguarded assignment here
# aborts the whole script on a container rename or a missing container, leaving
# the NEW release live with gates 2-4 never evaluated and no rollback fired —
# gate LOGIC failures roll back, gate SCAFFOLDING failures walked away. And it
# must be captured on its own line first: `date -u -d " - 5 seconds"` is a VALID
# GNU date expression (= now-5s, exit 0), so interpolating a failed inspect fails
# OPEN into a five-second window wearing the boot anchor's name.
STARTED_AT=$(docker inspect -f '{{.State.StartedAt}}' dreamfinder-avatar 2>/dev/null || true)
BOOT_SINCE=""
[ -n "$STARTED_AT" ] && BOOT_SINCE=$(date -u -d "$STARTED_AT - 5 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
[ -n "$BOOT_SINCE" ] || rollback "cannot read dreamfinder-avatar StartedAt — the boot anchor is unavailable, so gates 2-5 cannot be trusted"
echo "log window anchored to container boot: $BOOT_SINCE"
# POLL for the banner rather than `sleep 10` and look once. A fixed sleep is the
# same instrument class as the wall-clock log window in a softer register: it
# asserts "the banner has been printed by now" using elapsed time as the proxy.
# Under a slow voice init the banner arrives late, gate 2 reads empty, and the
# auto-rollback fires on a perfectly good deploy — reproducing the 2026-08-10
# topology without a single `--since 3m` left in the file. Waiting for the thing
# itself can only ever be more patient than waiting for the clock; the deploy is
# still bounded, it just fails on the CONTRACT rather than on the stopwatch.
BANNER=""
for _ in $(seq 1 30); do
  BANNER=$(docker logs dreamfinder-avatar --since "$BOOT_SINCE" 2>&1 | grep -F "[voice] contract:" | tail -1 | sed "s/^.*\[voice\] contract: //" || true)
  [ "$BANNER" = "$CONTRACT" ] && break
  sleep 2
done
[ "$BANNER" = "$CONTRACT" ] || { echo "banner: [$BANNER]"; echo "expect: [$CONTRACT]"; rollback "boot-banner contract"; }
echo "gate 2/5 contract OK: $BANNER"

# --- 7. gate: container env (printenv, never the .env file) ---
for V in VOICE_MODE BRAIN STT TTS BRAIN_MODEL CLAUDE_CODE_OAUTH_TOKEN; do
  VAL=$(docker exec dreamfinder-avatar printenv "$V" 2>/dev/null || true)
  [ -n "$VAL" ] || rollback "printenv $V empty"
done
echo "gate 3/5 printenv OK"

# --- 8. gate: AT LEAST ONE worker registered as dreamfinder ---
# NOTE the asymmetry with lyra, which also enforces an UPPER bound and rolls back
# on a ghost worker. This gate is lower-bound only; two registrations pass green
# here and dispatch then load-balances across duplicates. The comment used to read
# "exactly-one", which described an enforcement that was never written.
# Deliberately NOT aligned in this PR: arming a new auto-rollback trigger on a
# script whose rollback path has never once been rehearsed is how the 2026-08-10
# regression happened. Align it after the rehearsal — see the follow-up task.
REG=$(docker logs dreamfinder-avatar --since "$BOOT_SINCE" 2>&1 | grep -ci "registered worker" || true)
[ "$REG" -ge 1 ] || rollback "no worker registration in logs"
echo "gate 4/5 worker registered (lines: $REG)"

# --- 8b. gate 5: deployed-artifact assert on the auth-bypass allowlist.
#          THIS host is where the hole actually bled. On 2026-08-10
#          df.imagineering.cc/avatars/../server.js served 200 with full source for
#          ~10 minutes. The fixes above address the false RED that caused the
#          rollback ONTO the vulnerable image; this is the instrument that refuses
#          a false GREEN while the hole is open. Health and the boot banner can
#          both pass with a broken allowlist — they measure different things.
#
#          It CANNOT be an HTTP probe from this box. lib/scope.js grants
#          LOCALHOST_IPS base scope, so a loopback request returns 200 for
#          everything and reads as a false green. That exact mistake was made on
#          this exact boundary. So: call the pure predicate inside the running
#          container, against the artifact that was actually deployed.
#
#          Fed by QUOTED heredoc, not `node -e '...'`: a single-quoted shell
#          argument cannot contain an apostrophe, and prose comments in here do.
#          That broke lyra's version mid-string on its first run and bash tried to
#          execute `//` as a command.
docker exec -i dreamfinder-avatar node --input-type=module <<'ASSERT' || rollback "deployed-artifact allowlist assert"
import { isRendererAsset, isAllowedMeshPath } from "/app/lib/renderer-assets.js";
// Vectors are written out BY HAND and NOT derived from the module's exported
// constants. Deriving them would only assert that the module agrees with itself,
// and a verifier sharing a representation with the thing it verifies is blind to
// bugs in that shared layer. The cost is real and must be paid deliberately when
// the layout moves: lyra's pre-extraction list failed 3 of its 5 allow-vectors
// after the engine subtree landed, i.e. it would have rolled back a good deploy.
// Verified against the deployed /app/lib/renderer-assets.js on 2026-08-10.
const mustDeny = [
  // The vectors that were LIVE in production. /avatars/ is an allowlisted prefix,
  // so a raw-path prefix match admitted these and express.static then resolved
  // the traversal and served the file.
  "/avatars/../server.js", "/avatars/../lib/scope.js", "/avatars/../package.json",
  "/avatars/../data/last-night.json",
  // encoding variants of the same idea
  "/avatars/%2e%2e/package.json", "/avatars/..%2fpackage.json",
  "/avatars/%252e%252e/server.js",            // double-encoded: decode is not a fixed point
  "/avatars/..\\server.js",                   // backslash separator
  "/avatars//../server.js", "/avatars/./../server.js",
  "/avatars/%00/../server.js",                // NUL truncation
  // moved-prefix regressions: public BEFORE the extraction, must not be now.
  // If any of these start passing, the allowlist has drifted back.
  "/headaudio/headaudio.min.mjs", "/avatar-renderer.js", "/sparks.js",
  // engine internals sharing the /engine/ stem but NOT allowlisted
  "/engine/README.md", "/engine/character.js", "/engine/agent-runner.js",
  // and the ordinary protected surface
  "/server.js", "/lib/scope.js",
];
const mustAllow = [
  "/avatar", "/engine/avatar-renderer.html", "/engine/avatar-renderer.js",
  "/engine/sparks.js", "/engine/headaudio/headaudio.min.mjs",
  "/avatars/dreamfinder.glb", "/avatars/dreamfinder-compressed.glb",
];
// isAllowedMeshPath guards the ?avatar= override on the UNAUTHENTICATED renderer
// page. The module's own header calls this the one part of the extraction that
// genuinely widened what an anonymous caller can reach: an open loader fetching
// arbitrary remote geometry under our origin. lyra's gate does not test it.
const meshMustDeny = [
  "https://evil.example/payload.glb",         // absolute cross-origin
  "//evil.example/payload.glb",               // protocol-relative reads as absolute
  "data:model/gltf-binary;base64,AAAA",       // inline payload
  "/avatars/../../etc/passwd.glb",            // traversal wearing a mesh extension
  "/avatars/%2e%2e/x.glb",
  "/avatars/x.glb%00.txt",                    // NUL truncation back to a mesh extension
  "/avatars/notamesh.txt",                    // public but not geometry
  "/engine/sparks.js",                        // readable, but not a mesh
  "avatars/dreamfinder.glb",                  // bare relative
];
const meshMustAllow = ["/avatars/dreamfinder.glb", "/avatars/dreamfinder-compressed.glb"];

const bad = mustDeny.filter((p) => isRendererAsset(p));
const broke = mustAllow.filter((p) => !isRendererAsset(p));
const meshBad = meshMustDeny.filter((p) => isAllowedMeshPath(p));
const meshBroke = meshMustAllow.filter((p) => !isAllowedMeshPath(p));
if (bad.length) { console.error("ALLOWLIST STILL MATCHES TRAVERSAL: " + bad.join(", ")); process.exit(1); }
if (broke.length) { console.error("ALLOWLIST NOW DENIES LEGITIMATE ASSETS: " + broke.join(", ")); process.exit(1); }
if (meshBad.length) { console.error("MESH GUARD ACCEPTS A FOREIGN/TRAVERSAL MESH: " + meshBad.join(", ")); process.exit(1); }
if (meshBroke.length) { console.error("MESH GUARD NOW DENIES OUR OWN MESH: " + meshBroke.join(", ")); process.exit(1); }
console.log("allowlist: " + mustDeny.length + " denied, " + mustAllow.length + " allowed; mesh guard: "
  + meshMustDeny.length + " denied, " + meshMustAllow.length + " allowed");
ASSERT
echo "gate 5/5 allowlist assert OK"

# DISARM. The trap covers the window from cutover to the last gate — a failure in
# there means the release is unverified and should be rolled back. Past this line
# the release has PASSED all five gates, and everything remaining is bookkeeping:
# docker inspect, a tag, writing deployed.txt. Leaving the trap armed wires the
# record step into the recovery bus, so a full disk or a permissions slip would
# roll back a release that was just proven good. "Any GATE failure rolls back" is
# the contract; a bookkeeping spark is not a gate failure.
trap - ERR

# --- 9. record release identity + preserve the forward image ---
IMG=$(docker inspect --format "{{.Image}}" dreamfinder-avatar)
docker tag dreamfinder-avatar-app:latest dreamfinder-avatar-app:post-engine
{ echo "sha=$SHA"; echo "image=$IMG"; echo "env_md5=$(md5sum .env | cut -d" " -f1)"; echo "container=$(docker ps -qf "name=^dreamfinder-avatar$")"; echo "date=$(date -u +%FT%TZ)"; } > "$FREEZE/deployed.txt"
cat "$FREEZE/deployed.txt"
echo "=== DEPLOY GREEN. NOW: voice canary (laptop spoken turn at df.imagineering.cc), then phone/cellular, then rollback rehearsal. ==="
