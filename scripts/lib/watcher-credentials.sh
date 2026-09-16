#!/usr/bin/env bash
# Parse a watcher's DECLARED credential requirements.
#
# WHY THIS EXISTS. deploy-to.sh already asserts, before scheduling anything, that
# the watcher user can reach notify — because a watcher that cannot alert is
# worse than no watcher: tg() logs "skipping", returns 0, and the run reads as
# healthy. That assert is hardcoded to ONE credential.
#
# It was not enough. Measured 2026-09-15 (claude-tasks#4470): email-health-watch
# needs BREVO_API_KEY from a PER-USER file that nothing deploys, and #194 moved
# it to run as `nick` while the credential sat in ubuntu's home. Its phase_a
# returns 1 on a missing key — which is the NORMAL "still waiting" path for a
# recurring watcher — so the watcher exits 0. Scheduled, green, checking nothing,
# for days.
#
# That is the third credential in the same class (notify #4363, OCI #4364,
# Brevo #4470). Three instances means one-guard-per-credential is the defect.
# So the requirement moves INTO the watcher, next to the code that reads it, and
# the deploy asserts whatever is declared rather than whatever someone remembered
# to hardcode here.
#
# DECLARATION FORMAT — a comment, deliberately. deploy-to.sh runs on a
# workstation against the REPO copy of a watcher; sourcing the file to read a
# variable would EXECUTE it. A comment is inert.
#
#   # requires-credential: <path-relative-to-the-scheduled-user's-HOME> <VAR_NAME>
#
# e.g.  # requires-credential: .config/imagineering/brevo-credentials BREVO_API_KEY
#
# The path is HOME-relative on purpose: the whole defect class is that these
# files are per-user, so an absolute path would paper over the thing being
# checked.

# watcher_declared_creds <watcher-file>
#   Emits one "<path> <VAR>" line per declaration. No output = none declared.
#   Returns 2 on a malformed declaration rather than skipping it: a typo'd
#   requirement that silently declares nothing is exactly the failure this
#   file exists to remove.
watcher_declared_creds() {
    local f="$1" line path var rc=0
    [ -r "$f" ] || { echo "watcher_declared_creds: cannot read $f" >&2; return 2; }
    while IFS= read -r line; do
        # Strip the marker and normalise whitespace.
        line="${line#*requires-credential:}"
        # `set -f` BEFORE the split: `set --` performs pathname expansion as well as
        # word splitting, so a declaration of `.config/x/* KEY` in a directory with
        # one match is rewritten by the FILESYSTEM into a well-formed pair and then
        # checked rather than refused. The allowlist below never sees the `*`.
        # Confirmed: `sub/*` -> `sub/afile`. (Tesla, cage-match #199 round 3.)
        local _glob_was_off=0
        case "$-" in *f*) _glob_was_off=1 ;; esac
        set -f
        # shellcheck disable=SC2086  # deliberate word-split into exactly two fields
        set -- $line
        [ "$_glob_was_off" -eq 1 ] || set +f
        path="${1:-}"; var="${2:-}"
        if [ "$#" -ne 2 ] || [ -z "$path" ] || [ -z "$var" ]; then
            echo "watcher_declared_creds: malformed declaration in $f: 'requires-credential:$line'" >&2
            echo "  expected: # requires-credential: <home-relative-path> <VAR_NAME>" >&2
            rc=2; continue
        fi
        # SANITISE AT THE ASSIGNMENT SITE, not at the use site. These two values
        # are consumed by deploy-to.sh inside a remote `bash -c` running as the
        # watcher user, so anything that reaches that point is code. Validate to
        # a conservative ALLOWLIST here and the use site cannot be surprised.
        #
        # An earlier revision used `case "$var" in [A-Za-z_]*)`, which checks only
        # the FIRST CHARACTER — `*` matches the rest — so `BREVO;touch /tmp/pwn`
        # was accepted and spliced into the remote shell. Its test asserted
        # "invalid variable name rejected" and PASSED, because the fixture was
        # `9NOTAVAR`, the single case a first-character check does catch. A guard
        # verified only by the input it already handles reports its own contract
        # rather than its behaviour. (Carnot, cage-match #199 round 2.)
        case "$path" in
            /*) echo "watcher_declared_creds: $f declares an ABSOLUTE path '$path'; must be HOME-relative (the defect class is per-user files)" >&2; rc=2; continue ;;
            *..*) echo "watcher_declared_creds: $f declares a path containing '..': '$path'" >&2; rc=2; continue ;;
        esac
        # Full-string match, anchored by construction: reject if ANY character
        # falls outside the allowlist. Deliberately excludes whitespace, quotes,
        # `;`, `$`, backtick, `&`, `|`, `(`, `)`, `<`, `>` and `\`.
        case "$path" in
            *[!A-Za-z0-9._/-]*) echo "watcher_declared_creds: $f declares a path with disallowed characters: '$path' (allowed: A-Za-z0-9 . _ / -)" >&2; rc=2; continue ;;
        esac
        case "$var" in
            [A-Za-z_]) ;;                       # single-character name
            [A-Za-z_]*[!A-Za-z0-9_]*) echo "watcher_declared_creds: $f declares an invalid variable name '$var' (must match [A-Za-z_][A-Za-z0-9_]*)" >&2; rc=2; continue ;;
            [A-Za-z_]*) ;;                      # valid: starts right, no bad chars
            *) echo "watcher_declared_creds: $f declares an invalid variable name '$var' (must match [A-Za-z_][A-Za-z0-9_]*)" >&2; rc=2; continue ;;
        esac
        printf '%s %s\n' "$path" "$var"
    done < <(grep -E '^[[:space:]]*#[[:space:]]*requires-credential:' "$f" 2>/dev/null)
    return "$rc"
}

# watcher_credentials_ok <watcher-file> <checker-cmd> [args...]
#   For each declaration in <watcher-file>, invoke:  <checker-cmd> [args...] <path> <VAR>
#   Returns 0 only if EVERY declaration checks out. Returns 1 on the first
#   failure, 2 on a malformed declaration.
#
#   The checker is INJECTED rather than hardcoded so the refusal decision — the
#   actual safety property — is testable without a production box. deploy-to.sh
#   passes an ssh-based checker that resolves paths as the scheduled user; the
#   test passes a stub. A guard whose only proof requires prod is a guard nobody
#   re-verifies after the next refactor.
#
#   Fails CLOSED on a malformed declaration: a requirement that parses to
#   nothing asserts nothing, which is the same failure-equals-success collapse
#   this whole mechanism exists to remove.
watcher_credentials_ok() {
    local wfile="$1"; shift
    [ "$#" -ge 1 ] || { echo "watcher_credentials_ok: no checker command given" >&2; return 2; }
    local creds rc=0 path var
    creds=$(watcher_declared_creds "$wfile") || return 2
    [ -n "$creds" ] || return 0   # declares nothing: nothing to assert
    while read -r path var; do
        [ -n "${path:-}" ] || continue
        if ! "$@" "$path" "$var"; then
            echo "watcher_credentials_ok: $wfile declares $path ($var) — unusable by the scheduled user" >&2
            rc=1
        fi
    done <<< "$creds"
    return "$rc"
}
