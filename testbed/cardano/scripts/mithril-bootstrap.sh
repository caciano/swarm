#!/bin/bash
#
# testbed/cardano/scripts/mithril-bootstrap.sh — Issue #28
# Downloads Cardano preprod configs and bootstrap database via Mithril snapshot.
#
set -euo pipefail

CONFIG_DIR="$(dirname "$0")/../config"
DB_DIR="${1:-/tmp/cardano-db}"

mkdir -p "$CONFIG_DIR" "$DB_DIR"

echo "[mithril] Downloading preprod configs..."
BASE="https://book.play.dev.cardano.org/environments/preprod"

for f in config.json topology.json byron-genesis.json shelley-genesis.json alonzo-genesis.json conway-genesis.json; do
    if [ ! -f "${CONFIG_DIR}/${f}" ]; then
        curl -sL "${BASE}/${f}" -o "${CONFIG_DIR}/${f}"
        echo "[mithril] Got ${f}"
    else
        echo "[mithril] ${f} already present"
    fi
done

echo "[mithril] Configs ready in ${CONFIG_DIR}"
echo ""
echo "To bootstrap the database, start cardano-node with the compose override:"
echo "  cd testbed && ./manage.sh up --cardano"
echo ""
echo "The blinklabs-io/cardano-node image auto-fetches a Mithril snapshot"
echo "on first start when the data directory is empty."
