#!/usr/bin/env bash
# check-run-paths.sh — does the repo actually reach the code that runs?
#
# The failure this exists to catch is not a bug in a script. It is a script the
# repo cannot reach at all: PR #94 merged 2026-08-13 and never executed once,
# because cron ran watchers from /home/ubuntu while deploys landed in
# /opt/scripts/watchers. Three of five files were byte-identical, so every
# spot-check passed. A human comparing by hand will keep passing.
#
# Two questions, and the SECOND one is the point:
#   1. For each manifest row, does the running copy match the repo copy?
#   2. Does anything on the box run from a path NO manifest row claims?
#
# (1) catches drift in things we know about. (2) catches the class — a new
# untracked script appearing in cron is reported without anyone updating this
# file first. A checker that only knows what it was told cannot find what
# nobody knew.
#
# READ-ONLY. It never writes to the box. Safe to run any time, from anywhere
# with ssh access.
#
# Usage: scripts/check-run-paths.sh [host]      (default: 149.118.69.221)
# Exit:  0 = everything reconciled
#        1 = drift, missing file, or an untracked running path
#        2 = could not complete the check (ssh/manifest problem) — NOT a pass

set -euo pipefail

HOST="${1:-149.118.69.221}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/host/run-paths.tsv"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
problems=0

[ -r "$MANIFEST" ] || { echo "FATAL: no manifest at $MANIFEST" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Collect the box's side in ONE ssh round trip. Two things are gathered:
#   - md5 of every manifest running-path
#   - every command target named by cron (both crontabs + /etc/cron.d) and by
#     enabled systemd units
# sudo is needed to read ubuntu's crontab and /home/ubuntu; it is read-only.
# ---------------------------------------------------------------------------
# NOT `mapfile`: macOS ships bash 3.2 and this script is run from dev laptops
# as well as the box. A bash-4 builtin here would fail with "command not found"
# and, piped into anything, would surface as a silent exit 0.
rows=()
while IFS= read -r line; do
    rows+=("$line")
done < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST")
[ "${#rows[@]}" -gt 0 ] || { echo "FATAL: manifest has no rows" >&2; exit 2; }

run_paths=()
for row in "${rows[@]}"; do
    IFS=$'\t' read -r _repo runpath _status <<<"$row"
    run_paths+=("$runpath")
done

remote_script=$(cat <<'REMOTE'
# Passwordless sudo is a PRECONDITION, not a data point. Without it the hash
# arm prints ABSENT for every privileged path and the target arm silently
# collapses to the unprivileged subset — the script would then report drift, or
# even a pass, for what is actually "could not look". Announce the failure so
# the caller can exit 2.
sudo -n true 2>/dev/null || { echo "---NOSUDO---"; exit 0; }
echo "---HASHES---"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if sudo -n test -f "$p" 2>/dev/null; then
        printf '%s\t%s\n' "$(sudo -n md5sum "$p" 2>/dev/null | awk '{print $1}')" "$p"
    else
        printf 'ABSENT\t%s\n' "$p"
    fi
done
echo "---TARGETS---"
# Absolute paths named by any schedule. Field 6+ of a cron line is the command;
# grab anything that looks like a path to a script we might own.
{
    crontab -l 2>/dev/null
    sudo -n crontab -u ubuntu -l 2>/dev/null
    # root's OWN crontab, which is separate from /etc/cron.d and was not read
    # at all. Empty on this box today, verified — but "empty" and "never
    # looked" must not be the same reading.
    sudo -n crontab -u root -l 2>/dev/null
    # ONE privileged shell so the glob expands as root, and /etc/crontab too,
    # which was missing entirely. Expanded unprivileged, a permissions change
    # on /etc/cron.d would silently shrink the corpus instead of erroring.
    sudo -n sh -c 'cat /etc/cron.d/* /etc/crontab 2>/dev/null'

    # systemd, ONE UNIT AT A TIME. A single batched
    #   systemctl show -p ExecStart --value $(list of every enabled service)
    # dies on the first TEMPLATE unit in the list — `getty@.service` is not a
    # loadable name, so systemctl prints "Unit name getty@.service is neither a
    # valid invocation ID nor unit name", exits 1, and DROPS EVERY UNIT AFTER
    # IT. On Sydney that truncated 58 enabled services to 30 and silently hid
    # live-game.service (position 22, behind getty@ at 17) — an untracked
    # production service the check reported as clean. 2>/dev/null hid the
    # error and the remote block has no `set -e`, so the short read flowed on
    # looking exactly like a complete one.
    # Enabled services UNION the services enabled timers activate. A
    # timer-driven service is `static`, never `enabled`, so --state=enabled
    # cannot see it: 19 of 20 timer-activated units were invisible here,
    # including downstream-cd-poll.service, which runs
    # /home/nick/apps/downstream-server/cd-poll.sh — an absolute path the
    # pattern below would have matched if the unit were ever enumerated. Same
    # class as the getty@ truncation: a blind slice makes question 2 answer
    # "none" for everything inside it.
    for u in $( { systemctl list-unit-files --state=enabled --no-pager 2>/dev/null \
                    | awk '/\.service/{print $1}'
                  for t in $(systemctl list-unit-files --state=enabled --no-pager 2>/dev/null \
                             | awk '/\.timer/{print $1}'); do
                      systemctl show -p Unit --value "$t" 2>/dev/null
                  done
                } | grep -v '@' | sort -u); do
        es=$(sudo -n systemctl show -p ExecStart --value "$u" 2>/dev/null)
        [ -n "$es" ] || continue
        printf '%s\n' "$es"

        # ExecStart may name the script RELATIVE to WorkingDirectory:
        # embodied-agent-brain.service runs `/usr/bin/node server.js` with
        # WorkingDirectory=/home/nick/apps/embodied-agent-brain, so no absolute
        # path appears anywhere in the unit and the pattern below can never
        # match it. Re-absolutise those tokens so a relative ExecStart cannot
        # buy a service invisibility.
        wd=$(sudo -n systemctl show -p WorkingDirectory --value "$u" 2>/dev/null)
        [ -n "$wd" ] || continue
        argv=$(printf '%s' "$es" | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p')
        # Case patterns are written in the BALANCED `( pat )` form on purpose.
        # This heredoc sits inside $( ... ), and bash 3.2 (macOS) matches that
        # substitution by counting parens without honouring the heredoc — a
        # bare `/*)` closes it early and the whole script dies with a syntax
        # error 40 lines away from the cause.
        for tok in $argv; do
            case "$tok" in
                (/*) ;;  # already absolute — the pattern below picks it up
                (*.sh|*.mjs|*.js|*.py) printf '%s/%s\n' "${wd%/}" "$tok" ;;
            esac
        done
    done
# /home/[a-z0-9_-]+ not /home/[a-z]+: a username with a digit, underscore or
# hyphen (deploy-bot, ubuntu2) would otherwise slip past unseen.
# Drop WHOLE-LINE comments before extracting paths: a commented-out entry in
# /etc/cron.d is not a scheduled target, and reporting it as untracked trains
# the reader to ignore this section. Trailing `# tag` comments are left alone —
# the cron entries here carry them by design.
# KNOWN BOUNDARY, stated rather than papered over: this matches literal
# absolute paths, so a target reached indirectly (bash -lc 'cd /opt/app &&
# ./job.sh', run-parts, an extensionless wrapper) is still invisible. The check
# narrows the blind spot; it does not close it.
} | sed 's/^[[:space:]]*#.*$//' \
  | grep -oE '(/home/[a-z0-9_-]+|/opt)(/[A-Za-z0-9._-]+)+\.(sh|mjs|js|py)' | sort -u
REMOTE
)

if ! remote_out=$(printf '%s\n' "${run_paths[@]}" | ssh -o ConnectTimeout=25 "$HOST" "$remote_script" 2>/dev/null); then
    echo "FATAL: could not reach $HOST — this is NOT a pass" >&2
    exit 2
fi

if grep -q '^---NOSUDO---$' <<<"$remote_out"; then
    echo "FATAL: no passwordless sudo on $HOST — cannot read privileged paths. This is NOT a pass." >&2
    exit 2
fi

hashes=$(awk '/^---HASHES---$/{f=1;next} /^---TARGETS---$/{f=0} f' <<<"$remote_out")
targets=$(awk '/^---TARGETS---$/{f=1;next} f' <<<"$remote_out")

# A positive control: if the box returned no hashes at all, the remote block
# failed rather than finding nothing. Silence here would otherwise read as "all
# clear", which is the exact failure mode this script exists to refuse.
[ -n "$hashes" ] || { echo "FATAL: box returned no hashes — remote block failed" >&2; exit 2; }

# The SAME control on the targets arm, which had none — and that gap is not
# hypothetical: the getty@ truncation above emptied most of this list while the
# check still printed "none — every scheduled target is claimed". Question 2 is
# the half this script exists for, so an empty answer must mean the enumeration
# broke, never "nothing is scheduled". A box with no scheduled work at all does
# not exist here; if one ever does, it earns an explicit opt-out rather than a
# silent pass.
[ -n "$targets" ] || { echo "FATAL: box named no scheduled targets — enumeration failed, NOT a pass" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 1. Manifest rows: repo copy vs running copy
# ---------------------------------------------------------------------------
echo "== manifest rows =="
for row in "${rows[@]}"; do
    IFS=$'\t' read -r repo runpath status <<<"$row"
    # `external` rows have no source here by design — assert existence only.
    if [ "$status" = "external" ]; then
        rhash=$(awk -v p="$runpath" -F'\t' '$2==p{print $1}' <<<"$hashes")
        if [ "$rhash" = "ABSENT" ] || [ -z "$rhash" ]; then
            printf '%s VANISHED      %s %s %s(external: %s)%s\n' \
                "$RED" "$OFF" "$runpath" "$DIM" "${repo#EXTERNAL:}" "$OFF"
            problems=$((problems + 1))
        else
            printf '%s EXTERNAL      %s %s %s(owned by %s)%s\n' \
                "$DIM" "$OFF" "$runpath" "$DIM" "${repo#EXTERNAL:}" "$OFF"
        fi
        continue
    fi
    local_file="$REPO_ROOT/$repo"
    if [ ! -f "$local_file" ]; then
        printf '%s MISSING-IN-REPO%s %s\n' "$RED" "$OFF" "$repo"
        problems=$((problems + 1)); continue
    fi
    lhash=$(md5 -q "$local_file" 2>/dev/null || md5sum "$local_file" | awk '{print $1}')
    rhash=$(awk -v p="$runpath" -F'\t' '$2==p{print $1}' <<<"$hashes")
    if [ "$rhash" = "ABSENT" ] || [ -z "$rhash" ]; then
        printf '%s ABSENT-ON-BOX %s %s %s(%s)%s\n' "$RED" "$OFF" "$runpath" "$DIM" "$status" "$OFF"
        problems=$((problems + 1))
    elif [ "$lhash" = "$rhash" ]; then
        printf '%s IN-SYNC       %s %s %s(%s)%s\n' "$GRN" "$OFF" "$runpath" "$DIM" "$status" "$OFF"
    else
        printf '%s DRIFTED       %s %s %s(%s — repo %s, box %s)%s\n' \
            "$RED" "$OFF" "$runpath" "$DIM" "$status" "${lhash:0:7}" "${rhash:0:7}" "$OFF"
        problems=$((problems + 1))
    fi
done

# ---------------------------------------------------------------------------
# 1b. Executable tripwire for EXTERNAL:pending-* rows.
#
# `external` rows assert existence WITHOUT comparing content — correct for a
# file another repo owns, and exactly wrong once we own it. A row parked as
# EXTERNAL:pending-PR-163 becomes a lie the moment that PR merges, and the
# watcher's drift would then go permanently unreported by the very check meant
# to catch it. A TODO comment cannot be the guardrail for that; this can.
# ---------------------------------------------------------------------------
for row in "${rows[@]}"; do
    IFS=$'\t' read -r repo runpath status <<<"$row"
    case "$repo" in
        EXTERNAL:pending-*)
            base=$(basename "$runpath")
            if found=$(find "$REPO_ROOT/scripts" -name "$base" -type f 2>/dev/null | head -1) \
               && [ -n "$found" ]; then
                printf '%s PENDING-RESOLVED%s %s\n' "$RED" "$OFF" "$runpath"
                printf '   %s now exists in the repo, so this row must stop being external:\n' "${found#"$REPO_ROOT"/}"
                printf '   replace with: %s\t%s\torphaned\n' "${found#"$REPO_ROOT"/}" "$runpath"
                problems=$((problems + 1))
            fi
            ;;
    esac
done

# ---------------------------------------------------------------------------
# 2. The important half: schedule targets no manifest row claims
# ---------------------------------------------------------------------------
echo
echo "== scheduled targets not in the manifest =="
untracked=0
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! printf '%s\n' "${run_paths[@]}" | grep -qxF "$t"; then
        printf '%s UNTRACKED     %s %s\n' "$YEL" "$OFF" "$t"
        untracked=$((untracked + 1))
    fi
done <<<"$targets"
if [ "$untracked" -eq 0 ]; then
    printf '%s none%s — every scheduled target is claimed by a manifest row\n' "$GRN" "$OFF"
else
    problems=$((problems + untracked))
fi

echo
if [ "$problems" -eq 0 ]; then
    echo "${GRN}OK${OFF} — repo and box reconciled"
    exit 0
fi
echo "${RED}$problems problem(s)${OFF} — the repo does not describe what runs"
echo "Note: 'orphaned' rows are EXPECTED to drift until their schedule is cut over (#3482)."
exit 1
