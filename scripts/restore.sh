#!/bin/bash
# Restore script for all services
# Restores from GitHub backup repo (imagineering-cc/imagineering-backups)
# Usage: ./restore.sh <service>
#   service: kanbn, outline, radicale, pm-bot, claudius, aiko-island, matrix

set -e

SERVICE=${1:-}   # may be unset when sourced by the test harness (set -u safe)
RESTORE_DIR="/tmp/restore"
GITHUB_BACKUP_REPO="git@github-imagineering-backups:imagineering-cc/imagineering-backups.git"
BACKUP_CLONE_DIR="$RESTORE_DIR/imagineering-backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; }

AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}}"

# Live island volume/container discovery — the SAME single home backup.sh uses,
# so restore can never again drift back to a hardcoded (ghost) volume name
# (aiko_chat_gateway#1759). test-restore-aiko-island.sh sources this file with
# RESTORE_LIB_ONLY=1 to exercise _restore_island_core against a temp volume.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aiko-volume.sh
. "$SCRIPT_DIR/lib/aiko-volume.sh"

# Usage check + dispatch are deferred to the guarded tail so the test harness
# can source this file (RESTORE_LIB_ONLY=1) without triggering the arg check.

# Clone the backup repo (shallow) to get latest backups
fetch_backups() {
  log "Fetching backups from GitHub..."
  rm -rf "$BACKUP_CLONE_DIR"
  git clone --depth 1 "$GITHUB_BACKUP_REPO" "$BACKUP_CLONE_DIR"
}

cleanup_backups() {
  rm -rf "$BACKUP_CLONE_DIR"
}

# Validate a plain-text pg_dump BEFORE any destructive restore step: non-empty,
# complete (end-anchored '-- PostgreSQL database dump complete'), and not a
# schemaless/empty DB (has CREATE TABLE). Returns non-zero so the caller can abort
# with the LIVE database still intact. The old restore_kanbn/outline dropped the
# live DB FIRST, then blind-loaded — a corrupt/truncated repo dump wiped live data.
# (The full atomic restore-into-temp-DB-then-rename is Phase 2 of #29 — needs a
# postgres test container; this guard already stops a bad dump reaching dropdb.)
_validate_pg_dump() {
  local svc="$1" f="$2"
  if [ ! -s "$f" ]; then
    error "$svc: dump $(basename "$f") is empty — refusing (live DB untouched)"; return 1
  fi
  if ! tail -n5 "$f" | grep -qxF -- '-- PostgreSQL database dump complete'; then
    error "$svc: dump incomplete (no completion marker — truncated) — refusing (live DB untouched)"; return 1
  fi
  if ! grep -q 'CREATE TABLE' "$f"; then
    error "$svc: dump has no CREATE TABLE (empty/wrong DB) — refusing (live DB untouched)"; return 1
  fi
  # Refuse dumps that can escape the temp DB mid-replay: a `\connect`/`\c` reconnects
  # to another DB (incl. the LIVE one), and cluster-level `CREATE DATABASE` /
  # `DROP DATABASE` act on OTHER databases regardless of the current connection — any
  # of these replays against live BEFORE the atomic swap, breaking the "temp DB only,
  # live untouched" invariant (cage-match #140, Carnot r1 + Wu r2). Case-insensitive
  # so lowercase SQL keywords don't slip past. Our backups are plain `pg_dump <db>`,
  # so a real backup never trips this.
  if grep -qiE '^[[:space:]]*(\\c|\\connect|create database|drop database)\b' "$f"; then
    error "$svc: dump contains \\connect / CREATE DATABASE / DROP DATABASE (could act on the LIVE db mid-replay) — refusing. Expected a plain 'pg_dump <db>' dump."; return 1
  fi
  return 0
}

# Build the tiny alpine+sqlite helper image if absent (idempotent — mirrors
# backup-aiko-island-standalone.sh) so a box where the backup path never ran can
# still validate a SQLite candidate. Shared single door for _restore_island_core
# and _validate_sqlite_db so both paths validate identically. Returns non-zero on
# build failure so the caller can abort with live state intact.
_ensure_sqlite_dumper() {
  if ! docker image inspect sqlite-dumper:latest >/dev/null 2>&1; then
    log "Building sqlite-dumper:latest (alpine + sqlite3)..."
    printf 'FROM alpine:3.20\nRUN apk add --no-cache sqlite\n' \
      | docker build -q -t sqlite-dumper:latest - >/dev/null \
      || { error "failed to build sqlite-dumper:latest"; return 1; }
  fi
  return 0
}

# Validate a raw SQLite .db file BEFORE it overwrites live state. The 16-byte magic
# header alone is NOT enough: a truncated/garbage file that keeps the header still
# passes a magic check and then clobbers the live DB (cage-match #138: Carnot+Tesla).
# So this runs the same PRAGMA integrity_check the island path uses (reads the whole
# b-tree — truncation fails) PLUS a non-empty .tables check (rejects a schemaless/
# wrong DB). Exact-byte header match first as a cheap pre-filter. Returns non-zero
# so the caller aborts with the live DB untouched.
_validate_sqlite_db() {
  local svc="$1" f="$2"
  if [ ! -s "$f" ]; then
    error "$svc: $(basename "$f") is empty — refusing (live DB untouched)"; return 1
  fi
  # Exact 15-byte header ("SQLite format 3", the magic minus its trailing NUL) —
  # an exact prefix match, not a substring grep that any 16 bytes containing the
  # string would satisfy (cage-match #138: Carnot+Tesla).
  if [ "$(head -c 15 "$f")" != "SQLite format 3" ]; then
    error "$svc: $(basename "$f") is not a SQLite database (bad header) — refusing (live DB untouched)"; return 1
  fi
  _ensure_sqlite_dumper || { error "$svc: cannot validate SQLite candidate (no sqlite-dumper image) — refusing (live DB untouched)"; return 1; }
  # integrity_check reads the entire file, so a truncated-but-header-valid DB fails
  # here; the non-empty .tables check rejects a schemaless/wrong DB. Mount read-only.
  if ! docker run --rm -v "$f:/candidate.db:ro" sqlite-dumper:latest sh -c '
        integ=$(sqlite3 /candidate.db "PRAGMA integrity_check;" 2>&1) || { echo "sqlite3 failed: $integ" >&2; exit 1; }
        [ "$integ" = "ok" ] || { echo "integrity_check failed: $integ" >&2; exit 1; }
        [ -n "$(sqlite3 /candidate.db ".tables" 2>/dev/null)" ] || { echo "no tables (schemaless/wrong DB)" >&2; exit 1; }
      '; then
    error "$svc: $(basename "$f") failed SQLite integrity_check (truncated/corrupt/schemaless) — refusing (live DB untouched)"; return 1
  fi
  return 0
}

# Atomically restore a postgres DB from a plain dump WITHOUT ever leaving the live
# DB empty (#29 Phase 2). The postgres analog of _restore_island_core's temp-file +
# atomic-mv: load the dump into a TEMP database, integrity-gate it, then swap it into
# place with two ALTER DATABASE renames — keeping the prior live DB as a timestamped
# rescue. The old restore_kanbn/outline dropped the live DB FIRST then loaded, so a
# dump that passed validation but errored mid-replay left the DB EMPTY. Here the live
# DB is untouched until a fully-replayed, non-empty candidate exists.
#
# Validated end-to-end against postgres:alpine (cage-match #138 → #29 Phase 2):
# good dump swaps in with the old DB preserved as rescue; a truncated dump fails the
# temp load and the live DB is never touched.
#
# Args: <svc> <container> <pguser> <db> <composedir> <dumpfile>
# Requires the dump to have already passed _validate_pg_dump.
_restore_pg_atomic() {
  local svc="$1" container="$2" user="$3" db="$4" composedir="$5" dumpfile="$6"
  local ts temp rescue
  ts=$(date +%Y%m%d_%H%M%S)
  temp="${db}_restore_${ts}"
  rescue="${db}_rescue_${ts}"

  cd "$composedir" || { error "$svc: cannot cd $composedir"; return 1; }
  docker compose up -d postgres >/dev/null 2>&1 || { error "$svc: postgres failed to start"; return 1; }
  for _ in $(seq 1 30); do docker exec "$container" pg_isready -U "$user" >/dev/null 2>&1 && break; sleep 1; done
  docker exec "$container" pg_isready -U "$user" >/dev/null 2>&1 || { error "$svc: postgres not ready after 30s"; return 1; }

  # 1. Load into a fresh temp DB — live $db untouched. --single-transaction +
  #    ON_ERROR_STOP so a mid-replay error aborts with the temp DB discarded.
  log "$svc: loading dump into temp DB $temp (live $db untouched)..."
  docker exec "$container" psql -U "$user" -d postgres -c "DROP DATABASE IF EXISTS \"$temp\";" >/dev/null 2>&1
  docker exec "$container" psql -v ON_ERROR_STOP=1 -U "$user" -d postgres -c "CREATE DATABASE \"$temp\";" >/dev/null 2>&1 \
    || { error "$svc: could not create temp DB $temp — live $db untouched"; return 1; }
  if ! docker exec -i "$container" psql -v ON_ERROR_STOP=1 --single-transaction -U "$user" -d "$temp" < "$dumpfile" >/dev/null 2>&1; then
    error "$svc: dump failed to replay into temp DB — live $db UNTOUCHED. Dropping temp; investigate the dump before retrying."
    docker exec "$container" psql -U "$user" -d postgres -c "DROP DATABASE IF EXISTS \"$temp\";" >/dev/null 2>&1
    return 1
  fi

  # 2. Integrity gate: the candidate must have loaded at least one public table.
  local ntables
  # `|| true` so a hard docker/psql failure doesn't trip set -e on the assignment
  # (leaving temp undropped) — the numeric guard below treats empty as a failed gate.
  ntables=$(docker exec "$container" psql -U "$user" -d "$temp" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || true)
  # Validate ntables is actually a number before the -ge (a failed docker exec /
  # psql can emit a non-numeric error line, which would make `[ -ge ]` itself
  # error — treat any non-digit result as a failed gate, live untouched).
  if ! [[ "$ntables" =~ ^[0-9]+$ ]] || [ "$ntables" -lt 1 ]; then
    error "$svc: temp DB integrity gate failed (no public tables, or count query errored: '$ntables') — live $db UNTOUCHED. Dropping temp."
    docker exec "$container" psql -U "$user" -d postgres -c "DROP DATABASE IF EXISTS \"$temp\";" >/dev/null 2>&1
    return 1
  fi

  # Small helpers for the swap phase — every step is explicitly checked rather than
  # leaning on `set -e` (cage-match #140 round 2: Carnot/Tesla/Wu all flagged bare
  # set -e commands with no recovery). _pgx runs a psql statement with ON_ERROR_STOP
  # and returns its status; _unfence best-effort re-enables connections on a DB.
  # _pgx runs a CHECKED psql statement (ON_ERROR_STOP) — always used in `if !` so
  # set -e never aborts on it. _unfence + _apprestart are BEST-EFFORT recovery: they
  # end in `|| true` so a failure can never trip set -e and skip the recovery step
  # that follows (cage-match #140 r3, Carnot+Tesla: "best-effort under set -e is a
  # lie"). The critical path is the explicit `if !` checks, not set -e.
  _pgx() { docker exec "$container" psql -v ON_ERROR_STOP=1 -U "$user" -d postgres -c "$1" >/dev/null 2>&1; }
  _unfence() { docker exec "$container" psql -U "$user" -d postgres -c "ALTER DATABASE \"$1\" WITH ALLOW_CONNECTIONS true;" >/dev/null 2>&1 || true; }
  _apprestart() { docker compose up -d >/dev/null 2>&1 || true; }

  # 3. Stop the app so nothing holds a connection to the live DB (ALTER DATABASE
  #    RENAME needs zero connections), then bring ONLY postgres back for the swap.
  #    ASSERT readiness — a not-ready postgres must not proceed to fence/rename.
  log "$svc: stopping app for the atomic swap..."
  docker compose stop >/dev/null 2>&1 || true
  if ! docker compose up -d postgres >/dev/null 2>&1; then
    error "$svc: postgres failed to restart for the swap — live $db UNTOUCHED, temp $temp left. Bringing app back up."
    _apprestart; return 1
  fi
  for _ in $(seq 1 30); do docker exec "$container" pg_isready -U "$user" >/dev/null 2>&1 && break; sleep 1; done
  if ! docker exec "$container" pg_isready -U "$user" >/dev/null 2>&1; then
    error "$svc: postgres not ready after restart — live $db UNTOUCHED, temp $temp left. Bringing app back up."
    _apprestart; return 1
  fi

  # 4. Atomic swap. FENCE connections first (ALLOW_CONNECTIONS false) so an external
  #    client outside this compose project can't reconnect between terminate and
  #    rename — and the fence + terminate are CHECKED (a silent fence failure would
  #    reopen that race: cage-match #140 r2, Carnot+Tesla+Wu). On any failure before
  #    the live rename, live is still $db and UNTOUCHED — un-fence it and restart.
  if ! _pgx "ALTER DATABASE \"$db\" WITH ALLOW_CONNECTIONS false; ALTER DATABASE \"$temp\" WITH ALLOW_CONNECTIONS false;"; then
    error "$svc: could not fence connections — aborting, live $db UNTOUCHED, temp $temp left. Un-fencing + restarting app."
    _unfence "$db"; _apprestart; return 1
  fi
  if ! _pgx "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('$db','$temp') AND pid <> pg_backend_pid();"; then
    error "$svc: could not terminate live connections — aborting, live $db UNTOUCHED, temp $temp left. Un-fencing + restarting app."
    _unfence "$db"; _apprestart; return 1
  fi
  # Rename live->rescue, then temp->live. If the second rename fails, roll rescue
  # back so live is never lost.
  if ! _pgx "ALTER DATABASE \"$db\" RENAME TO \"$rescue\";"; then
    error "$svc: could not rename live $db -> rescue (connections still open?) — live UNTOUCHED, temp $temp left."
    _unfence "$db"; _apprestart; return 1
  fi
  if ! _pgx "ALTER DATABASE \"$temp\" RENAME TO \"$db\";"; then
    error "$svc: rename temp -> live FAILED after live moved to rescue — rolling back rescue -> live."
    if _pgx "ALTER DATABASE \"$rescue\" RENAME TO \"$db\";"; then
      _unfence "$db"
      error "$svc: rolled back — live $db is the original; temp $temp left for inspection."
    else
      error "$svc: ROLLBACK ALSO FAILED — original live is under DB '$rescue' (run: ALTER DATABASE \"$rescue\" RENAME TO \"$db\"; ALTER DATABASE \"$db\" WITH ALLOW_CONNECTIONS true;), candidate under '$temp'. Manual recovery needed; app NOT restarted."
      return 1
    fi
    _apprestart; return 1
  fi

  # 5. Un-fence the new live DB — CHECKED. It inherited ALLOW_CONNECTIONS false from
  #    the temp; if this fails, the app would come up against a DB that refuses
  #    connections (a silent RC=0 false-success — Tesla). Keep the app STOPPED and
  #    error loudly (starting it against a fenced DB just crash-loops — Carnot r3).
  if ! _pgx "ALTER DATABASE \"$db\" WITH ALLOW_CONNECTIONS true;"; then
    error "$svc: swap succeeded but FAILED to re-enable connections on live $db — app kept STOPPED to avoid crash-looping. Run: ALTER DATABASE \"$db\" WITH ALLOW_CONNECTIONS true; then 'docker compose up -d'. Previous live kept as '$rescue'."
    return 1
  fi
  # Re-enable the rescue DB too so operators can inspect it without a manual ALTER
  # (it inherited the fence when it was still the live $db — Carnot :207). Best-effort.
  _unfence "$rescue"

  # Success — previous live kept as $rescue (drop it manually once satisfied). Check
  # the app restart: the data swap already succeeded, so a restart failure is a warn
  # (not a data-loss error), but don't print "complete" as if the service is up.
  if docker compose up -d >/dev/null 2>&1; then
    log "$svc: atomic swap complete. Previous live DB kept as '$rescue' (drop when satisfied). App restarted."
    return 0
  fi
  warn "$svc: atomic swap complete and data is live, but 'docker compose up -d' failed to restart the app — run it manually. Previous live kept as '$rescue'."
  return 0
}

restore_kanbn() {
  log "Restoring Kan.bn..."

  fetch_backups

  # backup.sh stores decompressed SQL for better git deltas
  local BACKUP_FILE="$BACKUP_CLONE_DIR/kanbn.sql"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No kanbn.sql found in backup repo"
    cleanup_backups
    exit 1
  fi
  # Validate the dump, then atomically swap it in via a temp DB (never drops the
  # live DB before a fully-replayed candidate exists — #29 Phase 2). The old code
  # dropped+recreated FIRST then loaded, so a dump that errored mid-replay left the
  # DB empty.
  _validate_pg_dump kanbn "$BACKUP_FILE" || { cleanup_backups; exit 1; }
  _restore_pg_atomic kanbn kanbn_postgres kanbn kanbn ~/apps/kanbn "$BACKUP_FILE" || { cleanup_backups; exit 1; }

  cleanup_backups
  log "Kan.bn restore complete!"
}

restore_outline() {
  log "Restoring Outline..."

  fetch_backups

  local BACKUP_FILE="$BACKUP_CLONE_DIR/outline.sql"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No outline.sql found in backup repo"
    cleanup_backups
    exit 1
  fi
  # Validate + atomic temp-DB swap (see restore_kanbn / _restore_pg_atomic).
  _validate_pg_dump outline "$BACKUP_FILE" || { cleanup_backups; exit 1; }
  _restore_pg_atomic outline outline_postgres outline outline ~/apps/outline "$BACKUP_FILE" || { cleanup_backups; exit 1; }

  cleanup_backups
  log "Outline restore complete!"
}

restore_pm_bot() {
  log "Restoring Dreamfinder..."

  fetch_backups

  local BACKUP_FILE="$BACKUP_CLONE_DIR/pm-bot.db"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No pm-bot.db found in backup repo"
    cleanup_backups
    exit 1
  fi

  # Copy SQLite database into container volume
  log "Restoring database..."
  # Validate before overwriting the live DB: non-empty, exact SQLite header, AND
  # a full PRAGMA integrity_check + non-empty schema (see _validate_sqlite_db). A
  # header-only check would let a truncated-but-header-valid backup clobber the live
  # bot.db — the same content-sentinel the island/matrix paths already enforce.
  _validate_sqlite_db "Dreamfinder restore" "$BACKUP_FILE" || { cleanup_backups; exit 1; }

  # Target /app/data/bot.db — the path the app actually reads and that backup_pm_bot
  # copies FROM. The old kan-bot.db target was a stale pre-rename path, so restore
  # silently wrote a file the app ignores (a no-op restore).
  docker cp "$BACKUP_FILE" dreamfinder:/app/data/bot.db

  log "Restarting Dreamfinder..."
  cd ~/apps/dreamfinder
  docker compose restart

  cleanup_backups
  log "Dreamfinder restore complete!"
}

restore_radicale() {
  log "Restoring Radicale..."

  fetch_backups

  local BACKUP_FILE="$BACKUP_CLONE_DIR/radicale.tar"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No radicale.tar found in backup repo"
    cleanup_backups
    exit 1
  fi

  # Validate the archive BEFORE the destructive rm — a truncated/corrupt tar must
  # not reach `rm -rf /data/collections` (which would leave collections gone with
  # nothing to extract). Two gates, because `tar tf` checks the CARRIER not the
  # PAYLOAD (cage-match #138, Tesla): a well-formed EMPTY tar, or a valid tar of the
  # WRONG tree, lists fine and would still let the rm wipe collections with nothing
  # useful to restore.
  #   1. Readable/complete archive (truncation fails a full listing).
  local radicale_members
  if ! radicale_members=$(tar tf "$BACKUP_FILE" 2>/dev/null); then
    error "Radicale restore: $BACKUP_FILE is not a valid/complete tar — refusing (collections untouched)"
    cleanup_backups; exit 1
  fi
  #   2. Content sentinel: at least one member under data/collections (backup.sh
  #      tars `docker exec radicale tar czf - /data/collections`, so a real archive
  #      lists data/collections[/...]). An empty or wrong-tree tar fails here.
  # Exact directory boundary (`(/|$)`) — a bare prefix would also match a wrong
  # tree like data/collections-old / data/collections.bak, pass, then let the
  # rm wipe the real collections (cage-match #138 round 2, Carnot).
  if ! printf '%s\n' "$radicale_members" | grep -qE '^data/collections(/|$)'; then
    error "Radicale restore: $BACKUP_FILE has no data/collections members (empty/wrong-tree tar) — refusing (collections untouched)"
    cleanup_backups; exit 1
  fi

  # Stop Radicale
  log "Stopping Radicale..."
  cd ~/apps/radicale
  docker compose stop radicale

  # Restore collections into the volume. Content-validated above (readable tar with
  # real collections members), so the rm won't wipe live data with nothing to
  # restore. NOTE: the in-container extract itself is not yet atomic (a mid-extract
  # failure after the rm leaves a partial tree) — stage-to-temp-then-swap is Phase 2.
  log "Restoring collections..."
  docker compose run --rm --entrypoint sh -v "$BACKUP_FILE:/restore.tar:ro" radicale \
    -c "rm -rf /data/collections && tar xf /restore.tar -C /"

  # Start Radicale
  log "Starting Radicale..."
  docker compose up -d

  cleanup_backups
  log "Radicale restore complete!"
}

restore_claudius() {
  log "Restoring Claudius..."

  fetch_backups

  local BACKUP_FILE="$BACKUP_CLONE_DIR/claudius.tar"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No claudius.tar found in backup repo"
    cleanup_backups
    exit 1
  fi

  # Validate the archive before extracting over live state. Extract is additive
  # (no rm), so the blast is lower than radicale — but an empty/wrong-tree tar
  # would still "restore" nothing silently, exactly the no-op class this PR fights.
  # So carrier + payload here too, symmetric with radicale (cage-match #138, Tesla):
  #   1. Readable/complete archive.
  local claudius_members
  if ! claudius_members=$(tar tf "$BACKUP_FILE" 2>/dev/null); then
    error "Claudius restore: $BACKUP_FILE is not a valid/complete tar — refusing"
    cleanup_backups; exit 1
  fi
  #   2. Content sentinel: at least one workspace/ member (backup.sh tars
  #      /workspace/... paths). An empty/wrong-tree tar fails here rather than
  #      extracting nothing and reporting success.
  if ! printf '%s\n' "$claudius_members" | grep -q '^workspace/'; then
    error "Claudius restore: $BACKUP_FILE has no workspace/ members (empty/wrong-tree tar) — refusing"
    cleanup_backups; exit 1
  fi

  # Restore state files into container
  log "Restoring state..."
  docker cp "$BACKUP_FILE" claudius:/tmp/restore.tar
  docker exec claudius sh -c "tar xf /tmp/restore.tar -C / && rm /tmp/restore.tar"

  log "Restarting Claudius..."
  cd ~/apps/claudius
  docker compose restart

  cleanup_backups
  log "Claudius restore complete!"
}

# Core island restore: replace aiko.db in volume $vol from $sql_file, stopping
# then starting container $cid around the swap. NO prompt, NO git fetch — this
# is the unit test-restore-aiko-island.sh drives against a throwaway volume, so
# the CI test exercises the REAL install logic rather than a copy of it. Only
# the gateway container (the one mounting /data) is stopped — the broker/
# registrar never touch aiko.db, so a `docker stop <cid>` is more surgical than
# the old `docker compose stop` (less downtime) and needs no compose dir.
# Returns non-zero on any failure; the live aiko.db is intact in almost all
# failure paths (candidate is validated before the atomic install).
#
# Ordering that matters: validate dump -> stop container -> rescue+install ->
# start container. The dump carries the current schema (email col, nullable
# password_hash, social_identities), so the island's boot schema guard passes
# after restore. aiko_chat_gateway#4 / #1759.
_restore_island_core() {
  local sql_file=$1 cid=$2 vol=$3

  # Validate the dump BEFORE touching anything: present, non-empty, and complete
  # (a COMPLETE sqlite .dump ends with COMMIT;). The island DB is the SOLE copy
  # of auth+messages+ACL, so a bad dump must never reach the destructive path.
  if [ ! -s "$sql_file" ]; then
    error "No (non-empty) dump at $sql_file"; return 1
  fi
  # End-anchored completeness check (see backup.sh): the LAST non-blank line of a
  # complete sqlite .dump is exactly `COMMIT;`. A whole-file grep could be fooled
  # by `COMMIT;` embedded in multiline data, accepting a truncated dump.
  if [ "$(grep -ve '^[[:space:]]*$' "$sql_file" | tail -n1)" != "COMMIT;" ]; then
    error "dump looks truncated/invalid (last line is not COMMIT;)"; return 1
  fi

  # The island image ships no sqlite3; build the tiny alpine+sqlite helper if
  # absent (shared _ensure_sqlite_dumper, also used by _validate_sqlite_db) so
  # restore works on a box where the backup path has never run.
  _ensure_sqlite_dumper || return 1

  log "Stopping island container $cid..."
  docker stop "$cid" >/dev/null || { error "failed to stop container $cid"; return 1; }

  # Build + validate the candidate in a TEMP file, and only swap it in on
  # success — the live aiko.db is untouched until a valid replacement exists.
  # The old DB is kept as a timestamped rescue copy inside the volume.
  local rescue
  rescue="aiko.db.rescue-$(date +%Y%m%d-%H%M%S)"
  log "Building + validating candidate DB (live DB untouched until it passes)..."
  if ! docker run --rm -i -v "${vol}:/data" sqlite-dumper:latest sh -c '
        set -e
        rm -f /data/aiko.db.restore /data/aiko.db.restore-wal /data/aiko.db.restore-shm
        sqlite3 -bail /data/aiko.db.restore  # replay dump; -bail: exit non-zero on first SQL error
        integ=$(sqlite3 /data/aiko.db.restore "PRAGMA integrity_check;")
        [ "$integ" = "ok" ] || { echo "integrity_check failed: $integ" >&2; exit 1; }
        sqlite3 /data/aiko.db.restore ".tables" | grep -qw users || { echo "no users table in restored DB" >&2; exit 1; }
        rescue="'"$rescue"'"
        # 1. Rescue the COMPLETE old state (db + any WAL/SHM) by full file copy —
        #    no checkpoint dependency, so the rescue is faithful even if the old
        #    DB is too corrupt to checkpoint. Every copy is FATAL under set -e
        #    (the `if` guards make ABSENCE non-fatal without masking cp failure):
        #    we never clobber the sole DB unless a complete copy exists first.
        if [ -f /data/aiko.db ]; then
          cp -p /data/aiko.db "/data/$rescue"
          if [ -f /data/aiko.db-wal ]; then cp -p /data/aiko.db-wal "/data/$rescue-wal"; fi
          if [ -f /data/aiko.db-shm ]; then cp -p /data/aiko.db-shm "/data/$rescue-shm"; fi
        fi
        # 2. Remove the old sidecars BEFORE installing the new DB (they are now
        #    rescued). Ordering matters: a fresh-from-.dump DB must never sit
        #    beside a stale, salt-mismatched WAL (SQLite corruption). Doing this
        #    before the install means there is never a new-db + stale-wal window.
        rm -f /data/aiko.db-wal /data/aiko.db-shm
        # 3. Atomic install LAST: a single rename, always old-or-new, never
        #    neither. If it fails, the live aiko.db is still the old one.
        mv -f /data/aiko.db.restore /data/aiko.db
      ' < "$sql_file"; then
    error "aiko-island restore FAILED. The candidate was rejected before the final install in almost all cases, so the live aiko.db is the original; a complete rescue copy (aiko.db.rescue-*) is also in the volume. Inspect the volume before retrying. Restarting on the current DB."
    docker start "$cid" >/dev/null || error "ALSO failed to restart $cid — island is DOWN, start it manually"
    return 1
  fi

  log "Restored OK (previous DB kept in the volume as $rescue). Restarting island..."
  docker start "$cid" >/dev/null || { error "restore installed but restart of $cid FAILED — island is DOWN, start it manually"; return 1; }
}

# Restore the aiko-chat-island SQLite store from the latest .sql dump in the
# backup repo. Wraps _restore_island_core with: fetch-from-backup-repo, live
# volume/container AUTO-DETECT (never a hardcoded ghost name — #1759), and a
# typed-consent gate (irreversible: replaces the sole auth+message store).
restore_aiko_island() {
  log "Restoring aiko-chat-island..."

  fetch_backups
  local sql_file="$BACKUP_CLONE_DIR/aiko-island.sql"
  if [ ! -s "$sql_file" ]; then
    error "No (non-empty) aiko-island.sql in backup repo"; cleanup_backups; exit 1
  fi

  # Auto-detect the LIVE volume + container BEFORE the destructive confirm, so a
  # missing/renamed target fails early — and so restore writes into the SAME
  # volume the live island reads, not the orphaned pre-cutover ghost the old
  # hardcoded name pointed at (#1759).
  local gw_cid gw_vol
  gw_cid=$(aiko_island_container) || { cleanup_backups; exit 1; }
  gw_vol=$(aiko_island_volume "$gw_cid") || { cleanup_backups; exit 1; }

  # Irreversible: replacing the sole auth+message store. Require typed consent,
  # and show the resolved target so the operator can eyeball the volume.
  echo "WARNING: this REPLACES the island's SOLE database (all accounts + messages + ACL)."
  echo "  dump:   $sql_file ($(wc -l < "$sql_file") lines, $(du -h "$sql_file" | cut -f1))"
  echo "  target: volume $gw_vol (live container $gw_cid)"
  read -r -p "Type 'restore aiko-island' to proceed: " confirm
  if [ "$confirm" != "restore aiko-island" ]; then
    error "Aborted (no confirmation)"; cleanup_backups; exit 1
  fi

  if ! _restore_island_core "$sql_file" "$gw_cid" "$gw_vol"; then
    cleanup_backups; exit 1
  fi

  cleanup_backups
  log "aiko-island restore complete!"
}

# Restore matrix bridges + relay-bot SQLite DBs from latest SQL dumps in the
# backup repo. Each .sql file is replayed against a fresh SQLite DB inside
# the bridge's volume. Bridges must be stopped before the replay (writing
# to a live DB while replaying would corrupt it). The continuwuity homeserver
# is NOT backed up or restored (its signing key is saved separately — 2026-08-02).
restore_matrix() {
  log "Restoring matrix bridges + relay-bots..."

  fetch_backups

  local entries=(
    "matrix-discord:matrix_discord_data:discord.db"
    "matrix-signal:matrix_signal_data:signal.db"
    "matrix-telegram:matrix_telegram_data:mautrix-telegram.db"
    "matrix-whatsapp:matrix_whatsapp_data:whatsapp.db"
    "matrix-relay:matrix_relay_data:relay.db"
    "matrix-relay-hf:matrix_relay_hf_data:relay.db"
  )

  # Build the sqlite helper if absent — restore may run on a box where the backup
  # path (which builds it) has never executed. Shared _ensure_sqlite_dumper, same
  # as island/pm_bot (cage-match #138 round 2, Kelvin: was an inline copy).
  _ensure_sqlite_dumper || { cleanup_backups; return 1; }

  # Stop the matrix stack first so we don't write to live DBs.
  log "Stopping matrix stack..."
  cd ~/apps/matrix || { error "cannot cd ~/apps/matrix"; cleanup_backups; return 1; }
  docker compose stop

  local any_failed=0 skipped=0 skipped_names=""
  for entry in "${entries[@]}"; do
    IFS=: read -r name volume dbfile <<< "$entry"
    local sql_file="$BACKUP_CLONE_DIR/${name}.sql"
    if [ ! -f "$sql_file" ]; then
      # Missing dump: skip, but track it — a silent skip under a "complete!"
      # banner is a cousin of the old |continue bug (some bridges never touched
      # while the run reports success). Surface it loudly at the end.
      warn "No ${name}.sql found in backup repo, skipping"
      skipped=$((skipped+1)); skipped_names="$skipped_names $name"
      continue
    fi

    # Validate the dump BEFORE the destructive path. The OLD code rm'd the live
    # DB then replayed with a non-fatal `|| error`, so a truncated/empty dump
    # wiped a bridge DB while the run still logged success. Now a bad dump is
    # refused and the live DB is left intact. End-anchored COMMIT; check (not
    # `grep '^COMMIT;'`): app data can embed a COMMIT;-prefixed line.
    if [ ! -s "$sql_file" ]; then
      error "$name: dump $(basename "$sql_file") is empty — skipping (live DB untouched)"
      any_failed=1; continue
    fi
    if [ "$(grep -ve '^[[:space:]]*$' "$sql_file" | tail -n1)" != "COMMIT;" ]; then
      error "$name: dump looks truncated/invalid (last line not COMMIT;) — skipping (live DB untouched)"
      any_failed=1; continue
    fi
    # Reject a schemaless dump (valid COMMIT; but no tables — an empty/wrong DB):
    # PRAGMA integrity_check returns ok on an empty DB, so without this the empty
    # candidate would atomically replace a live bridge (Carnot's catch).
    if ! grep -q 'CREATE TABLE' "$sql_file"; then
      error "$name: dump has no CREATE TABLE (empty/wrong DB) — skipping (live DB untouched)"
      any_failed=1; continue
    fi

    log "  Restoring $name (build candidate -> integrity_check -> atomic install)..."
    # Build + validate the replacement in a TEMP file inside the volume; only
    # swap it in on success. Rescue the old DB (+WAL/SHM) by full copy first, so
    # the live $dbfile is never destroyed unless a valid replacement exists.
    # Mirrors _restore_island_core (minus the island-only users-table check —
    # bridge schemas differ, so PRAGMA integrity_check is the generic gate).
    local rescue; rescue="${dbfile}.rescue-$(date +%Y%m%d-%H%M%S)"
    if ! docker run --rm -i -v "${volume}:/data" sqlite-dumper:latest sh -c '
          set -e
          dbfile="'"$dbfile"'"; rescue="'"$rescue"'"
          rm -f "/data/$dbfile.restore" "/data/$dbfile.restore-wal" "/data/$dbfile.restore-shm"
          sqlite3 -bail "/data/$dbfile.restore"      # replay dump; -bail: exit non-zero on first SQL error
          integ=$(sqlite3 "/data/$dbfile.restore" "PRAGMA integrity_check;")
          [ "$integ" = "ok" ] || { echo "integrity_check failed: $integ" >&2; exit 1; }
          # Rescue the COMPLETE old state (db + WAL/SHM) by full copy before
          # touching it; cp failure is fatal under set -e, absence is not.
          if [ -f "/data/$dbfile" ]; then
            cp -p "/data/$dbfile" "/data/$rescue"
            if [ -f "/data/$dbfile-wal" ]; then cp -p "/data/$dbfile-wal" "/data/$rescue-wal"; fi
            if [ -f "/data/$dbfile-shm" ]; then cp -p "/data/$dbfile-shm" "/data/$rescue-shm"; fi
          fi
          # Remove stale sidecars BEFORE install so a fresh-from-.dump DB never
          # sits beside a salt-mismatched WAL (SQLite corruption).
          rm -f "/data/$dbfile-wal" "/data/$dbfile-shm"
          # Atomic install LAST: single rename, always old-or-new, never neither.
          mv -f "/data/$dbfile.restore" "/data/$dbfile"
        ' < "$sql_file"; then
      error "Restore FAILED for $name — the candidate was rejected or the install aborted. In the common case (bad dump / integrity_check fail) the failure is BEFORE any destructive step and live $dbfile is untouched; if it aborted mid-swap, the prior DB (+WAL/SHM) is preserved as $dbfile.rescue-* in the volume. Inspect the volume before retrying. Continuing with other bridges."
      any_failed=1; continue
    fi
    log "  $name restored OK (previous DB kept as $dbfile.rescue-* in the volume)"
  done

  log "Restarting matrix stack..."
  docker compose up -d

  cleanup_backups
  if [ "$any_failed" -eq 1 ]; then
    error "Matrix restore finished with errors (see above); failed/empty bridges were skipped with their live DBs intact"
    return 1
  fi
  if [ "$skipped" -gt 0 ]; then
    warn "Matrix restore complete for the bridges that had dumps, but ${skipped} had NO dump in the repo and were left untouched:${skipped_names}. This is an INCOMPLETE restore — confirm that's intended (fresh bridges) and not a partial/wrong backup clone."
    return 0
  fi
  log "Matrix restore complete!"
}

# Continuwuity restore constants. The image is the exact prod version so the
# validate-boot exercises the real RocksDB (no ldb version-skew).
MATRIX_COMPOSE_DIR="${MATRIX_COMPOSE_DIR:-$HOME/apps/matrix}"

# When sourced by the test harness (RESTORE_LIB_ONLY=1), stop here: expose the
# functions (_restore_island_core + the aiko_island_* lib) without running the
# dispatch, which would otherwise demand a $SERVICE arg. `return` is valid only
# because this branch is reached solely via `source`; a direct run never sets
# RESTORE_LIB_ONLY, so it falls through to the dispatch below.
if [ "${RESTORE_LIB_ONLY:-0}" = "1" ]; then
  # `return` when sourced, `exit` when executed directly — mechanical, not by
  # convention, so `RESTORE_LIB_ONLY=1 ./restore.sh` doesn't emit bash's
  # "can only return from a function or sourced script" error.
  return 0 2>/dev/null || exit 0
fi

# Deferred from the top of the file so the harness can source cleanly.
if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service>"
  echo "  service: kanbn, outline, radicale, pm-bot, claudius, aiko-island, matrix"
  echo ""
  echo "Examples:"
  echo "  $0 kanbn         # Restore latest from GitHub backup"
  echo "  $0 outline       # Restore latest from GitHub backup"
  echo "  $0 matrix        # Restore all matrix bridges + relay-bots"
  exit 1
fi

mkdir -p "$RESTORE_DIR"

# Run restore
case $SERVICE in
  kanbn)
    restore_kanbn
    ;;
  outline)
    restore_outline
    ;;
  radicale)
    restore_radicale
    ;;
  pm-bot)
    restore_pm_bot
    ;;
  claudius)
    restore_claudius
    ;;
  aiko-island)
    restore_aiko_island
    ;;
  matrix)
    restore_matrix
    ;;
  *)
    error "Unknown service: $SERVICE"
    echo "Valid services: kanbn, outline, radicale, pm-bot, claudius, aiko-island, matrix"
    exit 1
    ;;
esac
