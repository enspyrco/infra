#!/bin/bash
# The ONE definition of the sqlite-dumper helper image.
#
# WHY THIS FILE EXISTS: on 2026-09-05 the image disappeared from enspyr-syd — it is
# a LOCAL build with no registry behind it, so the estate cleanup that reclaimed
# 56 GB that week removed it (`docker image prune` frees anything no RUNNING
# container holds, and this one is only ever used by transient `docker run --rm`).
#
# For the next SEVEN NIGHTS the backup of aiko-island and all five matrix bridges
# failed — Signal, WhatsApp, Telegram, Discord and the relay — while the same run
# logged "Backups pushed to GitHub" and committed the services that had succeeded.
#
# Two things made a missing 11 MB image cost a week of messaging-history backups:
#
#   1. backup.sh USED the image and never BUILT it. restore.sh had a build-if-absent
#      helper; backup.sh did not. The half that runs NIGHTLY was the unprotected
#      one, and the half that runs only in a disaster was self-healing.
#   2. There were FIVE copies of the build recipe, and they had already drifted:
#      four said alpine:3.20 and the one deploy-to.sh actually shipped said
#      alpine:latest.
#
# So the recipe lives here once, every consumer calls this, and the image rebuilds
# itself on first use. A nightly job must not depend on an artifact that nothing
# recreates.
#
# alpine is PINNED, not :latest — an unpinned base in an image nothing records the
# provenance of is how you get a backup tool that silently changes under you.
#
# Usage — source this file, then:
#   ensure_sqlite_dumper || return 1

SQLITE_DUMPER_IMAGE="${SQLITE_DUMPER_IMAGE:-sqlite-dumper:latest}"
SQLITE_DUMPER_BASE="${SQLITE_DUMPER_BASE:-alpine:3.20}"

# Build the image if it is absent. Idempotent and cheap: the inspect costs
# milliseconds on the overwhelmingly common path where the image is present.
#
# Fails CLOSED and LOUD. A caller that cannot build this cannot dump a SQLite
# database, and must not proceed to report a successful backup of nothing.
ensure_sqlite_dumper() {
  if docker image inspect "$SQLITE_DUMPER_IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  # Deliberately not `log`/`error`: this file is sourced by scripts that define
  # those differently (or not at all, e.g. the standalone backup script), so it
  # speaks plain stderr and lets the caller's own handler add context.
  echo "sqlite-dumper: $SQLITE_DUMPER_IMAGE absent — building from $SQLITE_DUMPER_BASE" >&2
  if ! printf 'FROM %s\nRUN apk add --no-cache sqlite\n' "$SQLITE_DUMPER_BASE" \
       | docker build -q -t "$SQLITE_DUMPER_IMAGE" - >/dev/null 2>&1; then
    echo "sqlite-dumper: FAILED to build $SQLITE_DUMPER_IMAGE — SQLite-backed services (aiko-island, the matrix bridges) cannot be dumped" >&2
    return 1
  fi
  return 0
}
