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
  matches=$(docker ps --format '{{.Names}}' | grep -E "$pattern" || true)
  count=$(printf '%s' "$matches" | grep -c .)
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
  matches=$(docker ps \
    --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=$service" \
    --format '{{.Names}}' || true)
  count=$(printf '%s' "$matches" | grep -c .)
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
