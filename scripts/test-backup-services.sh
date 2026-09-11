#!/bin/bash
# Keeps lib/backup-services.sh honest against what backup.sh actually dispatches.
#
# The freshness watcher asserts "every expected service produced an artifact", and
# is therefore only as good as its idea of "expected". If that list silently falls
# behind backup.sh, the watcher reports a clean night while a service nobody is
# checking has stopped — which is a quieter version of the failure it exists to
# catch, and the drift is real: the matrix list lost relay-hf on 2026-09-04 and the
# box went on attempting it for a week.
#
# So this asserts the lib's list still equals backup.sh's own enumeration, parsed
# out of the `all)` dispatch rather than re-typed here. Hermetic: reads files only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }

# shellcheck source=lib/backup-services.sh
. "$SCRIPT_DIR/lib/backup-services.sh"

BACKUP_SH="$SCRIPT_DIR/backup.sh"

echo "== the lib's list matches backup.sh's own dispatch =="

# backup.sh enumerates the tree services and the matrix bridges as two inline
# `for` loops inside `case $SERVICE in all)`. Parse THOSE, so the assertion is
# against the code that runs rather than a restatement of it.
# Only the literal-list loop inside `all)` — another `for svc in "${services[@]}"`
# exists elsewhere in the file and must not be picked up.
sh_tree=$(sed -n 's/^[[:space:]]*for svc in \([a-z][a-z0-9 -]*\); do$/\1/p' "$BACKUP_SH" \
          | tr ' ' '\n' | grep -v '^$' | sort -u)
sh_matrix=$(sed -n '/for matrix_svc in/,/do$/p' "$BACKUP_SH" \
            | tr ' \\' '\n\n' | tr -d ';' | grep '^matrix-' | sort -u)

lib_tree=$(printf '%s\n' "${BACKUP_SERVICES_TREE[@]}" | sort -u)
lib_matrix=$(printf '%s\n' "${BACKUP_SERVICES_MATRIX[@]}" | sort -u)

# A parse that silently matched nothing would make both comparisons trivially
# "equal" and the whole file a no-op — assert the instrument found something first.
if [ -n "$sh_tree" ] && [ "$(printf '%s\n' "$sh_tree" | wc -l)" -ge 4 ]; then
  ok "parsed backup.sh's tree-service loop ($(printf '%s\n' "$sh_tree" | wc -l | tr -d ' ') entries)"
else
  no "parse of backup.sh tree loop" "found [$sh_tree] — the sed no longer matches; this file is inert until fixed"
fi
if [ -n "$sh_matrix" ] && [ "$(printf '%s\n' "$sh_matrix" | wc -l)" -ge 3 ]; then
  ok "parsed backup.sh's matrix-bridge loop ($(printf '%s\n' "$sh_matrix" | wc -l | tr -d ' ') entries)"
else
  no "parse of backup.sh matrix loop" "found [$sh_matrix] — the sed no longer matches"
fi

if [ "$sh_tree" = "$lib_tree" ]; then
  ok "tree services agree"
else
  no "tree services DRIFTED" "backup.sh=[$(echo $sh_tree)] lib=[$(echo $lib_tree)]"
fi
if [ "$sh_matrix" = "$lib_matrix" ]; then
  ok "matrix bridges agree"
else
  no "matrix bridges DRIFTED" "backup.sh=[$(echo $sh_matrix)] lib=[$(echo $lib_matrix)]"
fi

echo "== backup_service_age_hours is PER-SERVICE, not max-over-directory =="
# The exact shape of the seven-night outage: one service fresh, another absent.
# A max-over-directory reading calls this healthy; a per-service one does not.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
touch "$TMP/kanbn-2026-09-11.sql.gz"
touch -d '30 hours ago' "$TMP/outline-2026-09-11.sql.gz" 2>/dev/null \
  || touch -t "$(date -v-30H +%Y%m%d%H%M 2>/dev/null)" "$TMP/outline-2026-09-11.sql.gz"

age_fresh=$(backup_service_age_hours "$TMP" kanbn)
age_stale=$(backup_service_age_hours "$TMP" outline)
age_absent=$(backup_service_age_hours "$TMP" matrix-signal)

[ "$age_fresh" -lt 2 ] 2>/dev/null && ok "fresh service reads ~0h (got ${age_fresh})" \
  || no "fresh service age" "got [$age_fresh]"
[ "$age_stale" -ge 25 ] 2>/dev/null && ok "stale service reads >=25h (got ${age_stale}) even with a fresh sibling present" \
  || no "stale service age" "got [$age_stale] — a max-over-directory read would have said ~0"
[ "$age_absent" = "none" ] && ok "absent service reads 'none', distinct from 'old'" \
  || no "absent service" "got [$age_absent]"

# An absent service and a stale one are DIFFERENT states and must not collapse:
# "never produced" points at configuration, "old" points at a run that failed.
[ "$age_absent" != "$age_stale" ] && ok "absent and stale do not collapse into one reading" \
  || no "absent vs stale" "both read [$age_absent]"

echo "== the anchored prefix does not admit a longer sibling name =="
touch "$TMP/matrix-relay-hf-2026-09-11.sql.gz"
age_relay=$(backup_service_age_hours "$TMP" matrix-relay)
# matrix-relay-hf was REMOVED on 2026-09-04. If its artifact could satisfy a
# matrix-relay lookup, a retired service would keep a live one looking healthy.
if [ "$age_relay" = "none" ]; then
  ok "matrix-relay is not satisfied by a matrix-relay-hf artifact"
else
  no "prefix bleed" "matrix-relay read [$age_relay] from a matrix-relay-hf file"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
