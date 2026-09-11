#!/bin/bash
# Tests for lib/sqlite-dumper.sh, and for the invariant that made it necessary.
#
# WHY: on 2026-09-05 the sqlite-dumper image was pruned from enspyr-syd. backup.sh
# USED it and never BUILT it, so aiko-island and all five matrix bridges failed to
# back up for SEVEN NIGHTS while the run still reported the services that had
# succeeded. restore.sh had a build-if-absent helper the whole time; the nightly
# half did not.
#
# So the test that matters is not "does the builder work" — it is "does every
# consumer of this image ensure it exists before using it", which is a property of
# the CORPUS, not of any one function. `docker` is stubbed; no daemon needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }

# shellcheck source=lib/sqlite-dumper.sh
. "$SCRIPT_DIR/lib/sqlite-dumper.sh"

echo "== ensure_sqlite_dumper =="

# The build is invoked as `printf ... | docker build`, and a PIPELINE runs in a
# SUBSHELL — so a `BUILT=1` variable set inside the stub never reaches this shell
# and the assertion would read "did not build" no matter what happened. Record
# through a FILE, which crosses the subshell boundary. (Caught by this test
# failing while the code was correct: the instrument was wrong, not the subject.)
BUILT_FLAG=$(mktemp)
trap 'rm -f "$BUILT_FLAG"' EXIT
built() { [ -s "$BUILT_FLAG" ]; }
reset_built() { : > "$BUILT_FLAG"; }

docker() {
  case "${1:-}" in
    image)  return "$STUB_IMAGE_PRESENT" ;;   # `image inspect`: 0 = present
    build)  echo yes > "$BUILT_FLAG"; return "$STUB_BUILD_RC" ;;
  esac
  return 0
}

# Present -> no build, returns 0.
STUB_IMAGE_PRESENT=0 STUB_BUILD_RC=0; reset_built
ensure_sqlite_dumper >/dev/null 2>&1; rc=$?
{ [ $rc -eq 0 ] && ! built; } && ok "image present: succeeds without building" \
  || no "image present" "rc=$rc built=$(built && echo yes || echo no)"

# Absent -> builds, returns 0. This is the self-heal the nightly job lacked.
STUB_IMAGE_PRESENT=1 STUB_BUILD_RC=0; reset_built
ensure_sqlite_dumper >/dev/null 2>&1; rc=$?
{ [ $rc -eq 0 ] && built; } && ok "image absent: builds it and succeeds" \
  || no "image absent" "rc=$rc built=$(built && echo yes || echo no)"

# Absent AND unbuildable -> fails CLOSED. A caller must never go on to dump
# nothing and report success.
STUB_IMAGE_PRESENT=1 STUB_BUILD_RC=1; reset_built
out=$(ensure_sqlite_dumper 2>&1); rc=$?
[ $rc -ne 0 ] && ok "build failure fails closed" || no "build failure" "rc=0 out=[$out]"
printf '%s' "$out" | grep -q "aiko-island" \
  && ok "the failure names what cannot be backed up, not just the image" \
  || no "failure message" "does not name the affected services: [$out]"

# The base image is PINNED. An unpinned base in a backup tool changes under you.
case "$SQLITE_DUMPER_BASE" in
  *:latest) no "base image pinned" "SQLITE_DUMPER_BASE=$SQLITE_DUMPER_BASE is unpinned" ;;
  *:*)      ok "base image is pinned ($SQLITE_DUMPER_BASE)" ;;
  *)        no "base image pinned" "no tag at all: $SQLITE_DUMPER_BASE" ;;
esac

echo "== corpus invariant: one recipe, and every consumer ensures before using =="

# ONE recipe. Five copies had already drifted (four alpine:3.20, one alpine:latest)
# and the odd one out was what deploy actually shipped.
copies=$(grep -rl "apk add --no-cache sqlite" "$SCRIPT_DIR" 2>/dev/null | grep -v "/test-" | wc -l | tr -d ' ')
[ "$copies" = "1" ] && ok "exactly one build recipe in the corpus" \
  || no "one build recipe" "found $copies files containing a build recipe"

# Every script that RUNS the image must also ENSURE it. This is the assertion that
# would have caught the original defect: backup.sh ran it without ensuring it.
for f in "$SCRIPT_DIR"/*.sh; do
  base=$(basename "$f")
  case "$base" in test-*) continue ;; esac
  grep -q "sqlite-dumper:latest\|\$SQLITE_DUMPER_IMAGE\|\${SQLITE_DUMPER_IMAGE}" "$f" 2>/dev/null || continue
  grep -q "docker run .*sqlite-dumper\|docker run .*SQLITE_DUMPER_IMAGE" "$f" 2>/dev/null || continue
  if grep -q "ensure_sqlite_dumper" "$f"; then
    ok "$base runs the image and ensures it first"
  else
    no "$base uses the image without ensuring it" "this is exactly the 2026-09-05 defect"
  fi
done

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
