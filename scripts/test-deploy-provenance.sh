#!/bin/bash
# Tests for deploy-to.sh's provenance preflight.
#
# The preflight decides whether production may receive the bytes in the working
# tree. Its failure mode is the dangerous one: a check that silently always
# passes looks exactly like a clean deploy. So every assertion below is paired —
# a NULL arm that must pass and a FORCED arm that must refuse — and the suite is
# built so a preflight that unconditionally returned 0 would fail it loudly.
#
# HOW THE REAL SCRIPT IS EXERCISED WITHOUT DEPLOYING ANYTHING
# deploy-to.sh runs the preflight BEFORE the service dispatch, and an unknown
# service exits 1 without opening a single connection. So a probe of
#   deploy-to.sh <TEST-NET-3 addr> __probe__
# runs the genuine preflight and then stops. Reaching "Unknown service" is
# therefore the signal that the preflight PASSED — we never re-implement it here
# (a verifier sharing the verified code's logic is blind to bugs in it).
#
# The fixture repo is synthetic, but the script under test is the real file:
# provenance is a property of the REPO, so the repo is the input we vary.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/deploy-to.sh"
# 203.0.113.0/24 is TEST-NET-3 (RFC 5737): guaranteed never routed, so a bug
# that let the probe past the dispatch still cannot reach a real host.
PROBE_IP=203.0.113.1

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }

# POSITIVE CONTROL for the harness: the script must exist and parse before any
# assertion trusts its exit code. A missing or broken script exits non-zero for
# reasons unrelated to provenance, which would read as "correctly refused".
[ -f "$DEPLOY" ] || { echo "FAIL: $DEPLOY not found"; exit 1; }
bash -n "$DEPLOY" || { echo "FAIL: $DEPLOY does not parse"; exit 1; }
grep -q 'deploy_provenance_preflight' "$DEPLOY" || { echo "FAIL: preflight absent from $DEPLOY"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMP/home"; mkdir -p "$HOME"

git init -q --bare "$TMP/origin.git"
git init -q "$TMP/work"
git -C "$TMP/work" config user.email t@example.invalid
git -C "$TMP/work" config user.name test
mkdir -p "$TMP/work/scripts"
cp "$DEPLOY" "$TMP/work/scripts/deploy-to.sh"
echo tracked > "$TMP/work/tracked.txt"
git -C "$TMP/work" add -A >/dev/null
git -C "$TMP/work" commit -qm init
git -C "$TMP/work" branch -M main
git -C "$TMP/work" remote add origin "$TMP/origin.git"
git -C "$TMP/work" push -q -u origin main

# Runs the real preflight. Echoes PASS if the dispatch was reached, REFUSE if the
# preflight aborted first. Anything else is a harness problem, not a verdict.
probe() {
  local dir=$1 out
  out=$(cd "$dir" && bash scripts/deploy-to.sh "$PROBE_IP" __probe__ 2>&1)
  if printf '%s' "$out" | grep -q 'Unknown service'; then printf 'PASS\n%s' "$out"
  elif printf '%s' "$out" | grep -q 'Aborting deploy'; then printf 'REFUSE\n%s' "$out"
  else printf 'HARNESS-ERROR\n%s' "$out"; fi
}
verdict() { probe "$1" | head -1; }
body()    { probe "$1" | tail -n +2; }

echo "== NULL ARM: clean tree, HEAD on origin/main =="
[ "$(verdict "$TMP/work")" = PASS ] && ok "a clean tree at origin/main is allowed to deploy" \
                                    || no "a clean tree at origin/main was refused"
body "$TMP/work" | grep -q 'provenance:' && ok "the allowed deploy STAMPS the ref it is shipping" \
                                         || no "no provenance stamp on an allowed deploy"

echo "== FORCED ARM: uncommitted changes to a tracked file =="
echo dirty >> "$TMP/work/tracked.txt"
[ "$(verdict "$TMP/work")" = REFUSE ] && ok "refuses a dirty tree (bytes no commit can reproduce)" \
                                      || no "a dirty tree was allowed to deploy"
DEPLOY_ALLOW_DIRTY=1 ; export DEPLOY_ALLOW_DIRTY
[ "$(verdict "$TMP/work")" = PASS ] && ok "DEPLOY_ALLOW_DIRTY=1 permits it" || no "DEPLOY_ALLOW_DIRTY=1 did not permit it"
body "$TMP/work" | grep -q '!! DEPLOY_ALLOW_DIRTY' && ok "the override is STAMPED, not silent" \
                                                   || no "override was silent"
# An overridden deploy proceeds, so it must not shout ERROR — that habituates a
# reader to skipping ERROR lines, which is how a real one gets missed.
body "$TMP/work" | grep -q '^ERROR:' && no "an ALLOWED deploy still printed ERROR" \
                                     || ok "an allowed deploy reports WARN, never ERROR"
unset DEPLOY_ALLOW_DIRTY
git -C "$TMP/work" checkout -q -- tracked.txt

echo "== FORCED ARM: an unmerged branch (the shared-working-tree case) =="
git -C "$TMP/work" checkout -q -b peer-branch
echo peer > "$TMP/work/peer.txt"
git -C "$TMP/work" add -A >/dev/null; git -C "$TMP/work" commit -qm peer
[ "$(verdict "$TMP/work")" = REFUSE ] && ok "refuses a ref not contained in origin/main" \
                                      || no "an unmerged branch was allowed to deploy"
DEPLOY_FROM_BRANCH=1; export DEPLOY_FROM_BRANCH
[ "$(verdict "$TMP/work")" = PASS ] && ok "DEPLOY_FROM_BRANCH=1 permits it" || no "DEPLOY_FROM_BRANCH=1 did not permit it"
unset DEPLOY_FROM_BRANCH

echo "== NULL ARM: an OLDER main commit is a rollback, not a violation =="
# Guards against over-tightening to HEAD == origin/main, which would make every
# rollback need an override and train the override on.
git -C "$TMP/work" checkout -q main
git -C "$TMP/work" commit -q --allow-empty -m newer
git -C "$TMP/work" push -q origin main
git -C "$TMP/work" checkout -q HEAD~1
[ "$(verdict "$TMP/work")" = PASS ] && ok "an older commit contained in main deploys without an override" \
                                    || no "a legitimate rollback was refused"
git -C "$TMP/work" checkout -q main

echo "== FORCED ARM: not a git work tree at all =="
mkdir -p "$TMP/nogit/scripts"; cp "$DEPLOY" "$TMP/nogit/scripts/deploy-to.sh"
[ "$(verdict "$TMP/nogit")" = REFUSE ] && ok "refuses when provenance cannot be established" \
                                       || no "deployed from a non-git tree"
DEPLOY_ALLOW_UNVERIFIED=1; export DEPLOY_ALLOW_UNVERIFIED
[ "$(verdict "$TMP/nogit")" = PASS ] && ok "DEPLOY_ALLOW_UNVERIFIED=1 permits it" || no "DEPLOY_ALLOW_UNVERIFIED=1 did not permit it"
unset DEPLOY_ALLOW_UNVERIFIED

echo "== FORCED ARM: a FAILED measurement must not read as a clean tree =="
# Found by Kelvin in the #162 cage-match. `git status | wc -l` returns the
# PIPELINE's status, so a git that exits 128 is invisible and wc counts zero
# lines of nothing. Pre-fix, with a genuinely dirty tree and a corrupt index,
# this reported dirty=0 and ALLOWED the deploy with a clean provenance stamp.
git -C "$TMP/work" checkout -q main
cp -R "$TMP/work" "$TMP/corrupt"
echo mutate >> "$TMP/corrupt/tracked.txt"          # genuinely dirty ...
# POSITIVE CONTROL: prove the probe can see the dirt BEFORE we break the index.
[ "$(verdict "$TMP/corrupt")" = REFUSE ] && ok "control: the dirty tree is refused while git works" \
                                         || no "control failed — the dirty tree was not refused, so the next assertion proves nothing"
printf 'CORRUPT' > "$TMP/corrupt/.git/index"       # ... and now unmeasurable
[ "$(verdict "$TMP/corrupt")" = REFUSE ] && ok "refuses when git status FAILS (unknown != clean)" \
                                         || no "a failed git status read as a clean tree and the deploy was allowed"

echo "== FORCED ARM: a repo with no commits =="
mkdir -p "$TMP/empty/scripts"; cp "$DEPLOY" "$TMP/empty/scripts/deploy-to.sh"
git init -q "$TMP/empty"
[ "$(verdict "$TMP/empty")" = REFUSE ] && ok "refuses a repo with no commits (no revision to attribute)" \
                                       || no "deployed from a repo with no commits"
# It must also not spray raw git plumbing errors at the operator.
body "$TMP/empty" | grep -q "fatal: ambiguous argument" && no "leaks a raw git 'fatal: ambiguous argument' to the operator" \
                                                        || ok "reports the no-commits case in its own words, not git's"

echo "== FORCED ARM: origin/main not present locally =="
mkdir -p "$TMP/noremote/scripts"; cp "$DEPLOY" "$TMP/noremote/scripts/deploy-to.sh"
git init -q "$TMP/noremote"
git -C "$TMP/noremote" config user.email t@example.invalid
git -C "$TMP/noremote" config user.name test
git -C "$TMP/noremote" add -A >/dev/null; git -C "$TMP/noremote" commit -qm solo
[ "$(verdict "$TMP/noremote")" = REFUSE ] && ok "refuses when there is no origin/main to compare against" \
                                          || no "deployed with no origin/main to compare against"
body "$TMP/noremote" | grep -q "cannot compare HEAD against origin/main" \
  && ok "names the real reason (no comparable ref), not 'unmerged branch'" \
  || no "reported a misleading reason for the missing-ref case"

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
