#!/bin/bash
# ci-skip: reads imagineering-cc/imagineering-backups, a private repo in another org that CI's GITHUB_TOKEN cannot read
# Matrix-bridge restore proof driven by the REAL nightly artifacts.
#
# Third in the family, after the sqlite (aiko-island) and postgres (outline,
# kanbn) proofs. This one covers FIVE services at once — discord, signal,
# telegram, whatsapp, relay — which is the largest single block of unproven
# restores left in the estate.
#
# WHY IT LOOKS DIFFERENT FROM ITS SIBLINGS. restore_matrix is not decomposed the
# way _restore_island_core and _restore_pg_atomic are: it fetches from GitHub
# itself, drives the compose stack, and iterates a fixed list. There is no inner
# function to call with test arguments. So instead of calling a core, this drives
# the WHOLE REAL FUNCTION with its two external dependencies redirected:
#
#   fetch_backups      -> overridden to a no-op; the artifacts are staged already
#   BACKUP_CLONE_DIR   -> repointed at that staging dir
#   MATRIX_COMPOSE_DIR -> a throwaway compose project
#
# Everything between those edges — validation, candidate build, integrity_check,
# rescue copy, sidecar removal, atomic install, the per-bridge failure accounting
# — is the real code path, unmodified.
#
# DANGEROUS BY CONSTRUCTION, SO IT REFUSES TO RUN WHERE IT WOULD MATTER. The
# volume names are hardcoded inside restore_matrix (matrix_discord_data, ...), so
# this test cannot use uniquely-suffixed fixtures the way the island proof does —
# it must create volumes with the production names. On the box those ARE the live
# bridge volumes. It therefore aborts if any of them already exists. That is not
# a limitation to route around: this proof belongs on a workstation, never on
# enspyr-syd.
#
# Per bridge, three properties:
#   [1] REPLAYS + INSTALLS — the real dump lands in the real volume.
#   [2] COMPLETE  — ALL tables match a control built by an independent replay.
#   [3] PRESERVES — the prior DB survives as <dbfile>.rescue-*, carrying a
#                   sentinel table that existed only before the restore.
# Then one whole-run property:
#   [4] ACCOUNTING — a bridge whose dump is missing is REPORTED, not silently
#                   skipped, and its live DB is left intact.
#
# Not in CI (see ci-skip). No vacuous-skip path.
# Usage:  ./scripts/test-restore-real-artifact-matrix.sh
# Exit non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SLUG="imagineering-cc/imagineering-backups"

# name:volume:dbfile — MUST match restore_matrix's own `entries` list. Drift here
# would make this test pass against a set of bridges the real function no longer
# restores, so it is asserted against the source below rather than trusted.
BRIDGES=(
  "matrix-discord:matrix_discord_data:discord.db"
  "matrix-signal:matrix_signal_data:signal.db"
  "matrix-telegram:matrix_telegram_data:mautrix-telegram.db"
  "matrix-whatsapp:matrix_whatsapp_data:whatsapp.db"
  "matrix-relay:matrix_relay_data:relay.db"
)

PASS=0
FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

[ $# -eq 0 ] || { echo "unknown argument: $1" >&2; exit 2; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "  FAIL - docker unavailable; this proof needs a real container runtime"; exit 1
fi

# --- PRODUCTION SAFETY GATE -------------------------------------------------
for entry in "${BRIDGES[@]}"; do
  IFS=: read -r _ volume _ <<< "$entry"
  if docker volume ls --format '{{.Name}}' | grep -qx "$volume"; then
    echo "  FAIL - volume '$volume' already exists here."
    echo "         This proof creates volumes with PRODUCTION names because"
    echo "         restore_matrix hardcodes them. Refusing to touch an existing one."
    exit 1
  fi
done

WORK="$(mktemp -d)"
STAGE="$WORK/backups"
COMPOSE_DIR="$WORK/apps/matrix"
mkdir -p "$STAGE" "$COMPOSE_DIR"

cleanup() {
  docker compose --project-directory "$COMPOSE_DIR" down -v >/dev/null 2>&1 || true
  for e in "${BRIDGES[@]}"; do
    IFS=: read -r _ v _ <<< "$e"
    docker volume rm -f "$v" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- Assert our bridge list matches restore_matrix's ------------------------
# A test carrying its own copy of a list is a second source of truth. Diff them.
SRC_LIST=$(sed -n '/local entries=(/,/^  )/p' "$SCRIPT_DIR/restore.sh" \
           | grep -oE '"[a-z-]+:[a-z_]+:[a-zA-Z.-]+\.db"' | tr -d '"' | sort)
OUR_LIST=$(printf '%s\n' "${BRIDGES[@]}" | sort)
if [ "$SRC_LIST" = "$OUR_LIST" ]; then
  ok "bridge list matches restore_matrix's own entries (5 bridges)"
else
  bad "bridge list has DRIFTED from restore.sh:"
  diff <(echo "$SRC_LIST") <(echo "$OUR_LIST") | sed 's/^/         /'
fi

# --- Stage the REAL artifacts ------------------------------------------------
echo ""
echo "[fetch] the real bridge dumps from $BACKUP_SLUG"
fetch_one() {
  local name="$1" meta sha expect got
  meta="$(gh api "repos/$BACKUP_SLUG/contents/${name}.sql" --jq '.sha + " " + (.size|tostring)' 2>/dev/null)" || return 1
  sha="${meta%% *}"; expect="${meta##* }"
  local i
  for i in 1 2 3; do
    if gh api "repos/$BACKUP_SLUG/git/blobs/$sha" --jq '.content' 2>"$WORK/f.err" \
       | base64 -d > "$STAGE/${name}.sql"; then
      got="$(wc -c < "$STAGE/${name}.sql" | tr -d ' ')"
      [ "$got" = "$expect" ] && { echo "  $name: $got bytes"; return 0; }
      echo "  $name: short read ($got/$expect), retry $i/3"
    else
      echo "  $name: fetch failed ($(tr '\n' ' ' < "$WORK/f.err" | tail -c 80)), retry $i/3"
    fi
    sleep 2
  done
  return 1
}
for entry in "${BRIDGES[@]}"; do
  IFS=: read -r name _ _ <<< "$entry"
  fetch_one "$name" || { bad "could not fetch ${name}.sql"; echo ""; echo "matrix restore proof: $PASS passed, $FAIL failed"; exit 1; }
done

# shellcheck source=lib/sqlite-dumper.sh disable=SC1091
. "$SCRIPT_DIR/lib/sqlite-dumper.sh"
ensure_sqlite_dumper || { echo "  FAIL - could not build sqlite-dumper"; exit 1; }

# table_counts <volume> <dbfile> — enumerated from sqlite_master, never a list in
# this script: a hardcoded list is blind to a restore that drops a table.
table_counts() {
  docker run --rm -v "$1:/data:ro" sqlite-dumper:latest sh -c "
    [ -f '/data/$2' ] || { echo 'NO-DB'; exit 0; }
    for t in \$(sqlite3 '/data/$2' \"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;\"); do
      printf '%s=%s\n' \"\$t\" \"\$(sqlite3 '/data/$2' \"SELECT count(*) FROM \\\"\$t\\\";\")\"
    done"
}

# --- Fixture: volumes with a KNOWN pre-restore DB ---------------------------
echo ""
echo "[setup] seed each bridge volume with a sentinel DB, then build controls"
cat > "$COMPOSE_DIR/docker-compose.yml" <<'YML'
services:
  placeholder:
    image: alpine:3.20
    command: ["sleep", "3600"]
YML
for entry in "${BRIDGES[@]}"; do
  IFS=: read -r name volume dbfile <<< "$entry"
  docker volume create "$volume" >/dev/null
  docker run --rm -v "$volume:/data" sqlite-dumper:latest sh -c \
    "sqlite3 '/data/$dbfile' \"CREATE TABLE zz_sentinel(note text); INSERT INTO zz_sentinel VALUES('PRE-RESTORE $name');\"" >/dev/null
  # POSITIVE CONTROL on the seed: every [2]/[3] claim is a claim about this row,
  # so a silently-failed seed makes them vacuous rather than red.
  seeded=$(docker run --rm -v "$volume:/data:ro" sqlite-dumper:latest sh -c \
    "sqlite3 '/data/$dbfile' \"SELECT note FROM zz_sentinel LIMIT 1;\"" 2>/dev/null)
  [ "$seeded" = "PRE-RESTORE $name" ] || { bad "$name: seed did not land — later checks would be vacuous"; echo ""; echo "matrix restore proof: $PASS passed, $FAIL failed"; exit 1; }
  # CONTROL: independent plain replay, outside the restore path.
  docker run --rm -i -v "$WORK:/w" sqlite-dumper:latest sh -c \
    "rm -f '/w/ctl-$name.db'; sqlite3 -bail '/w/ctl-$name.db'" < "$STAGE/${name}.sql" \
    || { bad "$name: the real artifact does not replay AT ALL"; continue; }
done
ok "all five volumes seeded and verified, controls built by independent replay"

# --- Drive the REAL restore_matrix ------------------------------------------
echo ""
echo "[1] the REAL restore_matrix, real artifacts, real volumes"
# shellcheck source=restore.sh disable=SC1091
RESTORE_LIB_ONLY=1 . "$SCRIPT_DIR/restore.sh"
set +e
# Redirect the two external edges; everything between them is untouched.
# SC2034: both ARE read — by restore_matrix in the file sourced above, which the
# linter cannot follow across a `source`. Disabled at the assignment, with the
# reason, rather than file-wide where it would also mask a genuinely dead
# variable added later. (Note: a comment line may not START with the linter's
# own name, or it is parsed as a malformed directive — SC1072/SC1073.)
# shellcheck disable=SC2034
BACKUP_CLONE_DIR="$STAGE"
# shellcheck disable=SC2034
MATRIX_COMPOSE_DIR="$COMPOSE_DIR"
fetch_backups() { :; }          # artifacts are already staged
cleanup_backups() { :; }        # would rm -rf our staging dir

restore_matrix > "$WORK/restore.log" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "restore_matrix completed (rc=0)"
else bad "restore_matrix returned $RC: $(tr '\n' ' ' < "$WORK/restore.log" | tail -c 400)"; fi

# --- [2] + [3] per bridge ---------------------------------------------------
echo ""
echo "[2] every bridge: ALL tables match its control"
for entry in "${BRIDGES[@]}"; do
  IFS=: read -r name volume dbfile <<< "$entry"
  docker run --rm -v "$WORK:/w:ro" sqlite-dumper:latest sh -c "
    for t in \$(sqlite3 '/w/ctl-$name.db' \"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;\"); do
      printf '%s=%s\n' \"\$t\" \"\$(sqlite3 '/w/ctl-$name.db' \"SELECT count(*) FROM \\\"\$t\\\";\")\"
    done" > "$WORK/ctl-$name.txt" 2>/dev/null
  table_counts "$volume" "$dbfile" > "$WORK/live-$name.txt"
  NT=$(grep -c . "$WORK/ctl-$name.txt" || true)
  if diff -q "$WORK/ctl-$name.txt" "$WORK/live-$name.txt" >/dev/null 2>&1; then
    ok "$name: all $NT tables identical to control"
  else
    bad "$name: per-table mismatch:"
    diff "$WORK/ctl-$name.txt" "$WORK/live-$name.txt" | head -6 | sed 's/^/         /'
  fi
  if grep -q '^zz_sentinel=' "$WORK/live-$name.txt"; then
    bad "$name: the pre-restore sentinel is STILL live — the DB was not replaced"
  fi
done

echo ""
echo "[3] every bridge: the previous DB survives as a rescue copy"
for entry in "${BRIDGES[@]}"; do
  IFS=: read -r name volume dbfile <<< "$entry"
  RESCUE=$(docker run --rm -v "$volume:/data:ro" sqlite-dumper:latest sh -c \
    "ls /data | grep '^${dbfile}.rescue-' | head -1" 2>/dev/null | tr -d '\r')
  if [ -z "$RESCUE" ]; then
    bad "$name: no rescue copy — the previous DB was destroyed, not kept"
    continue
  fi
  NOTE=$(docker run --rm -v "$volume:/data:ro" sqlite-dumper:latest sh -c \
    "sqlite3 '/data/$RESCUE' \"SELECT note FROM zz_sentinel LIMIT 1;\"" 2>/dev/null | tr -d '\r')
  if [ "$NOTE" = "PRE-RESTORE $name" ]; then
    ok "$name: previous DB preserved in $RESCUE (sentinel readable)"
  else
    bad "$name: rescue exists but the sentinel is not readable in it (got '$NOTE')"
  fi
done

# --- [4] missing-dump accounting --------------------------------------------
# The function's own warning path: a bridge with no dump must be REPORTED and its
# live DB left intact. A silent skip under a "complete!" banner is the failure
# this accounting exists to prevent, and it can only be checked by removing one.
echo ""
echo "[4] a MISSING dump is reported, not silently skipped"
IFS=: read -r MNAME MVOL MDB <<< "${BRIDGES[0]}"
BEFORE_MISSING="$(table_counts "$MVOL" "$MDB")"
mv "$STAGE/${MNAME}.sql" "$WORK/held.sql"
restore_matrix > "$WORK/missing.log" 2>&1
MRC=$?
mv "$WORK/held.sql" "$STAGE/${MNAME}.sql"
if grep -q "No ${MNAME}.sql found" "$WORK/missing.log"; then
  ok "the missing bridge is named in the output"
else
  bad "a missing dump produced no warning naming $MNAME"
fi
if grep -qi "INCOMPLETE restore" "$WORK/missing.log"; then
  ok "the run is flagged INCOMPLETE rather than reported as complete"
else
  bad "no INCOMPLETE warning — a partial restore reported as a whole one (rc=$MRC)"
fi
if [ "$(table_counts "$MVOL" "$MDB")" = "$BEFORE_MISSING" ]; then
  ok "$MNAME's live DB untouched when its dump was absent"
else
  bad "$MNAME's live DB CHANGED despite having no dump"
fi

echo ""
echo "matrix restore proof: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
