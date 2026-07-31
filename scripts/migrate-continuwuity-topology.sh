#!/usr/bin/env bash
#
# One-time migration: move continuwuity's RocksDB tree from the volume ROOT into
# a `db/` SUBDIR, so that restore/rollback becomes a single atomic directory
# rename instead of a per-file promote-with-ordering dance (see
# scripts/restore.sh restore_continuwuity + matrix/CONTINUWUITY_BACKUP_RESTORE.md).
#
# WHY this must run BEFORE the new compose (CONTINUWUITY_DATABASE_PATH=
# /var/lib/continuwuity/db) starts continuwuity: on the new path an empty db/
# looks like a FRESH homeserver and continuwuity would mint a NEW signing key,
# orphaning the federation identity. This script relocates the existing tree so
# the new path finds the real data on first boot.
#
# Idempotent: re-running after a successful (or partial) migration is safe.
# Fail-closed: refuses to run while continuwuity is up (moving a live RocksDB
# tree corrupts it), rejects unknown flags, and asserts the result is a complete
# DB tree before declaring success.
#
# Usage (on the host):
#   cd ~/apps/matrix && docker compose stop continuwuity
#   /path/to/migrate-continuwuity-topology.sh
#   # then deploy the new matrix compose and start continuwuity:
#   docker compose up -d continuwuity && docker compose logs -f continuwuity
#
# Env overrides:
#   CONTINUWUITY_DATA_VOL   (default: matrix_continuwuity_data)
#   CONTINUWUITY_CONTAINER  (default: continuwuity)

set -euo pipefail

CONTINUWUITY_DATA_VOL="${CONTINUWUITY_DATA_VOL:-matrix_continuwuity_data}"
CONTINUWUITY_CONTAINER="${CONTINUWUITY_CONTAINER:-continuwuity}"

# Fail closed on unknown args — this is a mutating op, not a query.
if [ "$#" -gt 0 ]; then
  echo "error: unexpected argument '$1' — this script takes no positional args (configure via env)." >&2
  exit 2
fi

log()   { echo "[migrate-topology] $*"; }
error() { echo "[migrate-topology] ERROR: $*" >&2; }

command -v docker >/dev/null 2>&1 || { error "docker not found"; exit 1; }

if ! docker volume inspect "$CONTINUWUITY_DATA_VOL" >/dev/null 2>&1; then
  error "volume '$CONTINUWUITY_DATA_VOL' does not exist"; exit 1
fi

# Refuse to move data under a running server. Match the exact container name
# (anchored) so a substring match can't miss/over-match.
if docker ps --format '{{.Names}}' | grep -qx "$CONTINUWUITY_CONTAINER"; then
  error "container '$CONTINUWUITY_CONTAINER' is RUNNING. Stop it first:"
  error "  cd ~/apps/matrix && docker compose stop continuwuity"
  exit 1
fi

# All of the below runs inside one alpine container over the volume, so the
# whole decision+move is a single same-filesystem operation.
docker run --rm -v "${CONTINUWUITY_DATA_VOL}:/live" alpine sh -c '
  set -e
  cd /live

  # Split-brain guard (cage-match #141 r6 Carnot/Tesla): db/CURRENT alone is NOT
  # proof of a clean migration. If db/ has a DB *and* the root still has a RocksDB
  # tree, two generations coexist — the dangerous case being the new compose having
  # booted a FRESH homeserver under db/ (new signing key) while the REAL key DB sits
  # untouched at the root. Blessing that as "already migrated" would orphan the real
  # signing key. Fail closed and force an operator decision instead of a silent no-op.
  if [ -f db/CURRENT ]; then
    if [ -f CURRENT ] || ls ./*.sst >/dev/null 2>&1; then
      echo "[migrate-topology] ERROR: SPLIT BRAIN — db/CURRENT exists AND a RocksDB tree remains at the volume root." >&2
      echo "[migrate-topology] Two DB generations coexist. The root tree may be the REAL signing-key DB and db/ a fresh-key DB minted by an early compose start." >&2
      echo "[migrate-topology] Do NOT start continuwuity. Inspect both trees (compare sequence numbers by booting each read-only) and keep the correct one before migrating. Refusing to no-op." >&2
      exit 1
    fi
    echo "[migrate-topology] db/CURRENT present and root is clean — already migrated, nothing to do."
    exit 0
  fi

  # Fresh/partial detection. A valid OLD layout has CURRENT at the ROOT. If db/
  # exists WITHOUT CURRENT, a previous run moved part-way; we continue into it.
  if [ ! -d db ]; then
    # Nothing to migrate from? Refuse rather than create an empty db/ (which would
    # later boot as a fresh homeserver).
    if [ ! -f CURRENT ]; then
      echo "[migrate-topology] ERROR: no CURRENT at volume root and no db/ — refusing to create an empty db/ (would look like a fresh homeserver)." >&2
      exit 1
    fi
    mkdir db
  fi

  # Move every root entry EXCEPT our own work dirs into db/. find (not glob *) so
  # dotfiles come too; a RocksDB WAL/OPTIONS set is otherwise easy to strand.
  find . -mindepth 1 -maxdepth 1 \
      ! -name db ! -name db-staging ! -name "db.rescue-*" ! -name ".bk-scratch" \
    | while IFS= read -r p; do
        mv "$p" db/
      done

  # find|while runs in a subshell, so a failed mv does NOT trip set -e here —
  # assert the root is now clear of DB entries before trusting the result.
  leftover=$(find . -mindepth 1 -maxdepth 1 \
      ! -name db ! -name db-staging ! -name "db.rescue-*" ! -name ".bk-scratch")
  if [ -n "$leftover" ]; then
    echo "[migrate-topology] ERROR: entries remain at volume root after move:" >&2
    echo "$leftover" >&2
    echo "[migrate-topology] The DB is split between / and db/ — inspect before booting (do NOT start continuwuity)." >&2
    exit 1
  fi

  # media/ is part of database_path; ensure it exists inside db/ so a media-less
  # tree still boots (prune_missing_media needs the DIR present, empty is fine).
  mkdir -p db/media

  # Completeness gate: a bootable tree needs CURRENT + media/ + >=1 SST.
  if ! { [ -f db/CURRENT ] && [ -d db/media ] && ls db/*.sst >/dev/null 2>&1; }; then
    echo "[migrate-topology] ERROR: db/ is not a complete RocksDB tree after migration (missing CURRENT/media/SST)." >&2
    exit 1
  fi

  echo "[migrate-topology] OK: relocated $(ls db/*.sst | wc -l) SSTs into db/ (CURRENT + media/ present)."
'

log "Migration complete. Next:"
log "  1. Deploy the new matrix compose (CONTINUWUITY_DATABASE_PATH=/var/lib/continuwuity/db)."
log "  2. cd ~/apps/matrix && docker compose up -d continuwuity"
log "  3. docker compose logs -f continuwuity  # expect 'Opened database ... sequence=<non-zero>' + 'Services startup complete'"
