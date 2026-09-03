#!/bin/bash
# Restart any stopped containers and log Docker health
LOG=/var/log/docker-watchdog.log

STOPPED=$(docker ps -a --filter "status=exited" --filter "label=com.docker.compose.project" --format "{{.Names}}" 2>/dev/null)

# Filter to only containers that exited with a nonzero code. Exit 0 means
# the container did its job (one-shot init containers like kanbn-migrate,
# outline_minio_setup, and the img-* image-build helpers all exit clean by
# design) — restarting them every 15 min causes them to re-run their setup
# work in a loop. Nonzero is a real failure worth retrying.
FAILED=""
for name in $STOPPED; do
    code=$(docker inspect --format='{{.State.ExitCode}}' "$name" 2>/dev/null)
    if [ -n "$code" ] && [ "$code" != "0" ]; then
        FAILED="$FAILED $name"
    fi
done

if [ -n "$FAILED" ]; then
    echo "$(date): Restarting failed containers (nonzero exit):$FAILED" >> "$LOG"
    for name in $FAILED; do
        docker start "$name" 2>/dev/null
    done
fi

# Log container count as proof of activity
RUNNING=$(docker ps -q 2>/dev/null | wc -l)
echo "$(date): $RUNNING containers running" >> "$LOG"

# Rotate
tail -200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
