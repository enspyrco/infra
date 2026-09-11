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

# Every script that RUNS the image must also ENSURE it, and ensure it FIRST.
#
# Two earlier versions of this check were decorative, both caught by Carnot in the
# cage-match on #186 and both reproduced before fixing:
#
#   1. It required `docker run` and the image name on the SAME PHYSICAL LINE. A
#      normal continuation --  `docker run --rm \` ... `"$SQLITE_DUMPER_IMAGE"` --
#      was not merely mis-scored, it was SKIPPED ENTIRELY and never reported.
#   2. It accepted the string `ensure_sqlite_dumper` ANYWHERE in the file. A comment
#      reading "we should probably call ensure_sqlite_dumper here one day" scored a
#      green "runs the image and ensures it first".
#
#      Planting both as real unguarded consumers, the suite passed 11/11.
#
# So the file is NORMALISED first: `\`-continuations joined into logical lines, and
# whole-line comments dropped, with each logical line carrying the line number it
# STARTED on. Then the ordering is compared, not merely the presence.
#
# HONEST LIMIT, stated rather than implied: this compares TEXTUAL order, which is a
# proxy for execution order and not the same thing. A consumer that calls ensure
# inside a function defined below its use would fail this check while being correct,
# and one that guards only a branch would pass while being wrong. The proxy fits
# this corpus -- every consumer is a straight-line script -- and the check says so
# rather than claiming to have proved the ordering property.
_logical_lines() {
  # Join backslash continuations, drop whole-line comments, keep the starting line no.
  awk '
    { line = $0 }
    buf != "" { line = buf " " line; ln = startln }
    { startln = (buf == "" ? NR : ln) }
    /\\$/ { sub(/\\$/, "", line); buf = line; next }
    { buf = ""
      probe = line; sub(/^[ \t]+/, "", probe)
      if (probe !~ /^#/) print startln ":" line
    }
  ' "$1"
}

# WRAPPER VERIFICATION RUNS FIRST, and the consumer check below trusts the
# underscore alias ONLY if a wrapper was actually found AND verified here.
#
# restore.sh wraps the lib function to get its own `error` formatting, so the
# detector has to accept `_ensure_sqlite_dumper` — but acceptance by NAME is not a
# contract. The previous version verified wrappers declared as `_ensure_...()` and
# trusted the name regardless, so a wrapper written `function _ensure_... {` would
# be trusted and never checked (Carnot, #186 round 5).
#
# Enumerating bash's declaration forms would just move the arms race along one
# step. Instead the TRUST IS DERIVED: no verified wrapper found, no underscore
# acceptance. A wrapper in an unrecognised form is therefore not silently trusted
# — it makes the consumer that calls it fail, which is the safe direction.
WRAPPER_OK=0
while IFS= read -r wrapper_file; do
  wname=$(basename "$wrapper_file")
  body=$(awk '/_ensure_sqlite_dumper[[:space:]]*(\(\))?[[:space:]]*\{/,/^}/' "$wrapper_file")
  if printf '%s\n' "$body" | grep -qE '^[[:space:]]*(if[[:space:]]+)?!?[[:space:]]*ensure_sqlite_dumper([[:space:]]|$|;|\||&)'; then
    ok "$wname's _ensure_sqlite_dumper wrapper actually delegates to the lib function"
    WRAPPER_OK=1
  else
    no "$wname's _ensure_sqlite_dumper does not delegate" "the corpus check would trust this name; it must earn it"
  fi
done < <(grep -rlE '^[[:space:]]*(function[[:space:]]+)?_ensure_sqlite_dumper[[:space:]]*(\(\))?[[:space:]]*\{' "$SCRIPT_DIR" 2>/dev/null)

# Accept the underscore alias only if the line above earned it.
if [ "$WRAPPER_OK" -eq 1 ]; then ENSURE_NAMES='_?ensure_sqlite_dumper'; else ENSURE_NAMES='ensure_sqlite_dumper'; fi

scanned=0
while IFS= read -r f; do
  scanned=$((scanned + 1))
  base=$(basename "$f")
  case "$base" in test-*) continue ;; esac

  norm=$(_logical_lines "$f")

  # First line that actually RUNS the image (docker run + the image, same LOGICAL line).
  use_line=$(printf '%s\n' "$norm" \
    | grep -E 'docker[[:space:]]+run.*(sqlite-dumper:latest|SQLITE_DUMPER_IMAGE)' \
    | head -1 | cut -d: -f1)
  [ -n "$use_line" ] || continue

  # First ensure_sqlite_dumper CALL. Anchored at COMMAND POSITION, because merely
  # containing the token is not calling it: dropping whole-line comments still let
  # `FOO=1  # remember to call ensure_sqlite_dumper first` score a green tick, and
  # that is an ordinary comment somebody would really write. Every real consumer
  # calls it as the first word of a line (optionally `if !`), so the anchor costs
  # nothing and closes the inline-comment hole. (Carnot, third round on #186.)
  #
  # Remaining known gap, named rather than papered over: the token inside a QUOTED
  # STRING at command position would still match. Closing that needs a shell parser,
  # not a regex, and the trade is not worth it for a five-file corpus -- but a reader
  # should know the boundary rather than infer a stronger guarantee than this gives.
  ensure_line=$(printf '%s\n' "$norm" \
    | grep -E "^[0-9]+:[[:space:]]*(if[[:space:]]+)?!?[[:space:]]*${ENSURE_NAMES}([[:space:]]|$|;|\||&)" \
    | grep -vE '_?ensure_sqlite_dumper[[:space:]]*\(\)' \
    | head -1 | cut -d: -f1)

  if [ -z "$ensure_line" ]; then
    no "$base uses the image without ensuring it" "this is exactly the 2026-09-05 defect"
  elif [ "$ensure_line" -lt "$use_line" ]; then
    ok "$base ensures the image (line $ensure_line) before running it (line $use_line)"
  else
    no "$base ensures the image AFTER using it" "ensure at line $ensure_line, use at line $use_line"
  fi
done < <(find "$SCRIPT_DIR" -name '*.sh' -type f)

# A scan that silently covered nothing would pass every assertion above by
# vacuum. Assert the instrument saw the corpus it claims to check.
if [ "$scanned" -ge 25 ]; then
  ok "the scan covered the whole tree ($scanned shell scripts, not just the top level)"
else
  no "scan coverage" "only $scanned scripts scanned -- the find is not reaching the subdirectories"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
