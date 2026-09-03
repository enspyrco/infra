#!/usr/bin/env bash
# release-watch.sh — Watch GitHub repos for new releases and notify via Telegram.
#
# Watches repos listed in a config file (one "owner/repo" per line).
# Stores the last-seen release tag per repo and alerts when a new one appears.
#
# Usage:
#   release-watch.sh [config_file]
#
# Config file default: /opt/scripts/release-watch.conf
# State file: /home/nick/.release-watch-state
#
# Required env vars (for notifications):
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
# Optional:
#   TELEGRAM_THREAD_ID — post to a specific topic

set -euo pipefail

CONF_FILE="${1:-/opt/scripts/release-watch.conf}"
STATE_FILE="/home/nick/.release-watch-state"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_telegram_alert() {
  local message="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log "Telegram alert skipped (TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set)"
    return 0
  fi
  local -a args=(
    -s -X POST
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    -d "chat_id=$TELEGRAM_CHAT_ID"
    -d "parse_mode=HTML"
    --data-urlencode "text=$message"
  )
  if [ -n "${TELEGRAM_THREAD_ID:-}" ]; then
    args+=(-d "message_thread_id=$TELEGRAM_THREAD_ID")
  fi
  curl "${args[@]}" > /dev/null 2>&1 || true
}

get_last_seen() {
  local repo="$1"
  if [ -f "$STATE_FILE" ]; then
    grep "^${repo}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true
  fi
}

set_last_seen() {
  local repo="$1" tag="$2"
  touch "$STATE_FILE"
  if grep -q "^${repo}=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^${repo}=.*|${repo}=${tag}|" "$STATE_FILE"
  else
    echo "${repo}=${tag}" >> "$STATE_FILE"
  fi
}

check_repo() {
  local repo="$1"
  log "Checking ${repo}..."

  # Fetch latest release from GitHub API (no auth needed for public repos)
  local response
  response=$(curl -sf "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null) || {
    log "  Failed to fetch release info for ${repo}"
    return 0
  }

  local tag name url
  tag=$(echo "$response" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
  name=$(echo "$response" | grep -o '"name": *"[^"]*"' | head -1 | cut -d'"' -f4)
  url=$(echo "$response" | grep -o '"html_url": *"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ -z "$tag" ]; then
    log "  No release tag found for ${repo}"
    return 0
  fi

  local last_seen
  last_seen=$(get_last_seen "$repo")

  if [ -z "$last_seen" ]; then
    # First run — record current version, don't alert
    log "  First run, recording ${tag} as baseline"
    set_last_seen "$repo" "$tag"
    return 0
  fi

  if [ "$tag" = "$last_seen" ]; then
    log "  No new release (still ${tag})"
    return 0
  fi

  # New release detected!
  log "  New release: ${last_seen} → ${tag}"
  set_last_seen "$repo" "$tag"

  local short_repo="${repo#*/}"
  send_telegram_alert "$(cat <<EOF
🆕 <b>${short_repo}</b> ${tag}

${name}
<a href="${url}">Release notes →</a>
EOF
)"
}

# --- Main ---

if [ ! -f "$CONF_FILE" ]; then
  log "Config file not found: ${CONF_FILE}"
  log "Create it with one GitHub owner/repo per line, e.g.:"
  log "  outline/outline"
  exit 1
fi

log "Release watcher starting (config: ${CONF_FILE})"

while IFS= read -r repo || [ -n "$repo" ]; do
  # Skip blank lines and comments
  repo="${repo%%#*}"
  repo="$(echo "$repo" | xargs)"
  [ -z "$repo" ] && continue
  check_repo "$repo"
done < "$CONF_FILE"

log "Done."
