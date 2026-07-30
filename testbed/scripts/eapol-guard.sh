#!/bin/sh
set -eu

# ============================================================
# eapol-guard.sh — make the EAP segment a wire, and keep it one
#
# In a real deployment the segment between a device and the authenticator is
# not a network. It is the uncontrolled port of an 802.1X authenticator: no
# address on either end, no router, and nothing on it but EAPoL until the
# authenticator opens the controlled port. The testbed has to model that, or
# every isolation claim it makes rests on the device politely not using an IP
# stack that is sitting right there.
#
# Docker's bridge driver will not create a network without an IPAM pool, so the
# pool stays declared and three things take its meaning away:
#
#   1. com.docker.network.bridge.inhibit_ipv4 keeps the address off the bridge
#      itself, so the host is not on the segment and there is no gateway.
#   2. The entrypoints flush the address Docker assigns before hostapd or
#      wpa_supplicant start, so neither port carries one.
#   3. This script installs the ACL that makes 1 and 2 enforced rather than
#      merely observed: an nftables bridge-family chain on the testbed bridge
#      that accepts EAPoL and drops every other ethertype. A device that
#      configures an address on its own gets no further than one that does not.
#
# The filter is bridge family, so it sees frames as they are forwarded between
# ports of the bridge, before any IP layer is involved. It matches on the
# bridge name, so it is inert on every other bridge on the host — including the
# other Docker networks of this same deployment.
#
# Usage:
#   eapol-guard.sh apply    [bridge]   wait for the bridge, configure, verify
#   eapol-guard.sh check    [bridge]   verify only; non-zero if anything is off
#   eapol-guard.sh counters [bridge]   "eapol=<n> blocked=<n>", for tests
#   eapol-guard.sh clear    [bridge]   remove the ACL
#
# Runs anywhere the host network namespace is: on the host as root, or in a
# container with `--network host --cap-add NET_ADMIN`, which is how the
# init-bridge service runs it.
# ============================================================

BR="${2:-${EAPOL_BRIDGE:-swarm-br0}}"
TABLE=swarm_eapol

# 0x888e is EAPoL (IEEE 802.1X). Everything else — ARP, IPv4, IPv6 — is what
# the device must not be able to send while it is unauthenticated, and what
# this deployment claims it cannot send at all.
EAPOL_ETHERTYPE=0x888e

# The PAE group address 01:80:C2:00:00:03 is in the reserved range a bridge
# does not forward by default. Bit 3 of group_fwd_mask is the exemption for it,
# and without it EAPoL never reaches the other port.
GROUP_FWD_MASK=0x8

log() { echo "[eapol-guard] $*"; }
die() { echo "[eapol-guard] ERROR: $*" >&2; exit 1; }

need_nft() {
    command -v nft >/dev/null 2>&1 \
        || die "nft is not installed; the image needs the nftables package"
}

wait_for_bridge() {
    i=1
    while [ "$i" -le 30 ]; do
        if ip link show "$BR" >/dev/null 2>&1; then
            return 0
        fi
        log "waiting for $BR ..."
        sleep 1
        i=$((i + 1))
    done
    die "$BR did not appear; is the eapol-net network up?"
}

install_acl() {
    need_nft
    # -f adds to an existing table rather than replacing it, so a re-run would
    # stack duplicate rules. Start from nothing.
    nft delete table bridge "$TABLE" 2>/dev/null || true
    nft -f - <<NFT
table bridge $TABLE {
    counter eapol {}
    counter blocked {}

    chain forward {
        type filter hook forward priority -200; policy accept;

        # Every other bridge on this host, Docker's own included, is none of
        # our business.
        meta ibrname != "$BR" accept

        ether type $EAPOL_ETHERTYPE counter name eapol accept
        counter name blocked drop
    }
}
NFT
}

# Both halves of the claim: the ACL is loaded, and there is no address on the
# segment for it to have to protect in the first place.
check() {
    need_nft
    rc=0

    ip link show "$BR" >/dev/null 2>&1 || die "$BR does not exist"

    if ip -4 addr show dev "$BR" 2>/dev/null | grep -q 'inet '; then
        echo "[eapol-guard] ✗ $BR carries an IPv4 address; the host is on the EAP segment" >&2
        rc=1
    else
        log "✓ $BR has no address — the host is not on the segment"
    fi

    mask=$(cat "/sys/class/net/$BR/bridge/group_fwd_mask" 2>/dev/null || echo "")
    case "$mask" in
        0x8|0x0008|8) log "✓ group_fwd_mask=$mask — EAPoL is forwarded between ports" ;;
        "")           echo "[eapol-guard] ✗ cannot read group_fwd_mask of $BR" >&2; rc=1 ;;
        *)            echo "[eapol-guard] ✗ group_fwd_mask=$mask; EAPoL will not cross the bridge" >&2; rc=1 ;;
    esac

    if ! rules=$(nft list table bridge "$TABLE" 2>/dev/null); then
        echo "[eapol-guard] ✗ no bridge ACL; run: eapol-guard.sh apply" >&2
        return 1
    fi

    echo "$rules" | grep -q "ether type $EAPOL_ETHERTYPE .*accept" \
        || { echo "[eapol-guard] ✗ the ACL does not accept EAPoL" >&2; rc=1; }
    echo "$rules" | grep -q 'counter name "\?blocked"\? drop' \
        || { echo "[eapol-guard] ✗ the ACL does not drop non-EAPoL frames" >&2; rc=1; }
    echo "$rules" | grep -q "meta ibrname != \"$BR\" accept" \
        || { echo "[eapol-guard] ✗ the ACL is not scoped to $BR" >&2; rc=1; }

    [ "$rc" -eq 0 ] && log "✓ ACL loaded: EAPoL accepted, every other ethertype dropped"
    return "$rc"
}

counter_of() {
    nft list counter bridge "$TABLE" "$1" 2>/dev/null \
        | awk '/packets/ { print $2; exit }'
}

case "${1:-}" in
    apply)
        wait_for_bridge
        ip link set dev "$BR" type bridge group_fwd_mask "$GROUP_FWD_MASK" \
            || die "could not set group_fwd_mask on $BR"
        log "group_fwd_mask=$GROUP_FWD_MASK set on $BR"
        install_acl
        log "ACL installed on $BR"
        check || die "the segment is not in the state this script just set"
        log "ready"
        ;;
    check)
        check
        ;;
    counters)
        need_nft
        echo "eapol=$(counter_of eapol) blocked=$(counter_of blocked)"
        ;;
    clear)
        need_nft
        nft delete table bridge "$TABLE" 2>/dev/null \
            && log "ACL removed from $BR" \
            || log "no ACL to remove"
        ;;
    *)
        sed -n '/^# =\+$/,/^# =\+$/{/^# =\+$/d;s/^# \?//;p}' "$0"
        exit 1
        ;;
esac
