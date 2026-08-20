#!/bin/bash
# Tests for lib/pg-dump-guard.sh.
#
# The case that matters is TRAILER HEADROOM. The old inline guard was
# `tail -n5`, and pg_dump 15.17 already puts the completion marker exactly 5
# lines from EOF — so the guard was passing by one line. These tests pin the
# real fixture shape and then prove the guard survives further trailer growth,
# which is the failure that would silently delete every postgres backup.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pg-dump-guard.sh
. "$SCRIPT_DIR/lib/pg-dump-guard.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Body + marker + N trailing lines, mimicking pg_dump's real tail.
make_dump() {
  local out=$1 trailers=$2 i
  { echo "-- PostgreSQL database dump"; echo "CREATE TABLE t (id int);"
    echo "COPY t (id) FROM stdin;"; echo "1"; echo "\\."
    echo "--"; echo "-- PostgreSQL database dump complete"; echo "--"; } > "$out"
  for ((i = 0; i < trailers; i++)); do echo "\\unrestrict tok$i" >> "$out"; echo "" >> "$out"; done
}

echo "== the REAL fixture shape (pg_dump 15.17, measured on the box) =="
# Marker sits 5 lines from EOF: --, blank, \unrestrict, blank.
printf -- '--\n-- PostgreSQL database dump complete\n--\n\n\\unrestrict QCYt5h0EDZIG3cZal9B\n\n' > "$TMP/real.sql"
pg_dump_is_complete "$TMP/real.sql" && ok "accepts a real 15.17 dump" || no "accepts a real 15.17 dump"

echo "== headroom: survives trailer growth that would break tail -n5 =="
for n in 1 2 5 10 20; do
  make_dump "$TMP/t$n.sql" "$n"
  if pg_dump_is_complete "$TMP/t$n.sql"; then ok "accepts with $n trailer pair(s)"; else no "accepts with $n trailer pair(s)"; fi
done

echo "== REGRESSION PROOF: tail -n5 would have rejected these =="
# Demonstrate the old guard failing on the same fixtures the new one accepts,
# so the test documents WHY the window widened rather than just asserting it.
oldguard() { tail -n5 "$1" | grep -qxF -- '-- PostgreSQL database dump complete'; }
broke=0
for n in 2 5 10 20; do oldguard "$TMP/t$n.sql" || broke=$((broke + 1)); done
[ "$broke" -eq 4 ] && ok "old tail -n5 guard rejects all 4 grown-trailer dumps (this is the bug)" \
                   || no "expected old guard to fail 4 fixtures, it failed $broke"

echo "== still fails CLOSED on bad input =="
printf -- '-- PostgreSQL database dump\nCREATE TABLE t (id int);\nCOPY t (id) FROM stdin;\n1\n' > "$TMP/trunc.sql"
pg_dump_is_complete "$TMP/trunc.sql" && no "rejects a truncated dump" || ok "rejects a truncated dump"
: > "$TMP/empty.sql"
pg_dump_is_complete "$TMP/empty.sql" && no "rejects an empty file" || ok "rejects an empty file"
pg_dump_is_complete "$TMP/nope.sql" && no "rejects a missing file" || ok "rejects a missing file"
pg_dump_is_complete "" && no "rejects an empty arg" || ok "rejects an empty arg"

echo "== a truncation that happens to CONTAIN the marker text mid-body is rejected =="
# Whole-line + near-the-end are both load-bearing: a data row quoting the
# marker must not fake completeness.
{ echo "-- PostgreSQL database dump"; echo "COPY t (note) FROM stdin;"
  echo "some row mentioning -- PostgreSQL database dump complete inline"; } > "$TMP/sneaky.sql"
for ((i = 0; i < 60; i++)); do echo "row $i"; done >> "$TMP/sneaky.sql"
pg_dump_is_complete "$TMP/sneaky.sql" && no "rejects marker-as-substring far from EOF" \
                                      || ok "rejects marker-as-substring far from EOF"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
