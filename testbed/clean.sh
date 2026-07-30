#!/bin/bash
set -uo pipefail

# ============================================================
# clean.sh — take the deployment down
#
# Removes the containers of both profiles, the networks built around them, the
# agent databases, and everything provisioning generated. What is left is a
# checkout: the next `make test` provisions from nothing.
#
# Usage:
#   ./clean.sh                    containers, networks, volumes, artifacts
#   ./clean.sh --keep-volumes     leave the agent databases in place
#   ./clean.sh --keep-artifacts   leave env.test and did-keys/ in place
#   ./clean.sh --results          also remove benchmark-results/
#
# Stopping the deployment while keeping a provisioning to come back to:
#   ./clean.sh --keep-volumes --keep-artifacts
# ============================================================

# The header block above is the usage message.
usage() { sed -n '/^# =\+$/,/^# =\+$/{/^# =\+$/d;s/^# \?//;p}' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE=(docker compose -f docker-compose.yml --profile identus --profile eap)

KEEP_VOLUMES=0
KEEP_ARTIFACTS=0
DROP_RESULTS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-volumes)   KEEP_VOLUMES=1; shift ;;
        --keep-artifacts) KEEP_ARTIFACTS=1; shift ;;
        --results)        DROP_RESULTS=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "Usage: $0 [--keep-volumes] [--keep-artifacts] [--results]" >&2; exit 1 ;;
    esac
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  EAP-DID teardown                            ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

echo "[1/4] Containers and networks..."
DOWN=("${COMPOSE[@]}" down --remove-orphans)
[ "$KEEP_VOLUMES" -eq 0 ] && DOWN+=(-v)
"${DOWN[@]}" 2>&1 | sed 's/^/  /'
[ "$KEEP_VOLUMES" -eq 0 ] && echo "  ✓ agent databases removed" || echo "  - agent databases kept"

# Networks compose does not own, because these scripts create them by hand:
# provision-net exists for the length of provisioning, vp-relay for the length
# of an authentication. Either can outlive its script if it was interrupted.
echo "[2/4] Networks created outside compose..."
for net in swarm-testbed_provision-net swarm-testbed_vp-relay; do
    if docker network inspect "$net" >/dev/null 2>&1; then
        # A network with containers still attached will not be removed until
        # they are disconnected, which is what an interrupted run leaves behind.
        for cid in $(docker network inspect "$net" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
            docker network disconnect -f "$net" "$cid" 2>/dev/null || true
        done
        docker network rm "$net" >/dev/null 2>&1 \
            && echo "  ✓ $net removed" \
            || echo "  ⚠ $net could not be removed"
    else
        echo "  - $net absent"
    fi
done

# The bridge ACL is a table in the host's nftables, not a property of a
# container or of a Docker network, so nothing above takes it with it. Left
# behind it would filter a bridge that no longer exists — harmless, and
# confusing the next time someone reads the host's ruleset.
echo "[3/4] The EAP segment's ACL..."
if docker image inspect swarm-testbed:latest >/dev/null 2>&1; then
    docker run --rm --network host --cap-add NET_ADMIN \
        -v "$SCRIPT_DIR/scripts/eapol-guard.sh:/eapol-guard.sh:ro" \
        --entrypoint /bin/sh swarm-testbed:latest /eapol-guard.sh clear 2>&1 | sed 's/^/  /'
else
    echo "  - swarm-testbed:latest is not built; if an ACL is loaded, remove it with:"
    echo "    sudo ./scripts/eapol-guard.sh clear"
fi

echo "[4/4] Generated files..."
if [ "$KEEP_ARTIFACTS" -eq 0 ]; then
    # env.test and did-keys/ describe one provisioning of one deployment. Kept
    # past the databases that back them, they name DIDs that no longer resolve
    # and hand the supplicant keys for a credential nothing holds.
    rm -f  env.test config/hostapd/.method
    rm -rf did-keys
    echo "  ✓ env.test, did-keys/, .method removed"
else
    echo "  - env.test and did-keys/ kept"
fi

if [ "$DROP_RESULTS" -eq 1 ]; then
    rm -rf benchmark-results
    echo "  ✓ benchmark-results/ removed"
elif [ -d benchmark-results ]; then
    echo "  - benchmark-results/ kept (--results to remove)"
fi

echo ""
echo "✅ Clean."
