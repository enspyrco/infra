#!/bin/bash
# Tests for lib/resolve-container.sh, with the co-located-tenant case that
# actually bit us as the centrepiece.
#
# This box runs imagineering-* and xdeca-* stacks side by side, so the SAME
# service exists twice with different names. `docker exec radicale` silently
# selected xdeca's container: imagineering's nightly radicale.tar held xdeca's
# calendars, imagineering's own collections were never captured, and restore.sh
# — which resolves the correct container via compose — would have written one
# tenant's data over the other's.
#
# `docker` is stubbed here, so this is hermetic: no daemon, no containers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/resolve-container.sh
. "$SCRIPT_DIR/lib/resolve-container.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "want [$1] got [$2]"; fi
}

# --- Stub: the real co-located fleet on 149.118.69.221 ---------------------
# imagineering radicale -> container `img-radicale`, compose project `radicale`
# xdeca radicale        -> container `radicale`,     compose project `xdeca-radicale`
# Both expose compose service `radicale`. That collision is the whole point.
docker() {
  local project="" service=""
  for arg in "$@"; do
    case "$arg" in
      label=com.docker.compose.project=*) project="${arg#label=com.docker.compose.project=}" ;;
      label=com.docker.compose.service=*) service="${arg#label=com.docker.compose.service=}" ;;
    esac
  done
  if [ -n "$project" ]; then
    case "$project/$service" in
      radicale/radicale)         echo "img-radicale" ;;
      xdeca-radicale/radicale)   echo "radicale" ;;
      ambiguous/dup)             printf 'one\ntwo\n' ;;
      *)                         : ;;   # no match
    esac
    return 0
  fi
  # Plain `docker ps --format '{{.Names}}'` for the name-pattern resolver.
  printf 'img-radicale\nradicale\nimagineering-outline-postgres\nxdeca-outline-postgres\n'
}

echo "== resolve_container_by_compose: picks the right tenant =="
assert_eq "img-radicale" "$(resolve_container_by_compose radicale radicale 2>/dev/null)" \
  "imagineering project resolves to img-radicale"
assert_eq "radicale" "$(resolve_container_by_compose xdeca-radicale radicale 2>/dev/null)" \
  "xdeca project resolves to the bare radicale container"

echo "== the regression this exists to prevent =="
# The old code was `docker exec radicale`. Assert the resolver does NOT return
# the xdeca container for the imagineering project — i.e. that a future rename
# cannot silently reintroduce cross-tenant capture.
got=$(resolve_container_by_compose radicale radicale 2>/dev/null)
if [ "$got" = "radicale" ]; then
  no "imagineering lookup must not return xdeca's container" "got the xdeca container"
else
  ok "imagineering lookup never returns xdeca's container"
fi

echo "== fail closed on zero matches =="
out=$(resolve_container_by_compose nosuch radicale 2>&1); rc=$?
assert_eq "1" "$rc" "zero matches returns non-zero"
case "$out" in *"no running container"*) ok "zero matches explains why" ;; *) no "zero matches explains why" "$out" ;; esac

echo "== fail closed on ambiguity (never guess between tenants) =="
out=$(resolve_container_by_compose ambiguous dup 2>&1); rc=$?
assert_eq "1" "$rc" "ambiguous match returns non-zero"
case "$out" in *"refusing to guess"*) ok "ambiguous match refuses to guess" ;; *) no "ambiguous match refuses to guess" "$out" ;; esac

echo "== missing arguments are an error, not a wildcard =="
out=$(resolve_container_by_compose "" "" 2>&1); rc=$?
assert_eq "1" "$rc" "empty project/service returns non-zero"

echo "== resolve_container (name pattern) still fails closed on ambiguity =="
# '^radicale$' is exact, so it matches only the xdeca container here; the
# anchored imagineering pattern must not also match it.
assert_eq "img-radicale" "$(resolve_container '^img-radicale$' radicale 2>/dev/null)" \
  "anchored name pattern still works"
out=$(resolve_container 'radicale' radicale 2>&1); rc=$?
assert_eq "1" "$rc" "unanchored pattern matching both tenants is refused"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
