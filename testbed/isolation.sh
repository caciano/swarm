#!/bin/bash
set -uo pipefail

# ============================================================
# isolation.sh — prove the boundaries the design claims
#
# Model D rests on the device having no path to the home institution, to the
# ledger, or to the visited institution's machinery once enrolment is over: the
# EAP channel is all it gets. `make test` shows that authentication succeeds. It
# cannot show that it succeeds for the right reason, and this project has been
# fooled by that difference before.
#
# So this asserts the topology instead of trusting it. Every probe runs from
# inside the network namespace of the container it is about, using the testbed
# image for its tools, and every expectation is stated in both directions:
# what must be reachable is as much a part of the claim as what must not.
#
# The EAP segment gets a section of its own, because there the claim is not
# about routing but about there being no IP layer at all: no address on the
# bridge, none on either port, and an ACL that carries EAPoL and drops the
# rest. That one is checked against a device that does not cooperate — it puts
# the addresses back and tries to use them — since a boundary that only holds
# while both ends behave is not a boundary. See scripts/eapol-guard.sh.
#
# Usage:
#   ./isolation.sh            probe, report, exit non-zero on any violation
#   ./isolation.sh --keep-eap leave the EAP layer up afterwards
#
# Run it after provision.sh and before auth.sh: the supplicant needs the
# credential that provisioning leaves in did-keys/.
# ============================================================

# The header block above is the usage message.
usage() { sed -n '/^# =\+$/,/^# =\+$/{/^# =\+$/d;s/^# \?//;p}' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE=(docker compose -f docker-compose.yml)
IMAGE=swarm-testbed:latest

KEEP_EAP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keep-eap) KEEP_EAP=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "Usage: $0 [--keep-eap]" >&2; exit 1 ;;
    esac
done

log()  { echo "  $*"; }
die()  { echo "  ERROR: $*" >&2; exit 1; }

VIOLATIONS=0

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  EAP-DID isolation                           ║"
echo "╚══════════════════════════════════════════════╝"

# ── The probe ──

# Answers one question per target: can this network namespace open a TCP
# connection to it. Name resolution failing is an answer too — in a compose
# deployment a name that does not resolve is a name on a network we are not on
# — and it is reported separately, because "unresolved" and "refused" fail for
# different reasons and the difference is worth seeing when a probe surprises.
PROBE=$(cat <<'PY'
import socket, sys

for target in sys.argv[1:]:
    host, _, port = target.partition(":")
    try:
        addr = socket.gethostbyname(host)
    except OSError:
        print("%s unresolved" % target)
        continue
    s = socket.socket()
    s.settimeout(2)
    try:
        s.connect((addr, int(port)))
        print("%s reachable" % target)
    except OSError:
        print("%s refused" % target)
    finally:
        s.close()
PY
)

# Run the probe inside another container's network namespace. The tools are
# ours, the network is theirs, and nothing is assumed about the image the
# subject runs — the Cloud Agents carry no interpreter we could rely on.
probe_in_netns() {
    local cid=$1; shift
    docker run --rm --network "container:$cid" --entrypoint python3 \
        "$IMAGE" -c "$PROBE" "$@" 2>/dev/null
}

# The same idea for anything else: a command of ours, in their namespace. The
# capabilities are needed by the frames-and-addresses probes further down,
# which have to be able to configure what they are testing.
in_netns() {
    local cid=$1 bin=$2; shift 2
    docker run --rm --network "container:$cid" \
        --cap-add NET_ADMIN --cap-add NET_RAW \
        --entrypoint "$bin" "$IMAGE" "$@" 2>/dev/null
}

# The bridge and its ACL are the host's, not any container's.
guard() {
    docker run --rm --network host --cap-add NET_ADMIN \
        -v "$SCRIPT_DIR/scripts/eapol-guard.sh:/eapol-guard.sh:ro" \
        --entrypoint /bin/sh "$IMAGE" /eapol-guard.sh "$@" 2>&1
}

# Which interface of a container is its port on the EAP segment. It cannot be
# found by address — the whole point is that it has none — so it is found by
# the MAC Docker recorded for that attachment.
eap_iface() {
    local cid=$1 mac
    mac=$(docker inspect -f \
        '{{with index .NetworkSettings.Networks "swarm-testbed_eapol-net"}}{{.MacAddress}}{{end}}' \
        "$cid" 2>/dev/null)
    [ -n "$mac" ] || return 1
    # Reported only if it is a name the namespace actually has: everything
    # downstream reads "no address on this interface" as a passing check, and
    # a name that does not exist would pass it without meaning anything.
    in_netns "$cid" /bin/sh -c \
        "n=\$(ip -o link | grep -i ' $mac ' | sed 's/^[0-9]*: //; s/[@:].*//' | head -1);
         [ -n \"\$n\" ] && ip link show dev \"\$n\" >/dev/null 2>&1 && echo \"\$n\""
}

eapol_count() { guard counters | sed -n 's/.*eapol=\([0-9]*\).*/\1/p'; }

blocked_count() { guard counters | sed -n 's/.*blocked=\([0-9]*\).*/\1/p'; }

# Compare a probe's answers with what the topology says they should be.
# Expectations arrive as "target=reachable" or "target=blocked".
expect() {
    local subject=$1 output=$2; shift 2
    local spec target want got line

    for spec in "$@"; do
        target="${spec%%=*}"
        want="${spec##*=}"
        line=$(echo "$output" | grep -F "$target " | head -1)
        got="${line##* }"
        [ -n "$got" ] || got="no answer"

        # Anything short of an open connection is the boundary holding.
        case "$got" in
            reachable) got=reachable ;;
            *)         got=blocked ;;
        esac

        if [ "$got" = "$want" ]; then
            log "✓ $target $want"
        else
            log "✗ $target is $got, must be $want    [$subject]"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    done
}

container_id() {
    local svc=$1 cid
    cid=$("${COMPOSE[@]}" --profile identus --profile eap ps -q "$svc" 2>/dev/null | head -1)
    [ -n "$cid" ] || die "$svc is not running"
    echo "$cid"
}

# ── The subjects ──

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "$IMAGE is not built; run: make build or docker compose --profile eap build"

echo ""
echo "[1/5] Bringing the EAP layer up"
[ -s did-keys/credential.jwt ] \
    || die "no credential in did-keys/; run ./provision.sh first"
"${COMPOSE[@]}" --profile eap up -d --wait >/dev/null 2>&1 \
    || die "the EAP layer did not start"
log "✓ supplicant and authradius running"

SUPPLICANT_CID=$(container_id supplicant)
AUTHRADIUS_CID=$(container_id authradius)
HOLDER_CID=$(container_id agent-holder)
VERIFIER_CID=$(container_id agent-verifier)

# The endpoints an attacker — or a careless compose edit — would want the
# device to have. None of them is on device-net, and none may become so.
OFF_LIMITS=(
    caddy-issuer:8080
    agent-issuer:8085
    caddy-verifier:8082
    agent-verifier:8085
    verifier-keys:8090
    node:50053
)

echo ""
echo "[2/5] The EAP segment is a wire, not a network"

# What the deployment claims about eapol-net is not that the device chooses not
# to use IP on it, but that there is no IP on it to use: no address on the
# bridge, none on either port, and a bridge ACL that drops every ethertype but
# EAPoL. The three are checked separately because each fails on its own — an
# address restored by hand is invisible to the second check, and an ACL that
# was never loaded is invisible to the first two.
GUARD_OUT=$(guard check); GUARD_RC=$?
echo "$GUARD_OUT" | sed 's/^\[eapol-guard\] /  /'
[ "$GUARD_RC" -eq 0 ] || VIOLATIONS=$((VIOLATIONS + GUARD_RC))

SUPPLICANT_IF=$(eap_iface "$SUPPLICANT_CID" || true)
AUTHRADIUS_IF=$(eap_iface "$AUTHRADIUS_CID" || true)

for pair in "supplicant:$SUPPLICANT_CID:$SUPPLICANT_IF" "authradius:$AUTHRADIUS_CID:$AUTHRADIUS_IF"; do
    name="${pair%%:*}"; rest="${pair#*:}"; cid="${rest%%:*}"; iface="${rest##*:}"
    if [ -z "$iface" ]; then
        log "✗ $name has no identifiable port on eapol-net"
        VIOLATIONS=$((VIOLATIONS + 1))
        continue
    fi
    if in_netns "$cid" ip -o addr show dev "$iface" | grep -qE ' inet | inet6 '; then
        log "✗ $name: $iface carries an address —"
        in_netns "$cid" ip -br addr show dev "$iface" | sed 's/^/      /'
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        log "✓ $name: $iface carries no address"
    fi
done

# The uncooperative device. Nothing above stops a supplicant from configuring
# the address the pool would have given it and using the segment as a LAN, and
# a claim that rests on the entrypoint's good manners is not a claim. So: put
# the addresses back on both ends and try. The ACL is what has to answer.
if [ -n "$SUPPLICANT_IF" ] && [ -n "$AUTHRADIUS_IF" ]; then
    BLOCKED_BEFORE=$(blocked_count)
    in_netns "$SUPPLICANT_CID" ip addr add 172.30.0.20/24 dev "$SUPPLICANT_IF" >/dev/null 2>&1 || true
    in_netns "$AUTHRADIUS_CID" ip addr add 172.30.0.10/24 dev "$AUTHRADIUS_IF" >/dev/null 2>&1 || true

    if in_netns "$SUPPLICANT_CID" ping -c 2 -W 2 172.30.0.10 >/dev/null 2>&1; then
        log "✗ IP reaches the authenticator over the EAP segment"
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        log "✓ a self-addressed device gets no IP across the segment"
    fi

    BLOCKED_AFTER=$(blocked_count)
    if [ "${BLOCKED_AFTER:-0}" -gt "${BLOCKED_BEFORE:-0}" ]; then
        log "✓ the ACL dropped them ($((BLOCKED_AFTER - BLOCKED_BEFORE)) frames)"
    else
        log "✗ nothing was dropped; the frames did not reach the ACL, or it is not loaded"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi

    in_netns "$SUPPLICANT_CID" ip addr flush dev "$SUPPLICANT_IF" >/dev/null 2>&1 || true
    in_netns "$AUTHRADIUS_CID" ip addr flush dev "$AUTHRADIUS_IF" >/dev/null 2>&1 || true
fi

# The positive half: the device is isolated, not unplugged. The old form of
# this check pinged the authenticator, which is exactly what must now fail, so
# it asks the question at the layer the segment actually carries — an EAPoL
# frame out, an EAPoL frame back. The window is generous because the
# authenticator's hostapd waits for the RADIUS one before it listens, and this
# section runs seconds after the containers started.
EAPOL_PROBE=$(cat <<'PY'
import socket, struct, sys, time

iface = sys.argv[1]
PAE_GROUP = b"\x01\x80\xc2\x00\x00\x03"   # the 802.1X PAE group address
ETH_P_PAE = 0x888e

with open("/sys/class/net/%s/address" % iface) as f:
    mac = bytes.fromhex(f.read().strip().replace(":", ""))

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_PAE))
s.bind((iface, ETH_P_PAE))
s.settimeout(1.0)

# EAPOL-Start: version 2, type 1 (Start), length 0. An authenticator that hears
# it restarts authentication, so a reply is an answer about the whole path.
frame = PAE_GROUP + mac + struct.pack("!H", ETH_P_PAE) + b"\x02\x01\x00\x00"

deadline = time.time() + 30
next_send = 0.0
while time.time() < deadline:
    if time.time() >= next_send:
        s.send(frame)
        next_send = time.time() + 2
    try:
        pkt, addr = s.recvfrom(2048)
    except socket.timeout:
        continue
    # addr[2] is sll_pkttype; 4 is PACKET_OUTGOING, our own frames looping back
    if addr[2] == 4 or pkt[6:12] == mac:
        continue
    print("answered by %s" % pkt[6:12].hex(":"))
    sys.exit(0)

print("no eapol frame arrived")
sys.exit(1)
PY
)

if [ -n "$SUPPLICANT_IF" ]; then
    EAPOL_BEFORE=$(eapol_count)
    OUT=$(docker run --rm --network "container:$SUPPLICANT_CID" --cap-add NET_RAW \
        --entrypoint python3 "$IMAGE" -c "$EAPOL_PROBE" "$SUPPLICANT_IF" 2>&1)
    PROBE_RC=$?
    EAPOL_AFTER=$(eapol_count)

    if [ "$PROBE_RC" -eq 0 ]; then
        log "✓ EAPoL crosses the segment and the authenticator answers ($OUT)"
    else
        log "✗ EAPoL does not cross the segment — the EAP channel itself is gone"
        log "  $OUT"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi

    # Which half broke: the frames leaving the device, or the reply. The ACL
    # counts what it forwarded, so it can tell them apart.
    if [ "${EAPOL_AFTER:-0}" -gt "${EAPOL_BEFORE:-0}" ]; then
        log "✓ the ACL forwarded them ($((EAPOL_AFTER - EAPOL_BEFORE)) frames)"
    else
        log "✗ the ACL forwarded no EAPoL at all"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
fi

echo ""
echo "[3/5] The supplicant sees only the authenticator"
OUT=$(probe_in_netns "$SUPPLICANT_CID" "${OFF_LIMITS[@]}")
expect supplicant "$OUT" \
    caddy-issuer:8080=blocked \
    agent-issuer:8085=blocked \
    caddy-verifier:8082=blocked \
    agent-verifier:8085=blocked \
    verifier-keys:8090=blocked \
    node:50053=blocked

echo ""
echo "[4/5] The wallet is as isolated as the supplicant"
# The wallet holds the credential and the keys. If it can still reach the
# Issuer, provisioning left a door open and the device is enrolled forever.
OUT=$(probe_in_netns "$HOLDER_CID" "${OFF_LIMITS[@]}")
expect agent-holder "$OUT" \
    caddy-issuer:8080=blocked \
    agent-issuer:8085=blocked \
    caddy-verifier:8082=blocked \
    agent-verifier:8085=blocked \
    verifier-keys:8090=blocked \
    node:50053=blocked

echo ""
echo "[5/5] The visited institution reaches the public, and nothing private"
# The Verifier resolves the Issuer's DID on the ledger and fetches the schema
# and status list the credential names. Those are public documents over a
# public path, and they are the only things it is entitled to.
OUT=$(probe_in_netns "$VERIFIER_CID" \
    caddy-issuer:8080 node:50053 caddy-holder:8081 agent-holder:8085 db-issuer:5432)
expect agent-verifier "$OUT" \
    caddy-issuer:8080=reachable \
    node:50053=reachable \
    caddy-holder:8081=blocked \
    agent-holder:8085=blocked \
    db-issuer:5432=blocked

if [ "$KEEP_EAP" -eq 0 ]; then
    "${COMPOSE[@]}" --profile eap down >/dev/null 2>&1 || true
fi

echo ""
if [ "$VIOLATIONS" -eq 0 ]; then
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ✅ Isolated — the boundaries hold           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    exit 0
fi

echo "╔══════════════════════════════════════════════╗"
printf "║  ❌ %-41s║\n" "$VIOLATIONS boundary violation(s)"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "A reachable endpoint here means an authentication that appears to succeed"
echo "may be succeeding over a path the design says does not exist."
echo ""
exit 1
