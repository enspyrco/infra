#!/bin/bash
# Unified backup script for all services
# Dumps databases/data, pushes to GitHub (imagineering-cc/imagineering-backups)
# Usage: ./backup.sh [all|kanbn|outline|radicale|pm-bot|claudius|aiko-island|matrix|continuwuity]
#
# NOTE: downstream-server's DB backup moved to the downstream repo
# (nickmeinhold/downstream deploy/oci/scripts/backup-downstream.sh, cron
# 03:45) in the #291 Phase B ops-move — no longer backed up here.

SERVICE=${1:-all}
BACKUP_DIR="/tmp/backups"
DATE=$(date +%Y-%m-%d)
RETENTION_DAYS=7
FAILED_SERVICES=()

# GitHub backup config
GITHUB_BACKUP_REPO="git@github-imagineering-backups:imagineering-cc/imagineering-backups.git"
GITHUB_BACKUP_DIR="/tmp/imagineering-backups"
GITHUB_REPO_SIZE_ALERT_MB=500

# Continuwuity backup config. AGE_RECIPIENT and MATRIX_ADMIN_TOKEN are
# sourced at runtime from MATRIX_ADMIN_SECRETS_FILE (see backup_continuwuity).
# Decryption: `age -d -i <key> continuwuity.tar.gz.age | tar xzf -`.
MATRIX_ADMIN_SECRETS_FILE="/etc/imagineering-secrets/matrix.env"
CONTINUWUITY_ADMIN_ROOM='!L8ZmuakjgpeL1P3Jl8:imagineering.cc'
CONTINUWUITY_HOMESERVER='https://matrix.imagineering.cc'
# Continuwuity tarballs are large + opaque to git deltas. When the repo
# exceeds this size, prune_repo_history_if_needed collapses history to a
# fresh root commit (loses non-essential git history; keeps current files).
RETENTION_PRUNE_THRESHOLD_MB=300
# Keep only the newest N archive-* tags. Each prune pins the pre-prune HEAD in an
# archive-DATE tag; the ~100MB encrypted (undeltable) continuwuity blob it holds is
# a fresh object GitHub keeps forever while the tag references it. Unbounded, that
# was 45 tags / 4.37GB (2026-07-30). Capping retention keeps a rolling PITR window
# without the runaway growth. Structural fix (object storage) tracked separately.
ARCHIVE_TAG_RETENTION=${ARCHIVE_TAG_RETENTION:-7}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log() {
  echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
  echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

# Source shared Telegram helper (defines send_telegram_alert + loads creds
# from /etc/imagineering-secrets/telegram.env at deploy targets).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/telegram.sh
. "$SCRIPT_DIR/lib/telegram.sh"
# Live island volume/container discovery — single home for the invariant so
# backup and restore can't drift apart (aiko_chat_gateway#1759).
# shellcheck source=lib/aiko-volume.sh
. "$SCRIPT_DIR/lib/aiko-volume.sh"

check_repo_size() {
  if [ ! -d "$GITHUB_BACKUP_DIR" ]; then
    return 0
  fi
  local size_mb
  size_mb=$(du -sm "$GITHUB_BACKUP_DIR" --exclude='.git' 2>/dev/null | awk '{print $1}')
  if [ -z "$size_mb" ]; then
    return 0
  fi
  if [ "$size_mb" -gt "$GITHUB_REPO_SIZE_ALERT_MB" ]; then
    log "GitHub backup payload is ${size_mb} MB (threshold: ${GITHUB_REPO_SIZE_ALERT_MB} MB)"
    send_telegram_alert "$(printf '<b>Backup Size Alert</b>\nGitHub backup payload: %s MB (threshold: %s MB)\nConsider pruning old data or increasing the threshold.' "$size_mb" "$GITHUB_REPO_SIZE_ALERT_MB")"
  fi
}

# Create backup directory
mkdir -p "$BACKUP_DIR"

backup_kanbn() {
  log "Backing up Kan.bn..."

  local tmp="$BACKUP_DIR/kanbn-$DATE.sql"
  local err="$BACKUP_DIR/kanbn-$DATE.err"
  local out="$BACKUP_DIR/kanbn-$DATE.sql.gz"

  # Dump to a plain .sql first so pg_dump's REAL exit is seen — piping straight
  # to gzip masks it behind gzip's status, silently committing a truncated/empty
  # backup over the good one. Then require pg_dump's end-marker before gzip.
  if ! docker exec kanbn_postgres pg_dump -U kanbn kanbn > "$tmp" 2>"$err"; then
    error "Kan.bn pg_dump failed: $(tr '\n' ' ' < "$err")"
    rm -f "$tmp" "$err"; return 1
  fi
  # A COMPLETE pg_dump plain-text dump ends with the EXACT line
  # '-- PostgreSQL database dump complete'. Anchor on the whole line (grep -qxF),
  # not a loose substring, so a data row near EOF can't fake completeness after a
  # truncation (same end-anchoring discipline as the sqlite COMMIT; check).
  if ! tail -n5 "$tmp" | grep -qxF -- '-- PostgreSQL database dump complete'; then
    error "Kan.bn dump incomplete (no completion marker — truncated/empty)"
    rm -f "$tmp" "$err"; return 1
  fi
  rm -f "$err"
  # Check gzip's own exit — a failed compress (ENOSPC/SIGKILL) must not leave the
  # function logging success with a missing/partial .gz (pipe-masks-exit reborn).
  if ! gzip -f "$tmp"; then error "Kan.bn gzip failed (disk full?)"; rm -f "$tmp" "$out"; return 1; fi
  log "Kan.bn backup complete: $(basename "$out") ($(du -h "$out" | cut -f1))"
}

backup_pm_bot() {
  log "Backing up Dreamfinder..."

  local backup_file="$BACKUP_DIR/pm-bot-$DATE.db"

  # Copy SQLite database from container volume.
  # Path is /app/data/bot.db (was kan-bot.db from an earlier rename;
  # docker cp silently produces an empty/wrong file on path mismatch
  # which is why this bug went undetected — fail loudly instead).
  if ! docker cp dreamfinder:/app/data/bot.db "$backup_file"; then
    error "Dreamfinder docker cp failed — backup file is incomplete or missing"
    rm -f "$backup_file"
    return 1
  fi

  log "Dreamfinder backup complete: pm-bot-$DATE.db"
}

backup_outline() {
  log "Backing up Outline..."

  local tmp="$BACKUP_DIR/outline-$DATE.sql"
  local err="$BACKUP_DIR/outline-$DATE.err"
  local out="$BACKUP_DIR/outline-$DATE.sql.gz"

  # Plain .sql first (see backup_kanbn) so pg_dump's exit isn't masked by gzip,
  # then require the completion marker before gzip.
  if ! docker exec outline_postgres pg_dump -U outline outline > "$tmp" 2>"$err"; then
    error "Outline pg_dump failed: $(tr '\n' ' ' < "$err")"
    rm -f "$tmp" "$err"; return 1
  fi
  if ! tail -n5 "$tmp" | grep -qxF -- '-- PostgreSQL database dump complete'; then
    error "Outline dump incomplete (no completion marker — truncated/empty)"
    rm -f "$tmp" "$err"; return 1
  fi
  rm -f "$err"
  if ! gzip -f "$tmp"; then error "Outline gzip failed (disk full?)"; rm -f "$tmp" "$out"; return 1; fi
  log "Outline backup complete: $(basename "$out") ($(du -h "$out" | cut -f1))"
}

backup_radicale() {
  log "Backing up Radicale..."

  local out="$BACKUP_DIR/radicale-$DATE.tar.gz"

  # Tar the collections from the Docker volume. The old code ignored tar's exit
  # AND never checked the artifact, so a failed/partial tar committed silently.
  if ! docker exec radicale tar czf - /data/collections > "$out" 2>/dev/null; then
    error "Radicale tar failed"; rm -f "$out"; return 1
  fi
  # Verify the archive is a readable, complete gzip'd tar (a truncated .tar.gz
  # fails to list); catches a corrupt/partial write before it's committed.
  if ! tar tzf "$out" >/dev/null 2>&1; then
    error "Radicale backup is not a valid tar.gz (truncated/empty)"; rm -f "$out"; return 1
  fi
  log "Radicale backup complete: $(basename "$out") ($(du -h "$out" | cut -f1))"
}

backup_claudius() {
  log "Backing up Claudius..."

  local out="$BACKUP_DIR/claudius-$DATE.tar.gz"

  # Some of these files may not exist yet; tar warns and exits non-zero but still
  # archives whatever IS present — so we deliberately do NOT gate on tar's exit.
  # Instead we validate the RESULT is a readable, non-empty tar.gz, which catches
  # a truncated/corrupt write (the actual silent-loss risk) without failing the
  # legitimate "some optional state files absent" case.
  docker exec claudius tar czf - \
    /workspace/logs/agent-state.json \
    /workspace/logs/persona-evolution.md \
    /workspace/logs/conversation.log \
    /workspace/logs/playwright-storage.json \
    /workspace/logs/initiative-state.json \
    2>/dev/null > "$out" || true
  if [ ! -s "$out" ] || ! tar tzf "$out" >/dev/null 2>&1; then
    error "Claudius backup is not a valid/non-empty tar.gz"; rm -f "$out"; return 1
  fi
  log "Claudius backup complete: $(basename "$out") ($(du -h "$out" | cut -f1))"
}

# Dumps each mautrix bridge's SQLite DB + both relay-bots' DBs to .sql.gz.
# The bridge container images don't ship sqlite3, so we mount each volume
# read-only into an ephemeral alpine container that installs sqlite3 on the
# fly. Using `.dump` (text SQL) instead of `.backup` (binary checkpoint) so
# the resulting files diff cleanly in git — same pattern as Kan.bn/Outline.
backup_matrix() {
  log "Backing up matrix bridges + relay-bots..."

  # (svc_name, docker_volume, db_filename) — adjust if new bridges added.
  local entries=(
    "matrix-discord:matrix_discord_data:discord.db"
    "matrix-signal:matrix_signal_data:signal.db"
    "matrix-telegram:matrix_telegram_data:mautrix-telegram.db"
    "matrix-whatsapp:matrix_whatsapp_data:whatsapp.db"
    "matrix-relay:matrix_relay_data:relay.db"
    "matrix-relay-hf:matrix_relay_hf_data:relay.db"
  )

  local any_failed=0
  for entry in "${entries[@]}"; do
    IFS=: read -r name volume dbfile <<< "$entry"
    local tmp="$BACKUP_DIR/${name}-$DATE.sql"
    local err="$BACKUP_DIR/${name}-$DATE.err"
    local out="$BACKUP_DIR/${name}-$DATE.sql.gz"

    # Dump to a PLAIN .sql first (no pipe) so sqlite3's REAL exit is seen —
    # piping straight to gzip would mask a sqlite3 failure behind gzip's exit
    # status, and a gzip of empty input is still a non-empty container so an
    # `-s` size check on the .gz lies (it "passes" for a zero-row dump). Mount
    # the volume read-only (online-safe snapshot) and capture stderr so a
    # WAL-locked/failed read reports loudly. Mirrors backup_aiko_island.
    if ! docker run --rm -v "${volume}:/data:ro" sqlite-dumper:latest \
         sqlite3 -cmd '.timeout 5000' "/data/${dbfile}" .dump > "$tmp" 2>"$err"; then
      error "${name} sqlite3 .dump failed: $(tr '\n' ' ' < "$err")"
      rm -f "$tmp" "$err"
      any_failed=1
      continue
    fi
    # A COMPLETE .dump's LAST non-blank line is exactly `COMMIT;`. Check the
    # tail end-anchored (not `grep '^COMMIT;'`): application data can embed a
    # multiline string whose line starts `COMMIT;` and fool a whole-file grep
    # into accepting a truncated dump. A silent empty/truncated backup is worse
    # than none — restore would replay it over a live bridge DB.
    local lastline
    lastline=$(grep -ve '^[[:space:]]*$' "$tmp" | tail -n1)
    if [ "$lastline" != "COMMIT;" ]; then
      error "${name} dump invalid (last line '$lastline', not COMMIT; — empty/truncated): $(tr '\n' ' ' < "$err")"
      rm -f "$tmp" "$err"
      any_failed=1
      continue
    fi
    # Reject a structurally-valid but SCHEMALESS dump — `.dump` of an empty or
    # wrong DB (opened fresh) ends in COMMIT; with no tables. A real bridge DB
    # always emits CREATE TABLE; its absence means we'd back up an empty DB that
    # restore would then replay over a live bridge (the silent-loss class moved
    # from truncation to wrong/empty-DB — Carnot's catch).
    if ! grep -q 'CREATE TABLE' "$tmp"; then
      error "${name} dump has no CREATE TABLE (empty/wrong DB) — refusing"
      rm -f "$tmp" "$err"
      any_failed=1
      continue
    fi
    rm -f "$err"
    if ! gzip -f "$tmp"; then
      error "${name} gzip failed (disk full?)"; rm -f "$tmp" "$out"; any_failed=1; continue
    fi
    log "  ${name} → $(basename "$out") ($(du -h "$out" | cut -f1))"
  done

  if [ "$any_failed" -eq 1 ]; then
    return 1
  fi
  log "Matrix backup complete"
}

# aiko-chat-island: the island's local SQLite store is the SOLE copy of message
# history + auth credentials + the ACL/membership overlay. Per the #1281
# HyperSpace-source-of-truth redesign, HyperSpace holds only channel/user
# EXISTENCE; everything else lives in this one file on the named volume. A
# `docker volume rm` or host disk loss would vaporize every account with no
# second copy (aiko_chat_gateway#4). The gateway image ships no sqlite3, so —
# like the matrix bridges — mount the volume read-only into sqlite-dumper and
# `.dump` to text SQL (git-diffable). Online-safe: `.dump` reads a consistent
# snapshot; the read-only mount can't perturb the live DB.
backup_aiko_island() {
  log "Backing up aiko-chat-island..."

  local tmp="$BACKUP_DIR/aiko-island-$DATE.sql"
  local err="$BACKUP_DIR/aiko-island-$DATE.err"
  local out="$BACKUP_DIR/aiko-island-$DATE.sql.gz"

  # Dump to a PLAIN .sql first (no pipe) so sqlite3's REAL exit is seen — piping
  # to gzip would mask it behind gzip's status (and a gzip of empty input is
  # still a non-empty container, so an `-s` size check on the .gz lies). Capture
  # stderr for the error message (a WAL-locked read fails loudly, not silently).
  # Derive the live island volume from the RUNNING container rather than
  # hardcoding it (see lib/aiko-volume.sh for the full ghost-volume history).
  # Auto-detect follows the island cutover automatically and works on BOTH
  # islands regardless of cutover state (Melbourne still runs the pre-cutover
  # volume name).
  local gw_cid gw_vol
  gw_cid=$(aiko_island_container) || return 1
  gw_vol=$(aiko_island_volume "$gw_cid") || return 1
  log "  live island volume: $gw_vol (container $gw_cid)"

  if ! docker run --rm -v "${gw_vol}:/data:ro" sqlite-dumper:latest \
       sqlite3 -cmd '.timeout 5000' /data/aiko.db .dump > "$tmp" 2>"$err"; then
    error "aiko-island sqlite3 .dump failed: $(tr '\n' ' ' < "$err")"
    rm -f "$tmp" "$err"
    return 1
  fi
  # A COMPLETE .dump's LAST non-blank line is exactly `COMMIT;`. Check the tail
  # (end-anchored), not `grep '^COMMIT;'` — application data can contain a
  # multiline string literal whose embedded line starts with `COMMIT;` and would
  # fool a whole-file grep into accepting a truncated dump. An empty/truncated
  # backup is worse than none here: restore would replay it over the sole live DB.
  local lastline
  lastline=$(grep -ve '^[[:space:]]*$' "$tmp" | tail -n1)
  if [ "$lastline" != "COMMIT;" ]; then
    error "aiko-island dump invalid (last line '$lastline', not COMMIT; — empty/truncated): $(tr '\n' ' ' < "$err")"
    rm -f "$tmp" "$err"
    return 1
  fi
  # Schemaless-dump gate (same as backup_matrix, and MORE important here): the
  # island DB is the SOLE copy, so a `.dump` of an empty/wrong volume ending in
  # COMMIT; with no tables must not overwrite yesterday's good backup in the repo.
  if ! grep -q 'CREATE TABLE' "$tmp"; then
    error "aiko-island dump has no CREATE TABLE (empty/wrong DB) — refusing"
    rm -f "$tmp" "$err"
    return 1
  fi
  rm -f "$err"
  if ! gzip -f "$tmp"; then error "aiko-island gzip failed (disk full?)"; rm -f "$tmp" "$out"; return 1; fi
  log "aiko-island backup complete: $(basename "$out") ($(du -h "$out" | cut -f1))"
}

# Triggers Continuwuity's online RocksDB checkpoint via the admin API
# (`!admin server backup-database`). Each run wipes the in-volume backup
# dir first, then triggers the admin command which writes a fresh
# checkpoint, then tars+age-encrypts the output. RocksDB BackupEngine
# uses hardlinks back to the live SST files so the operation is fast
# and online — Continuwuity stays available throughout. Encryption is
# critical: this tarball contains the homeserver signing keys
# (irreplaceable identity).
backup_continuwuity() {
  log "Backing up Continuwuity..."

  if ! command -v age &>/dev/null; then
    error "age not installed; run apt-get install -y age"
    return 1
  fi
  if [ ! -f "$MATRIX_ADMIN_SECRETS_FILE" ]; then
    error "Matrix admin secrets file missing at $MATRIX_ADMIN_SECRETS_FILE"
    return 1
  fi
  # Source secrets file FIRST so MATRIX_ADMIN_TOKEN and AGE_RECIPIENT are
  # populated before the checks below.
  # shellcheck source=/dev/null
  . "$MATRIX_ADMIN_SECRETS_FILE"
  if [ -z "${MATRIX_ADMIN_TOKEN:-}" ]; then
    error "MATRIX_ADMIN_TOKEN not set in $MATRIX_ADMIN_SECRETS_FILE"
    return 1
  fi
  if [ -z "${AGE_RECIPIENT:-}" ]; then
    error "AGE_RECIPIENT not set; refusing to back up signing keys in plaintext"
    return 1
  fi

  local backup_volume="matrix_continuwuity_backups"
  local out="$BACKUP_DIR/continuwuity-$DATE.tar.gz.age"

  # Continuwuity uses RocksDB's BackupEngine (not Checkpoint API). Each
  # call adds an incremental backup into the same directory (meta/,
  # private/, shared_checksum/). If left alone, the dir grows over time as
  # incrementals accumulate — meaning each daily tarball grows too.
  #
  # We wipe the dir before each run so every tarball is a fresh, complete
  # snapshot of constant size (~equal to a single full RocksDB backup,
  # which for our scale is ~50MB encrypted). Safe because shared_checksum/
  # only holds hardlinks back to the live data dir's SST files — deleting
  # the hardlinks doesn't touch the live database.

  # 1. Wipe previous backup contents so this run produces a clean snapshot.
  log "  Wiping previous backup contents..."
  docker run --rm -v "${backup_volume}:/data" alpine \
    sh -c "rm -rf /data/* /data/.* 2>/dev/null; true" >/dev/null 2>&1 || true

  # 2. Trigger the online backup via the admin room.
  local txn; txn=$(date +%s%N)
  local trigger_resp
  trigger_resp=$(curl -sf -X PUT \
    -H "Authorization: Bearer $MATRIX_ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    "$CONTINUWUITY_HOMESERVER/_matrix/client/v3/rooms/$CONTINUWUITY_ADMIN_ROOM/send/m.room.message/$txn" \
    -d '{"msgtype":"m.text","body":"!admin server backup-database"}' 2>&1) || {
    error "Failed to send backup-database admin command: $trigger_resp"
    return 1
  }

  # 3. Wait for the backup to appear (meta/ subdir gets created when
  # BackupEngine writes its first backup). 5 min cap is generous for
  # multi-GB databases; typical completion is <10s.
  local meta_exists=0
  for _ in $(seq 1 60); do
    sleep 5
    if docker run --rm -v "${backup_volume}:/data:ro" alpine \
         test -d /data/meta 2>/dev/null; then
      meta_exists=1
      break
    fi
  done
  if [ "$meta_exists" -ne 1 ]; then
    error "Continuwuity backup did not complete within 5 minutes (meta/ never appeared)"
    return 1
  fi
  log "  Backup completed"

  # 4. Tar the whole backups dir through age encryption. Alpine ships
  # busybox tar (not GNU), so we avoid GNU-specific flags. The dir is
  # static at this point (we just produced a fresh snapshot and won't
  # call backup-database again until tomorrow), so no concurrent-write
  # concerns.
  # pipefail in a subshell so tar's failure propagates instead of being masked by
  # age's exit (the pipe-masks-exit class — critical here: this tarball holds the
  # homeserver SIGNING KEYS, so a silent-empty backup is unrecoverable identity loss).
  if ! ( set -o pipefail; docker run --rm -v "${backup_volume}:/data:ro" alpine \
       tar czf - -C /data . 2>/dev/null \
       | age -r "$AGE_RECIPIENT" > "$out" ); then
    error "Continuwuity tar/encrypt failed"
    rm -f "$out"
    return 1
  fi
  # Non-empty floor: age of a failed/empty tar can still write a tiny valid-looking
  # ciphertext; refuse it rather than commit an unrestorable signing-key backup.
  # (Completeness beyond non-empty — meta/ race, BackupEngine layout, min-size
  # floor — is deferred to #29.)
  if [ ! -s "$out" ]; then
    error "Continuwuity encrypted tarball is empty — refusing"
    rm -f "$out"
    return 1
  fi

  log "Continuwuity backup complete: $(basename "$out") ($(du -h "$out" | cut -f1))"
}

# Repo size management. Continuwuity tarballs are encrypted opaque binary
# blobs — git cannot delta them, so each daily commit grows the .git pack
# by roughly the tarball size. Rather than try to surgically remove old
# blobs from history (filter-repo with date-conditional callbacks is
# fragile across versions), we collapse the entire repo to a fresh root
# commit when total size exceeds RETENTION_PRUNE_THRESHOLD_MB.
#
# What we lose: git diff history for the bridge SQL files. What we keep:
# every current file (latest backups for all services). For a backup repo
# this is the right trade — history is decorative; the latest state is
# what restore actually uses. Trigger frequency depends on rate of growth:
# at ~50MB/day with a 300MB threshold this is ~weekly.
prune_repo_history_if_needed() {
  local repo=$1
  local threshold_mb=${RETENTION_PRUNE_THRESHOLD_MB:-300}

  local total_mb
  total_mb=$(du -sm "$repo" 2>/dev/null | awk '{print $1}')
  if [ -z "$total_mb" ] || [ "$total_mb" -lt "$threshold_mb" ]; then
    return 0
  fi

  log "Repo size ${total_mb}MB exceeds prune threshold ${threshold_mb}MB; collapsing history..."

  # Capture pre-prune HEAD so we can push a tag that pins the old history.
  # GitHub will keep the commits the tag references even after main no
  # longer touches them — so old continuwuity blobs remain recoverable
  # via `git checkout archive-YYYY-MM-DD` for any forensic need.
  local old_head archive_tag
  old_head=$(git -C "$repo" rev-parse HEAD)
  archive_tag="archive-$DATE"

  # Create a fresh orphan branch with current files, replace main, push
  # force-with-lease. Only the cron writes here so collision is unlikely;
  # --force-with-lease is the safety belt that aborts if origin shifted.
  if ! git -C "$repo" checkout --orphan _prune_tmp 2>&1 | tail -3; then
    error "checkout --orphan failed; skipping prune"
    return 1
  fi
  git -C "$repo" add -A
  git -C "$repo" \
    -c user.name="imagineering-backup" \
    -c user.email="backup@imagineering.cc" \
    commit -m "backup $DATE (history pruned; pre-prune HEAD at tag $archive_tag)"
  git -C "$repo" branch -D main 2>/dev/null || true
  git -C "$repo" branch -m main

  # Tag the old HEAD before force-pushing the collapsed main. The tag
  # push must succeed FIRST — otherwise the old commits become orphan
  # candidates for GC on the GitHub side. If tag push fails, abort the
  # prune rather than risk silent history loss.
  if ! git -C "$repo" tag "$archive_tag" "$old_head" 2>&1 | tail -3; then
    error "Failed to create archive tag $archive_tag; skipping prune"
    return 1
  fi
  if ! git -C "$repo" push origin "$archive_tag" 2>&1 | tail -3; then
    error "Failed to push archive tag $archive_tag to origin; skipping prune"
    return 1
  fi

  if git -C "$repo" push --force-with-lease origin main 2>&1 | tail -3; then
    log "Repo history pruned to single root commit ($(du -sm "$repo" | awk '{print $1}')MB)"
    log "Pre-prune history preserved at tag $archive_tag (recover with: git checkout $archive_tag)"
  else
    error "Failed to force-push pruned history; manual intervention needed"
    return 1
  fi

  # Cap archive-tag retention. List archive tags on ORIGIN (a shallow clone has no
  # local tags), keep the newest N, delete the rest. The end-anchored grep excludes
  # any `^{}` deref lines; sort -ru gives newest-first, unique. Failures here don't
  # fail the (already-succeeded) prune, but they are NOT silenced: an ls-remote
  # failure means bloat pruning silently stopped, so it's surfaced + alerted
  # (cage-match #141 Kelvin/Carnot/Tesla: the old `2>/dev/null` + pipe-to-`tail`
  # fail-open let bloat resume in the dark — and the `| tail` masked git's own exit,
  # the very pipe-masks-exit class this PR exists to kill).
  # Fail-closed on this destructive op (cage-match #141 Carnot): a non-positive-int
  # retention (0 / empty / negative / garbage from a bad cron env) would compute
  # `tail -n +1` and delete EVERY archive tag. Refuse it and fall back to the safe
  # default rather than mass-deleting the PITR window.
  local keep=${ARCHIVE_TAG_RETENTION:-7}
  case "$keep" in ''|*[!0-9]*) error "ARCHIVE_TAG_RETENTION='$keep' not a non-negative integer — using 7"; keep=7;; esac
  [ "$keep" -lt 1 ] && { error "ARCHIVE_TAG_RETENTION=$keep < 1 would delete ALL archive tags — using 7"; keep=7; }
  local remote_tags
  if ! remote_tags=$(git -C "$repo" ls-remote --tags origin 2>&1); then
    error "archive-tag retention: ls-remote failed — bloat pruning SKIPPED this run (retries next run): $remote_tags"
    send_telegram_alert "$(printf '<b>Backup Retention Warning</b>\narchive-tag ls-remote failed; repo-bloat pruning skipped this run. Repo growth may resume until the next successful run.')" || true
  else
    local old_tags
    old_tags=$(printf '%s\n' "$remote_tags" \
      | grep -oE 'refs/tags/archive-[0-9-]+$' | sed 's#refs/tags/##' \
      | sort -ru | tail -n +$((keep + 1)))
    if [ -n "$old_tags" ]; then
      local del_count; del_count=$(printf '%s\n' "$old_tags" | wc -l | tr -d ' ')
      # Fail-closed blast-radius cap (cage-match #141 r4 Tesla): a malformed ls-remote
      # parse must not vacuum the entire archive set in one unattended cron tick.
      # Steady state deletes 0-1 tags; refuse an implausibly large batch and alert.
      local del_ceiling=${ARCHIVE_TAG_DELETE_CEILING:-30}
      if [ "$del_count" -gt "$del_ceiling" ]; then
        error "archive-tag retention: $del_count tags queued for delete exceeds ceiling $del_ceiling — REFUSING (possible bad ls-remote parse), no tags deleted"
        send_telegram_alert "$(printf '<b>Backup Retention BLOCKED</b>\n%s archive tags queued for delete (ceiling %s) — refused as a likely parse error; no tags deleted.' "$del_count" "$del_ceiling")" || true
      else
        local del_out
        # shellcheck disable=SC2086
        if del_out=$(git -C "$repo" push --delete origin $old_tags 2>&1); then
          log "archive-tag retention: kept newest $keep, pruned $del_count old tag(s)"
        else
          error "archive-tag retention: some old tags not deleted (non-fatal, retried next run): $del_out"
          send_telegram_alert "$(printf '<b>Backup Retention Warning</b>\narchive-tag delete failed; repo-bloat pruning incomplete this run.')" || true
        fi
      fi
    fi
  fi
}

backup_to_github() {
  local services=("$@")

  # Check prerequisites. Both error returns are 1 (not 0) so the caller's
  # FAILED_SERVICES tracking captures the failure — a missing deploy key
  # silently producing local-only backups for weeks (caught 2026-05-03)
  # is exactly the failure mode this script must surface.
  if ! command -v git &> /dev/null; then
    error "git not installed, GitHub backup failed"
    return 1
  fi
  if [ ! -f "$HOME/.ssh/imagineering-backups-deploy" ]; then
    error "Deploy key not found at ~/.ssh/imagineering-backups-deploy, GitHub backup failed"
    return 1
  fi

  log "Pushing backups to GitHub..."

  # Clone or pull the backup repo (shallow)
  if [ -d "$GITHUB_BACKUP_DIR/.git" ]; then
    git -C "$GITHUB_BACKUP_DIR" pull --rebase 2>/dev/null || {
      rm -rf "$GITHUB_BACKUP_DIR"
      git clone --depth 1 "$GITHUB_BACKUP_REPO" "$GITHUB_BACKUP_DIR"
    }
  else
    rm -rf "$GITHUB_BACKUP_DIR"
    git clone --depth 1 "$GITHUB_BACKUP_REPO" "$GITHUB_BACKUP_DIR" 2>/dev/null || {
      # First push — repo may be empty
      mkdir -p "$GITHUB_BACKUP_DIR"
      git -C "$GITHUB_BACKUP_DIR" init -b main
      git -C "$GITHUB_BACKUP_DIR" remote add origin "$GITHUB_BACKUP_REPO"
    }
  fi

  # Copy each service dump, decompressing so git deltas work
  for svc in "${services[@]}"; do
    local dump
    dump=$(find "$BACKUP_DIR" -name "${svc}-${DATE}.*" -type f 2>/dev/null | head -1)

    if [ -z "$dump" ] || [ ! -f "$dump" ]; then
      error "Dump file not found for $svc (expected ${svc}-${DATE}.*)"
      continue
    fi

    case "$dump" in
      *.tar.gz.age)
        # Encrypted opaque binary — pass through as-is. Git can't delta
        # these; that's why prune_repo_history_if_needed runs afterwards.
        cp "$dump" "$GITHUB_BACKUP_DIR/${svc}.tar.gz.age"
        log "Copied $svc backup → ${svc}.tar.gz.age"
        ;;
      *.sql.gz)
        gunzip -c "$dump" > "$GITHUB_BACKUP_DIR/${svc}.sql"
        log "Decompressed $svc backup → ${svc}.sql"
        ;;
      *.tar.gz)
        gunzip -c "$dump" > "$GITHUB_BACKUP_DIR/${svc}.tar"
        log "Decompressed $svc backup → ${svc}.tar"
        ;;
      *)
        local ext="${dump##*.}"
        cp "$dump" "$GITHUB_BACKUP_DIR/${svc}.${ext}"
        log "Copied $svc backup → ${svc}.${ext}"
        ;;
    esac
  done

  # Commit and push
  git -C "$GITHUB_BACKUP_DIR" add -A
  if git -C "$GITHUB_BACKUP_DIR" diff --cached --quiet; then
    log "No changes to push to GitHub"
  else
    git -C "$GITHUB_BACKUP_DIR" \
      -c user.name="imagineering-backup" \
      -c user.email="backup@imagineering.cc" \
      commit -m "backup $DATE"
    git -C "$GITHUB_BACKUP_DIR" push origin HEAD 2>/dev/null || \
      git -C "$GITHUB_BACKUP_DIR" push --set-upstream origin main
    log "Backups pushed to GitHub"
  fi

  check_repo_size

  # Cap unbounded git history growth from daily continuwuity tarballs.
  # Cheap to run; only triggers when repo exceeds RETENTION_PRUNE_THRESHOLD_MB.
  prune_repo_history_if_needed "$GITHUB_BACKUP_DIR" || \
    error "repo history prune failed (non-fatal)"
}

cleanup_old_backups() {
  log "Cleaning up local backups older than $RETENTION_DAYS days..."
  find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
  log "Cleanup complete"
}

# Run backups
case $SERVICE in
  all)
    SUCCEEDED=()
    for svc in kanbn outline radicale pm-bot claudius aiko-island; do
      if "backup_${svc//-/_}"; then
        SUCCEEDED+=("$svc")
      else
        error "$svc backup failed"
        FAILED_SERVICES+=("$svc")
      fi
    done
    # Matrix produces up to 6 separate files (one per bridge + 2 relay-bots).
    # Each becomes its own "service" entry for backup_to_github so they
    # land as individual files in the repo root (git-diffable SQL). Track
    # successes individually so that a failure of one bridge doesn't drop
    # the backups of the others from the commit.
    backup_matrix || error "matrix backup had partial failures"
    for matrix_svc in matrix-discord matrix-signal matrix-telegram \
                      matrix-whatsapp matrix-relay matrix-relay-hf; do
      if find "$BACKUP_DIR" -name "${matrix_svc}-${DATE}.*" -type f 2>/dev/null | grep -q .; then
        SUCCEEDED+=("$matrix_svc")
      else
        FAILED_SERVICES+=("$matrix_svc")
      fi
    done
    # Continuwuity is a single encrypted tarball. Don't run if matrix
    # bridges failed catastrophically — we'd be wasting time on a single
    # service in a broader-outage situation. But individual matrix-bridge
    # failures are fine; continuwuity is independent of bridge state.
    if backup_continuwuity; then
      SUCCEEDED+=("continuwuity")
    else
      error "continuwuity backup failed"
      FAILED_SERVICES+=("continuwuity")
    fi
    if [ ${#SUCCEEDED[@]} -gt 0 ]; then
      backup_to_github "${SUCCEEDED[@]}" || FAILED_SERVICES+=("github-upload")
    fi
    cleanup_old_backups
    ;;
  kanbn)
    backup_kanbn && backup_to_github kanbn || FAILED_SERVICES+=(kanbn)
    ;;
  outline)
    backup_outline && backup_to_github outline || FAILED_SERVICES+=(outline)
    ;;
  radicale)
    backup_radicale && backup_to_github radicale || FAILED_SERVICES+=(radicale)
    ;;
  pm-bot)
    backup_pm_bot && backup_to_github pm-bot || FAILED_SERVICES+=(pm-bot)
    ;;
  claudius)
    backup_claudius && backup_to_github claudius || FAILED_SERVICES+=(claudius)
    ;;
  aiko-island)
    backup_aiko_island && backup_to_github aiko-island || FAILED_SERVICES+=(aiko-island)
    ;;
  matrix)
    if backup_matrix; then
      backup_to_github matrix-discord matrix-signal matrix-telegram \
                       matrix-whatsapp matrix-relay matrix-relay-hf \
        || FAILED_SERVICES+=("github-upload")
    else
      FAILED_SERVICES+=(matrix)
    fi
    ;;
  continuwuity)
    backup_continuwuity && backup_to_github continuwuity || FAILED_SERVICES+=(continuwuity)
    ;;
  cleanup)
    cleanup_old_backups
    ;;
  *)
    echo "Usage: $0 [all|kanbn|outline|radicale|pm-bot|claudius|aiko-island|matrix|continuwuity|cleanup]"
    exit 1
    ;;
esac

if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
  error "Backups failed for: ${FAILED_SERVICES[*]}"
  exit 1
fi

log "Backup complete!"
