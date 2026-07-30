#!/bin/bash
set -euo pipefail

# ============================================================
# extract-did5-keys.sh — Extract Holder keys from the Identus
#                        Cloud Agent postgres DBs
#
# Usage: bash scripts/extract-did5-keys.sh
#
# Output: ./did-keys/
#   - holder_did.txt       (holder did:peer:2)
#   - ed25519_priv.b64url  (holder Ed25519 private key)
#   - x25519_keys.json     (holder Ed25519 keypair JWK)
#   - holder_x25519_priv.b64url  (holder X25519 private key)
#   - holder_x25519_pub.b64url   (holder X25519 public key)
#   - credential.jwt       (VC JWT)
#
# Nothing is extracted for the verifier: it mints a new peer DID per
# invitation, so anything taken here would be stale by the time it is used.
# The authenticator reads the matching key at authentication time instead.
# ============================================================

OUT_DIR="${DID5_OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/did-keys}"
HOLDER_DB="${DB_CONTAINER:-swarm-testbed-db-holder-1}"

mkdir -p "$OUT_DIR"

# The holder keys used to be written without the "holder_" prefix. Leaving
# those files behind lets a stale key pair be picked up by anything still
# reading the old names, which is silent and hard to spot.
rm -f "$OUT_DIR/x25519_priv.b64url" "$OUT_DIR/x25519_pub.b64url"

# ── Helper: extract X25519 keys from a peer DID in a given DB ──
extract_peer_did_keys() {
    local db=$1 label=$2 prefix=$3

    local did
    did=$(docker exec "$db" psql -U postgres -d agent -t -A -c \
        "SELECT did FROM peer_did ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || echo "")

    if [ -z "$did" ]; then
        echo "[extract] WARNING: No peer DID found in $label DB"
        return 1
    fi
    echo "[extract] $label peer DID: $did"
    echo -n "$did" > "$OUT_DIR/${prefix}_did.txt"

    # X25519 (agreement) keys
    local x_jwk
    x_jwk=$(docker exec "$db" psql -U postgres -d agent -t -A -c \
        "SELECT key_pair::text FROM peer_did_rand_key WHERE did = '${did}' AND key_id = 'agreement';" 2>/dev/null || echo "")

    if [ -n "$x_jwk" ]; then
        local x_d x_x
        x_d=$(echo "$x_jwk" | python3 -c "import sys,json; print(json.load(sys.stdin)['d'])")
        x_x=$(echo "$x_jwk" | python3 -c "import sys,json; print(json.load(sys.stdin)['x'])")
        echo -n "$x_d" > "$OUT_DIR/${prefix}_x25519_priv.b64url"
        echo -n "$x_x" > "$OUT_DIR/${prefix}_x25519_pub.b64url"
        if [ "$prefix" = "holder" ]; then
            # What the supplicant reads through DID_X25519_KEY_FILE. The
            # member names are the ones did_credential_load() looks for; this
            # file used to hold the Ed25519 JWK, whose members are d and x, so
            # nothing was ever read out of it and the pair arrived in the
            # environment instead.
            printf '{"x25519_priv":"%s","x25519_pub":"%s"}\n' \
                "$x_d" "$x_x" > "$OUT_DIR/x25519_keys.json"
        fi
        echo "[extract] $label X25519 keys written"
    else
        echo "[extract] WARNING: No X25519 key for $label"
    fi

    # Ed25519 (authentication) key — holder only
    if [ "$prefix" = "holder" ]; then
        local ed_jwk
        ed_jwk=$(docker exec "$db" psql -U postgres -d agent -t -A -c \
            "SELECT key_pair::text FROM peer_did_rand_key WHERE did = '${did}' AND key_id = 'authentication';" 2>/dev/null || echo "")
        if [ -n "$ed_jwk" ]; then
            echo "$ed_jwk" | python3 -c "import sys,json; print(json.load(sys.stdin)['d'])" \
                | tr -d '\n' > "$OUT_DIR/ed25519_priv.b64url"
            echo "[extract] Holder Ed25519 private key written"
        fi
    fi
}

# ── 1. Holder keys ──
extract_peer_did_keys "$HOLDER_DB" "Holder" "holder" || true

# ── 2. VC JWT (from holder pollux DB) ──
VC_RAW=$(docker exec "$HOLDER_DB" psql -U postgres -d pollux -t -A -c \
    "SELECT issued_credential_raw FROM issue_credential_records WHERE protocol_state = 'CredentialReceived' ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null || echo "")

if [ -n "$VC_RAW" ]; then
    echo "$VC_RAW" | python3 -c "
import sys, json, base64
raw = json.load(sys.stdin)
print(base64.b64decode(raw['base64']).decode().strip())
" | tr -d '\n' > "$OUT_DIR/credential.jwt"
    echo "[extract] VC JWT written"
else
    echo "[extract] WARNING: No CredentialReceived record found"
fi

# ── 4. Holder prism DID authentication key ──
#
# The presentation is issued by the DID the credential was issued to, so the
# supplicant needs that DID's authentication key. The agent keeps prism keys as
# HD derivations of the wallet seed, so it is derived here and checked against
# the public key published in the DID before being handed over.
SUBJECT_DID=$(python3 - "$OUT_DIR/credential.jwt" <<'PY' 2>/dev/null || echo ""
import base64, json, sys
try:
    payload = open(sys.argv[1]).read().strip().split('.')[1]
except (IndexError, OSError):
    sys.exit(1)
payload += '=' * (-len(payload) % 4)
print(json.loads(base64.urlsafe_b64decode(payload)).get('sub', ''))
PY
)

# The credential names the long form; the wallet keys it by the short form
SHORT_DID=$(echo "$SUBJECT_DID" | cut -d: -f1-3)

if [ -n "$SHORT_DID" ]; then
    read -r DID_INDEX KEY_ID KEY_USAGE KEY_INDEX KEY_MODE PUB_HEX <<EOF
$(docker exec "$HOLDER_DB" psql -U postgres -d agent -t -A -F' ' -c \
    "SELECT s.did_index, k.key_id, k.key_usage, k.key_index, k.key_mode,
            encode(s.atala_operation_content, 'hex')
     FROM prism_did_key k JOIN prism_did_wallet_state s ON s.did = k.did
     WHERE k.did = '${SHORT_DID}' AND k.key_usage = 'AUTHENTICATION'
     ORDER BY k.key_index LIMIT 1;" 2>/dev/null || echo "")
EOF

    SEED=$(docker exec "$HOLDER_DB" psql -U postgres -d agent -t -A -c \
        "SELECT encode(seed, 'hex') FROM wallet_seed LIMIT 1;" 2>/dev/null || echo "")

    if [ "$KEY_MODE" = "HD" ] && [ -n "$SEED" ]; then
        DERIVED=$(python3 "$(dirname "$0")/derive-prism-key.py" \
            "$SEED" "$DID_INDEX" "$KEY_USAGE" "$KEY_INDEX")
        PRIV=$(echo "$DERIVED" | sed -n 1p)
        PUB_RAW=$(echo "$DERIVED" | sed -n 3p)

        # The create operation carries the public key; refuse to hand over a
        # key that does not match it
        if echo "$PUB_HEX" | grep -qi "$PUB_RAW"; then
            echo -n "$PRIV" > "$OUT_DIR/holder_secp256k1_priv.b64url"
            echo -n "$KEY_ID" > "$OUT_DIR/holder_prism_key_id.txt"
            echo -n "$SUBJECT_DID" > "$OUT_DIR/holder_prism_did.txt"
            echo "[extract] Holder prism $KEY_ID key derived and verified"
        else
            echo "[extract] ERROR: derived key does not match the one in $SHORT_DID"
        fi
    else
        echo "[extract] WARNING: no HD authentication key for $SHORT_DID"
    fi
else
    echo "[extract] WARNING: credential carries no subject DID"
fi

# ── 5. Permissions ──
#
# did_credential_load() refuses a private key file that anyone but its owner
# can read, so these have to be 0600 before the supplicant is started.
chmod 0600 "$OUT_DIR"/*.b64url "$OUT_DIR"/x25519_keys.json 2>/dev/null || true

echo ""
echo "Files in $OUT_DIR/:"
ls -la "$OUT_DIR/"
