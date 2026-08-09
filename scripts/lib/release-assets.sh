#!/bin/bash
# GitHub Release assets — the storage tier for LARGE BINARY backup artifacts
# (MinIO object-store tarballs), as distinct from the small text artifacts
# (SQL dumps, radicale tars) that are committed to the backup repo's tree.
#
# WHY NOT COMMIT THEM
# Two independent reasons, and the second is the one that actually stops a
# backup dead:
#   1. Retention. A blob committed to git is in history forever; deleting the
#      file reclaims nothing. That is why prune_repo_history_if_needed exists
#      in backup.sh at all — and why its archive tags then grew to 4.37 GB
#      across 45 tags (2026-07-30), pinning the very blobs the prune removed.
#      A tree-committed binary has no retention story that isn't a rewrite.
#   2. GitHub blocks any file over 100 MiB outright (warning at 50 MiB). This
#      is a hard push rejection, not bloat, and no amount of history rewriting
#      helps: the cap applies to the incoming object.
#
# Release assets sit OUTSIDE git history. GitHub states it does not limit the
# total size of release binaries or the bandwidth to deliver them, and an asset
# DELETE actually reclaims. So retention becomes an ordinary API call, history
# stays append-only, and the per-file cap stops being the binding constraint.
#
# The guards below deliberately mirror prune_repo_history_if_needed's, which
# were hardened over 7 cage-match rounds in #141. Same destructive-remote-op
# hazards, same invariants: validate the retention integer (a garbage cron env
# must not compute a delete-everything window), cap the blast radius of one
# unattended run, capture the API's stderr so a failure's WHY reaches the log,
# and loop per item rather than leaning on word-splitting.

# Auth. A deploy key cannot create releases (it authenticates git-over-SSH
# only), so this needs a token — the one credential the tree-committed backup
# path does not require. Loaded from a root:nick 0640 file at source time,
# never inlined into a cron entry, same convention as lib/telegram.sh.
if [ -z "${GH_TOKEN:-}" ] && [ -r /etc/imagineering-secrets/github-release.env ]; then
  # shellcheck disable=SC1091
  . /etc/imagineering-secrets/github-release.env
fi
GH_TOKEN="${GH_TOKEN:-}"
export GH_TOKEN

# Every GitHub call funnels through this single indirection so the test suite
# can stub it — hermetically, with no token, no network and no real mutation.
release_gh() {
  gh "$@"
}

# True when a token is present. Callers gate on this so a box without the
# secret degrades to "text artifacts still back up, object store is SKIPPED
# and says so" rather than failing the whole nightly run — while never
# silently pretending the object store was captured.
release_auth_available() {
  [ -n "${GH_TOKEN:-}" ]
}

# Logging indirection. This lib is sourced by backup.sh (which defines log/error
# with its own timestamped format) AND standalone by the test suite, so it must
# work either way.
#
# It deliberately does NOT probe for a callable named `log`. An earlier version
# used `declare -F log` and it failed in two compounding ways outside bash:
# `declare -F` means "declare a float" in zsh rather than "is this a function",
# so the guard misfired — and `log` is a zsh BUILTIN, so the subsequent call
# resolved to that builtin instead of erroring. The result was a silent wrong
# call, not a visible failure. Probing a bare name for callability is unsafe
# when the name may collide with a shell builtin.
#
# So: delegate only when we are demonstrably in bash AND the name is genuinely a
# shell function; otherwise print our own. Internal names are prefixed so they
# cannot collide with a builtin in any shell.
_ra_log() {
  if [ -n "${BASH_VERSION:-}" ] && declare -f log >/dev/null 2>&1; then
    _ra_log "$*"
  else
    printf '[release-assets] %s\n' "$*"
  fi
}
_ra_err() {
  if [ -n "${BASH_VERSION:-}" ] && declare -f error >/dev/null 2>&1; then
    _ra_err "$*"
  else
    printf '[release-assets] ERROR: %s\n' "$*" >&2
  fi
}
_ra_alert() {
  if [ -n "${BASH_VERSION:-}" ] && declare -f send_telegram_alert >/dev/null 2>&1; then
    send_telegram_alert "$*" || true
  fi
}

# release_publish_asset <repo> <tag> <file>
# Uploads FILE as an asset of release TAG, creating the release if absent.
# Idempotent: --clobber replaces a same-named asset, so a re-run on the same
# day overwrites rather than accumulating duplicates.
release_publish_asset() {
  local repo=$1 tag=$2 file=$3

  # Fail closed on a missing or EMPTY artifact. An empty file is the shape a
  # silently-failed dump takes, and publishing it would overwrite a good asset
  # from an earlier run with nothing — a backup that destroys its predecessor.
  if [ ! -s "$file" ]; then
    _ra_err "release asset '$file' is missing or empty — refusing to publish"
    return 1
  fi

  if ! release_gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    local create_err
    if ! create_err=$(release_gh release create "$tag" --repo "$repo" \
        --title "$tag" \
        --notes "Automated backup artifacts. Binary object-store archives are attached as release assets rather than committed, so retention is a real delete and the 100 MiB per-file git limit does not apply." 2>&1); then
      _ra_err "failed to create release '$tag': $create_err"
      return 1
    fi
    _ra_log "created release $tag"
  fi

  local upload_err
  if ! upload_err=$(release_gh release upload "$tag" "$file" --repo "$repo" --clobber 2>&1); then
    _ra_err "failed to upload '$(basename "$file")' to release '$tag': $upload_err"
    return 1
  fi

  _ra_log "published $(basename "$file") ($(du -h "$file" | cut -f1)) to release $tag"
}

# release_prune <repo> <tag-prefix> <keep>
# Deletes releases whose tag starts with TAG-PREFIX, keeping the newest KEEP.
# Tags are expected to carry an ISO date suffix, so a lexical sort is a date
# sort — `gh release list` orders by creation time, which is NOT the same
# thing once a backfilled or re-run release exists.
release_prune() {
  local repo=$1 prefix=$2 keep=$3

  # Fail closed on a non-positive-integer retention. A garbage value would
  # compute `tail -n +1` and queue EVERY release for deletion — the entire
  # recovery window, unattended.
  case "$keep" in
    '' | *[!0-9]*)
      _ra_err "release retention '$keep' is not a non-negative integer — using 7"
      keep=7
      ;;
  esac
  if [ "$keep" -lt 1 ]; then
    _ra_err "release retention $keep < 1 would delete ALL releases — using 7"
    keep=7
  fi

  local listing
  if ! listing=$(release_gh release list --repo "$repo" --limit 200 \
                   --json tagName --jq '.[].tagName' 2>&1); then
    _ra_err "release retention: list failed — pruning SKIPPED this run (retries next run): $listing"
    _ra_alert "$(printf '<b>Backup Retention Warning</b>\nRelease listing failed; object-store asset pruning skipped this run. Storage growth may resume until the next successful run.')"
    return 0
  fi

  # Prefix-match with a glob, not a regex — the prefix is caller-supplied and
  # must not be interpreted as a pattern.
  local matched="" tag
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    case "$tag" in
      "${prefix}"*) matched="${matched}${tag}"$'\n' ;;
    esac
  done <<< "$listing"

  local old
  old=$(printf '%s' "$matched" | grep -v '^$' | sort -ru | tail -n +$((keep + 1)))
  [ -n "$old" ] || return 0

  local del_count
  del_count=$(printf '%s\n' "$old" | wc -l | tr -d ' ')

  # Blast-radius cap. Steady state deletes 0-1 releases; an implausibly large
  # batch means the listing or the parse went wrong, and executing it would
  # vacuum the recovery window in one unattended cron tick.
  local ceiling=${RELEASE_DELETE_CEILING:-30}
  case "$ceiling" in
    '' | *[!0-9]*) ceiling=30 ;;
  esac
  [ "$ceiling" -lt 1 ] && ceiling=30
  if [ "$del_count" -gt "$ceiling" ]; then
    _ra_err "release retention: $del_count releases queued for delete exceeds ceiling $ceiling — REFUSING (likely a bad listing parse), nothing deleted"
    _ra_alert "$(printf '<b>Backup Retention BLOCKED</b>\n%s release(s) queued for delete (ceiling %s) — refused as a likely parse error; nothing deleted.' "$del_count" "$ceiling")"
    return 0
  fi

  local del_fail=0 del_err last_err=""
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    # Capture stderr: a failed remote delete's WHY (auth revoked, protected
    # ref, network) is the diagnostic and must reach the log, not /dev/null.
    if ! del_err=$(release_gh release delete "$tag" --repo "$repo" --yes --cleanup-tag 2>&1); then
      del_fail=$((del_fail + 1))
      last_err="$del_err"
      _ra_err "release retention: failed to delete '$tag': $del_err"
    fi
  done <<< "$old"

  if [ "$del_fail" -eq 0 ]; then
    _ra_log "release retention: kept newest $keep, pruned $del_count old release(s)"
  else
    _ra_err "release retention: $del_fail of $del_count releases not deleted (non-fatal, retried next run)"
    _ra_alert "$(printf '<b>Backup Retention Warning</b>\nRelease delete failed for %s of %s; object-store pruning incomplete this run. Last error: %s' "$del_fail" "$del_count" "$last_err")"
  fi
}
