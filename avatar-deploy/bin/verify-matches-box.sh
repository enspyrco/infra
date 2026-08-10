#!/bin/bash
# Drift check: does this repo still match what is actually installed on the box?
#
# The whole hazard of a tracked COPY is that it reads as truth while silently
# diverging from the thing that runs. Until the deploy is inverted (repo
# authoritative, box downstream) this script is the only thing standing between
# "avatar-deploy/ describes production" and "avatar-deploy/ used to describe
# production". Run it after any hand-edit on either side.
#
# Compares md5 only — it does not copy, install or repair anything.
# Exit 0 = repo and box agree. Exit 1 = drift (or the box is unreachable).
set -euo pipefail

HOST="${AVATAR_DEPLOY_HOST:-imagineering}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# repo-relative path <-> path on the box
PAIRS=(
  "bin/deploy-dreamfinder-avatar.sh:\$HOME/bin/deploy-dreamfinder-avatar.sh"
  "bin/deploy-lyra-avatar.sh:\$HOME/bin/deploy-lyra-avatar.sh"
  "bin/rollback-dreamfinder-avatar.sh:\$HOME/bin/rollback-dreamfinder-avatar.sh"
  "bin/rollback-lyra-avatar.sh:\$HOME/bin/rollback-lyra-avatar.sh"
  "ssh/config:\$HOME/.ssh/config"
  "ssh/config.d/imagineering-backups:\$HOME/.ssh/config.d/imagineering-backups"
  "ssh/config.d/lyra:\$HOME/.ssh/config.d/lyra"
  "ssh/config.d/xdeca-backups:\$HOME/.ssh/config.d/xdeca-backups"
)

# The pairing below matches on the $HOME-relative TAIL of each box path, which is
# only sound while those tails are mutually non-suffixing. That holds today and is
# invisible when it stops holding — a new entry whose tail is a suffix of another
# would silently cross-wire two files' digests. Assert it rather than trust it: the
# cost is eight string compares, and the failure it prevents is this tool
# confidently reporting the wrong file as clean.
for pair_a in "${PAIRS[@]}"; do
  tail_a="${pair_a#*:}"; tail_a="${tail_a#\$HOME}"
  for pair_b in "${PAIRS[@]}"; do
    [ "$pair_a" = "$pair_b" ] && continue
    tail_b="${pair_b#*:}"; tail_b="${tail_b#\$HOME}"
    case "$tail_a" in *"$tail_b")
      echo "FAIL: PAIRS tails are ambiguous — '$tail_a' ends with '$tail_b'."
      echo "      Path-keyed matching would cross-wire these two entries. Fix PAIRS."
      exit 1 ;;
    esac
  done
done

# One ssh round trip, not one per file — this runs against a production host.
REMOTE_CMD=""
for pair in "${PAIRS[@]}"; do
  REMOTE_CMD+="md5sum ${pair#*:} 2>/dev/null || echo 'ABSENT ${pair#*:}'; "
done

if ! REMOTE_OUT=$(ssh -o BatchMode=yes "$HOST" "$REMOTE_CMD" 2>/dev/null); then
  echo "FAIL: cannot reach $HOST — cannot confirm the box matches the repo."
  echo "      Treat this as UNKNOWN, not as agreement."
  exit 1
fi

# Fail closed: an md5 tool that is missing or a path that is absent must not
# read as a match. Anything other than a byte-identical digest is drift.
# Pair each output line to a repo path BY THE PATH THE REMOTE ECHOED BACK, not by
# line number. Positional pairing assumes the remote emits exactly one line per
# input, in order — an invariant nothing here can enforce. One dropped, doubled or
# unexpected line under that scheme shifts every later comparison onto the wrong
# repo path, and the report becomes confidently wrong in the one tool whose entire
# job is to be trusted about drift. Matching on the echoed path removes the
# ordering assumption rather than guarding it; the seen-set below then enforces
# coverage, so a missing line fails closed instead of passing unexamined.
drift=0
# A space-delimited string, NOT an associative array: macOS ships bash 3.2 as
# /bin/bash and `declare -A` is a bash 4 feature, so an assoc array would abort
# this script on the very laptop it is meant to be run from.
SEEN=" "
# Probe for the digest tool ONCE, explicitly, instead of chaining a fallback off a
# pipeline's exit status. `md5sum f | cut -f1 || md5 -q f` never falls back: the
# pipeline's status is CUT's, and cut exits 0 on empty input, so on a host without
# md5sum the `||` arm is skipped and every file reports "missing in the repo".
# macOS has no md5sum by default and this script is written to run from a macOS
# laptop, so that is the primary path, not an edge case.
if command -v md5sum >/dev/null 2>&1; then
  local_digest() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
elif command -v md5 >/dev/null 2>&1; then
  local_digest() { md5 -q "$1" 2>/dev/null; }
else
  echo "FAIL: neither md5sum nor md5 is available locally — cannot compute digests."
  echo "      Treat this as UNKNOWN, not as agreement."
  exit 1
fi

resolve_repo_path() {  # $1 = a path as reported by the box; echoes the repo path, or empty
  local reported="$1" pair repo tail
  for pair in "${PAIRS[@]}"; do
    repo="${pair%%:*}"
    # Match on the $HOME-relative tail, which is unique across PAIRS. The box
    # paths travel over the wire with $HOME unexpanded inside the ABSENT branch's
    # single quotes, so a literal whole-path compare would miss those.
    tail="${pair#*:}"; tail="${tail#\$HOME}"
    case "$reported" in *"$tail") echo "$repo"; return;; esac
  done
  echo ""
}

while IFS= read -r line; do
  [ -n "$line" ] || continue

  if [[ "$line" == ABSENT* ]]; then
    repo_path=$(resolve_repo_path "${line#ABSENT }")
    [ -n "$repo_path" ] || { echo "DRIFT  unrecognised remote line: $line"; drift=1; continue; }
    SEEN="$SEEN$repo_path "
    echo "DRIFT  $repo_path — absent on the box"
    drift=1
    continue
  fi

  box_md5="${line%% *}"
  repo_path=$(resolve_repo_path "${line##* }")
  if [ -z "$repo_path" ]; then
    echo "DRIFT  unrecognised remote line: $line"
    drift=1
    continue
  fi
  SEEN="$SEEN$repo_path "

  local_md5=$(local_digest "$HERE/$repo_path")

  if [ -z "$local_md5" ]; then
    echo "DRIFT  $repo_path — missing in the repo"
    drift=1
  elif [ "$box_md5" != "$local_md5" ]; then
    echo "DRIFT  $repo_path — repo $local_md5 != box $box_md5"
    drift=1
  else
    echo "ok     $repo_path"
  fi
done <<< "$REMOTE_OUT"

# Coverage assert — the fail-closed half. Silence about a file is NOT agreement
# about it, and without this a truncated remote response would print a short list
# of "ok" lines and then certify the whole set as matching.
for pair in "${PAIRS[@]}"; do
  repo_path="${pair%%:*}"
  case "$SEEN" in
    *" $repo_path "*) ;;
    *) echo "DRIFT  $repo_path — NO result returned by the box (truncated output?)"
       drift=1 ;;
  esac
done

if [ "$drift" -ne 0 ]; then
  echo
  echo "The box and this repo disagree. Decide which is right BEFORE deploying —"
  echo "the box is still the source of truth, so a repo-side edit that was never"
  echo "copied up has had no effect on production."
  exit 1
fi

echo
echo "repo matches $HOST for all ${#PAIRS[@]} files."
