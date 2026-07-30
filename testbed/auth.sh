#!/bin/bash
set -euo pipefail

# ============================================================
# auth.sh — EAP-DID / EAP-TLS / EAP-MD5 benchmark
#
# Uso:
#   ./auth.sh --method did --rounds 10
#   ./auth.sh --method tls --rounds 10
#   ./auth.sh --method md5 --rounds 10
#   ./auth.sh --benchmark 30         # DID, 30 rounds
#   ./auth.sh --benchmark 30 --methods "did tls md5"
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VP_RELAY_NET="swarm-testbed_vp-relay"
ENV_FILE="$SCRIPT_DIR/env.test"
TEST_TIMEOUT="${EAP_TIMEOUT:-120}"
ROUNDS=1
METHOD="did"
BENCHMARK=0
METHODS="did"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --method)
            METHOD="$2"; shift 2 ;;
        --methods)
            METHODS="$2"; shift 2 ;;
        --rounds)
            ROUNDS="$2"; shift 2 ;;
        --benchmark)
            BENCHMARK=1
            ROUNDS="${2:-10}"
            METHODS="${METHODS:-did tls md5}"
            shift 2 2>/dev/null || shift 1 ;;
        --timeout)
            TEST_TIMEOUT="$2"; shift 2 ;;
        *)
            echo "Usage: $0 [--method did|tls|md5] [--rounds N] [--benchmark N] [--methods 'did tls md5'] [--timeout T]"
            exit 1 ;;
    esac
done

# Load env.test (needed for DID credentials)
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

# ── Per-method configuration ──
WPA_CONF_DID="/etc/wpa_supplicant/wpa_supplicant.conf"
WPA_CONF_TLS="/etc/wpa_supplicant/wpa_supplicant.tls.conf"
WPA_CONF_MD5="/etc/wpa_supplicant/wpa_supplicant.md5.conf"

# Success patterns for each method
SUCCESS_DID='CTRL-EVENT-EAP-SUCCESS|EAPOL authentication completed - result=SUCCESS'
SUCCESS_TLS='CTRL-EVENT-EAP-SUCCESS|EAPOL authentication completed - result=SUCCESS'
SUCCESS_MD5='CTRL-EVENT-EAP-SUCCESS|EAPOL authentication completed - result=SUCCESS'

# Start markers (from wpa_supplicant timestamps)
START_DID='CTRL-EVENT-EAP-METHOD.*EAP vendor 0 method 57'
START_TLS='CTRL-EVENT-EAP-METHOD.*EAP vendor 0 method 13'
START_MD5='CTRL-EVENT-EAP-METHOD.*EAP vendor 0 method 4'

get_wpa_conf() { local m=$1; case "$m" in did) echo "$WPA_CONF_DID";; tls) echo "$WPA_CONF_TLS";; md5) echo "$WPA_CONF_MD5";; esac }
get_success() { local m=$1; case "$m" in did) echo "$SUCCESS_DID";; tls) echo "$SUCCESS_TLS";; md5) echo "$SUCCESS_MD5";; esac }
get_start()   { local m=$1; case "$m" in did) echo "$START_DID";; tls) echo "$START_TLS";; md5) echo "$START_MD5";; esac }

# ── Docker compose uses WPA_CONF env var for supplicant config ──
# The supplicant container mounts ./config/wpa_supplicant volume at /etc/wpa_supplicant
# We select the config file by setting WPA_CONF environment variable

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  EAP Authentication Benchmark                ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
mkdir -p "$RESULTS_DIR"

setup_vp_relay() {
    if [ "$METHOD" != "did" ]; then return; fi
    echo "[vp-relay] Setting up VP relay..."
    docker network rm "$VP_RELAY_NET" 2>/dev/null || true
    docker network create "$VP_RELAY_NET" 2>/dev/null
    docker network connect --alias caddy-verifier "$VP_RELAY_NET" swarm-supplicant 2>/dev/null || true
    local ah=$(docker compose --profile identus ps -q agent-holder 2>/dev/null | head -1)
    [ -n "$ah" ] && docker network connect "$VP_RELAY_NET" "$ah" 2>/dev/null || true
    sleep 1
}

teardown_vp_relay() {
    docker network disconnect "$VP_RELAY_NET" swarm-supplicant 2>/dev/null || true
    local ah=$(docker compose --profile identus ps -q agent-holder 2>/dev/null | head -1)
    [ -n "$ah" ] && docker network disconnect "$VP_RELAY_NET" "$ah" 2>/dev/null || true
    docker network rm "$VP_RELAY_NET" 2>/dev/null || true
}

# Extract EAP duration from supplicant log timestamps (3 decimal places)
extract_duration() {
    local since_ts=$1 method=$2
    local start_pat end_pat
    start_pat=$(get_start "$method")
    end_pat='EAPOL authentication completed - result=SUCCESS|CTRL-EVENT-EAP-SUCCESS'

    docker logs swarm-supplicant --since "$since_ts" 2>&1 | python3 -c "
import sys, re

start_pat = r'(\d+\.\d+):.*($start_pat)'
end_pat = r'(\d+\.\d+):.*($end_pat)'

start_ts = None
end_ts = None

for line in sys.stdin:
    if start_ts is None:
        m = re.match(start_pat, line)
        if m:
            start_ts = float(m.group(1))
            continue
    if end_ts is None:
        m = re.match(end_pat, line)
        if m:
            end_ts = float(m.group(1))
            break

if start_ts and end_ts:
    print(f'{end_ts - start_ts:.3f}')
else:
    print('N/A')
"
}

run_single_auth() {
    local method=$1 round=$2
    echo "── Round $round/$ROUNDS ($method) ──"

    local wpa_conf
    wpa_conf=$(get_wpa_conf "$method")

    # The method has to be on disk before the authenticator starts: its
    # entrypoint reads this file to choose a hostapd configuration.
    echo "$method" > config/hostapd/.method

    # One `up`, not one per service. Compose creates the networks before any
    # container, and init-bridge needs that: it configures the EAP bridge from
    # the host's namespace and cannot bring it into existence. Started alone it
    # finds no bridge and times out. The other two wait for it through
    # depends_on, so when this returns the segment is configured.
    echo "[1/3] Starting EAP layer ($method)..."
    WPA_CONF="$wpa_conf" docker compose --profile eap up -d 2>&1 | tail -3

    # scripts/eapol-guard.sh prints this after verifying its own work.
    if ! docker compose --profile eap logs init-bridge 2>&1 | grep -q "eapol-guard] ready"; then
        echo "  ❌ the EAP segment was not configured:"
        docker compose --profile eap logs init-bridge 2>&1 | tail -5 | sed 's/^/    /'
        return 1
    fi

    sleep 2
    : # did: vp-relay not needed - peer creates VP+JWE locally

    # Write credentials (DID only)
    if [ "$method" = "did" ]; then
        docker exec swarm-supplicant bash -c "echo '$CRED_ID' > /tmp/holder_cred_id.txt" 2>/dev/null || true
        docker exec swarm-authradius bash -c "echo '$SCHEMA_ID' > /tmp/schema_url.txt" 2>/dev/null || true
    fi

    # Wait for completion
    local success_pat
    success_pat=$(get_success "$method")
    echo "[2/3] Waiting for EAP-$method authentication (timeout ${TEST_TIMEOUT}s)..."
    local wall_start wall_end found eap_dur
    wall_start=$(date +%s)
    found=0

    for i in $(seq 1 "$TEST_TIMEOUT"); do
        if docker logs swarm-supplicant --since "$wall_start" 2>&1 | grep -qE "$success_pat"; then
            found=1; break
        fi
        if docker logs swarm-authradius --since "$wall_start" 2>&1 | grep -qE "Building EAP-Success|EAP-SUCCESS"; then
            found=1; sleep 1; break
        fi
        sleep 1
    done

    wall_end=$(date +%s)
    local wall_dur=$((wall_end - wall_start))
    eap_dur="N/A"
    if [ "$found" -eq 1 ]; then
        eap_dur=$(extract_duration "$wall_start" "$method")
    fi

    echo "[3/3] Result..."
    if [ "$found" -eq 1 ]; then
        echo "  ✅ EAP-$method SUCCESS (EAP: ${eap_dur}s, wall: ${wall_dur}s)"
        return 0
    else
        echo "  ❌ EAP-$method FAILED/TIMEOUT (wall: ${wall_dur}s)"
        # The authenticator is the process that decides, so its log is the one
        # that says why. Everything else goes to a bundle, taken now because it
        # is gone once the containers are recreated for the next round.
        local bundle="$RESULTS_DIR/failure-${method}-$(date +%Y%m%d-%H%M%S)"
        "$SCRIPT_DIR/logs.sh" authenticator -n 20 2>/dev/null | sed 's/^/    /'
        "$SCRIPT_DIR/logs.sh" all --out "$bundle" >/dev/null 2>&1 || true
        [ -d "$bundle" ] && echo "    full logs: $bundle/"
        return 1
    fi
}

run_method_benchmark() {
    local method=$1

    echo ""
    echo "════════════════════════════════════════════════"
    echo "  Method: EAP-$method  |  Rounds: $ROUNDS"
    echo "════════════════════════════════════════════════"
    echo ""

    local csv="$RESULTS_DIR/bench-${method}-$(date +%Y%m%d-%H%M%S).csv"
    echo "round,eap_duration_s,status" > "$csv"

    local success=0 fail=0
    for round in $(seq 1 "$ROUNDS"); do
        local round_start=$round

        # For DID method, allow warm-up: first round may be slow
        if run_single_auth "$method" "$round"; then
            success=$((success + 1))
            # Extract duration from last run
            local since_ts
            since_ts=$(($(date +%s) - 30))
            local dur
            dur=$(extract_duration "$since_ts" "$method")
            echo "$round,$dur,SUCCESS" >> "$csv"
        else
            fail=$((fail + 1))
            echo "$round,$(date +%s),FAILED" >> "$csv"
        fi

        if [ "$round" -lt "$ROUNDS" ]; then
            echo "Recreating EAP containers..."
            docker compose --profile eap down 2>/dev/null || true
            sleep 2
        fi
    done

    echo ""
    echo "── EAP-$method Summary: $success/$ROUNDS succeeded ──"

    # Statistics
    local durations
    durations=$(grep ',SUCCESS$' "$csv" | cut -d, -f2 | grep -v 'N/A')
    if [ -n "$durations" ]; then
        python3 -c "
vals = [float(x) for x in '''$durations'''.split()]
n = len(vals)
if n > 0:
    m = sum(vals)/n
    mn = min(vals); mx = max(vals)
    sd = (sum((x-m)**2 for x in vals)/(n-1))**0.5 if n > 1 else 0
    print(f'  n={n}  min={mn:.3f}s  max={mx:.3f}s  avg={m:.3f}s  stddev={sd:.3f}s')
" 2>/dev/null
    fi
    echo "  CSV: $csv"
    echo ""

    METHOD_CSVS="$METHOD_CSVS $method:$csv"
}

# ═══════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════

METHOD_CSVS=""

if [ "$BENCHMARK" -eq 1 ]; then
    # Multi-method benchmark
    for m in $METHODS; do
        METHOD="$m"
        run_method_benchmark "$m"
    done

    # Comparison table
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  Comparison Summary                          ║"
    echo "╚══════════════════════════════════════════════╝"
    printf "%-8s %5s %8s %8s %8s %8s\n" "Method" "N" "Min" "Max" "Avg" "StdDev"
    echo "---------------------------------------------------"

    for entry in $METHOD_CSVS; do
        m="${entry%%:*}"
        csv="${entry#*:}"
        python3 -c "
import csv as csvmod
durations = []
with open('$csv') as f:
    for row in csvmod.DictReader(f):
        if row['status'] == 'SUCCESS' and row['eap_duration_s'] != 'N/A':
            try:
                durations.append(float(row['eap_duration_s']))
            except: pass
n = len(durations)
if n > 0:
    m = sum(durations)/n
    sd = (sum((x-m)**2 for x in durations)/(n-1))**0.5 if n > 1 else 0
    print(f'{\"$m\":<8} {n:>5} {min(durations):>8.3f} {max(durations):>8.3f} {m:>8.3f} {sd:>8.3f}')
else:
    print(f'{\"$m\":<8} {0:>5} {\"N/A\":>8} {\"N/A\":>8} {\"N/A\":>8} {\"N/A\":>8}')
" 2>/dev/null
    done
    echo ""
else
    # Single method
    run_method_benchmark "$METHOD"
fi

teardown_vp_relay
docker compose --profile eap down 2>/dev/null || true
