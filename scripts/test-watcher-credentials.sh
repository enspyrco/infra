#!/usr/bin/env bash
# Prove the declared-credential preflight REFUSES to schedule a blind watcher.
#
# The defect (claude-tasks#4470): email-health-watch needs BREVO_API_KEY from a
# per-user file nothing deploys. #194 moved it to run as `nick` while the file
# sat in ubuntu's home. Its missing-credential branch returns 1 — which is the
# NORMAL "still waiting" path for a recurring watcher — so the watcher exits 0.
# Scheduled, green, checking nothing, for days.
#
# The property under test is the REFUSAL, not the parse. So the checker is
# injected and stubbed here; a guard whose only proof requires production is a
# guard nobody re-verifies after the next refactor.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/watcher-credentials.sh
. "$REPO/scripts/lib/watcher-credentials.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
expect_rc() {  # <label> <expected-rc> <actual-rc>
    if [ "$2" -eq "$3" ]; then ok "$1 (rc=$3)"; else bad "$1 — expected rc=$2, got rc=$3"; fi
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkw() { printf '%s\n' "$2" > "$WORK/$1.sh"; printf '%s' "$WORK/$1.sh"; }

# Stub checkers: one that always succeeds, one that always fails.
check_ok()   { return 0; }
check_fail() { return 1; }

echo "=== PARSER — a declaration that parses to nothing asserts nothing, so malformed must FAIL CLOSED ==="
W=$(mkw good '# requires-credential: .config/imagineering/brevo-credentials BREVO_API_KEY')
out=$(watcher_declared_creds "$W"); rc=$?
[ "$out" = ".config/imagineering/brevo-credentials BREVO_API_KEY" ] && [ "$rc" -eq 0 ] \
  && ok "well-formed declaration parsed" || bad "well-formed declaration: got '$out' rc=$rc"

W=$(mkw none '# just a normal comment'); out=$(watcher_declared_creds "$W"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "no declaration → no output, rc=0" || bad "no declaration: got '$out' rc=$rc"

W=$(mkw onefield '# requires-credential: .config/only-a-path')
watcher_declared_creds "$W" >/dev/null 2>&1; expect_rc "missing VAR name rejected" 2 $?

W=$(mkw abspath '# requires-credential: /etc/imagineering-secrets/x VAR')
watcher_declared_creds "$W" >/dev/null 2>&1; expect_rc "ABSOLUTE path rejected (defect class is per-USER files)" 2 $?

W=$(mkw dotdot '# requires-credential: ../../etc/shadow VAR')
watcher_declared_creds "$W" >/dev/null 2>&1; expect_rc "path traversal rejected" 2 $?

W=$(mkw badvar '# requires-credential: .config/x 9NOTAVAR')
watcher_declared_creds "$W" >/dev/null 2>&1; expect_rc "invalid variable name rejected" 2 $?

echo
echo "=== REFUSAL — the safety property ==="
W=$(mkw declares '# requires-credential: .config/imagineering/brevo-credentials BREVO_API_KEY')
watcher_credentials_ok "$W" check_fail >/dev/null 2>&1
expect_rc "MUST-FAIL ARM: credential unusable → refuse (rc=1)" 1 $?

watcher_credentials_ok "$W" check_ok >/dev/null 2>&1
expect_rc "NULL ARM: credential usable → permit (rc=0)" 0 $?

W=$(mkw silent '# no declarations here')
watcher_credentials_ok "$W" check_fail >/dev/null 2>&1
expect_rc "declares nothing → permitted even with a failing checker (arm 1 measures the DECLARATION, not the checker)" 0 $?

W=$(mkw broken '# requires-credential: /absolute BAD')
watcher_credentials_ok "$W" check_ok >/dev/null 2>&1
expect_rc "malformed declaration → refuse even though the checker would pass (fail closed)" 2 $?

echo
echo "=== REGRESSION — the real watcher that caused this ==="
out=$(watcher_declared_creds "$REPO/scripts/watchers/email-health-watch.sh"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'BREVO_API_KEY'; then
    ok "email-health-watch declares BREVO_API_KEY (claude-tasks#4470 would now be refused, not scheduled)"
else
    bad "email-health-watch no longer declares its credential — the #4470 guard is inert"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
