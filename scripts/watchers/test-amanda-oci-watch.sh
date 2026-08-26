#!/usr/bin/env bash
# Exercise amanda-oci-watch's phase_a_check against a stubbed `oci`.
# Every arm asserts a SPECIFIC return code, including the failure arms — a test
# that cannot produce the bad state cannot clear it.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0

run_arm() {
    local name="$1" want_rc="$2" oci_rc="$3" oci_out="$4"
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/.config/imagineering" "$sandbox/bin" "$sandbox/watchers/lib"

    # stub oci
    cat > "$sandbox/bin/oci" <<STUB
#!/usr/bin/env bash
if [ "\$2" = "list-vnics" ] || [ "\$3" = "list-vnics" ]; then
  cat <<'VNIC'
${VNIC_OUT:-{\"data\":[]}}
VNIC
  exit ${VNIC_RC:-0}
fi
cat <<'OUT'
$oci_out
OUT
exit $oci_rc
STUB
    chmod +x "$sandbox/bin/oci"

    printf 'AMANDA_TENANCY_OCID=ocid1.tenancy.oc1..TESTFIXTURE\n' \
        > "$sandbox/.config/imagineering/oci-accounts.env"
    printf 'NOTIFY_URL=http://127.0.0.1:9\nNOTIFY_API_KEY=testfixture\n' \
        > "$sandbox/.config/imagineering/notify-credentials"

    cp "$REPO/scripts/watchers/lib/watcher-base.sh" "$sandbox/watchers/lib/"
    cp "$REPO/scripts/watchers/amanda-oci-watch.sh" "$sandbox/watchers/"

    # Source the watcher without running run_watcher, then call phase_a_check.
    # MUST live beside the real watcher so `dirname "$0"`/lib resolves — a
    # harness one directory up fails to source the lib and every arm returns
    # rc=1, which silently reads as a PASS on the "not up yet" arm.
    local harness="$sandbox/watchers/harness.sh"
    # Replace run_watcher with a direct phase_a_check call, and EXECUTE the file
    # (not `bash -c "source ..."`) so $0 is a real path and `dirname "$0"`/lib
    # resolves the way it will under cron.
    sed 's/^run_watcher$/phase_a_check/' "$sandbox/watchers/amanda-oci-watch.sh" > "$harness"
    chmod +x "$harness"

    local rc=0
    HOME="$sandbox" PATH="$sandbox/bin:$PATH" DRY_RUN="${DRY_RUN_ARM:-1}" \
        bash "$harness" > "$sandbox/out.txt" 2>&1 || rc=$?

    if [ "$rc" = "$want_rc" ]; then
        printf '  PASS  %-46s rc=%s\n' "$name" "$rc"; PASS=$((PASS+1))
    else
        printf '  FAIL  %-46s want rc=%s got rc=%s\n' "$name" "$want_rc" "$rc"; FAIL=$((FAIL+1))
        sed 's/^/          /' "$sandbox/out.txt" | head -5
    fi
    tail -3 "$sandbox/amanda-oci-watch.log" 2>/dev/null | sed 's/^/          log: /'
    rm -rf "$sandbox"
}

echo "=== FAILURE ARMS (must NOT read as 'not up yet') ==="
run_arm "oci call fails (bad creds/PATH/region)" 2 1 'ServiceError: NotAuthenticated'
run_arm "oci returns non-JSON"                   2 0 'command not found'

echo
echo "=== NULL ARM (genuine 'not up yet') ==="
run_arm "successful query, zero instances"       1 0 '{"data":[]}'

echo
echo "=== LANDED ARMS ==="
VNIC_OUT='{"data":[{"public-ip":null}]}' \
  run_arm "RUNNING but IP not assigned yet"      2 0 '{"data":[{"id":"ocid1.instance.oc1..X","shape-config":{"ocpus":2}}]}'
VNIC_RC=1 VNIC_OUT='{"data":[]}' \
  run_arm "RUNNING but list-vnics fails"         2 0 '{"data":[{"id":"ocid1.instance.oc1..X","shape-config":{"ocpus":2}}]}'
VNIC_OUT='{"data":[{"public-ip":"10.0.0.7"}]}' \
  run_arm "landed, real IP, DRY_RUN delivery ok" 0 0 '{"data":[{"id":"ocid1.instance.oc1..X","shape-config":{"ocpus":2}}]}'

echo
echo "=== DELIVERY ARM (real notify attempt to a dead port must NOT self-advance) ==="
VNIC_OUT='{"data":[{"public-ip":"10.0.0.7"}]}' DRY_RUN_ARM=0 \
  run_arm "landed but notify unreachable"        2 0 '{"data":[{"id":"ocid1.instance.oc1..X","shape-config":{"ocpus":2}}]}'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
