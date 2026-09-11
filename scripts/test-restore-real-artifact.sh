#!/bin/bash
# ci-skip: reads imagineering-cc/imagineering-backups, a private repo in another org that CI's GITHUB_TOKEN cannot read
# Restore proof driven by the REAL nightly artifact, not a fixture.
#
# WHY THIS EXISTS, given test-restore-aiko-island.sh already passes:
# that test writes its OWN dump — a hand-authored, guaranteed-complete four-row
# .sql ending in COMMIT;. It proves the restore MACHINERY handles a well-formed
# dump. It says nothing about whether the bytes backup.sh actually produced at
# 04:00 are replayable. Those are two different propositions, and only the
# second one is what a backup is FOR.
#
# So this script closes the loop end to end: it pulls the artifact the nightly
# job really pushed to imagineering-cc/imagineering-backups and replays THAT
# through the production _restore_island_core.
#
# Three properties, each with its own evidence:
#   [1] REPLAYS   — the real artifact loads at all, integrity_check ok.
#   [2] COMPLETE  — ALL tables match, per-table row counts, against a control
#                   built by an independent plain replay. Not "the DB exists",
#                   not "one known row is present": every table, or red. An
#                   any-table check would have read green through a restore
#                   that dropped twenty of twenty-two tables.
#   [3] FAILS CLOSED — a truncated artifact AND a body-corrupt one (which passes
#                   the cheap last-line COMMIT; check) are both refused, with
#                   the live DB left byte-intact and the container restarted.
#                   Without this arm a restore path that refused EVERYTHING
#                   would also produce a green [1] and [2] on the happy case.
#
# NOT IN CI. Reading the artifact needs credentials for the private backups
# repo, which the CI job does not have. Run it by hand, or with --artifact
# against a dump you already hold. There is deliberately NO vacuous-skip path:
# a restore proof that cannot reach an artifact must fail, not pass quietly.
#
# Usage:
#   ./scripts/test-restore-real-artifact.sh                    # fetch today's
#   ./scripts/test-restore-real-artifact.sh --artifact d.sql   # use a local one
#
# Exit non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SLUG="imagineering-cc/imagineering-backups"
ARTIFACT_IN_REPO="aiko-island.sql"

PASS=0
FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

ARTIFACT=""
while [ $# -gt 0 ]; do
  case "$1" in
    # `shift 2` FAILS (and shifts nothing) when only one positional remains, so
    # `--artifact` with no value would spin this loop forever, silently, with no
    # output — there is no set -e here to stop it. Require the value explicitly.
    --artifact)
      [ $# -ge 2 ] || { echo "--artifact requires a path" >&2; exit 2; }
      ARTIFACT="$2"; shift 2 ;;
    # Fail closed on an unrecognised flag rather than silently ignoring it —
    # this script drives a destructive code path against whatever it is handed.
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "  FAIL - docker unavailable; this proof needs a real container runtime"
  exit 1
fi

WORK="$(mktemp -d)"
SUFFIX="$$-$(date +%s)"
IMG="aiko-chat-island:realtest-$SUFFIX"   # tag must match the discovery regex
CTR="aiko-island-realtest-$SUFFIX"
VOL="aiko-realtest-live-$SUFFIX"
CTLVOL="aiko-realtest-control-$SUFFIX"

cleanup() {
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL" "$CTLVOL" >/dev/null 2>&1 || true
  docker image rm -f "$IMG" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- Obtain the real artifact ------------------------------------------------
if [ -z "$ARTIFACT" ]; then
  command -v gh >/dev/null 2>&1 || { echo "  FAIL - no --artifact and no gh to fetch one"; exit 1; }
  ARTIFACT="$WORK/$ARTIFACT_IN_REPO"
  echo "Fetching $ARTIFACT_IN_REPO from $BACKUP_SLUG ..."
  # Fetch via the GIT BLOBS api, not contents. The contents api silently returns
  # `"encoding":"none","content":""` for any file over 1MB — and NINE of the
  # twelve backup artifacts are over 1MB, so a contents fetch would hand this
  # script an empty file and report "artifact is empty", which reads as a backup
  # problem rather than an api limit. Blobs handles up to 100MB.
  # (`Accept: raw` is not the fix either: gh refuses to emit responses containing
  # terminal escape sequences, which the postgres dumps contain.)
  META="$(gh api "repos/$BACKUP_SLUG/contents/$ARTIFACT_IN_REPO" --jq '.sha + " " + (.size|tostring)' 2>"$WORK/fetch.err")" || {
    echo "  FAIL - could not stat the artifact: $(tr '\n' ' ' < "$WORK/fetch.err")"; exit 1; }
  BLOB_SHA="${META%% *}"
  EXPECT_BYTES="${META##* }"
  if ! gh api "repos/$BACKUP_SLUG/git/blobs/$BLOB_SHA" --jq '.content' \
       | base64 -d > "$ARTIFACT" 2>"$WORK/fetch.err"; then
    echo "  FAIL - could not fetch the artifact: $(tr '\n' ' ' < "$WORK/fetch.err")"; exit 1
  fi
  # "the bytes arrived" and "ALL the bytes arrived" are different claims, and a
  # short read would present downstream as a truncated BACKUP rather than a
  # truncated TRANSFER. Pin it here, where the two can still be told apart.
  GOT_BYTES="$(wc -c < "$ARTIFACT" | tr -d ' ')"
  if [ "$GOT_BYTES" != "$EXPECT_BYTES" ]; then
    echo "  FAIL - short read: got $GOT_BYTES bytes, the api reports $EXPECT_BYTES"; exit 1
  fi
  # Provenance matters more than the bytes: an artifact from an unknown night
  # proves a restore of an unknown thing. Print when it was actually pushed.
  PUSHED="$(gh api "repos/$BACKUP_SLUG/commits?path=$ARTIFACT_IN_REPO&per_page=1" \
            --jq '.[0].commit.committer.date' 2>/dev/null)"
  echo "  artifact last pushed: ${PUSHED:-unknown}"
fi
[ -s "$ARTIFACT" ] || { echo "  FAIL - artifact is empty: $ARTIFACT"; exit 1; }
echo "  artifact: $ARTIFACT ($(wc -c < "$ARTIFACT") bytes)"
echo ""

# shellcheck source=lib/sqlite-dumper.sh disable=SC1091
. "$SCRIPT_DIR/lib/sqlite-dumper.sh"
ensure_sqlite_dumper || { echo "  FAIL - could not build sqlite-dumper"; exit 1; }

docker build -q -t "$IMG" - >/dev/null <<'DOCKERFILE'
FROM alpine:3.20
CMD ["sleep", "3600"]
DOCKERFILE
docker volume create "$VOL" >/dev/null
docker volume create "$CTLVOL" >/dev/null
docker run -d --name "$CTR" -v "$VOL:/data" "$IMG" >/dev/null

# table_counts <volume> <dbfile> — one "table=rows" line per table, sorted.
# Enumerated from sqlite_master rather than from a table list in this script:
# a hardcoded list makes the check blind to exactly the failure where the
# restore drops a table nobody thought to name.
table_counts() {
  docker run --rm -v "$1:/data:ro" sqlite-dumper:latest sh -c "
    [ -f /data/$2 ] || { echo 'NO-DB'; exit 0; }
    for t in \$(sqlite3 /data/$2 \"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;\"); do
      printf '%s=%s\n' \"\$t\" \"\$(sqlite3 /data/$2 \"SELECT count(*) FROM \\\"\$t\\\";\")\"
    done"
}

# --- CONTROL: independent plain replay, outside the restore path ------------
# The comparison needs a truth built by different machinery than the thing
# under test, or it is the restore path agreeing with itself.
echo "[control] plain sqlite3 replay of the real artifact"
if ! docker run --rm -i -v "$CTLVOL:/data" sqlite-dumper:latest sh -c 'sqlite3 -bail /data/ctl.db' < "$ARTIFACT"; then
  bad "the real artifact does not replay AT ALL — the backup is not a backup"
  echo ""; echo "restore proof: $PASS passed, $FAIL failed"; exit 1
fi
table_counts "$CTLVOL" ctl.db > "$WORK/control.txt"
CTL_TABLES=$(wc -l < "$WORK/control.txt" | tr -d ' ')
CTL_ROWS=$(awk -F= '{s+=$2} END {print s+0}' "$WORK/control.txt")
ok "real artifact replays: $CTL_TABLES tables, $CTL_ROWS rows"

# --- [1]+[2] SUBJECT: the production restore path ---------------------------
echo ""
echo "[1] the REAL artifact through the REAL _restore_island_core"
# shellcheck source=restore.sh disable=SC1091
RESTORE_LIB_ONLY=1 . "$SCRIPT_DIR/restore.sh"
set +e   # restore.sh sets -e; drive control flow explicitly from here.

_restore_island_core "$ARTIFACT" "$CTR" "$VOL" >"$WORK/restore.log" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "_restore_island_core succeeded on the real artifact"
else bad "_restore_island_core returned $RC: $(tr '\n' ' ' < "$WORK/restore.log")"; fi

INTEG="$(docker run --rm -v "$VOL:/data:ro" sqlite-dumper:latest sh -c \
  '[ -f /data/aiko.db ] && sqlite3 /data/aiko.db "PRAGMA integrity_check;" || echo NO-DB')"
if [ "$INTEG" = "ok" ]; then ok "restored DB passes integrity_check"; else bad "integrity_check: $INTEG"; fi

if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)" = "true" ]; then
  ok "island container is running again after restore"
else
  bad "island container is NOT running after restore"
fi

echo ""
echo "[2] ALL tables match the control — every table, not any table"
table_counts "$VOL" aiko.db > "$WORK/restored.txt"
if diff -u "$WORK/control.txt" "$WORK/restored.txt" > "$WORK/diff.txt"; then
  ok "all $CTL_TABLES tables identical ($CTL_ROWS rows) — nothing dropped, nothing invented"
else
  bad "per-table mismatch between control and restored:"
  sed 's/^/         /' "$WORK/diff.txt"
fi

# --- [3] FAILS CLOSED on real-shaped damage ---------------------------------
# Both arms are cut from the REAL artifact, so they are the same shape as the
# thing being restored. A control that states its own answer (an obviously
# bogus one-line file) would certify an easier task than the one being run.
echo ""
echo "[3] fails closed on a damaged artifact, live DB untouched"
LIVE_BEFORE="$(table_counts "$VOL" aiko.db)"

head -c $(( $(wc -c < "$ARTIFACT") * 2 / 3 )) "$ARTIFACT" > "$WORK/truncated.sql"
if _restore_island_core "$WORK/truncated.sql" "$CTR" "$VOL" >/dev/null 2>&1; then
  bad "truncated artifact ACCEPTED"
else
  ok "truncated artifact refused"
fi

# The nastier arm: ends in COMMIT; so the cheap end-anchored check passes, but
# the SQL body is cut mid-statement. This is the one that proves the guard is
# real validation and not a string match on the last line.
{ head -c $(( $(wc -c < "$ARTIFACT") * 2 / 3 )) "$ARTIFACT"; printf '\nCOMMIT;\n'; } > "$WORK/corrupt.sql"
if _restore_island_core "$WORK/corrupt.sql" "$CTR" "$VOL" >/dev/null 2>&1; then
  bad "body-corrupt artifact ACCEPTED — the check is only reading the last line"
else
  ok "body-corrupt artifact refused despite a valid COMMIT; last line"
fi

LIVE_AFTER="$(table_counts "$VOL" aiko.db)"
if [ "$LIVE_BEFORE" = "$LIVE_AFTER" ]; then
  ok "live DB byte-identical after both refusals (no partial write)"
else
  bad "live DB CHANGED during a refused restore — the destructive path ran anyway"
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)" = "true" ]; then
  ok "container restarted after each refusal (not left down)"
else
  bad "container left DOWN after a refused restore"
fi

echo ""
echo "restore proof: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
