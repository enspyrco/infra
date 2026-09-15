#!/bin/bash
# ci-skip: reads imagineering-cc/imagineering-backups, a private repo in another org that CI's GITHUB_TOKEN cannot read
# Postgres restore proof driven by the REAL nightly artifact, on a STOPPED stack.
#
# The sibling of test-restore-real-artifact.sh, for the path that carries the two
# biggest databases in the estate. Same argument, different machinery.
#
# WHY THIS EXISTS, given test-restore-pg-ordering.sh already passes: that test says
# so itself — "docker is stubbed and records every invocation, so this is hermetic:
# no daemon, no containers, no postgres." It proves the ORDER of two calls, which is
# exactly the right instrument for the defect it was built for. It cannot see the
# temp-DB load, the integrity gate, the fence, the double rename, the rollback or
# the un-fence, because none of those run against a stub.
#
# So _restore_pg_atomic's entire swap choreography had never met a real database.
#
# THE STACK IS STOPPED ON PURPOSE. A recovery happens on a box where the stack is
# down, and the resolver reads `docker ps` — running containers only. That asymmetry
# is the whole reason the anchor resolves from `docker ps -a` instead. Testing this
# against a RUNNING stack would pass while saying nothing about the case the code is
# for.
#
# Properties, each separately evidenced:
#   [1] RESOLVES + RUNS on a stopped stack, end to end, with the real artifact.
#   [2] COMPLETE   — ALL tables and row counts match a control built by an
#                    independent plain replay. rc=0 proves the choreography ran;
#                    it says nothing about whether the rows arrived.
#   [3] PRESERVES  — the PREVIOUS live database survives in the rescue DB. A restore
#                    that lands the new data and silently destroys the old one
#                    passes [1] and [2] perfectly.
#   [4] UNFENCED   — the new live DB accepts connections. The swap fences both DBs
#                    and the new live INHERITS that fence from the temp; if the
#                    un-fence fails the data is correct and the app crash-loops,
#                    which is a success return with a dead service behind it.
#   [5] FAILS CLOSED — a body-corrupt artifact leaves live data AND the container
#                    untouched. Without this, a restore path that refused every
#                    dump would produce an identically green [1]-[4].
#
# NOT IN CI (see the ci-skip above) and no vacuous-skip path: a restore proof that
# cannot reach an artifact must fail rather than pass quietly.
#
# Usage:  ./scripts/test-restore-real-artifact-postgres.sh [--service outline|kanbn] [--artifact FILE]
# Exit non-zero on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SLUG="imagineering-cc/imagineering-backups"
# The two postgres-backed services, as a CLOSED SET. Both declare
# postgres:15-alpine and both are called as `_restore_pg_atomic <svc> <svc> <svc>`
# in restore.sh, so service name == pg user == pg database for each.
# An unknown --service is refused rather than defaulted: this drives a destructive
# code path, and guessing which database is meant is exactly the wrong-tenant
# hazard the resolvers already fail closed on.
PG_SERVICES="outline kanbn"
SVC=outline                       # default: the bigger of the two
PG_IMAGE="postgres:15-alpine"     # the image BOTH stacks' compose files declare

PASS=0
FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

ARTIFACT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact)
      [ $# -ge 2 ] || { echo "--artifact requires a path" >&2; exit 2; }
      ARTIFACT="$2"; shift 2 ;;
    --service)
      [ $# -ge 2 ] || { echo "--service requires a name ($PG_SERVICES)" >&2; exit 2; }
      SVC="$2"; shift 2
      # shellcheck disable=SC2086
      case " $PG_SERVICES " in
        *" $SVC "*) ;;
        *) echo "unknown service '$SVC' — expected one of: $PG_SERVICES" >&2; exit 2 ;;
      esac ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ARTIFACT_IN_REPO="${SVC}.sql"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "  FAIL - docker unavailable; this proof needs a real container runtime"
  exit 1
fi

WORK="$(mktemp -d)"
PROJ="$WORK/fixture-$SVC"
# The container MUST carry the deployed `imagineering-` prefix: _pg_select_match
# refuses a lone legacy `img-` match outright (claude-tasks#4288). Note that
# outline/docker-compose.yml in this repo still declares the legacy name — using
# it here would make this test fail on a namespace question rather than on the
# restore, which is a different proposition than the one being measured.
CTR="imagineering-${SVC}-postgres"

cleanup() {
  docker compose --project-directory "$PROJ" down -v >/dev/null 2>&1 || true
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if docker ps -a --format '{{.Names}}' | grep -qx "$CTR"; then
  echo "  FAIL - a container named $CTR already exists here; refusing to touch it"
  exit 1
fi

# --- Obtain the real artifact ------------------------------------------------
if [ -z "$ARTIFACT" ]; then
  command -v gh >/dev/null 2>&1 || { echo "  FAIL - no --artifact and no gh to fetch one"; exit 1; }
  ARTIFACT="$WORK/$ARTIFACT_IN_REPO"
  echo "Fetching $ARTIFACT_IN_REPO from $BACKUP_SLUG ..."
  # Blobs api, not contents: contents returns empty content above 1MB and outline.sql
  # is 8.6MB, so a contents fetch would hand this an empty file and call the BACKUP
  # empty. Same reason as the sqlite proof; here it is not a latent trap but the
  # normal case.
  META="$(gh api "repos/$BACKUP_SLUG/contents/$ARTIFACT_IN_REPO" --jq '.sha + " " + (.size|tostring)' 2>"$WORK/fetch.err")" || {
    echo "  FAIL - could not stat the artifact: $(tr '\n' ' ' < "$WORK/fetch.err")"; exit 1; }
  BLOB_SHA="${META%% *}"
  EXPECT_BYTES="${META##* }"
  # The redirect goes on GH, not on base64. `... | base64 -d > f 2>err` binds the
  # stderr of BASE64, so gh's actual error escapes to the terminal and the operator
  # is handed an empty reason — measured: a real `stream error: stream ID 1; CANCEL`
  # printed as "could not fetch the artifact: ". Capture the channel that speaks.
  #
  # Retried because the transfer genuinely flakes: three transient network failures
  # in one session (two curl-35 in CI, one HTTP/2 CANCEL here), all on GitHub
  # downloads, none of them a defect in what was being fetched. A single-shot fetch
  # turns a flake into a red restore proof, which is the expensive misreading.
  FETCHED=0
  for attempt in 1 2 3; do
    if gh api "repos/$BACKUP_SLUG/git/blobs/$BLOB_SHA" --jq '.content' 2>"$WORK/fetch.err" \
         | base64 -d > "$ARTIFACT"; then
      FETCHED=1; break
    fi
    echo "  retry $attempt/3 after: $(tr '\n' ' ' < "$WORK/fetch.err" | tail -c 120)"
    sleep 2
  done
  if [ "$FETCHED" != "1" ]; then
    echo "  FAIL - could not fetch the artifact after 3 attempts: $(tr '\n' ' ' < "$WORK/fetch.err")"; exit 1
  fi
  GOT_BYTES="$(wc -c < "$ARTIFACT" | tr -d ' ')"
  if [ "$GOT_BYTES" != "$EXPECT_BYTES" ]; then
    echo "  FAIL - short read: got $GOT_BYTES bytes, the api reports $EXPECT_BYTES"; exit 1
  fi
  PUSHED="$(gh api "repos/$BACKUP_SLUG/commits?path=$ARTIFACT_IN_REPO&per_page=1" \
            --jq '.[0].commit.committer.date' 2>/dev/null)"
  echo "  artifact last pushed: ${PUSHED:-unknown}"
fi
[ -s "$ARTIFACT" ] || { echo "  FAIL - artifact is empty: $ARTIFACT"; exit 1; }
echo "  artifact: $(wc -c < "$ARTIFACT" | tr -d ' ') bytes"
echo ""

# --- Fixture: a REAL compose project ----------------------------------------
# resolve_compose_workdir reads com.docker.compose.project.working_dir, a label only
# compose sets — a bare `docker run` container cannot exercise this path at all.
mkdir -p "$PROJ"
cat > "$PROJ/docker-compose.yml" <<YML
services:
  postgres:
    image: $PG_IMAGE
    container_name: $CTR
    environment:
      POSTGRES_USER: $SVC
      POSTGRES_DB: $SVC
      POSTGRES_HOST_AUTH_METHOD: trust
YML

# NOTE THE -i. `docker exec` WITHOUT it silently discards stdin: psql reads nothing,
# does nothing, and exits 0. That cost a false red here — a heredoc seed no-opped,
# so the sentinel never existed, and the "sentinel is gone from live" assertion
# passed because there was nothing to find. A check that passes on absence.
_psql() { docker exec -i "$CTR" psql -U "$SVC" -v ON_ERROR_STOP=1 "$@"; }

echo "[setup] start the stack once, seed KNOWN live data, then stop it"
docker compose --project-directory "$PROJ" up -d postgres >/dev/null 2>&1 || {
  echo "  FAIL - fixture postgres would not start"; exit 1; }
for _ in $(seq 1 60); do docker exec "$CTR" pg_isready -U "$SVC" >/dev/null 2>&1 && break; sleep 1; done
docker exec "$CTR" pg_isready -U "$SVC" >/dev/null 2>&1 || { echo "  FAIL - fixture postgres never became ready"; exit 1; }

# A sentinel row that exists ONLY in the pre-restore live DB. After the swap it must
# be absent from live (the restore really replaced it) and present in the rescue DB
# (the previous state really survived). One row proves both directions.
_psql -d "$SVC" >/dev/null <<SQL || { echo "  FAIL - could not seed the sentinel"; exit 1; }
CREATE TABLE zz_sentinel(note text);
INSERT INTO zz_sentinel VALUES ('PRE-RESTORE LIVE DATA');
SQL
# POSITIVE CONTROL on the seed itself. Everything in [2] and [3] is a claim ABOUT
# this row, so a silently-failed seed does not make those checks fail — it makes
# them vacuous, which is worse. Prove the row is really there before proceeding.
SEEDED=$(docker exec -i "$CTR" psql -U "$SVC" -d "$SVC" -tAc \
  "SELECT note FROM zz_sentinel LIMIT 1;" 2>/dev/null | tr -d '\r' | sed 's/^ *//;s/ *$//')
if [ "$SEEDED" = "PRE-RESTORE LIVE DATA" ]; then
  ok "sentinel really is in the live DB before the restore (seed verified, not assumed)"
else
  bad "the seed did not land (read back '$SEEDED') — [2] and [3] would be vacuous; aborting"
  echo ""; echo "postgres restore proof: $PASS passed, $FAIL failed"; exit 1
fi
echo "  image psql: $(docker exec "$CTR" psql --version | awk '{print $3}')"

# --- CONTROL: independent plain replay --------------------------------------
# Built by different machinery than the subject: a plain single-transaction replay
# into a separate DB, no fencing, no renames, no compose.
echo ""
echo "[control] plain replay of the real artifact into a separate DB"
_psql -d postgres -c 'CREATE DATABASE ctl;' >/dev/null 2>&1 || { echo "  FAIL - could not create control DB"; exit 1; }
if ! docker exec -i "$CTR" psql -v ON_ERROR_STOP=1 --single-transaction -U "$SVC" -d ctl \
     < "$ARTIFACT" > "$WORK/ctl.log" 2>&1; then
  bad "the real artifact does not replay AT ALL — the backup is not a backup"
  tail -5 "$WORK/ctl.log" | sed 's/^/         /'
  echo ""; echo "postgres restore proof: $PASS passed, $FAIL failed"; exit 1
fi

# table_counts <db> — "table=rows" per public table, enumerated from the catalog
# rather than a list in this script: a hardcoded list is blind to exactly the
# failure where a restore drops a table nobody thought to name.
table_counts() {
  docker exec "$CTR" psql -U "$SVC" -d "$1" -tAc "
    SELECT string_agg(t || '=' || n, E'\n' ORDER BY t) FROM (
      SELECT c.relname AS t, c.reltuples::bigint AS n
      FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
      WHERE ns.nspname = 'public' AND c.relkind = 'r') s;" 2>/dev/null
}
# reltuples is a planner ESTIMATE and is -1 on a never-analysed table, so ANALYZE
# first to make the numbers real. Without this the comparison would be between two
# sets of estimates that happen to agree — true, and about a different question.
_psql -d ctl -c 'ANALYZE;' >/dev/null 2>&1
table_counts ctl > "$WORK/control.txt"
CTL_TABLES=$(grep -c . "$WORK/control.txt" || true)
CTL_ROWS=$(awk -F= '{s+=$2} END {print s+0}' "$WORK/control.txt")
ok "real artifact replays: $CTL_TABLES tables, ~$CTL_ROWS rows"

echo ""
echo "[setup] STOP the stack — the disaster-recovery case"
docker compose --project-directory "$PROJ" stop >/dev/null 2>&1
RUNNING=$(docker ps --format '{{.Names}}' | grep -cx "$CTR" || true)
PRESENT=$(docker ps -a --format '{{.Names}}' | grep -cx "$CTR" || true)
if [ "$RUNNING" = "0" ] && [ "$PRESENT" = "1" ]; then
  ok "stack is present but NOT running (what a recovery actually faces)"
else
  bad "fixture is not in the stopped state (running=$RUNNING present=$PRESENT) — the DR case was never entered"
fi

# --- [1] SUBJECT ------------------------------------------------------------
echo ""
echo "[1] the REAL artifact through the REAL _restore_pg_atomic, stack down"
# shellcheck source=restore.sh disable=SC1091
RESTORE_LIB_ONLY=1 . "$SCRIPT_DIR/restore.sh"
set +e   # restore.sh sets -e; drive control flow explicitly from here.

_restore_pg_atomic "$SVC" "$SVC" "$SVC" "$ARTIFACT" > "$WORK/restore.log" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "_restore_pg_atomic succeeded from a stopped stack"
else bad "_restore_pg_atomic returned $RC: $(tr '\n' ' ' < "$WORK/restore.log" | tail -c 300)"; fi

# --- [2] COMPLETE -----------------------------------------------------------
echo ""
echo "[2] ALL tables match the control — every table, not any table"
_psql -d "$SVC" -c 'ANALYZE;' >/dev/null 2>&1
table_counts "$SVC" > "$WORK/restored.txt"
if diff -u "$WORK/control.txt" "$WORK/restored.txt" > "$WORK/diff.txt"; then
  ok "all $CTL_TABLES tables identical (~$CTL_ROWS rows) — nothing dropped, nothing invented"
else
  bad "per-table mismatch between control and restored live DB:"
  head -20 "$WORK/diff.txt" | sed 's/^/         /'
fi
if grep -q '^zz_sentinel=' "$WORK/restored.txt"; then
  bad "the pre-restore sentinel table is STILL in live — the restore did not replace the DB"
else
  ok "pre-restore sentinel is gone from live (the DB really was replaced)"
fi

# --- [3] PRESERVES ----------------------------------------------------------
echo ""
echo "[3] the PREVIOUS live database survives as the rescue DB"
RESCUE=$(docker exec "$CTR" psql -U "$SVC" -d postgres -tAc \
  "SELECT datname FROM pg_database WHERE datname LIKE '${SVC}_rescue_%' ORDER BY datname DESC LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
if [ -n "$RESCUE" ]; then
  ok "rescue DB exists ($RESCUE)"
  NOTE=$(docker exec "$CTR" psql -U "$SVC" -d "$RESCUE" -tAc \
    "SELECT note FROM zz_sentinel LIMIT 1;" 2>/dev/null | tr -d '\r' | sed 's/^ *//;s/ *$//')
  if [ "$NOTE" = "PRE-RESTORE LIVE DATA" ]; then
    ok "the previous live data is intact inside it (sentinel row readable)"
  else
    bad "rescue DB exists but the sentinel is not readable in it (got '$NOTE') — old data not preserved"
  fi
else
  bad "no rescue DB — the previous live database was destroyed, not kept"
fi

# --- [4] UNFENCED -----------------------------------------------------------
echo ""
echo "[4] the new live DB actually accepts connections"
ALLOW=$(docker exec "$CTR" psql -U "$SVC" -d postgres -tAc \
  "SELECT datallowconn FROM pg_database WHERE datname='$SVC';" 2>/dev/null | tr -d '[:space:]')
if [ "$ALLOW" = "t" ]; then
  ok "datallowconn is true — the swap's fence was lifted"
else
  bad "live DB still FENCED (datallowconn=$ALLOW) — data correct, app would crash-loop"
fi
if docker exec "$CTR" psql -U "$SVC" -d "$SVC" -tAc 'SELECT 1;' >/dev/null 2>&1; then
  ok "a real client connection to the restored DB succeeds"
else
  bad "cannot connect to the restored live DB"
fi

# --- [5] FAILS CLOSED -------------------------------------------------------
# Cut from the REAL artifact, so it is the same shape as the thing under test.
echo ""
echo "[5] fails closed on a damaged artifact, restored data untouched"
BEFORE="$(table_counts "$SVC")"
head -c $(( $(wc -c < "$ARTIFACT") * 2 / 3 )) "$ARTIFACT" > "$WORK/corrupt.sql"
printf '\n\\unrestrict x\n' >> "$WORK/corrupt.sql"
if _restore_pg_atomic "$SVC" "$SVC" "$SVC" "$WORK/corrupt.sql" >/dev/null 2>&1; then
  bad "body-corrupt artifact ACCEPTED"
else
  ok "body-corrupt artifact refused"
fi
_psql -d "$SVC" -c 'ANALYZE;' >/dev/null 2>&1
AFTER="$(table_counts "$SVC")"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "live data unchanged by the refused restore (no partial write)"
else
  bad "live data CHANGED during a refused restore — the destructive path ran anyway"
fi
if docker exec "$CTR" psql -U "$SVC" -d "$SVC" -tAc 'SELECT 1;' >/dev/null 2>&1; then
  ok "database still reachable after the refusal (not left fenced or down)"
else
  bad "database unreachable after a refused restore"
fi

echo ""
echo "postgres restore proof: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
