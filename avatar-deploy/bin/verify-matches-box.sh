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
  "bin/flip-brain-api.sh:\$HOME/bin/flip-brain-api.sh"
  "ssh/config:\$HOME/.ssh/config"
  "ssh/config.d/imagineering-backups:\$HOME/.ssh/config.d/imagineering-backups"
  "ssh/config.d/lyra:\$HOME/.ssh/config.d/lyra"
  "ssh/config.d/xdeca-backups:\$HOME/.ssh/config.d/xdeca-backups"
)

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
drift=0
i=0
while IFS= read -r line; do
  repo_path="${PAIRS[$i]%%:*}"
  i=$((i + 1))
  [ -n "$line" ] || continue

  if [[ "$line" == ABSENT* ]]; then
    echo "DRIFT  $repo_path — absent on the box"
    drift=1
    continue
  fi

  box_md5="${line%% *}"
  local_md5=$(md5sum "$HERE/$repo_path" 2>/dev/null | cut -d' ' -f1 \
    || md5 -q "$HERE/$repo_path" 2>/dev/null || true)

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

if [ "$drift" -ne 0 ]; then
  echo
  echo "The box and this repo disagree. Decide which is right BEFORE deploying —"
  echo "the box is still the source of truth, so a repo-side edit that was never"
  echo "copied up has had no effect on production."
  exit 1
fi

echo
echo "repo matches $HOST for all ${#PAIRS[@]} files."
