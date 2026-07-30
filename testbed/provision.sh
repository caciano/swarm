#!/bin/bash
set -euo pipefail

# ============================================================
# provision.sh — enrolment, once
#
# Takes the deployment from nothing to a provisioned Holder: the Cloud Agents
# running, an Issuer DID on the ledger, a Holder DID deliberately not on it, a
# schema, a signed credential, and the keys the supplicant needs to present it.
#
# This is Section 3 of doc/model-d-architecture.md. It happens once, well
# before any Wi-Fi is involved. Authentication (auth.sh) uses only what
# this leaves behind and contacts the Issuer never.
#
# Usage:
#   ./provision.sh                provision, or confirm an existing provisioning
#   ./provision.sh --force        discard env.test and provision from scratch
#   ./provision.sh --no-agents    the agents are already up; do not touch compose
#
# Leaves behind:
#   env.test    identifiers and keys, read by auth.sh and docker compose
#   did-keys/   the credential and its private keys, mounted into the supplicant
# ============================================================

# The header block above is the usage message.
usage() { sed -n '/^# =\+$/,/^# =\+$/{/^# =\+$/d;s/^# \?//;p}' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/env.test"
DID_KEYS_DIR="$SCRIPT_DIR/did-keys"

HOLDER_URL="http://127.0.0.1:8081/cloud-agent"
ISSUER_URL="http://127.0.0.1:8080/cloud-agent"

COMPOSE=(docker compose -f docker-compose.yml)

# Enrolment is the one moment the device is entitled to reach the home
# institution, so it is the one moment this network exists. It carries the
# DIDComm exchange in both directions — the Issuer delivers the credential by
# posting to the Holder's service endpoint, which a real device would receive
# through a mediator — and it gives the Holder the ledger it needs to resolve
# the Issuer's published DID while accepting the credential.
#
# It is removed before the script returns. Model D has the device isolated from
# the home institution once the deployment is running, and a network that
# outlived provisioning would quietly undo that.
PROVISION_NET="swarm-testbed_provision-net"

# Terminal states of the DIDComm connection protocol. There is no state beyond
# these: the inviter's machine ends at ConnectionResponseSent and the invitee's
# at ConnectionResponseReceived (connect/connect-protocol-state.md in the agent
# source). Identus treats exactly this pair as an established connection when it
# resolves the pairwise DIDs for a credential offer, in
# ControllerHelper.extractDidIdPairFromEstablishedConnection. There is no
# "ConnectionCompleted" in ProtocolState at all.
INVITER_ESTABLISHED=ConnectionResponseSent
INVITEE_ESTABLISHED=ConnectionResponseReceived

FORCE=0
MANAGE_AGENTS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --force)     FORCE=1; shift ;;
        --no-agents) MANAGE_AGENTS=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Usage: $0 [--force] [--no-agents]" >&2; exit 1 ;;
    esac
done

# Progress goes to stderr throughout, so that a function can return a value by
# printing it and still report what it is doing.
STEP=0
step() { STEP=$((STEP + 1)); echo "" >&2; echo "[$STEP] $*" >&2; }
log()  { echo "  $*" >&2; }
die()  { echo "  ERROR: $*" >&2; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  EAP-DID provisioning                        ║"
echo "╚══════════════════════════════════════════════╝"

# ── HTTP and JSON helpers ──

api() {
    local method=$1 url=$2 data=${3:-}
    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" -H "Content-Type: application/json" -d "$data" 2>/dev/null || true
    else
        curl -s -X "$method" "$url" -H "Content-Type: application/json" 2>/dev/null || true
    fi
}

# Read one field out of a JSON object on stdin, following the named keys.
# Prints nothing, and succeeds, if the input is not JSON or the field is absent.
jget() {
    python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for key in sys.argv[1:]:
    if not isinstance(d, dict):
        sys.exit(0)
    d = d.get(key)
    if d is None:
        sys.exit(0)
print(d)
' "$@" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════
# 1. The Cloud Agents
# ═══════════════════════════════════════════════════════════

wait_for_agent() {
    local name=$1 port=$2 attempts=${3:-120}
    for _ in $(seq 1 "$attempts"); do
        if curl -sf "http://127.0.0.1:${port}/cloud-agent/did-registrar/dids" -o /dev/null 2>/dev/null; then
            log "✓ $name answering on :$port"
            return 0
        fi
        sleep 1
    done
    die "$name did not answer on :$port"
}

if [ "$MANAGE_AGENTS" -eq 1 ]; then
    step "Starting the Cloud Agents and the ledger (compose profile: identus)"
    "${COMPOSE[@]}" --profile identus up -d --wait 2>&1 | tail -5
else
    step "Using the Cloud Agents already running"
fi

step "Waiting for the agents to answer"
wait_for_agent "Issuer"   8080
wait_for_agent "Holder"   8081
wait_for_agent "Verifier" 8082

# ═══════════════════════════════════════════════════════════
# 2. provision-net
# ═══════════════════════════════════════════════════════════

# Container ids are resolved once; the network is attached to and detached from
# these, and the aliases are the hostnames the agents put in their service
# endpoints, so DIDComm URLs minted during enrolment resolve on both sides.
ISSUER_CID=$("${COMPOSE[@]}" --profile identus ps -q agent-issuer  2>/dev/null | head -1)
HOLDER_CID=$("${COMPOSE[@]}" --profile identus ps -q agent-holder  2>/dev/null | head -1)
CADDY_ISSUER_CID=$("${COMPOSE[@]}" --profile identus ps -q caddy-issuer 2>/dev/null | head -1)
CADDY_HOLDER_CID=$("${COMPOSE[@]}" --profile identus ps -q caddy-holder 2>/dev/null | head -1)
NODE_CID=$("${COMPOSE[@]}" --profile identus ps -q node 2>/dev/null | head -1)

# The node is here because the Holder is not on internet: it needs the ledger
# to resolve the Issuer's published DID while it accepts the credential, and
# only while it does that.
PROVISION_MEMBERS=(
    "agent-issuer:$ISSUER_CID"
    "agent-holder:$HOLDER_CID"
    "caddy-issuer:$CADDY_ISSUER_CID"
    "caddy-holder:$CADDY_HOLDER_CID"
    "node:$NODE_CID"
)

provision_net_down() {
    local spec cid
    for spec in "${PROVISION_MEMBERS[@]}"; do
        cid="${spec##*:}"
        [ -n "$cid" ] && docker network disconnect "$PROVISION_NET" "$cid" 2>/dev/null || true
    done
    docker network rm "$PROVISION_NET" >/dev/null 2>&1 || true
}

provision_net_up() {
    provision_net_down
    docker network create "$PROVISION_NET" >/dev/null
    local spec alias cid
    for spec in "${PROVISION_MEMBERS[@]}"; do
        alias="${spec%%:*}"
        cid="${spec##*:}"
        [ -n "$cid" ] || die "$alias is not running"
        docker network connect --alias "$alias" "$PROVISION_NET" "$cid"
        log "✓ $alias"
    done
}

step "Opening provision-net between the device and the home institution"
provision_net_up

# Everything from here can fail, and provision-net must not outlive the script:
# leaving it up would leave the Holder able to reach the Issuer at authentication
# time, which is precisely what Model D says must not happen.
trap 'provision_net_down' EXIT

# ═══════════════════════════════════════════════════════════
# 3. Is there a provisioning already?
# ═══════════════════════════════════════════════════════════

step "Checking for an existing provisioning"

NEEDS_PROVISION=1
if [ "$FORCE" -eq 1 ]; then
    log "--force given; discarding env.test"
    rm -f "$ENV_FILE"
elif [ -f "$ENV_FILE" ] && grep -q '^ISSUER_DID=' "$ENV_FILE"; then
    # env.test survives across deployments, so it is only worth anything if the
    # Issuer DID it names is still published in the agent that is running now.
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
    if [ "$(api GET "${ISSUER_URL}/did-registrar/dids/${ISSUER_DID}" | jget status)" = "PUBLISHED" ]; then
        log "✓ env.test names an Issuer DID that is published here; keeping it"
        NEEDS_PROVISION=0
    else
        log "env.test is stale — its Issuer DID is not published here; provisioning again"
        rm -f "$ENV_FILE"
    fi
else
    log "no env.test; provisioning from scratch"
fi

# ═══════════════════════════════════════════════════════════
# 4. DIDs
# ═══════════════════════════════════════════════════════════

# Create a DID and hand back the identifier to use it by. A published DID is
# named by its short form; an unpublished one by its long form, which carries
# the create operation and so resolves without the ledger.
create_did() {
    local base=$1 template=$2 label=$3

    local did
    did=$(api GET "${base}/did-registrar/dids" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for c in d.get("contents", []):
    if c.get("status") == "PUBLISHED":
        print(c["did"]); sys.exit(0)
for c in d.get("contents", []):
    if c.get("longFormDid"):
        print(c["longFormDid"]); sys.exit(0)
' 2>/dev/null)

    if [ -n "$did" ]; then
        log "✓ $label DID exists: ${did:0:60}..."
        echo "$did"
        return 0
    fi

    log "creating the $label DID..."
    local resp
    resp=$(api POST "${base}/did-registrar/dids" "$template")
    did=$(echo "$resp" | jget longFormDid)
    [ -n "$did" ] || { echo "  ERROR: $label DID creation failed: $resp" >&2; return 1; }
    echo "$did"
}

# Publish a DID and wait for it to settle. Only the Issuer gets this: nothing
# about the Holder belongs on the ledger, and the long form resolves without it,
# so the Holder stays uncorrelatable across authentications.
publish_did() {
    local base=$1 did=$2 label=$3 resp status

    status=$(api GET "${base}/did-registrar/dids/${did}" | jget status)
    if [ "$status" = "PUBLISHED" ]; then
        log "✓ $label DID already published"
        echo "$did"
        return 0
    fi

    log "publishing the $label DID..."
    api POST "${base}/did-registrar/dids/${did}/publications" >/dev/null

    local i
    for i in $(seq 1 40); do
        resp=$(api GET "${base}/did-registrar/dids/${did}")
        status=$(echo "$resp" | jget status)
        if [ "$status" = "PUBLISHED" ]; then
            log "✓ $label DID published"
            # A published DID is named by its short form from here on
            echo "$resp" | jget did
            return 0
        fi
        echo "    $label state=$status ($i/40)..." >&2
        sleep 3
    done
    echo "  WARNING: $label DID still $status after 40 attempts" >&2
    echo "$did"
}

if [ "$NEEDS_PROVISION" -eq 1 ]; then

step "Creating the DIDs (only the Issuer is published)"

ISSUER_DID=$(create_did "$ISSUER_URL" \
    '{"documentTemplate":{"publicKeys":[{"id":"issuanceKey","purpose":"assertionMethod"}],"services":[]}}' \
    "Issuer") || die "could not create the Issuer DID"
ISSUER_DID=$(publish_did "$ISSUER_URL" "$ISSUER_DID" "Issuer")

HOLDER_DID=$(create_did "$HOLDER_URL" \
    '{"documentTemplate":{"publicKeys":[{"id":"authKey","purpose":"authentication"}],"services":[]}}' \
    "Holder") || die "could not create the Holder DID"

[ -n "$ISSUER_DID" ] && [ -n "$HOLDER_DID" ] || die "empty DID"
log "Issuer: $ISSUER_DID"
log "Holder: ${HOLDER_DID:0:60}... (unpublished, by design)"

# ═══════════════════════════════════════════════════════════
# 5. The DIDComm connection between the Holder and the Issuer
# ═══════════════════════════════════════════════════════════
#
# This connection belongs to enrolment and to nothing else. It is the channel
# the credential is offered and delivered over, it lives on provision-net, and
# it is gone before the script returns. The Verifier is not party to it and no
# connection to a Verifier is ever pre-established: the visited institution
# mints a fresh invitation, and a fresh peer DID, for every authentication.

# Print "<connectionId> <state>" for the newest connection record in the wanted
# state, or for the newest record of any state if there is none.
newest_connection() {
    local base=$1 wanted=$2
    api GET "${base}/connections" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
wanted = sys.argv[1]
records = sorted(d.get("contents", []), key=lambda c: c.get("createdAt", ""))
match = [c for c in records if c.get("state") == wanted]
chosen = (match or records)[-1:]
for c in chosen:
    print(c.get("connectionId", c.get("id", "")), c.get("state", ""))
' "$wanted" 2>/dev/null
}

step "Establishing the DIDComm connection between the Holder and the Issuer"

CONN_ID="" CONN_STATE=""
read -r CONN_ID CONN_STATE <<<"$(newest_connection "$ISSUER_URL" "$INVITER_ESTABLISHED")" || true

if [ "$CONN_STATE" = "$INVITER_ESTABLISHED" ]; then
    log "✓ connection already established ($CONN_STATE)"
else
    log "no established connection; the Issuer is issuing an OOB invitation..."

    INV_RESP=$(api POST "${ISSUER_URL}/connections" '{"label":"issuer-to-holder"}')
    INVITE_URL=$(echo "$INV_RESP" | jget invitation invitationUrl)
    [ -n "$INVITE_URL" ] || INVITE_URL=$(echo "$INV_RESP" | jget invitationUrl)
    [ -n "$INVITE_URL" ] || die "no invitation URL in the response: $INV_RESP"

    # The invitation travels as the _oob query parameter, percent-encoded
    OOB_BASE64=$(INVITE_URL="$INVITE_URL" python3 -c '
import os, sys, urllib.parse
url = os.environ["INVITE_URL"]
if "_oob=" not in url:
    sys.exit(0)
print(urllib.parse.unquote(url.split("_oob=", 1)[1]))
' 2>/dev/null)
    [ -n "$OOB_BASE64" ] || die "no _oob payload in the invitation URL"
    log "invitation: ${#OOB_BASE64} octets"

    ACCEPT_RESP=$(api POST "${HOLDER_URL}/connection-invitations" \
        "$(OOB="$OOB_BASE64" python3 -c 'import json, os; print(json.dumps({"invitation": os.environ["OOB"]}))')")
    log "Holder accepted: $(echo "$ACCEPT_RESP" | jget state)"

    # Both machines have to arrive: the Issuer at ConnectionResponseSent, the
    # Holder at ConnectionResponseReceived. Those are terminal — waiting for
    # anything past them waits forever.
    CONN_OK=0
    HOLDER_STATE=""
    for i in $(seq 1 20); do
        CONN_ID="" CONN_STATE="" HOLDER_STATE=""
        read -r CONN_ID CONN_STATE <<<"$(newest_connection "$ISSUER_URL" "$INVITER_ESTABLISHED")" || true
        read -r _ HOLDER_STATE     <<<"$(newest_connection "$HOLDER_URL" "$INVITEE_ESTABLISHED")" || true
        log "Issuer=${CONN_STATE:-none} Holder=${HOLDER_STATE:-none} ($i/20)"
        if [ "$CONN_STATE" = "$INVITER_ESTABLISHED" ] && [ "$HOLDER_STATE" = "$INVITEE_ESTABLISHED" ]; then
            CONN_OK=1
            break
        fi
        sleep 3
    done
    [ "$CONN_OK" -eq 1 ] || die "connection not established (Issuer=${CONN_STATE:-none} Holder=${HOLDER_STATE:-none})"
    log "✓ connection established"
fi

[ -n "${CONN_ID:-}" ] || die "no connection id"
log "connection: $CONN_ID"

# ═══════════════════════════════════════════════════════════
# 6. The schema
# ═══════════════════════════════════════════════════════════

step "Defining the credential schema"

# The name carries a timestamp because a schema is immutable and its name is
# unique per author; reusing one across provisionings is rejected. The author
# must be the Issuer DID, or the registry refuses the document.
SCHEMA_BODY=$(ISSUER_DID="$ISSUER_DID" python3 -c '
import json, os, time
print(json.dumps({
    "name": "eduroam-cred-%d" % time.time(),
    "version": "1.0.0",
    "tags": ["eduroam"],
    "type": "https://w3c-ccg.github.io/vc-json-schemas/schema/2.0/schema.json",
    "schema": {
        "$id": "https://example.com/eduroam-1.0",
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "properties": {
            "name": {"type": "string"},
            "institution": {"type": "string"},
        },
        "required": ["name"],
        "additionalProperties": False,
    },
    "author": os.environ["ISSUER_DID"],
}))
')

SCHEMA_GUID=""
for attempt in 1 2 3; do
    SCHEMA_RESP=$(api POST "${ISSUER_URL}/schema-registry/schemas" "$SCHEMA_BODY")
    SCHEMA_GUID=$(echo "$SCHEMA_RESP" | jget guid)
    [ -n "$SCHEMA_GUID" ] && break
    log "attempt $attempt failed, retrying in 5s: ${SCHEMA_RESP:0:120}"
    sleep 5
done
[ -n "$SCHEMA_GUID" ] || die "schema creation failed after 3 attempts: $SCHEMA_RESP"
log "✓ schema $SCHEMA_GUID"

# Named by the URL the agents resolve it at, not the one the host does: this
# goes into the credential and into the presentation request.
SCHEMA_URL="http://caddy-issuer:8080/cloud-agent/schema-registry/schemas/${SCHEMA_GUID}/schema"

# ═══════════════════════════════════════════════════════════
# 7. The credential
# ═══════════════════════════════════════════════════════════

step "Issuing the credential"

OFFER_BODY=$(ISSUER_DID="$ISSUER_DID" CONN_ID="$CONN_ID" SCHEMA_URL="$SCHEMA_URL" python3 -c '
import json, os
print(json.dumps({
    "claims": {"name": "Test User", "institution": "Universidade Federal"},
    "credentialFormat": "JWT",
    "issuingDID": os.environ["ISSUER_DID"],
    "connectionId": os.environ["CONN_ID"],
    "schemaId": os.environ["SCHEMA_URL"],
}))
')

OFFER_RESP=$(api POST "${ISSUER_URL}/issue-credentials/credential-offers" "$OFFER_BODY")
OFFER_THID=$(echo "$OFFER_RESP" | jget thid)
[ -n "$OFFER_THID" ] || die "credential offer rejected: $OFFER_RESP"
log "offer thid=$OFFER_THID"

CRED_ID=""
for i in $(seq 1 15); do
    CRED_ID=$(api GET "${HOLDER_URL}/issue-credentials/records?thid=${OFFER_THID}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for c in d.get("contents", []):
    if c.get("protocolState") in ("OfferReceived", "ProposalReceived", "RequestReceived"):
        print(c["recordId"]); sys.exit(0)
' 2>/dev/null)
    [ -n "$CRED_ID" ] && break
    sleep 2
done
[ -n "$CRED_ID" ] || die "the Holder never received the offer"

# The subject is a DID of the Holder's own agent: Identus signs the credential
# request with a key its wallet controls, so the subject cannot be a DID minted
# anywhere else.
api POST "${HOLDER_URL}/issue-credentials/records/${CRED_ID}/accept-offer" \
    "$(HOLDER_DID="$HOLDER_DID" python3 -c 'import json, os; print(json.dumps({"subjectId": os.environ["HOLDER_DID"]}))')" >/dev/null
log "offer accepted, subject ${HOLDER_DID:0:40}..."

CRED_STATE=""
for i in $(seq 1 20); do
    CRED_STATE=$(api GET "${HOLDER_URL}/issue-credentials/records/${CRED_ID}" | jget protocolState)
    [ "$CRED_STATE" = "CredentialReceived" ] && break
    sleep 2
done
[ "$CRED_STATE" = "CredentialReceived" ] || die "credential not received (state=$CRED_STATE)"
log "✓ credential received"

# ═══════════════════════════════════════════════════════════
# 8. The keys
# ═══════════════════════════════════════════════════════════

step "Lifting the Holder's keys out of the wallet"

# On a real device the wallet would hold these and nothing would be extracted.
# The supplicant here is a separate process from the agent that owns the keys,
# so they are read out of its database — see doc/model-d-architecture.md §3.
bash "$SCRIPT_DIR/scripts/extract-did5-keys.sh" >/dev/null 2>&1 \
    || log "WARNING: key extraction reported an error"

read_key() { [ -f "$DID_KEYS_DIR/$1" ] && cat "$DID_KEYS_DIR/$1" || true; }

PEER_HOLDER_DID=$(read_key holder_did.txt)
X25519_PRIV=$(read_key holder_x25519_priv.b64url)
X25519_PUB=$(read_key holder_x25519_pub.b64url)
SECP256K1_PRIV=$(read_key holder_secp256k1_priv.b64url)
PRISM_KEY_ID=$(read_key holder_prism_key_id.txt)

[ -s "$DID_KEYS_DIR/credential.jwt" ] || die "no credential JWT was extracted"
[ -n "$PEER_HOLDER_DID" ] || die "no peer DID was extracted; the supplicant has no messaging identity"
[ -n "$X25519_PRIV" ] && [ -n "$X25519_PUB" ] \
    || die "no X25519 key pair was extracted; the supplicant cannot encrypt the presentation"
[ -n "$SECP256K1_PRIV" ] \
    || die "no secp256k1 key was extracted; the presentation would be issued by the peer DID and the Verifier would reject it"
log "✓ peer DID, X25519 pair, secp256k1 authentication key, credential"

# Files from the two-recipient scheme, when the presentation was also encrypted
# for a DID of the authenticator's own. It unwraps the Verifier entry now, and
# leaving these behind invites something to pick up a key that means nothing.
rm -f "$DID_KEYS_DIR"/auth_did.txt "$DID_KEYS_DIR"/auth_x25519_*.b64url \
      "$DID_KEYS_DIR"/verifier_did.txt "$DID_KEYS_DIR"/verifier_x25519_*.b64url

# ═══════════════════════════════════════════════════════════
# 9. env.test
# ═══════════════════════════════════════════════════════════

step "Writing env.test"
cat > "$ENV_FILE" <<ENVEOF
# EAP-DID testbed configuration — generated by provision.sh
# $(date -Iseconds)
ISSUER_DID=${ISSUER_DID}
HOLDER_DID=${HOLDER_DID}
SCHEMA_ID=${SCHEMA_URL}
SCHEMA_GUID=${SCHEMA_GUID}
CRED_ID=${CRED_ID}
CONN_ID=${CONN_ID}
# The Holder's messaging identity, used by the standalone supplicant. The
# private keys are not here: they are mounted from did-keys/ and named by
# DID_*_FILE in the compose file, because a key in the environment is readable
# through /proc, inherited by children and printed by ps e.
DID_HOLDER_DID=${PEER_HOLDER_DID}
DID_PRISM_KEY_ID=${PRISM_KEY_ID}
ENVEOF
log "✓ $ENV_FILE"

fi  # NEEDS_PROVISION

# ═══════════════════════════════════════════════════════════
# 10. Verification
# ═══════════════════════════════════════════════════════════

# Checked with provision-net still up, so that every internal reference in
# env.test resolves the way the agents will resolve it.
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

step "Verifying what was provisioned"

OK_ISSUER=0 OK_HOLDER=0 OK_CRED=0 OK_SCHEMA=0

# The Issuer is the one identifier that must be on the ledger: a verifier that
# has never met it resolves it there and nowhere else.
for i in $(seq 1 30); do
    [ "$(api GET "${ISSUER_URL}/did-registrar/dids/${ISSUER_DID}" | jget status)" = "PUBLISHED" ] \
        && { OK_ISSUER=1; break; }
    sleep 2
done
[ "$OK_ISSUER" -eq 1 ] && log "✓ Issuer DID published" || log "⚠ Issuer DID not published"

# The Holder is the one identifier that must not be. It only has to exist.
HOLDER_STATUS=$(api GET "${HOLDER_URL}/did-registrar/dids/${HOLDER_DID}" | jget status)
if [ -n "$HOLDER_STATUS" ]; then
    OK_HOLDER=1
    log "✓ Holder DID present, $HOLDER_STATUS (unpublished, by design)"
else
    log "⚠ Holder DID does not resolve"
fi

if [ -n "${CRED_ID:-}" ]; then
    CRED_STATE=$(api GET "${HOLDER_URL}/issue-credentials/records/${CRED_ID}" | jget protocolState)
    if [ "$CRED_STATE" = "CredentialReceived" ]; then
        OK_CRED=1
        log "✓ credential held by the Holder"
    else
        log "⚠ credential state is ${CRED_STATE:-absent}"
    fi
fi

if [ -n "${SCHEMA_ID:-}" ]; then
    SCHEMA_HOST_URL=${SCHEMA_ID/caddy-issuer:8080/127.0.0.1:8080}
    for i in $(seq 1 15); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' "$SCHEMA_HOST_URL" 2>/dev/null)" = "200" ] \
            && { OK_SCHEMA=1; break; }
        sleep 2
    done
    [ "$OK_SCHEMA" -eq 1 ] && log "✓ schema resolvable" || log "⚠ schema not resolvable"
fi

# ═══════════════════════════════════════════════════════════
# 11. The EAP segment
# ═══════════════════════════════════════════════════════════

# Enrolment is the last moment before the device is on its own, so it is the
# right moment to find out that the segment it will be on is what the design
# says. The declaration is checked here because a careless compose edit is
# invisible until an authentication succeeds over a path that should not
# exist; the running segment is checked too, when there is one. isolation.sh
# does the rest, against a device that does not cooperate.
step "Checking the EAP segment is declared as a wire"

OK_SEGMENT=0
COMPOSE_JSON=$("${COMPOSE[@]}" --profile eap config --format json 2>/dev/null || true)
if [ -z "$COMPOSE_JSON" ]; then
    log "⚠ could not read the compose configuration; skipped"
else
    SEGMENT_ERRORS=$(echo "$COMPOSE_JSON" | python3 -c '
import json, sys

d = json.load(sys.stdin)
net = d.get("networks", {}).get("eapol-net")
bad = []

if net is None:
    bad.append("eapol-net is not declared")
else:
    opts = net.get("driver_opts") or {}
    if not net.get("internal"):
        bad.append("eapol-net is not internal: it has a route off the segment")
    if str(opts.get("com.docker.network.bridge.inhibit_ipv4", "")).lower() != "true":
        bad.append("inhibit_ipv4 is not set: the bridge would take an address "
                   "and the host would be on the segment")

for name, svc in (d.get("services") or {}).items():
    attach = (svc.get("networks") or {}).get("eapol-net") or {}
    if isinstance(attach, dict) and (attach.get("ipv4_address") or attach.get("ipv6_address")):
        bad.append("%s pins an address on eapol-net" % name)

print("\n".join(bad))
' 2>/dev/null || true)

    if [ -n "$SEGMENT_ERRORS" ]; then
        echo "$SEGMENT_ERRORS" | while read -r line; do [ -n "$line" ] && log "⚠ $line"; done
    else
        OK_SEGMENT=1
        log "✓ eapol-net is internal, address-less, and no service pins an address on it"
    fi
fi

# If the EAP layer happens to be up — `make test` provisions first, so usually
# it is not — the ACL that enforces all of the above is verifiable right now.
if docker image inspect swarm-testbed:latest >/dev/null 2>&1 \
   && docker network inspect swarm-testbed_eapol-net >/dev/null 2>&1; then
    GUARD_RC=0
    GUARD_OUT=$(docker run --rm --network host --cap-add NET_ADMIN \
        -v "$SCRIPT_DIR/scripts/eapol-guard.sh:/eapol-guard.sh:ro" \
        --entrypoint /bin/sh swarm-testbed:latest /eapol-guard.sh check 2>&1) || GUARD_RC=$?
    echo "$GUARD_OUT" | sed 's/^\[eapol-guard\] /  /' >&2
    if [ "$GUARD_RC" -eq 0 ]; then
        log "✓ the running segment matches the declaration"
    else
        log "⚠ the running segment does not match the declaration"
        OK_SEGMENT=0
    fi
else
    log "- the EAP layer is down; isolation.sh checks the ACL when it brings it up"
fi

# ═══════════════════════════════════════════════════════════
# 12. Done
# ═══════════════════════════════════════════════════════════

step "Closing provision-net"
provision_net_down
trap - EXIT
log "✓ the device can no longer reach the Issuer or the ledger"

echo ""
if [ "$((OK_ISSUER + OK_HOLDER + OK_CRED + OK_SCHEMA + OK_SEGMENT))" -eq 5 ]; then
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ✅ Provisioned — ready to authenticate      ║"
    echo "╚══════════════════════════════════════════════╝"
else
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ⚠  Provisioned with warnings                ║"
    echo "╚══════════════════════════════════════════════╝"
fi
echo ""
cat "$ENV_FILE"
echo ""
echo "Next: ./auth.sh --method did       (logs: ./logs.sh all)"
