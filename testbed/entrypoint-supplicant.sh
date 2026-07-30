#!/bin/bash
set -euo pipefail

# The EAP port is the one attached to eapol-net, and eapol-net carries no
# addresses (docker-compose.yml, networks). Docker still allocates one from the
# pool it is forced to declare, so the address is what identifies the port —
# and then it goes, before wpa_supplicant sees the interface. What is left is
# an 802.1X uncontrolled port: no address, no route, EAPoL and nothing else.
EAPOL_PREFIX="${EAPOL_SUBNET_PREFIX:-172.30.}"

IFACE=""
for if in $(ls /sys/class/net/ | grep -E "^eth" | sort); do
    if ip -4 addr show "$if" 2>/dev/null | grep -q "inet ${EAPOL_PREFIX}"; then
        IFACE="$if"
        break
    fi
done

# Already flushed — a restart of the container's process rather than the
# container — or the deployment names the port explicitly.
IFACE="${IFACE:-${EAP_IFACE:-eth1}}"

CONF="${WPA_CONF:-/etc/wpa_supplicant/wpa_supplicant.conf}"

echo "[supplicant] host=$(hostname) conf=$CONF iface=$IFACE (auto-detected)"

ip addr flush dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true

if ip addr show dev "$IFACE" 2>/dev/null | grep -qE 'inet |inet6 '; then
    echo "[supplicant] ERROR: $IFACE still carries an address:" >&2
    ip -br addr show dev "$IFACE" >&2
    exit 1
fi
echo "[supplicant] $IFACE has no address — the EAP segment is a wire"
ip -br addr || true

sleep "${START_DELAY:-3}"

echo "[supplicant] starting wpa_supplicant (driver=wired) on $IFACE"
exec wpa_supplicant -t -dd -D wired -i "$IFACE" -c "$CONF"
