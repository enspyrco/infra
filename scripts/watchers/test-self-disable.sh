#!/usr/bin/env bash
# self_disable must NEVER write a crontab it did not successfully read.
#
# The failure this exists to prevent (found by Kelvin, PR #163 cage-match):
#   crontab -l fails for any reason other than "no crontab" -> 2>/dev/null eats
#   the error -> grep gets an empty stream -> `|| true` keeps the pipeline
#   alive -> `crontab -` is handed EMPTY stdin and installs an empty crontab.
#   Every unrelated cron job on that account is gone, silently, from a function
#   whose job was to remove ONE line.
#
# `crontab` is stubbed so the real one is never touched. The stub records every
# write to $CRONTAB_WRITES so an arm can assert a write did NOT happen — the
# assertion that actually matters here.
#
# Run: scripts/watchers/test-self-disable.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0

# mode: ok | readfail | nocrontab
run_arm() {
    local name="$1" mode="$2" want_write="$3" want_content="${4:-}"
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/bin" "$sandbox/.config/imagineering" "$sandbox/lib"
    cp "$REPO/scripts/watchers/lib/watcher-base.sh" "$sandbox/lib/"

    cat > "$sandbox/bin/crontab" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-l" ]; then
    case "$mode" in
        ok)        printf '%s\n' "0 5 * * * /opt/unrelated-backup.sh  # unrelated" \
                                 "*/10 * * * * /opt/thing.sh  # amanda-oci-watch"; exit 0 ;;
        nocrontab) echo "no crontab for testuser" >&2; exit 1 ;;
        readfail)  echo "crontab: installing new crontab: Permission denied" >&2; exit 1 ;;
        # TOCTOU: the FIRST read succeeds (so the tag-present guard passes),
        # the SECOND fails. self_disable reads twice and validates only the
        # first, so the second read's empty output is piped straight to
        # `crontab -`. This is the arm that can actually produce the wipe;
        # the blanket "any read failure" arm cannot, because the guard
        # catches it.
        toctou)    if [ -f "$sandbox/READ_ONCE" ]; then
                       echo "crontab: temporary failure" >&2; exit 1
                   fi
                   touch "$sandbox/READ_ONCE"
                   printf '%s\n' "0 5 * * * /opt/unrelated-backup.sh  # unrelated" \
                                  "*/10 * * * * /opt/thing.sh  # amanda-oci-watch"; exit 0 ;;
    esac
fi
if [ "\$1" = "-" ]; then cat > "$sandbox/WRITE"; echo WROTE >> "$sandbox/writes"; fi
STUB
    chmod +x "$sandbox/bin/crontab"

    cat > "$sandbox/run.sh" <<'HARNESS'
WATCHER_NAME="amanda-oci-watch"
CRON_TAG="amanda-oci-watch"
source "$HOME/lib/watcher-base.sh"
self_disable
HARNESS

    HOME="$sandbox" PATH="$sandbox/bin:$PATH" bash "$sandbox/run.sh" >/dev/null 2>&1

    local wrote="no"; [ -f "$sandbox/writes" ] && wrote="yes"
    local ok=1
    [ "$wrote" = "$want_write" ] || ok=0
    if [ -n "$want_content" ] && [ -f "$sandbox/WRITE" ]; then
        grep -qF "$want_content" "$sandbox/WRITE" || ok=0
    fi
    if [ "$ok" = "1" ]; then
        printf '  PASS  %-44s wrote=%s\n' "$name" "$wrote"; PASS=$((PASS+1))
    else
        printf '  FAIL  %-44s wrote=%s (want %s)\n' "$name" "$wrote" "$want_write"; FAIL=$((FAIL+1))
        [ -f "$sandbox/WRITE" ] && sed 's/^/          wrote: /' "$sandbox/WRITE"
        [ -f "$sandbox/amanda-oci-watch.log" ] && tail -2 "$sandbox/amanda-oci-watch.log" | sed 's/^/          log: /'
    fi
    rm -rf "$sandbox"
}

echo "=== THE DANGEROUS ARMS — a failed read must NOT cause a destructive write ==="
run_arm "crontab -l fails (permission error)"   readfail  no
# The real defect was: self_disable read the crontab TWICE and validated only
# the first read, so a transient failure between them handed `crontab -` an
# empty stream and wiped every unrelated job.
#
# Now that it reads ONCE, the stub's second read is never called and the write
# is correct — so the assertion is on CONTENT, not on write-vs-no-write. This
# stays a live regression guard: reintroduce a second read and the stub fails
# it, the write becomes empty, and this content check goes red.
run_arm "second read would fail: unrelated job survives" toctou yes "unrelated-backup"

echo
echo "=== normal operation ==="
run_arm "tag present: rewrites, keeps other jobs" ok      yes "unrelated-backup"
run_arm "no crontab at all: no write attempted"   nocrontab no

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
