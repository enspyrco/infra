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

# A REAL /proc/meminfo fixture. The first version of this harness stubbed `free`,
# which health-check.sh does not call — it reads /proc/meminfo — so the memory and
# swap probes ran against the REAL HOST inside a test that claimed disk/memory/swap
# were held quiet. Host swap above 50% was live current in a supposedly isolated
# test. (Tesla, cage-match #198.)
write_meminfo() {  # $1=target file
    cat > "$1" <<'EOF'
MemTotal:       16000000 kB
MemAvailable:   15000000 kB
SwapTotal:       2000000 kB
SwapFree:        2000000 kB
EOF
}

run_arm() {  # $1=docker_exit  $2=docker_stdout  [$3=meminfo_path_override]
    local dexit="$1" dout="$2"
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
    chmod +x "$sandbox/bin/"*

    # Seed the PREVIOUS active set with a broken container.
    printf 'container:img-radicale\n' > "$sandbox/state"
    write_meminfo "$sandbox/meminfo"

    PATH="$sandbox/bin:$PATH" HEALTHCHECK_STATE="$sandbox/state" NOTIFY_API_KEY="" \
        HEALTHCHECK_MEMINFO="${3:-$sandbox/meminfo}" \
        "$BASH4" "$REPO/scripts/health-check.sh" > "$sandbox/out.txt" 2>"$sandbox/err.txt"
    printf '%s' "$sandbox"
}

echo "=== ARM 1 (forced bad state): docker unreachable — must NOT report recovery ==="
S=$(run_arm 1 "")
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
S2=$(run_arm 0 "")
if grep -qi "Resolved" "$S2/out.txt"; then
    ok "docker up + empty: recovery correctly reported (arm 1 measures the daemon, not emptiness)"
else
    bad "docker up + empty: no recovery reported — arm 1's pass would be vacuous"
    sed 's/^/        /' "$S2/out.txt"
fi

echo
echo "=== ARM 3 (parse energised): a REAL exited container must persist, not resolve ==="
# Both arms above fed the stub an EMPTY census, so the `while read` over real
# "{{.Names}} {{.Status}}" lines was never struck — PASS from a coil never
# energised. This arm makes the parser do work. (Tesla, cage-match #198.)
S3=$(run_arm 0 "img-radicale Exited (1) 2 hours ago")
if grep -qi "Resolved" "$S3/out.txt"; then
    bad "a still-exited container was reported RESOLVED"
    sed 's/^/        /' "$S3/out.txt"
else
    ok "a still-exited container is NOT resolved (the parse actually ran)"
fi
if grep -q "container:img-radicale" "$S3/state"; then
    ok "its key survives in state"
else
    bad "its key was dropped from state despite the container still being exited"
fi

echo
echo "=== ARM 4 (disk sensor): df unreachable must NOT resolve disk issues ==="
S4=$(mktemp -d); mkdir -p "$S4/bin"
cat > "$S4/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$S4/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "df: cannot read table of mounted file systems" >&2
exit 1
EOF
chmod +x "$S4/bin/"*
printf 'disk:/
' > "$S4/state"
write_meminfo "$S4/meminfo"
PATH="$S4/bin:$PATH" HEALTHCHECK_STATE="$S4/state" NOTIFY_API_KEY="" \
    HEALTHCHECK_MEMINFO="$S4/meminfo" "$BASH4" "$REPO/scripts/health-check.sh" > "$S4/out.txt" 2>&1
if grep -qi "Resolved" "$S4/out.txt" && grep -q "disk:/" "$S4/out.txt"; then
    bad "df down: reported disk:/ as RESOLVED (the false all-clear, second sensor)"
    sed 's/^/        /' "$S4/out.txt"
else
    ok "df down: no recovery claimed for disk:/"
fi
grep -qi "BLIND on disk" "$S4/out.txt" \
  && ok "df down: raised the disk blindness as an issue" \
  || { bad "df down: stayed quiet about being unable to measure disk"; sed 's/^/        /' "$S4/out.txt"; }

echo
echo "=== ARM 5 (memory sensor): unreadable /proc/meminfo must NOT resolve memory/swap ==="
S5=$(mktemp -d); mkdir -p "$S5/bin"
cat > "$S5/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$S5/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Use% Mounted on"
echo "  1% /"
EOF
chmod +x "$S5/bin/"*
printf 'memory
swap
' > "$S5/state"
PATH="$S5/bin:$PATH" HEALTHCHECK_STATE="$S5/state" NOTIFY_API_KEY="" \
    HEALTHCHECK_MEMINFO="$S5/does-not-exist" "$BASH4" "$REPO/scripts/health-check.sh" > "$S5/out.txt" 2>&1
if grep -qi "Resolved" "$S5/out.txt"; then
    bad "meminfo unreadable: reported memory/swap as RESOLVED (third sensor)"
    sed 's/^/        /' "$S5/out.txt"
else
    ok "meminfo unreadable: no recovery claimed for memory/swap"
fi
grep -qi "BLIND on memory" "$S5/out.txt" \
  && ok "meminfo unreadable: raised the memory blindness as an issue" \
  || { bad "meminfo unreadable: stayed quiet"; sed 's/^/        /' "$S5/out.txt"; }

echo
echo "=== ARM 5b (sensor validity): a READABLE but incomplete meminfo is BLIND, not a measurement ==="
# Two doors, opposite directions, same defect — a readable file taken as a valid
# measurement. MemAvailable missing => false ALARM at 100% (Carnot). File empty
# => not blind, guard skips, memory/swap silently RESOLVE (Tesla).
for case_name in "empty" "no-MemAvailable"; do
    S5b=$(mktemp -d); mkdir -p "$S5b/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$S5b/bin/docker"
    printf '#!/usr/bin/env bash\necho "Use%%%% Mounted on"\necho "  1%%%% /"\n' > "$S5b/bin/df"
    chmod +x "$S5b/bin/"*
    printf 'memory\nswap\n' > "$S5b/state"
    if [ "$case_name" = "empty" ]; then : > "$S5b/meminfo"
    else printf 'MemTotal:       16000000 kB\nSwapTotal:       2000000 kB\nSwapFree:        2000000 kB\n' > "$S5b/meminfo"; fi
    PATH="$S5b/bin:$PATH" HEALTHCHECK_STATE="$S5b/state" NOTIFY_API_KEY="" \
        HEALTHCHECK_MEMINFO="$S5b/meminfo" "$BASH4" "$REPO/scripts/health-check.sh" > "$S5b/out.txt" 2>&1
    if grep -qi "Resolved" "$S5b/out.txt"; then
        bad "$case_name meminfo: reported memory/swap RESOLVED (false all-clear)"
        sed 's/^/        /' "$S5b/out.txt"
    else
        ok "$case_name meminfo: no recovery claimed"
    fi
    if grep -qi "BLIND on memory" "$S5b/out.txt"; then
        ok "$case_name meminfo: marked blind rather than measured"
    else
        bad "$case_name meminfo: treated an incomplete read as a measurement"
        sed 's/^/        /' "$S5b/out.txt"
    fi
    if grep -q "100% used" "$S5b/out.txt"; then
        bad "$case_name meminfo: emitted a spurious 100% memory alarm"
    else
        ok "$case_name meminfo: no spurious 100% alarm"
    fi
done

echo
echo "=== ARM 6 (stderr must not become a container): a WARNING on a healthy daemon ==="
# `2>&1` on a ZERO exit folded stderr into the roster, so a daemon warning became
# a phantom container:* key — then a false recovery when the warning stopped.
S6=$(mktemp -d); mkdir -p "$S6/bin"
cat > "$S6/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "WARNING: the plugin api is deprecated" >&2
exit 0
EOF
cat > "$S6/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Use% Mounted on"
echo "  1% /"
EOF
chmod +x "$S6/bin/"*
: > "$S6/state"
write_meminfo "$S6/meminfo"
PATH="$S6/bin:$PATH" HEALTHCHECK_STATE="$S6/state" NOTIFY_API_KEY="" \
    HEALTHCHECK_MEMINFO="$S6/meminfo" "$BASH4" "$REPO/scripts/health-check.sh" > "$S6/out.txt" 2>&1
if grep -qE "container:(WARNING|the|plugin)" "$S6/state" "$S6/out.txt" 2>/dev/null; then
    bad "a stderr warning was parsed as a container name (phantom issue)"
    sed 's/^/        /' "$S6/out.txt"; cat "$S6/state"
else
    ok "stderr on a healthy daemon does not become a container key"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
