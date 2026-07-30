#!/bin/bash
set -uo pipefail

# The EAP port is the one attached to eapol-net, identified by the address
# Docker allocates from the pool it is forced to declare, and address-less
# immediately afterwards: the segment between a device and an authenticator
# carries EAPoL and nothing else. See docker-compose.yml, networks.
EAPOL_PREFIX="${EAPOL_SUBNET_PREFIX:-172.30.}"

IFACE=""
for if in $(ls /sys/class/net/ | grep -E "^eth" | sort); do
    if ip -4 addr show "$if" 2>/dev/null | grep -q "inet ${EAPOL_PREFIX}"; then
        IFACE="$if"; break
    fi
done
IFACE="${IFACE:-${EAP_IFACE:-eth1}}"

# Read method from file (written by auth.sh via docker exec)
METHOD_FILE="/etc/hostapd/.method"
if [ -f "$METHOD_FILE" ]; then
    METHOD=$(cat "$METHOD_FILE")
else
    METHOD="did"
fi
echo "[authradius] host=$(hostname) iface=$IFACE method=$METHOD"

RLOG=/var/log/hostapd-radius.log
ALOG=/var/log/hostapd-auth.log

case "$METHOD" in
    tls)  RCONF="/etc/hostapd/radius-tls.conf"; ACONF="/etc/hostapd/hostapd-tls.conf" ;;
    md5)  RCONF="/etc/hostapd/radius-md5.conf"; ACONF="/etc/hostapd/hostapd-md5.conf" ;;
    *)    RCONF="${RADIUS_CONF:-/etc/hostapd/radius.conf}"; ACONF="${AUTH_CONF:-/etc/hostapd/hostapd.conf}" ;;
esac

ip addr flush dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true

if ip addr show dev "$IFACE" 2>/dev/null | grep -qE 'inet |inet6 '; then
    echo "[authradius] ERROR: $IFACE still carries an address:" >&2
    ip -br addr show dev "$IFACE" >&2
    exit 1
fi
echo "[authradius] $IFACE has no address — the EAP segment is a wire"

: > "$RLOG"; : > "$ALOG"

# 1) RADIUS / EAP server
hostapd -t -dd -f "$RLOG" "$RCONF" &
RADIUS_PID=$!

for _ in $(seq 1 40); do
    if ss -lun 2>/dev/null | grep -q "1812"; then
        echo "[authradius] RADIUS listening on udp/1812"; break
    fi
    if ! kill -0 "$RADIUS_PID" 2>/dev/null; then
        echo "[authradius] ERROR: RADIUS hostapd exited early" >&2
        cat "$RLOG" >&2; exit 1
    fi
    sleep 0.5
done

# 2) Authenticator
cp "$ACONF" /tmp/auth.conf && sed -i "s/interface=.*/interface=$IFACE/" /tmp/auth.conf
hostapd -t -dd -f "$ALOG" /tmp/auth.conf &
AUTH_PID=$!

# Each hostapd writes to its own file, which is what -f is for and what
# CONFIG_DEBUG_FILE in build/hostapd.extra.config makes work. Both are relayed
# to the container's stdout with a label, because two hostapd instances on one
# stream are otherwise impossible to tell apart. ./logs.sh reads the files.
tail -n +1 -F "$RLOG" 2>/dev/null | sed -u 's/^/[radius] /' &
RTAIL_PID=$!
tail -n +1 -F "$ALOG" 2>/dev/null | sed -u 's/^/[auth]   /' &
ATAIL_PID=$!

cleanup() { kill "$RADIUS_PID" "$AUTH_PID" "$RTAIL_PID" "$ATAIL_PID" 2>/dev/null || true; }
trap cleanup TERM INT EXIT

wait -n "$RADIUS_PID" "$AUTH_PID" 2>/dev/null || true
echo "[authradius] a process exited; shutting down"
