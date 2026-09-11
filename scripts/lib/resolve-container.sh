#!/bin/bash
# Resolve a RUNNING container by name pattern, failing closed on 0 or >1 match.
#
# WHY THIS FILE EXISTS: backup.sh hardcoded `outline_postgres` and
# `kanbn_postgres`. The 2026-03-29 xdeca-colocation rename made those names
# nonexistent, and the nightly outline + kanbn dumps failed EVERY night from
# then until 2026-08-07 — 40 logged failures, and before the completion-marker
# guard landed they failed SILENTLY, gzipping empty files while logging
# "backup complete". The live DB had 93 documents; the backup had 0 bytes.
#
# Hardcoding is the root cause, so the fix is not a fourth hardcoded name.
# There are currently THREE naming schemes in play for the same service — the
# infra repo's compose says `img-outline-postgres`, the deployed app dir says
# `imagineering-outline-postgres`, and the old script said `outline_postgres` —
# so any name written here would be a guess with a shelf life. Derive from the
# running container instead, the same way lib/aiko-volume.sh derives the island
# volume, and refuse to guess when the answer is ambiguous.
#
# Fail CLOSED on both edges. Zero matches must be an ERROR, never a skip: a
# backup that quietly backs up nothing is the exact failure this file exists to
# end. More than one match must also be an error, because the caller is about
# to dump "the" database and must not pick arbitrarily between co-located
# tenants (this box runs both imagineering-* and xdeca-* stacks).
#
# Usage — source this file, then:
#   cid=$(resolve_container '^(imagineering|img)-outline-postgres$' outline) || return 1

# Print the single running container matching $1 (an ERE against the container
# name). $2 is a human label used only in diagnostics.
resolve_container() {
  local pattern=${1:-} label=${2:-container} matches count
  if [ -z "$pattern" ]; then
    echo "resolve-container: a name pattern is required" >&2
    return 1
  fi
  # Two failures were collapsed into one message: `docker ps ... | grep || true`
  # reports "no running container matches" both when nothing matches AND when the
  # DAEMON IS UNREACHABLE (docker ps exits 1; measured). Both fail closed, so this
  # was never a fail-open -- but during a disaster recovery "no container matches"
  # sends the operator hunting for a renamed container when the real answer is that
  # dockerd is down. Split them: `|| true` now covers only grep's no-match exit.
  local ps_out
  if ! ps_out=$(docker ps --format '{{.Names}}' 2>/dev/null); then
    echo "resolve-container: 'docker ps' failed for $label -- is the Docker daemon running?" >&2
    return 1
  fi
  matches=$(printf '%s\n' "$ps_out" | grep -E "$pattern" || true)
  # `|| true`: grep -c EXITS 1 on zero matches. Callers wrap these resolvers in
  # `if !`, which suspends set -e -- but a future bare `cid=$(resolve_pg_container x)`
  # under set -e would die here, before the fail-closed diagnostic below could print.
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    echo "resolve-container: no running container matches /$pattern/ for $label" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "resolve-container: >1 running container matches /$pattern/ for $label ($(printf '%s' "$matches" | tr '\n' ' ')) — refusing to guess" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

# Print the single running container for a compose PROJECT + SERVICE.
#
# Prefer this over resolve_container's name pattern whenever the two tenants
# run the SAME service, because the compose project is the durable identity and
# the container name is not. Radicale is the worked example: imagineering's
# container is `img-radicale` (project `radicale`) and xdeca's is plain
# `radicale` (project `xdeca-radicale`). backup.sh hardcoded `docker exec
# radicale`, which therefore resolved to XDECA'S container — imagineering's
# nightly radicale.tar contained xdeca's calendars, imagineering's own Radicale
# (including dreamfinder's collections) was never backed up at all, and because
# restore.sh drives the correct container via `cd ~/apps/radicale && docker
# compose`, a restore would have wiped imagineering's collections and replaced
# them with the other tenant's. A name pattern would have fixed this instance;
# the project label makes the class unrepresentable, since two tenants cannot
# share a compose project on one host.
#
# Usage:
#   cid=$(resolve_container_by_compose radicale radicale) || return 1
resolve_container_by_compose() {
  local project=${1:-} service=${2:-} label=${3:-${1:-container}} matches count
  if [ -z "$project" ] || [ -z "$service" ]; then
    echo "resolve-container: both a compose project and service are required" >&2
    return 1
  fi
  # Last site in the class: a bare `|| true` here reported "no running container for
  # compose project X" when dockerd was simply down. Every docker call in this file
  # now distinguishes a daemon failure from an empty result -- swept as a class after
  # a reviewer named the third instance, rather than patched one per round.
  if ! matches=$(docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=$service" \
    --format '{{.Names}}' 2>/dev/null); then
    echo "resolve-container: 'docker ps' failed for compose project '$project' ($label) -- is the Docker daemon running?" >&2
    return 1
  fi
  # `|| true`: grep -c EXITS 1 on zero matches. Callers wrap these resolvers in
  # `if !`, which suspends set -e -- but a future bare `cid=$(resolve_pg_container x)`
  # under set -e would die here, before the fail-closed diagnostic below could print.
  count=$(printf '%s' "$matches" | grep -c . || true)
  # Fail closed on both edges, same as resolve_container: zero matches must
  # never degrade to "back up nothing and report success", and an ambiguous
  # match must never be resolved by picking arbitrarily between tenants.
  if [ "$count" -eq 0 ]; then
    echo "resolve-container: no running container for compose project '$project' service '$service' ($label)" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "resolve-container: >1 running container for compose project '$project' service '$service' ($(printf '%s' "$matches" | tr '\n' ' ')) — refusing to guess" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

# Print the single running Postgres container for one of this box's app stacks,
# and (via resolve_compose_workdir below) the compose dir that drives it.
#
# WHY A THIRD FUNCTION: the two above fixed backup.sh in 2026-08-07 and
# restore.sh was left holding the original hardcoded names — the same strings whose
# staleness caused the 40 silent empty backups this file's header describes. One half of a backup/restore pair
# was repaired and the other was not, so the same defect stayed live on the
# side nobody exercises. A single definition both halves call cannot drift that
# way again; two correct copies can.
#
# Usage:
#   cid=$(resolve_pg_container outline) || return 1
# The one place the postgres container name pattern is written. Both resolvers below
# call this. THIS FILE EXISTS because two correct copies of a name drifted apart and
# the unexercised half was the disaster path -- and it had grown two copies of its
# own ERE, one against `docker ps` and one against `docker ps -a`, so the next prefix
# change would have retuned backup's resolver and left the dead-box anchor on the old
# note. Same defect, one level in. (Tesla, cage-match round 2/3.)
#
# Both historical prefixes, because the deployed app dirs say `imagineering-` and this
# repo's compose files say `img-`. Anchored so `-postgres` cannot also match a future
# `-postgres-replica`.
_pg_container_pattern() {
  printf '^(imagineering|img)-%s-postgres$' "${1:-}"
}

resolve_pg_container() {
  local svc=${1:-}
  if [ -z "$svc" ]; then
    echo "resolve-container: a service name is required (outline|kanbn)" >&2
    return 1
  fi
  resolve_container "$(_pg_container_pattern "$svc")" "$svc"
}

# Print the single container for an app stack's Postgres WHETHER OR NOT IT IS RUNNING.
#
# WHY THIS EXISTS -- it breaks a circular dependency that the running-only resolver
# creates on the one path that matters:
#
#     to start the stack   you need the compose directory
#     to get the directory you need a container to read the label off
#     to get a container   `docker ps` requires it to be ALREADY RUNNING
#
# A restore on a box whose stack is DOWN is not an edge case, it is the disaster
# recovery case. Resolving the directory anchor from `docker ps -a` breaks the cycle
# at the only link that does not actually need to be tight: `docker inspect` reads
# labels off a stopped container perfectly well (verified), and only the later
# `docker exec` phase needs a running one -- by which point `compose up` has run.
#
# Still fails closed on 0 or >1, same as the running-only resolver: an ambiguous
# match must never be resolved by picking between tenants.
#
# Honest limit: if the container has been REMOVED entirely (`docker compose down`),
# there is no label anywhere on the box to read and this returns 1. Nothing records
# the directory at that point, so the error says so rather than an override env var
# being added -- that would reintroduce the hand-fed constant this file exists to
# delete, for a case where the operator is rebuilding from the repo and already has
# the path in hand.
resolve_pg_container_any() {
  local svc=${1:-} label=${2:-${1:-container}} ps_out matches count
  if [ -z "$svc" ]; then
    echo "resolve-container: a service name is required (outline|kanbn)" >&2
    return 1
  fi
  if ! ps_out=$(docker ps -a --format '{{.Names}}' 2>/dev/null); then
    echo "resolve-container: 'docker ps -a' failed for $label -- is the Docker daemon running?" >&2
    return 1
  fi
  matches=$(printf '%s\n' "$ps_out" | grep -E "$(_pg_container_pattern "$svc")" || true)
  # `|| true`: grep -c EXITS 1 on zero matches. Callers wrap these resolvers in
  # `if !`, which suspends set -e -- but a future bare `cid=$(resolve_pg_container x)`
  # under set -e would die here, before the fail-closed diagnostic below could print.
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    echo "resolve-container: no container (running or stopped) matches ${svc}-postgres for $label -- if the stack was removed with 'docker compose down', no label records its directory; bring it up once, or run the restore from the stack's directory" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "resolve-container: >1 container matches ${svc}-postgres for $label ($(printf '%s' "$matches" | tr '\n' ' ')) -- refusing to guess" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

# Print the compose working directory that owns $1 (a container name), read from
# the label docker compose itself writes. The caller needs a dir to `cd` into for
# `docker compose up -d postgres`, and a hardcoded one is the same hand-fed
# constant this file exists to delete: restore.sh's were stale for nearly three
# months after a 2026-06-26 rename, naming directories that no longer existed.
#
# Fails closed on an empty label or a dir that is not there, so a restore aborts
# before the swap rather than cd-ing nowhere and running compose against $PWD.
resolve_compose_workdir() {
  local container=${1:-} label=${2:-$1} dir
  if [ -z "$container" ]; then
    echo "resolve-container: a container name is required" >&2
    return 1
  fi
  # Split the daemon failure from the absent label, same as resolve_container: a
  # bare `|| true` reported "no working_dir label" when dockerd was simply down,
  # which names the wrong absence at the worst possible moment.
  if ! dir=$(docker inspect "$container" \
    --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null); then
    echo "resolve-container: 'docker inspect $container' failed ($label) -- is the Docker daemon running, or was the container removed?" >&2
    return 1
  fi
  if [ -z "$dir" ]; then
    echo "resolve-container: container '$container' carries no compose working_dir label ($label) -- it was not created by docker compose" >&2
    return 1
  fi
  if [ ! -d "$dir" ]; then
    echo "resolve-container: compose working_dir '$dir' for '$container' does not exist ($label)" >&2
    return 1
  fi
  printf '%s\n' "$dir"
}
