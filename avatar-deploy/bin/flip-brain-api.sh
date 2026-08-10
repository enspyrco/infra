#!/bin/bash
# Break-glass: flip the deployed DF brain from oauth (weekly-capped) to api (metered key).
set -euo pipefail
cd /home/nick/apps/embodied-dreamfinder
grep -q "^ANTHROPIC_API_KEY=sk-" .env || { echo "ANTHROPIC_API_KEY not in .env yet — aborting"; exit 1; }
sed -i "s/^BRAIN=oauth$/BRAIN=api/" .env
cp BOOT_CONTRACT.api BOOT_CONTRACT
exec ~/bin/deploy-embodied-dreamfinder.sh   # full 4-gate pass, auto-rollback armed
