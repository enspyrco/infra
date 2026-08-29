#!/bin/bash
# Robust keep-alive for OCI free tier
# Oracle reclaims instances with <20% CPU at p95 over 7 days
# Strategy: sustained background load + periodic spikes

LOG=/var/log/keep-alive.log

# Generate CPU load for 2 minutes (enough to register on 15-min sampling)
# `_` rather than `i`: the loop variable is genuinely unused, we just want N
# parallel burners. nproc is quoted — unquoted it would word-split, which is
# harmless for a bare integer but fails CI's shellcheck gate.
for _ in $(seq 1 "$(nproc)"); do
    timeout 120 sha256sum /dev/urandom &>/dev/null &
done

# Wait for load to register
sleep 120

# Kill any lingering processes
pkill -f "sha256sum /dev/urandom" 2>/dev/null || true

# Network activity (proves instance is doing real work)
curl -s -o /dev/null https://cloudflare.com/cdn-cgi/trace
curl -s -o /dev/null https://1.1.1.1

echo "$(date): keep-alive ping ($(nproc) cores loaded for 120s)" >> "$LOG"

# Rotate log
tail -100 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
