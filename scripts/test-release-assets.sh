#!/bin/bash
# Tests for lib/release-assets.sh — the storage tier for LARGE BINARY backup
# artifacts (MinIO object-store tarballs).
#
# Every GitHub call in the lib funnels through the `release_gh` indirection,
# which these tests stub. That keeps the suite hermetic: no token, no network,
# no mutation of a real repo — while still exercising the real control flow,
# including the fail-closed guards that gate a DESTRUCTIVE remote delete.
#
# The guards mirror prune_repo_history_if_needed's, which were established over
# 7 cage-match rounds in #141. Same invariants, same failure modes, so they are
# asserted here rather than re-derived: a non-integer retention must not compute
# a delete-everything window, and an implausibly large batch must be refused
# rather than executed unattended.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/release-assets.sh
. "$SCRIPT_DIR/lib/release-assets.sh"

PASS=0
FAIL=0

# The stub records to a FILE, not a shell variable. The lib invokes release_gh
# inside command substitutions so it can capture the API's stderr for
# diagnostics — which means every call runs in a subshell, and a variable the
# stub assigned there would be discarded on return. A variable-based recorder
# silently observes NOTHING and, worse, makes every assert_not_contains pass
# vacuously: the suite would go green while testing nothing at all.
GH_LOG=$(mktemp)
trap 'rm -f "$GH_LOG"' EXIT
calls() { cat "$GH_LOG"; }

ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }

assert_eq() {
  local want="$1" got="$2" what="$3"
  if [ "$want" = "$got" ]; then ok "$what"; else no "$what" "want [$want] got [$got]"; fi
}

assert_contains() {
  local hay="$1" needle="$2" what="$3"
  case "$hay" in *"$needle"*) ok "$what" ;; *) no "$what" "[$needle] not in [$hay]" ;; esac
}

assert_not_contains() {
  local hay="$1" needle="$2" what="$3"
  case "$hay" in *"$needle"*) no "$what" "[$needle] unexpectedly in [$hay]" ;; *) ok "$what" ;; esac
}

# --- Stub -----------------------------------------------------------------
# Records every invocation and replies with canned output. STUB_RELEASES is
# the fixture list of existing release tags (newest-first is NOT assumed —
# the lib must sort, because `gh release list` orders by creation date, which
# is not the same as the date embedded in the tag name).
STUB_RELEASES=""
STUB_FAIL_DELETE=""
release_gh() {
  printf 'gh %s\n' "$*" >> "$GH_LOG"
  case "$1 ${2:-}" in
    "release list")
      printf '%s\n' "$STUB_RELEASES"
      ;;
    "release delete")
      if [ -n "$STUB_FAIL_DELETE" ] && [ "$3" = "$STUB_FAIL_DELETE" ]; then
        echo "HTTP 403: forbidden" >&2
        return 1
      fi
      ;;
    "release view")
      # Non-zero means "release does not exist yet".
      [ -n "$STUB_RELEASE_EXISTS" ] && return 0
      return 1
      ;;
  esac
  return 0
}
STUB_RELEASE_EXISTS=""

reset() { : > "$GH_LOG"; STUB_RELEASES=""; STUB_FAIL_DELETE=""; STUB_RELEASE_EXISTS=""; }

echo "== release_prune: keeps the newest N, deletes the rest =="
reset
STUB_RELEASES="objects-2026-08-01
objects-2026-08-05
objects-2026-08-03
objects-2026-08-04
objects-2026-08-02"
release_prune "owner/repo" "objects-" 3 >/dev/null 2>&1
# Newest three by TAG DATE are 08-05, 08-04, 08-03 — so 08-02 and 08-01 go.
assert_contains "$(calls)" "release delete objects-2026-08-01" "deletes oldest"
assert_contains "$(calls)" "release delete objects-2026-08-02" "deletes 2nd oldest"
assert_not_contains "$(calls)" "release delete objects-2026-08-03" "keeps 3rd newest"
assert_not_contains "$(calls)" "release delete objects-2026-08-05" "keeps newest"

echo "== release_prune: ignores releases outside the prefix =="
reset
STUB_RELEASES="objects-2026-08-01
v1.2.3
some-other-release
objects-2026-08-02"
release_prune "owner/repo" "objects-" 1 >/dev/null 2>&1
assert_contains "$(calls)" "release delete objects-2026-08-01" "prunes matching prefix"
assert_not_contains "$(calls)" "release delete v1.2.3" "never touches unrelated release"
assert_not_contains "$(calls)" "release delete some-other-release" "never touches unrelated tag"

echo "== release_prune: fail-closed on a non-integer retention =="
# A garbage value from a bad cron env must NOT compute tail -n +1 and delete
# everything. It must fall back to the safe default and keep the window.
reset
STUB_RELEASES="objects-2026-08-01
objects-2026-08-02"
release_prune "owner/repo" "objects-" "garbage" >/dev/null 2>&1
assert_not_contains "$(calls)" "release delete" "garbage retention deletes NOTHING"

echo "== release_prune: fail-closed on zero retention =="
reset
STUB_RELEASES="objects-2026-08-01
objects-2026-08-02"
release_prune "owner/repo" "objects-" 0 >/dev/null 2>&1
assert_not_contains "$(calls)" "release delete" "keep=0 deletes NOTHING"

echo "== release_prune: refuses an implausibly large batch =="
# Steady state deletes 0-1 releases. A huge batch means the listing parse went
# wrong; executing it unattended would vacuum the whole recovery window.
reset
STUB_RELEASES="$(for d in $(seq -w 1 40); do echo "objects-2026-01-$d"; done)"
out=$(RELEASE_DELETE_CEILING=5 release_prune "owner/repo" "objects-" 1 2>&1)
assert_not_contains "$(calls)" "release delete" "over-ceiling batch deletes NOTHING"
assert_contains "$out" "REFUSING" "over-ceiling batch reports refusal"

echo "== release_prune: a failed delete is surfaced, not swallowed =="
reset
STUB_RELEASES="objects-2026-08-01
objects-2026-08-02
objects-2026-08-03"
STUB_FAIL_DELETE="objects-2026-08-01"
out=$(release_prune "owner/repo" "objects-" 1 2>&1)
assert_contains "$out" "objects-2026-08-01" "failed delete names the release"
assert_contains "$out" "403" "failed delete surfaces the API error text"
assert_contains "$(calls)" "release delete objects-2026-08-02" "other deletes still proceed"

echo "== release_prune: nothing to do is not an error =="
reset
STUB_RELEASES="objects-2026-08-01"
release_prune "owner/repo" "objects-" 7 >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "under-retention prune exits 0"
assert_not_contains "$(calls)" "release delete" "under-retention deletes nothing"

echo "== release_publish_asset: creates the release when absent =="
reset
STUB_RELEASE_EXISTS=""
tmp=$(mktemp); echo payload > "$tmp"
release_publish_asset "owner/repo" "objects-2026-08-09" "$tmp" >/dev/null 2>&1
assert_contains "$(calls)" "release create objects-2026-08-09" "creates missing release"
assert_contains "$(calls)" "release upload objects-2026-08-09" "uploads the asset"

echo "== release_publish_asset: reuses an existing release =="
reset
STUB_RELEASE_EXISTS=1
release_publish_asset "owner/repo" "objects-2026-08-09" "$tmp" >/dev/null 2>&1
assert_not_contains "$(calls)" "release create" "does not recreate an existing release"
assert_contains "$(calls)" "release upload objects-2026-08-09" "still uploads the asset"

echo "== release_publish_asset: --clobber so a re-run replaces, not duplicates =="
assert_contains "$(calls)" "--clobber" "upload is idempotent via --clobber"

echo "== release_publish_asset: refuses a missing or empty file =="
reset
release_publish_asset "owner/repo" "objects-2026-08-09" "/nonexistent/file" >/dev/null 2>&1
rc=$?
assert_eq "1" "$rc" "missing file returns non-zero"
assert_not_contains "$(calls)" "release upload" "missing file uploads NOTHING"

reset
empty=$(mktemp)
release_publish_asset "owner/repo" "objects-2026-08-09" "$empty" >/dev/null 2>&1
rc=$?
assert_eq "1" "$rc" "empty file returns non-zero"
assert_not_contains "$(calls)" "release upload" "empty file uploads NOTHING"
rm -f "$tmp" "$empty"

echo "== logging delegates to a host log/error WITHOUT recursing =="
# Regression guard for a production-only SIGSEGV. _ra_log's delegating branch
# fires only when a real `log` function exists — i.e. only when sourced from
# backup.sh. Every test above takes the printf fallback, so an `_ra_log` that
# called ITSELF instead of `log` stayed invisible: 25/25 green while the
# deployed script overflowed its stack and died with a core dump.
#
# So define host log/error here, exactly as backup.sh does, and assert the
# delegation both reaches them and terminates. `timeout` bounds the runaway
# case: unbounded recursion would otherwise hang or crash the suite itself
# rather than reporting a clean failure.
delegation_probe() {
  # shellcheck disable=SC2317  # invoked indirectly via _ra_log
  log() { echo "HOSTLOG:$1"; }
  # shellcheck disable=SC2317  # invoked indirectly via _ra_err
  error() { echo "HOSTERR:$1" >&2; }
  . "$SCRIPT_DIR/lib/release-assets.sh"
  _ra_log "hello"
  _ra_err "boom"
}
probe_out=$(timeout 10 bash -c "SCRIPT_DIR='$SCRIPT_DIR'; $(declare -f delegation_probe); delegation_probe" 2>&1)
probe_rc=$?

assert_eq "0" "$probe_rc" "delegation terminates (no stack overflow / SIGSEGV)"
assert_contains "$probe_out" "HOSTLOG:hello" "_ra_log reaches the host log()"
assert_contains "$probe_out" "HOSTERR:boom" "_ra_err reaches the host error()"
assert_not_contains "$probe_out" "[release-assets] hello" "_ra_log does not fall back when a host log exists"

echo "== and still falls back cleanly with NO host log/error =="
fallback_out=$(timeout 10 bash -c "SCRIPT_DIR='$SCRIPT_DIR'; . \"\$SCRIPT_DIR/lib/release-assets.sh\"; _ra_log hi; _ra_err oops" 2>&1)
fallback_rc=$?
assert_eq "0" "$fallback_rc" "fallback path terminates"
assert_contains "$fallback_out" "[release-assets] hi" "falls back to its own log format"
assert_contains "$fallback_out" "[release-assets] ERROR: oops" "falls back to its own error format"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
