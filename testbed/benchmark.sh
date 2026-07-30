#!/bin/bash
#
# EAP Benchmark Script (v3)
# Issue #14: Benchmark EAP-DID vs EAP-TLS vs EAP-MD5
# Issue #28: Add --ledger flag for cardano vs in-memory comparison
#
set -euo pipefail

TESTBED="$(cd "$(dirname "$0")" && pwd)"
MANAGE="${TESTBED}/manage.sh"
OUTPUT_DIR="/tmp/eap-benchmark"
RESULTS_CSV="${OUTPUT_DIR}/benchmark_results.csv"
WARMUP=5
ROUNDS=30
METHODS="did tls md5"
LEDGER="auto"
DO_COMPARE=false

log() { echo "[$(date +%H:%M:%S)] $*"; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --ledger cardano|in-memory|auto  Ledger mode (default: auto)"
    echo "  --rounds N                        Number of rounds (default: 30)"
    echo "  --warmup N                        Warmup rounds (default: 5)"
    echo "  --methods 'did tls md5'           Methods to benchmark"
    echo "  --compare                         Run in-memory then cardano and compare"
    echo "  -h, --help                        Show this help"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ledger)
            LEDGER="$2"; shift 2 ;;
        --rounds)
            ROUNDS="$2"; shift 2 ;;
        --warmup)
            WARMUP="$2"; shift 2 ;;
        --methods)
            METHODS="$2"; shift 2 ;;
        --compare)
            DO_COMPARE=true; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

detect_ledger() {
    local mode
    mode=$(bash "$MANAGE" status 2>/dev/null | grep "Mode:" | awk '{print $2}')
    if [ "$mode" = "cardano" ]; then
        echo "cardano"
    else
        echo "in-memory"
    fi
}

run_single_auth() {
    local method=$1
    local round=$2
    local ts_start ts_end duration_ms result

    ts_start=$(date +%s.%N)
    local log_file="${OUTPUT_DIR}/${method}_round_${round}.log"

    if [ "$method" = "did" ]; then
        cd "$TESTBED"
        timeout 120 docker compose -f docker-compose.benchmark.yml \
            --profile did run --rm did-supplicant bash -c \
            'wpa_supplicant -D wired -i eth0 \
             -c /etc/wpa_supplicant/wpa_supplicant.conf -dd 2>&1' \
            > "$log_file" 2>&1 || true

        if grep -q "EAP-DID AUTHENTICATION SUCCESS\|CTRL-EVENT-EAP-SUCCESS" "$log_file" 2>/dev/null; then
            result="success"
        elif grep -q "CTRL-EVENT-EAP-FAILURE" "$log_file" 2>/dev/null; then
            result="failure"
        else
            result="timeout"
        fi

    elif [ "$method" = "tls" ]; then
        cd "$TESTBED"
        timeout 60 docker compose -f docker-compose.benchmark.yml \
            --profile tls run --rm tls-supplicant bash -c \
            'wpa_supplicant -D wired -i eth0 \
             -c /etc/wpa_supplicant/wpa_supplicant.tls.conf -dd 2>&1' \
            > "$log_file" 2>&1 || true

        if grep -q "CTRL-EVENT-EAP-SUCCESS" "$log_file" 2>/dev/null; then
            result="success"
        elif grep -q "CTRL-EVENT-EAP-FAILURE" "$log_file" 2>/dev/null; then
            result="failure"
        else
            result="timeout"
        fi

    elif [ "$method" = "md5" ]; then
        cd "$TESTBED"
        timeout 60 docker compose -f docker-compose.benchmark.yml \
            --profile md5 run --rm md5-supplicant bash -c \
            'wpa_supplicant -D wired -i eth0 \
             -c /etc/wpa_supplicant/wpa_supplicant.md5.conf -dd 2>&1' \
            > "$log_file" 2>&1 || true

        if grep -q "CTRL-EVENT-EAP-SUCCESS" "$log_file" 2>/dev/null; then
            result="success"
        elif grep -q "CTRL-EVENT-EAP-FAILURE" "$log_file" 2>/dev/null; then
            result="failure"
        else
            result="timeout"
        fi
    fi

    ts_end=$(date +%s.%N)
    duration_ms=$(python3 -c "print(int(($ts_end - $ts_start) * 1000))" 2>/dev/null || echo "0")

    local eap_start eap_end
    eap_start=$(grep -m1 "EAP-Identity\|RX EAPOL-Start\|EAP: EAP-Request" "$log_file" 2>/dev/null | head -1 | awk '{print $1}' | tr -d '[]' || echo "")
    eap_end=$(grep -m1 "EAP-Success\|CTRL-EVENT-EAP-SUCCESS\|AUTHENTICATION SUCCESS" "$log_file" 2>/dev/null | head -1 | awk '{print $1}' | tr -d '[]' || echo "")

    if [ -n "$eap_start" ] && [ -n "$eap_end" ]; then
        duration_ms=$(python3 -c "print(int(($eap_end - $eap_start) * 1000))" 2>/dev/null || echo "$duration_ms")
    fi

    echo "${method},${round},${ts_start},${ts_end},${duration_ms},${result},${LEDGER_MODE}"
}

run_benchmark() {
    local label=$1
    local csv="${OUTPUT_DIR}/benchmark_${label}.csv"

    mkdir -p "$OUTPUT_DIR"

    log "=========================================="
    log "  EAP Benchmark (${label})"
    log "  Rounds: ${ROUNDS} (warmup: ${WARMUP})"
    log "  Methods: ${METHODS}"
    log "  Ledger: ${LEDGER_MODE}"
    log "=========================================="

    echo "method,run,timestamp_start,timestamp_end,duration_ms,result,ledger_mode" > "$csv"

    for method in $METHODS; do
        log ""
        log "--- Method: ${method} ---"

        log "Warmup (${WARMUP} rounds)..."
        for i in $(seq 1 "$WARMUP"); do
            log "  warmup round ${i}/${WARMUP}"
            run_single_auth "$method" "warmup_${i}" > /dev/null || true
        done

        log "Measurement (${ROUNDS} rounds)..."
        for i in $(seq 1 "$ROUNDS"); do
            log "  round ${i}/${ROUNDS}"
            run_single_auth "$method" "$i" >> "$csv" || \
                echo "${method},${i},0,0,0,error,${LEDGER_MODE}" >> "$csv"
        done
    done

    log ""
    log "Benchmark complete! Results: ${csv}"
    RESULTS_CSV="$csv"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$DO_COMPARE" = "true" ]; then
    # Comparative benchmark: in-memory vs cardano
    log "Starting comparative benchmark..."

    # Phase 1: in-memory
    LEDGER_MODE="in-memory"
    bash "$MANAGE" switch --in-memory 2>/dev/null || true
    sleep 5
    run_benchmark "in-memory"
    IN_MEM_CSV="$RESULTS_CSV"

    # Phase 2: cardano
    LEDGER_MODE="cardano"
    bash "$MANAGE" switch --cardano 2>/dev/null || true
    sleep 10
    run_benchmark "cardano"
    CARDANO_CSV="$RESULTS_CSV"

    # Generate comparison report
    log ""
    log "=========================================="
    log "  Comparative Report"
    log "=========================================="
    log "In-memory CSV:  $IN_MEM_CSV"
    log "Cardano CSV:    $CARDANO_CSV"
    log ""
    python3 -c "
import csv, sys, os

def load_stats(path):
    if not os.path.exists(path):
        return {}
    stats = {}
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            method = row['method']
            if row['result'] != 'success':
                continue
            ms = int(row['duration_ms'])
            stats.setdefault(method, []).append(ms)
    result = {}
    for method, times in stats.items():
        if times:
            result[method] = {
                'count': len(times),
                'mean': sum(times) / len(times),
                'min': min(times),
                'max': max(times),
                'median': sorted(times)[len(times)//2],
            }
    return result

im = load_stats('${IN_MEM_CSV}')
ca = load_stats('${CARDANO_CSV}')

print(f\"{'Method':<10} {'Mode':<12} {'N':>3} {'Mean':>8} {'Median':>8} {'Min':>8} {'Max':>8}\")
print('-' * 65)
for method in sorted(set(list(im.keys()) + list(ca.keys()))):
    for label, stats in [('in-memory', im), ('cardano', ca)]:
        if method in stats:
            s = stats[method]
            print(f\"{method:<10} {label:<12} {s['count']:>3} {s['mean']:>8.0f} {s['median']:>8.0f} {s['min']:>8.0f} {s['max']:>8.0f}\")
" 2>/dev/null || log "Comparison analysis requires both CSVs"
    log ""
    log "Comparison CSVs saved in ${OUTPUT_DIR}"

else
    # Single-mode benchmark
    if [ "$LEDGER" = "auto" ]; then
        LEDGER_MODE=$(detect_ledger)
    else
        LEDGER_MODE="$LEDGER"
    fi

    # Pre-benchmark validation
    bash "$MANAGE" status > /dev/null 2>&1 || true

    if [ "$LEDGER_MODE" = "cardano" ]; then
        # Check Cardano sync
        if docker exec swarm-cardano-node cardano-cli query tip --testnet-magic 1 2>/dev/null | grep -q "syncProgress"; then
            sync=$(docker exec swarm-cardano-node cardano-cli query tip --testnet-magic 1 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('syncProgress','?'))" 2>/dev/null || echo "?")
            log "Cardano sync progress: ${sync}"
            if [ "$sync" != "100.00" ]; then
                log "WARNING: Cardano not fully synced (${sync}%). Results may be affected."
            fi
        else
            log "WARNING: Cannot check Cardano sync status"
        fi
    fi

    run_benchmark "${LEDGER_MODE}"

    log ""
    log "Run analyze.py for detailed statistics:"
    log "  python3 tests/analyze.py ${RESULTS_CSV}"
fi
