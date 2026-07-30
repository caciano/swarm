#!/bin/bash
set -uo pipefail

# ============================================================
# logs.sh — read the logs of any part of the testbed
#
# Six processes matter when an authentication goes wrong, and none of them is
# reachable the same way. Two hostapd instances share one container and
# interleave on its stdout; the Cloud Agents have generated container names.
# This puts all of them behind one interface.
#
# Usage:
#   ./logs.sh                       what is running
#   ./logs.sh authenticator         one target
#   ./logs.sh eap -f                follow the EAP layer
#   ./logs.sh all -o /tmp/run       one file per target, for attaching to a report
#   ./logs.sh verifier -g Presentation
#
# Targets:
#   supplicant      wpa_supplicant, the EAP-DID peer
#   authenticator   hostapd as 802.1X authenticator   (in swarm-authradius)
#   radius          hostapd as RADIUS/EAP server      (in swarm-authradius)
#   verifier        Identus Verifier Cloud Agent
#   issuer          Identus Issuer Cloud Agent
#   holder          Identus Holder Cloud Agent
#   keys            verifier-keys, the key service
#   node            PRISM Node, the ledger
#
#   eap             supplicant authenticator radius
#   agents          verifier issuer holder keys node
#   all             every target above
# ============================================================

# The header block above is the usage message.
usage() { sed -n '/^# =\+$/,/^# =\+$/{/^# =\+$/d;s/^# \?//;p}' "$0"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE=(docker compose -f docker-compose.yml --profile identus --profile eap)

# How each target is read.
#
#   ctr:<container>            docker logs on a container of a known name
#   svc:<compose service>      docker logs on a container compose names
#   file:<container>:<path>    a file inside a container
#
# The two hostapd instances are read as files, which is what -f writes and what
# CONFIG_DEBUG_FILE in build/hostapd.extra.config makes work. The container's
# stdout carries both, labelled, but reading the files is what gives each
# process on its own and gives all of it: hostapd writes them line buffered,
# whereas its stdout is block buffered and ends a run mid-buffer.
target_source() {
    case "$1" in
        supplicant)    echo "ctr:swarm-supplicant" ;;
        authenticator) echo "file:swarm-authradius:/var/log/hostapd-auth.log" ;;
        radius)        echo "file:swarm-authradius:/var/log/hostapd-radius.log" ;;
        authradius)    echo "ctr:swarm-authradius" ;;
        verifier)      echo "svc:agent-verifier" ;;
        issuer)        echo "svc:agent-issuer" ;;
        holder)        echo "svc:agent-holder" ;;
        keys)          echo "svc:verifier-keys" ;;
        node)          echo "svc:node" ;;
        *)             return 1 ;;
    esac
}

GROUP_EAP="supplicant authenticator radius"
GROUP_AGENTS="verifier issuer holder keys node"
ALL_TARGETS="$GROUP_EAP $GROUP_AGENTS"

expand_target() {
    case "$1" in
        eap)    echo "$GROUP_EAP" ;;
        agents) echo "$GROUP_AGENTS" ;;
        all)    echo "$ALL_TARGETS" ;;
        *)      echo "$1" ;;
    esac
}

FOLLOW=0
TAIL=200
SINCE=""
PATTERN=""
OUT_DIR=""
TARGETS=""

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--follow) FOLLOW=1; shift ;;
        -n|--tail)   TAIL="$2"; shift 2 ;;
        -s|--since)  SINCE="$2"; shift 2 ;;
        -g|--grep)   PATTERN="$2"; shift 2 ;;
        -o|--out)    OUT_DIR="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        -*)          echo "logs.sh: unknown option $1" >&2; exit 1 ;;
        *)
            if ! expanded=$(expand_target "$1"); then
                echo "logs.sh: unknown target $1" >&2; exit 1
            fi
            for t in $expanded; do
                target_source "$t" >/dev/null || { echo "logs.sh: unknown target $t" >&2; exit 1; }
            done
            TARGETS="$TARGETS $expanded"
            shift ;;
    esac
done

TARGETS=$(echo "$TARGETS" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')

# Resolve a target to the container holding it, empty if it is not running.
container_of() {
    local src cid
    src=$(target_source "$1") || return 1
    case "$src" in
        ctr:*)  cid="${src#ctr:}"
                docker inspect -f '{{.Name}}' "$cid" >/dev/null 2>&1 && echo "$cid" ;;
        svc:*)  "${COMPOSE[@]}" ps -q "${src#svc:}" 2>/dev/null | head -1 ;;
        file:*) cid="${src#file:}"; cid="${cid%%:*}"
                docker inspect -f '{{.Name}}' "$cid" >/dev/null 2>&1 && echo "$cid" ;;
    esac
}

# ── No target: say what can be read ──
if [ -z "$TARGETS" ]; then
    echo ""
    printf "%-15s %-9s %s\n" "TARGET" "STATE" "SOURCE"
    printf "%-15s %-9s %s\n" "------" "-----" "------"
    for t in $ALL_TARGETS; do
        src=$(target_source "$t")
        cid=$(container_of "$t")
        if [ -n "$cid" ]; then
            state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "?")
        else
            state="-"
        fi
        printf "%-15s %-9s %s\n" "$t" "$state" "${src#*:}"
    done
    echo ""
    echo "Groups: eap ($GROUP_EAP), agents, all"
    echo "Usage:  ./logs.sh <target...> [-f] [-n N] [-s TIME] [-g RE] [-o DIR]"
    echo ""
    exit 0
fi

# ── Emit one target ──
emit() {
    local target=$1 src cid path
    src=$(target_source "$target")
    cid=$(container_of "$target")

    if [ -z "$cid" ]; then
        echo "logs.sh: $target is not running" >&2
        return 1
    fi

    case "$src" in
        ctr:*|svc:*)
            local args=(logs)
            [ "$FOLLOW" -eq 1 ] && args+=(-f)
            [ "$TAIL" != "all" ] && args+=(--tail "$TAIL")
            [ -n "$SINCE" ] && args+=(--since "$SINCE")
            docker "${args[@]}" "$cid" 2>&1
            ;;
        file:*)
            # --since has no meaning for a plain file; the hostapd lines carry
            # their own timestamps, so filter on those instead if you need to.
            path="${src##*:}"
            if [ "$FOLLOW" -eq 1 ]; then
                docker exec "$cid" tail -n "${TAIL/all/+1}" -F "$path" 2>&1
            elif [ "$TAIL" = "all" ]; then
                docker exec "$cid" cat "$path" 2>&1
            else
                docker exec "$cid" tail -n "$TAIL" "$path" 2>&1
            fi
            ;;
    esac
}

filter() {
    if [ -n "$PATTERN" ]; then grep -E --line-buffered "$PATTERN" || true
    else cat
    fi
}

# ── Bundle: one file per target ──
if [ -n "$OUT_DIR" ]; then
    [ "$FOLLOW" -eq 1 ] && { echo "logs.sh: --follow and --out are mutually exclusive" >&2; exit 1; }
    mkdir -p "$OUT_DIR"
    echo ""
    echo "Writing to $OUT_DIR/"
    for t in $TARGETS; do
        if emit "$t" 2>/dev/null | filter > "$OUT_DIR/$t.log"; then
            printf "  %-15s %8s lines\n" "$t" "$(wc -l < "$OUT_DIR/$t.log")"
        else
            printf "  %-15s %8s\n" "$t" "not running"
            rm -f "$OUT_DIR/$t.log"
        fi
    done
    if [ -f "$SCRIPT_DIR/env.test" ]; then
        cp "$SCRIPT_DIR/env.test" "$OUT_DIR/env.test"
        printf "  %-15s %8s\n" "env.test" "copied"
    fi
    "${COMPOSE[@]}" ps > "$OUT_DIR/containers.txt" 2>&1 || true
    echo ""
    exit 0
fi

# ── One target: stream it as it is ──
set -- $TARGETS
if [ $# -eq 1 ]; then
    emit "$1" | filter
    exit $?
fi

# ── Several: label every line, so an interleaving stays readable ──
if [ "$FOLLOW" -eq 1 ]; then
    pids=()
    for t in $TARGETS; do
        ( emit "$t" 2>/dev/null | filter | sed -u "s/^/[$t] /" ) &
        pids+=($!)
    done
    trap 'kill "${pids[@]}" 2>/dev/null' INT TERM EXIT
    wait
else
    for t in $TARGETS; do
        echo ""
        echo "━━━ $t ━━━"
        emit "$t" 2>/dev/null | filter
    done
fi
