#!/bin/bash
#
# testbed/cardano/scripts/wait-for-sync.sh — Issue #28
# Polls cardano-node sync until 100% or timeout.
#
set -euo pipefail

TIMEOUT=${1:-3600}  # default 1 hour
MAGIC=1             # preprod
CONTAINER="${2:-swarm-cardano-node}"

echo "[sync] Waiting for Cardano node to sync (timeout: ${TIMEOUT}s)..."

start=$(date +%s)
while true; do
    now=$(date +%s)
    elapsed=$((now - start))
    if [ "$elapsed" -gt "$TIMEOUT" ]; then
        echo "[sync] TIMEOUT after ${TIMEOUT}s"
        exit 1
    fi

    tip=$(docker exec "$CONTAINER" cardano-cli query tip --testnet-magic "$MAGIC" 2>/dev/null || echo "")
    if [ -z "$tip" ]; then
        echo "[sync] ($elapsed/${TIMEOUT}s) Node not ready yet..."
        sleep 10
        continue
    fi

    sync=$(echo "$tip" | python3 -c "import json,sys; print(json.load(sys.stdin).get('syncProgress','?'))" 2>/dev/null || echo "?")
    epoch=$(echo "$tip" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"epoch={d.get('epoch','?')} slot={d.get('slot','?')}\")" 2>/dev/null || echo "?")

    echo "[sync] ($elapsed/${TIMEOUT}s) syncProgress=${sync}% ${epoch}"

    if [ "$sync" = "100.00" ]; then
        echo "[sync] Fully synced!"
        exit 0
    fi

    sleep 15
done
