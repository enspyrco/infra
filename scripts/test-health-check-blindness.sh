#!/usr/bin/env bash
# Prove health-check.sh cannot mistake "docker unreachable" for "containers recovered".
#
# The defect this guards: the container enumeration used to be
#   done < <(docker ps -a ... 2>/dev/null)
# With the daemon down that yields nothing, `issues` gets no container:* keys,
# and the resolved-keys diff fires a ✅ RECOVERY for every container that was
# broken a moment ago — then clears the state so the real breakage can never
# re-alert. Silence would have been survivable; a false all-clear is not.
#
# TWO ARMS, deliberately. The forced-bad-state arm alone proves nothing: a test
# that can never go green for the wrong reason is indistinguishable from a test
# that cannot fail at all. The null arm proves a genuinely empty docker result
# STILL resolves, so arm 1 is measuring the daemon failure and not merely the
# absence of containers.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# health-check.sh uses associative arrays (declare -A), which need bash 4+.
# macOS ships bash 3.2, where `declare -A` fails and the script collapses on
# line 37 — WITHOUT this guard the harness still ran, the script produced no
# issues at all, and the forced-bad-state arm reported PASS ("no recovery
# claimed") against a script that was never executing. A test passing for the
# wrong reason is the exact defect under test, so resolve a real bash 4+ and
# refuse to run rather than grade a corpse.
BASH4=""
for b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)" /bin/bash; do
    [ -x "$b" ] || continue
    case "$("$b" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)" in
        ''|*[!0-9]*) continue ;;
        *) [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] && { BASH4="$b"; break; } ;;
    esac
done
if [ -z "$BASH4" ]; then
    echo "SKIP: no bash >= 4 found; health-check.sh needs associative arrays." >&2
    echo "      Refusing to run rather than emit passes from a script that cannot start." >&2
    exit 77
fi
echo "using $BASH4 ($("$BASH4" -c 'echo $BASH_VERSION'))"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

run_arm() {  # $1=label  $2=docker_exit  $3=docker_stdout
    local label="$1" dexit="$2" dout="$3"
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/bin"

    # Stub docker with the arm's behaviour.
    cat > "$sandbox/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s' '$dout'
[ -n '$dout' ] && echo
if [ $dexit -ne 0 ]; then echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2; fi
exit $dexit
EOF
    # Keep disk/memory/swap quiet so the assertions only see container keys.
    cat > "$sandbox/bin/df"   <<'EOF'
#!/usr/bin/env bash
# health-check.sh calls `df --output=pcent,target`; match that shape.
echo "Use% Mounted on"
echo "  1% /"
EOF
    cat > "$sandbox/bin/free" <<'EOF'
#!/usr/bin/env bash
echo "              total        used        free"
echo "Mem:          16000         100       15900"
echo "Swap:          2000           0        2000"
EOF
    chmod +x "$sandbox/bin/"*

    # Seed the PREVIOUS active set with a broken container.
    printf 'container:img-radicale\n' > "$sandbox/state"

    PATH="$sandbox/bin:$PATH" HEALTHCHECK_STATE="$sandbox/state" NOTIFY_API_KEY="" \
        "$BASH4" "$REPO/scripts/health-check.sh" > "$sandbox/out.txt" 2>"$sandbox/err.txt"
    printf '%s' "$sandbox"
}

echo "=== ARM 1 (forced bad state): docker unreachable — must NOT report recovery ==="
S=$(run_arm "blind" 1 "")
if grep -qi "Resolved" "$S/out.txt" && grep -q "img-radicale" "$S/out.txt"; then
    bad "docker down: reported img-radicale as RESOLVED (the false all-clear)"
    sed 's/^/        /' "$S/out.txt"
else
    ok "docker down: no recovery claimed for img-radicale"
fi
if grep -qi "BLIND" "$S/out.txt"; then
    ok "docker down: raised the blindness itself as an issue"
else
    bad "docker down: stayed quiet about being unable to see"
    sed 's/^/        /' "$S/out.txt"
fi
if grep -q "container:img-radicale" "$S/state"; then
    ok "docker down: previous container state carried forward (real breakage can still re-alert)"
else
    bad "docker down: cleared container state, so the real breakage can never re-alert"
fi

echo
echo "=== ARM 2 (null control): docker healthy, genuinely zero bad containers — MUST resolve ==="
S2=$(run_arm "clear" 0 "")
if grep -qi "Resolved" "$S2/out.txt"; then
    ok "docker up + empty: recovery correctly reported (arm 1 measures the daemon, not emptiness)"
else
    bad "docker up + empty: no recovery reported — arm 1's pass would be vacuous"
    sed 's/^/        /' "$S2/out.txt"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
