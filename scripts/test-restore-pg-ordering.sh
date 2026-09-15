#!/bin/bash
# Ordering test for _restore_pg_atomic — the ONE thing test-resolve-container.sh
# structurally cannot check.
#
# WHY IT EXISTS. The first revision of the derive-the-container change resolved the
# Postgres container BEFORE `docker compose up -d postgres`, through a resolver that
# reads `docker ps` — running containers only. On a healthy box that works, every
# resolver unit test passes, and the restore is BROKEN precisely on a box being
# recovered, where the stack is down. The defect lived in the ORDER of two correct
# calls, so no test of either call could see it.
#
# The invariant, stated so it can fail: on a stack that is present but STOPPED,
# `_restore_pg_atomic` must reach `compose up -d postgres` and must not have issued
# any `docker exec` before it.
#
# `docker` is stubbed and records every invocation, so this is hermetic: no daemon,
# no containers, no postgres.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; }

WORK=$(mktemp -d)
COMPOSE_DIR="$WORK/apps/imagineering-outline"
mkdir -p "$COMPOSE_DIR"
CALLS="$WORK/docker-calls.log"
trap 'rm -rf "$WORK"' EXIT

# The stack exists but is DOWN: visible to `docker ps -a`, absent from `docker ps`.
# Flip STUB_RUNNING=1 to simulate the post-`compose up` state.
STUB_RUNNING=0
docker() {
  echo "$*" >> "$CALLS"
  case "$1 ${2:-}" in
    "ps -a")
      printf 'imagineering-outline-postgres\n'; return 0 ;;
  esac
  if [ "$1" = "ps" ]; then
    [ "$STUB_RUNNING" = "1" ] && printf 'imagineering-outline-postgres\n'
    return 0
  fi
  if [ "$1" = "inspect" ]; then printf '%s\n' "$COMPOSE_DIR"; return 0; fi
  if [ "$1" = "compose" ]; then
    # `compose up -d postgres` is what brings the stack up — after it, the
    # container is running, exactly as on a real box.
    case "$*" in *"up -d postgres"*) STUB_RUNNING=1 ;; esac
    return 0
  fi
  # Any `docker exec` past this point: succeed on pg_isready so the readiness loop
  # exits, then fail so the function returns before touching a real database. We
  # are testing ORDER, not the swap (validated separately under #138/#29).
  if [ "$1" = "exec" ]; then
    case "$*" in *pg_isready*) return 0 ;; esac
    return 1
  fi
  return 0
}
export -f docker 2>/dev/null || true

# shellcheck source=restore.sh
RESTORE_LIB_ONLY=1 . "$SCRIPT_DIR/restore.sh" >/dev/null 2>&1
# restore.sh sets -e, and sourcing applies it to THIS shell — the first non-zero
# return from a deliberately-failing probe would then kill the harness silently
# (it did: the first run of this file printed its header and exited 1 with no
# assertions). The probes below are MEANT to fail; turn it back off.
set +e

echo "== _restore_pg_atomic on a STOPPED stack (the disaster-recovery case) =="

DUMP="$WORK/outline.sql"
printf 'CREATE TABLE x (a int);\n' > "$DUMP"
: > "$CALLS"
( _restore_pg_atomic outline outline outline "$DUMP" ) >/dev/null 2>&1

if [ ! -s "$CALLS" ]; then
  no "the function issued any docker call at all" "call log empty — the harness did not drive it"
else
  # 1. It must have got as far as starting the stack.
  if grep -q "compose .*up -d postgres" "$CALLS"; then
    ok "reached 'compose up -d postgres' on a stopped stack (did not abort at resolution)"
  else
    no "reached 'compose up -d postgres'" "never started the stack — the resolver aborted first. Calls: $(tr '\n' '|' < "$CALLS")"
  fi

  # 2. And it must not have tried to exec into the container before starting it.
  up_line=$(grep -n "compose .*up -d postgres" "$CALLS" | head -1 | cut -d: -f1)
  exec_line=$(grep -n "^exec " "$CALLS" | head -1 | cut -d: -f1)
  if [ -z "$up_line" ]; then
    : # already reported above
  elif [ -z "$exec_line" ]; then
    ok "no 'docker exec' issued before the stack was started"
  elif [ "$exec_line" -gt "$up_line" ]; then
    ok "every 'docker exec' comes AFTER 'compose up -d postgres' (line $exec_line > $up_line)"
  else
    no "exec ordering" "a 'docker exec' at line $exec_line precedes 'compose up' at line $up_line"
  fi

  # 3. The compose call must carry --project-directory, not rely on the caller's cwd.
  if grep -q -- "--project-directory" "$CALLS"; then
    ok "compose is driven with --project-directory (no cd side-effect on the caller)"
  else
    no "--project-directory" "compose was called without it: $(grep compose "$CALLS" | head -1)"
  fi
fi

# 4. The caller's working directory must be untouched.
#
# CALLED IN THE CURRENT SHELL, DELIBERATELY. The first version of this assertion ran
# the function inside `( ... )`, which made it VOID: a subshell cannot change its
# parent's $PWD, so the check passed whether or not the side-effect existed. Proven
# by reinstating `cd "$composedir"` in the function -- the assertion still reported
# ok. It was a check whose outcome did not depend on the thing it checked, in a suite
# written to catch exactly that. (Tesla, cage-match round 2/3.)
#
# The suite's must-fail arm did not catch it either, because that arm sabotaged the
# ORDERING: two OTHER assertions went red and the suite went red with them, which
# looks identical to this assertion being able to fail. A must-fail arm proves the
# control CAN fail, not that it fails for the proposition its assertion names.
before=$PWD
_restore_pg_atomic outline outline outline "$DUMP" >/dev/null 2>&1
if [ "$PWD" = "$before" ]; then
  ok "caller's \$PWD is unchanged after the call (checked in the CURRENT shell)"
else
  no "caller \$PWD" "was [$before], now [$PWD] -- the function left the caller somewhere else"
  cd "$before" || true
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
