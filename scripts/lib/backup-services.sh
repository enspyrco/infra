#!/bin/bash
# The services a nightly backup is expected to produce, in one place.
#
# WHY: on 2026-09-05 the sqlite-dumper image was pruned and SEVEN services stopped
# backing up for seven nights — while the run still committed the four that worked
# and logged "Backups pushed to GitHub". The failure was visible only in the last
# line of a log nobody reads.
#
# The detector for that is a per-service freshness assertion, and a per-service
# assertion needs to know WHICH services to expect. That list must not be a second
# hand-maintained copy: the matrix list has already drifted once (relay-hf was
# removed 2026-09-04 and the box went on attempting it for a week), and this repo
# has just spent a session removing five drifted copies of one Dockerfile recipe.
#
# So the list lives here, and scripts/test-backup-services.sh asserts it still
# matches the enumeration backup.sh actually dispatches on. Two copies that a test
# keeps honest — the same arrangement lib/pg-dump-guard.sh already uses to keep
# backup.sh and restore.sh from drifting apart.

# Services whose artifact is committed into the backup REPO.
BACKUP_SERVICES_TREE=(kanbn outline radicale pm-bot claudius aiko-island)

# Matrix bridges. backup_matrix writes one artifact per bridge so a single bridge
# failing does not drop the others from the commit.
BACKUP_SERVICES_MATRIX=(matrix-discord matrix-signal matrix-telegram matrix-whatsapp matrix-relay)

# Goes to RELEASE ASSETS rather than the git tree, so it is absent from the commit
# list — but it is still a nightly artifact and still belongs in a freshness check.
BACKUP_SERVICES_RELEASE=(minio)

# Every service a complete nightly run should have produced an artifact for.
backup_services_all() {
  printf '%s\n' "${BACKUP_SERVICES_TREE[@]}" "${BACKUP_SERVICES_MATRIX[@]}" "${BACKUP_SERVICES_RELEASE[@]}"
}

# Age in whole hours of the newest artifact for ONE service, or the literal string
# "none" when the service has produced nothing at all.
#
# Per-service by construction. The watcher this replaces took the newest file in
# the WHOLE directory, which is an ANY check wearing an ALL check's name: through
# the entire seven-night outage the directory always held a fresh kanbn or minio
# artifact, so a max-over-directory reading was green every night while signal,
# telegram, whatsapp, discord and aiko-island produced nothing. Verified against
# the artifacts still on disk:
#
#     2026-09-08  kanbn=1  matrix-signal=0  aiko-island=0
#     2026-09-09  kanbn=1  matrix-signal=0  aiko-island=0
#     2026-09-10  kanbn=1  matrix-signal=0  aiko-island=0
backup_service_age_hours() {
  local dir=${1:-} svc=${2:-} f m newest=0
  if [ -z "$dir" ] || [ -z "$svc" ]; then
    echo "backup-services: a directory and a service name are required" >&2
    return 2
  fi
  # `${svc}-[0-9]*` rather than `${svc}-*`: artifacts are named
  # <service>-YYYY-MM-DD.<ext>, so requiring a DIGIT after the dash stops a longer
  # sibling name from satisfying a shorter one. Without it `matrix-relay` is
  # satisfied by a `matrix-relay-hf-*` artifact — and relay-hf was RETIRED on
  # 2026-09-04, so a dead service would have kept a live one looking healthy.
  #
  # Deliberately a glob and `stat` rather than `find -printf`: -printf is
  # GNU-only. The box is Linux, but a lib whose tests cannot run on the dev
  # machine is a lib whose tests do not run in the dev loop — and the first
  # version of this silently returned "none" for EVERY service on macOS, which
  # made the anchoring test above pass for entirely the wrong reason.
  for f in "$dir/${svc}"-[0-9]*; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
    [ -n "$m" ] && [ "$m" -gt "$newest" ] && newest=$m
  done
  if [ "$newest" -eq 0 ]; then
    echo "none"
    return 0
  fi
  echo $(( ($(date +%s) - newest) / 3600 ))
}
