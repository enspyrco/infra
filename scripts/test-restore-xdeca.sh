#!/bin/bash
# Real restore test for the xdeca Postgres + MinIO backups.
#
# WHY THIS EXISTS: xdeca's recurring backup died on 2026-04-30 (its cron entry
# and /opt/scripts/backup.sh were overwritten by the co-located imagineering
# deploy — same host paths, outside the ~/apps/<prefix>-*/ isolation convention).
# A manual rescue snapshot was taken on 2026-08-07, and until 2026-09-01 nobody
# had ever proven it restores. It was a hypothesis wearing a backup's clothes.
#
# Worse, restore.sh is hardcoded to imagineering-cc/imagineering-backups: there
# is NO xdeca restore path in this repo at all, so the only way to answer "does
# it restore?" was to drive psql by hand. That is not a thing you want to be
# improvising during an actual disaster. This script is that path.
#
# It asserts CONTENT, not presence. "The dump exists" and even "psql exited 0"
# are both compatible with restoring an empty database; the checks below look
# for rows that must be there.
#
# Six assertions:
#   [1] COMPLETE     - pg_dump_is_complete passes on both dumps. Drives the REAL
#                      guard from lib/pg-dump-guard.sh, not a copy of it.
#   [2] GUARD/RED    - a deliberately truncated dump, and one carrying a FORGED
#                      completion marker mid-body, are both REJECTED. Without
#                      this, [1] could be a check that can only ever pass.
#   [3] RESTORE      - psql -f loads both dumps with zero ERROR lines.
#   [4] CONTENT      - specific known rows survive the round trip, not just
#                      non-zero counts.
#   [5] BLOBS        - minio.tar.gz passes gzip -t and carries all three buckets
#                      plus .minio.sys (without it the SQL restores to broken
#                      attachment links).
#   [6] SQL<->BLOBS  - every attachment key in the RESTORED database resolves to
#                      an object inside the tarball, or is accounted for as a
#                      row already orphaned in live storage. MinIO stores each
#                      object as a DIRECTORY (xl.meta + part.N), so the match is
#                      on "<bucket>/<key>/", never a plain file path.
#
# Backup source, in order of preference:
#   BACKUP_DIR=/path/to/dir   - use already-fetched files (offline, CI-friendly)
#   otherwise                 - fetch via gh from 10xdeca/xdeca-backups (private)
#
# ORPHANS_EXPECTED is the count of attachment rows known to point at objects
# that no longer exist in LIVE MinIO either. These are NOT backup defects — they
# are pre-existing orphans (measured 2026-09-01: 39 of 82, incl. ~15 duplicate
# uploads of the same submitted grant application). Assertion [6] allows exactly
# this many unresolved keys and fails if the number GROWS, which would mean the
# backup really is dropping blobs.
#
# REQUIRE_ALL=1 (set by CI) turns a missing docker/gh into a hard failure rather
# than a vacuous skip, so CI cannot go green with the test silently not running.
#
# THIS SCRIPT DOES NOT TEAR ITSELF DOWN — deliberately.
# Two reasons. A restore test whose container evaporates on exit cannot be
# INSPECTED: "24 passed" is the summary, and the whole value of a restore is
# being able to open the thing and look at it, especially the run where an
# assertion failed and you need the state that produced it. And an unattended
# `docker rm -f` inside a test is a destructive action running on a schedule
# nobody is watching; the restore is safe to automate, the destruction is not.
# The container name is printed on exit along with the exact removal command.
# Tear it down by hand when you are done looking.
#
# Re-running is safe: fixtures are suffixed per-run, so a second run never
# touches the first one's container. If the exact name somehow exists already,
# the script ABORTS rather than force-removing it — see the pre-flight below.
#
# Exit non-zero on any failure.

set -uo pipefail

REQUIRE_ALL=${REQUIRE_ALL:-0}
BACKUP_DIR=${BACKUP_DIR:-}
BACKUP_REPO=${BACKUP_REPO:-10xdeca/xdeca-backups}
BACKUP_REF=${BACKUP_REF:-HEAD}
ORPHANS_EXPECTED=${ORPHANS_EXPECTED:-39}
PG_IMAGE=${PG_IMAGE:-postgres:15.17}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

skip_or_fail() {
  if [ "$REQUIRE_ALL" = "1" ]; then
    echo "  FAIL - $1 (REQUIRE_ALL set — must be present in CI)"
    exit 1
  fi
  echo "  skip - $1 (set REQUIRE_ALL=1 to force)"
  exit 0
}

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  skip_or_fail "docker unavailable"
fi

# --- Per-run fixtures; NOT auto-removed (see header) -------------------------
SUFFIX="$$-$(date +%s)"
CTR="xdeca-resttest-$SUFFIX"
WORK="$(mktemp -d)"

# Fail closed. If this exact name exists, something is wrong with our
# assumptions — never force-remove a container we did not just create.
if docker inspect "$CTR" >/dev/null 2>&1; then
  echo "  FAIL - container $CTR already exists; refusing to touch it"
  exit 1
fi

# Print the teardown instructions no matter how we exit, including on an early
# abort, so a container is never left behind silently.
announce_teardown() {
  # Only claim something was left running if it actually exists. On an early
  # abort the container was never created, and telling someone to tear down a
  # container that is not there is a small lie that trains people to ignore
  # this banner.
  if ! docker inspect "$CTR" >/dev/null 2>&1; then
    echo ""
    echo "  (no container was created — nothing to tear down)"
    rm -rf "$WORK"
    return
  fi
  echo ""
  echo "  LEFT RUNNING FOR INSPECTION (not torn down — by design):"
  echo "    container : $CTR"
  echo "    workdir   : $WORK"
  echo "    inspect   : docker exec -it $CTR psql -U outline -d outline"
  echo "                docker exec -it $CTR psql -U kanbn   -d kanbn"
  echo "    TEAR DOWN : docker rm -f $CTR && rm -rf $WORK"
}
trap announce_teardown EXIT

# --- Obtain the backup ------------------------------------------------------
FETCH="$WORK/backup"
mkdir -p "$FETCH"

if [ -n "$BACKUP_DIR" ]; then
  for f in outline.sql kanbn.sql minio.tar.gz; do
    if [ ! -f "$BACKUP_DIR/$f" ]; then
      echo "  FAIL - BACKUP_DIR set but $BACKUP_DIR/$f is missing"
      exit 1
    fi
    cp "$BACKUP_DIR/$f" "$FETCH/$f"
  done
  echo "  info - using backup files from $BACKUP_DIR"
else
  if ! command -v gh >/dev/null 2>&1; then
    skip_or_fail "gh unavailable and BACKUP_DIR unset — cannot obtain backup"
  fi
  if ! gh auth status >/dev/null 2>&1; then
    skip_or_fail "gh not authenticated and BACKUP_DIR unset"
  fi
  echo "  info - fetching backup from $BACKUP_REPO@$BACKUP_REF"
  for f in outline.sql kanbn.sql minio.tar.gz; do
    if ! gh api "repos/$BACKUP_REPO/contents/$f?ref=$BACKUP_REF" \
         -H "Accept: application/vnd.github.raw" > "$FETCH/$f" 2>/dev/null; then
      echo "  FAIL - could not fetch $f from $BACKUP_REPO"
      exit 1
    fi
  done
fi

# =============================================================================
# [1] COMPLETE — drive the real guard, not a copy of it
# =============================================================================
echo ""
echo "[1] structural completeness"
# The guard MUST load. If it does not, `pg_dump_is_complete` becomes
# "command not found" -> non-zero -> assertion [2] reads that as "the guard
# rejected the bad dump" and reports ok. A missing guard would then LOOK like a
# working one. Found the hard way running this script from a directory without
# lib/ alongside it: [2] printed two ok lines with no guard loaded at all.
# So: assert the file exists AND the function is defined, and abort if not.
GUARD="$SCRIPT_DIR/lib/pg-dump-guard.sh"
if [ ! -r "$GUARD" ]; then
  echo "  FAIL - cannot read $GUARD — run this script from its place in the repo"
  exit 1
fi
# shellcheck source=lib/pg-dump-guard.sh
. "$GUARD"
if ! declare -F pg_dump_is_complete >/dev/null; then
  echo "  FAIL - $GUARD sourced but pg_dump_is_complete is not defined"
  exit 1
fi

for f in outline.sql kanbn.sql; do
  if pg_dump_is_complete "$FETCH/$f"; then
    ok "$f is a structurally complete pg_dump"
  else
    bad "$f failed pg_dump_is_complete — dump is truncated or malformed"
  fi
done

# =============================================================================
# [2] GUARD/RED — prove the guard can FAIL, else [1] proves nothing
# =============================================================================
echo ""
echo "[2] guard negative controls"
head -c 8000000 "$FETCH/outline.sql" > "$WORK/truncated.sql"
{
  head -c 8000000 "$FETCH/outline.sql"
  printf -- '-- PostgreSQL database dump complete\n'
  head -c 200000 "$FETCH/outline.sql"
} > "$WORK/forged.sql"

if pg_dump_is_complete "$WORK/truncated.sql"; then
  bad "guard ACCEPTED a truncated dump — assertion [1] is vacuous"
else
  ok "guard rejected a truncated dump"
fi
if pg_dump_is_complete "$WORK/forged.sql"; then
  bad "guard ACCEPTED a dump with a forged completion marker mid-body"
else
  ok "guard rejected a forged completion marker"
fi

# =============================================================================
# [3] RESTORE — into a throwaway container; live databases are never touched
# =============================================================================
echo ""
echo "[3] restore into throwaway postgres"
docker run -d --name "$CTR" \
  -e POSTGRES_PASSWORD=resttest -e POSTGRES_USER=postgres "$PG_IMAGE" >/dev/null 2>&1

READY=0
for _ in $(seq 1 45); do
  if docker exec "$CTR" pg_isready -U postgres >/dev/null 2>&1; then READY=1; break; fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then
  bad "throwaway postgres never became ready"
  echo ""
  echo "xdeca restore test: $PASS passed, $FAIL failed"
  exit 1
fi

# Roles and databases must pre-exist: the dumps are plain pg_dump output (no
# --create), and CREATE DATABASE cannot run inside psql's -c transaction block,
# so each statement gets its own invocation.
docker exec "$CTR" psql -U postgres -q -c "create role outline login superuser" >/dev/null 2>&1
docker exec "$CTR" psql -U postgres -q -c "create role kanbn login superuser" >/dev/null 2>&1
docker exec "$CTR" psql -U postgres -q -c "create database outline owner outline" >/dev/null 2>&1
docker exec "$CTR" psql -U postgres -q -c "create database kanbn owner kanbn" >/dev/null 2>&1

for pair in "outline:outline.sql" "kanbn:kanbn.sql"; do
  db="${pair%%:*}"; file="${pair#*:}"
  docker cp "$FETCH/$file" "$CTR:/tmp/$file" >/dev/null 2>&1
  docker exec "$CTR" psql -U "$db" -d "$db" -f "/tmp/$file" > "$WORK/$db.log" 2>&1
  errs=$(grep -c '^ERROR' "$WORK/$db.log")
  if [ "$errs" -eq 0 ]; then
    ok "$file restored with 0 errors"
  else
    bad "$file restored with $errs ERROR line(s):"
    grep '^ERROR' "$WORK/$db.log" | head -3 | sed 's/^/         /'
  fi
done

# =============================================================================
# [4] CONTENT — specific rows, not just non-zero counts
# =============================================================================
echo ""
echo "[4] content assertions"
q() { docker exec "$CTR" psql -U "$1" -d "$1" -tAc "$2" 2>/dev/null | tr -d '[:space:]'; }

assert_ge() {
  # $1 label  $2 actual  $3 minimum
  if [ -n "$2" ] && [ "$2" -ge "$3" ] 2>/dev/null; then
    ok "$1 = $2 (>= $3)"
  else
    bad "$1 = '${2:-<empty>}' (expected >= $3)"
  fi
}

assert_ge "outline: collections"  "$(q outline 'select count(*) from collections where "deletedAt" is null')" 10
assert_ge "outline: documents"    "$(q outline 'select count(*) from documents where "deletedAt" is null')" 120
assert_ge "outline: attachments"  "$(q outline 'select count(*) from attachments')" 80
assert_ge "outline: revisions"    "$(q outline 'select count(*) from revisions')" 500
assert_ge "kanbn: boards"         "$(q kanbn 'select count(*) from board where "deletedAt" is null')" 20
assert_ge "kanbn: cards"          "$(q kanbn 'select count(*) from card where "deletedAt" is null')" 370

# Named artifacts — a restore that loses these is a failed restore even if the
# aggregate counts look healthy. Recycled Sound is grant material.
rs_docs=$(q outline "select count(*) from documents d join collections c on d.\"collectionId\"=c.id where c.name = 'Recycled Sound' and d.\"deletedAt\" is null")
assert_ge "outline: Recycled Sound collection docs" "$rs_docs" 27

rs_board=$(q kanbn "select count(*) from board where \"publicId\" = 'tqy0nch0m8tm'")
if [ "$rs_board" = "1" ]; then
  ok "kanbn: Recycled Sound board (tqy0nch0m8tm) present"
else
  bad "kanbn: Recycled Sound board (tqy0nch0m8tm) MISSING"
fi

for title in 'Grant Application' 'Grant Application Learnings' 'Letter of Support'; do
  n=$(q outline "select count(*) from documents where title = '$title' and \"deletedAt\" is null")
  if [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null; then
    ok "outline: grant doc '$title' present"
  else
    bad "outline: grant doc '$title' MISSING"
  fi
done

# =============================================================================
# [5] BLOBS — the SQL is useless on its own; attachments live in MinIO
# =============================================================================
echo ""
echo "[5] minio tarball"
if gzip -t "$FETCH/minio.tar.gz" 2>/dev/null; then
  ok "minio.tar.gz passes gzip integrity check"
else
  bad "minio.tar.gz is CORRUPT (gzip -t failed)"
fi

tar tzf "$FETCH/minio.tar.gz" 2>/dev/null | sed 's|^\./||' > "$WORK/entries.txt"
if [ ! -s "$WORK/entries.txt" ]; then
  bad "minio.tar.gz listed no entries"
else
  ok "minio.tar.gz lists $(wc -l < "$WORK/entries.txt" | tr -d ' ') entries"
fi

for bucket in outline kanbn-attachments kanbn-avatars .minio.sys; do
  if grep -q "^$bucket/" "$WORK/entries.txt"; then
    ok "bucket present: $bucket"
  else
    bad "bucket MISSING from tarball: $bucket"
  fi
done

# =============================================================================
# [6] SQL <-> BLOBS — the join nobody checks until a restore is already failing
# =============================================================================
echo ""
echo "[6] restored attachment keys resolve to objects in the tarball"
docker exec "$CTR" psql -U outline -d outline -tAc 'select key from attachments' 2>/dev/null \
  | grep . > "$WORK/keys.txt"

total=$(wc -l < "$WORK/keys.txt" | tr -d ' ')
unresolved=0
while IFS= read -r k; do
  # MinIO stores an object as a DIRECTORY (xl.meta + part.N), so the tarball
  # entry is "<bucket>/<key>/..." — matching a plain file path finds nothing.
  grep -qF "outline/$k/" "$WORK/entries.txt" || unresolved=$((unresolved + 1))
done < "$WORK/keys.txt"

echo "  info - $total attachment keys, $unresolved unresolved, $ORPHANS_EXPECTED known pre-existing orphans"
if [ "$unresolved" -le "$ORPHANS_EXPECTED" ]; then
  ok "unresolved keys ($unresolved) within known-orphan allowance ($ORPHANS_EXPECTED)"
else
  bad "unresolved keys ($unresolved) EXCEEDS known orphans ($ORPHANS_EXPECTED) — the backup is dropping blobs"
fi

echo ""
echo "xdeca restore test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
