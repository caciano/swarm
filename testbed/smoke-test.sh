#!/bin/bash
set -euo pipefail

# ============================================================
# smoke-test.sh — Environment validation for EAP-DID/TLS/MD5
# Tests prerequisites, build, compose, and auth for all 3 methods
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOP="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$TOP"

PASS=0; FAIL=0; SKIP=0
RESULTS=""

record() { local status=$1 name=$2 detail=${3:-}; RESULTS="${RESULTS}${status}|${name}|${detail}\n"; }
pass()   { echo "  ✅ $1"; PASS=$((PASS+1)); record PASS "$1" "${2:-}"; }
fail()   { echo "  ❌ $1"; FAIL=$((FAIL+1)); record FAIL "$1" "${2:-}"; }
skip()   { echo "  ⏭️  $1"; SKIP=$((SKIP+1)); record SKIP "$1" "${2:-}"; }
section() { echo ""; echo "━━━ $1 ━━━"; }

# ═══════════════════════════════════════════════════════════
section "1. Prerequisites"

# 1.1 Git submodules
if [ -f third_party/hostap/hostapd/Makefile ] && \
   [ -f third_party/identus-cloud-agent/build.sbt ] && \
   { [ -f third_party/didcomm-jvm/build.gradle.kts ] || [ -f third_party/didcomm-jvm/build.gradle ]; }; then
    pass "Git submodules present"
else
    fail "Git submodules missing" "Run: make bootstrap"
fi

# 1.2 Patches applied (check for EAP-DID code)
if grep -ql "eap_did\|EAP_DID" third_party/hostap/src/eap_server/eap_server_did.c 2>/dev/null; then
    pass "hostap EAP-DID patch applied"
else
    fail "hostap EAP-DID patch not applied" "Run: make patch"
fi

if find third_party/identus-cloud-agent -name "*.scala" -exec grep -l "CekGlobalStore\|getCek" {} \; 2>/dev/null | head -1 | grep -q .; then
    pass "cloud-agent CEK patch applied"
else
    fail "cloud-agent CEK patch not applied" "Run: make patch"
fi

# 1.3 Build tools
for tool in make gcc docker; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "$tool available"
    else
        fail "$tool not found"
    fi
done
# sbt may be installed via sdkman without being in non-interactive PATH
SBT_PATH="$(command -v sbt 2>/dev/null || find /home /root /opt -path '*/sbt/*/bin/sbt' -type f 2>/dev/null | head -1)"
if [ -n "$SBT_PATH" ]; then
    pass "sbt available ($SBT_PATH)"
else
    fail "sbt not found"
fi

# 1.4 Docker compose
if docker compose version >/dev/null 2>&1; then
    pass "docker compose v2 available"
else
    fail "docker compose v2 not found"
fi

# ═══════════════════════════════════════════════════════════
section "2. Build artifacts"

# 2.1 hostap binaries
for bin in hostapd/hostapd hostapd/hostapd_cli wpa_supplicant/wpa_supplicant wpa_supplicant/wpa_cli; do
    f="third_party/hostap/$bin"
    if [ -x "$f" ]; then
        pass "$(basename $bin) binary exists"
    else
        fail "$(basename $bin) binary missing" "Run: make build"
    fi
done

# 2.2 Cloud agent image
if docker image inspect identus-cloud-agent:cek >/dev/null 2>&1; then
    pass "identus-cloud-agent:cek image exists"
else
    fail "identus-cloud-agent:cek image missing" "Run: make build"
fi

# ═══════════════════════════════════════════════════════════
section "3. Configuration files"

# 3.1 wpa_supplicant configs
for conf in wpa_supplicant.conf wpa_supplicant.tls.conf wpa_supplicant.md5.conf; do
    f="testbed/config/wpa_supplicant/$conf"
    if [ -f "$f" ]; then
        pass "$conf exists"
    else
        fail "$conf missing"
    fi
done

# 3.2 hostapd configs
for conf in hostapd.conf hostapd-tls.conf hostapd-md5.conf radius.conf radius-tls.conf radius-md5.conf; do
    f="testbed/config/hostapd/$conf"
    if [ -f "$f" ]; then
        pass "$conf exists"
    else
        fail "$conf missing"
    fi
done

# 3.3 EAP user databases
for uf in hostapd.eap_user hostapd.eap_user.tls hostapd.eap_user.md5; do
    f="testbed/config/hostapd/$uf"
    if [ -f "$f" ]; then
        pass "$uf exists"
    else
        fail "$uf missing"
    fi
done

# 3.4 TLS certificates
for cert in ca.pem server.pem server-key.pem client.pem client-key.pem; do
    f="testbed/config/certs/$cert"
    if [ -f "$f" ]; then
        pass "$cert exists"
    else
        fail "$cert missing"
    fi
done

# 3.5 did keys
for kf in credential.jwt ed25519_priv.b64url x25519_keys.json \
          holder_secp256k1_priv.b64url; do
    f="testbed/did-keys/$kf"
    if [ -f "$f" ]; then
        pass "did-keys/$kf exists"
    else
        fail "did-keys/$kf missing"
    fi
done

# The supplicant refuses a private key file that anyone but its owner can read
for kf in ed25519_priv.b64url x25519_keys.json holder_secp256k1_priv.b64url; do
    f="testbed/did-keys/$kf"
    [ -f "$f" ] || continue
    mode=$(stat -c '%a' "$f")
    if [ "$mode" = "600" ]; then
        pass "did-keys/$kf is 0600"
    else
        fail "did-keys/$kf is $mode, and the supplicant will refuse it"
    fi
done

# 3.6 env.test
if [ -f testbed/env.test ]; then
    pass "env.test exists"
    for var in ISSUER_DID HOLDER_DID SCHEMA_ID CRED_ID; do
        if grep -q "^${var}=." testbed/env.test; then
            pass "env.test has $var"
        else
            fail "env.test missing or empty $var"
        fi
    done
else
    fail "env.test missing" "Run: make provision"
fi

# ═══════════════════════════════════════════════════════════
section "4. Docker compose validation"

# 4.1 docker-compose.yml syntax
if docker compose -f testbed/docker-compose.yml config --quiet 2>/dev/null; then
    pass "docker-compose.yml valid"
else
    fail "docker-compose.yml invalid" "Check YAML syntax"
fi

# 4.2 Networks not external
if ! grep -q "external: true" testbed/docker-compose.yml; then
    pass "No external networks in compose"
else
    fail "Compose still has external networks" "See issue #23"
fi

# 4.3 Dockerfile structure (multi-stage is expected for glibc compat)
if grep -q "FROM.*AS build" testbed/Dockerfile && grep -q "FROM.*AS runtime" testbed/Dockerfile; then
    pass "Dockerfile is multi-stage (build + runtime)"
else
    fail "Dockerfile structure unexpected" "Expected multi-stage build"
fi

# 4.4 Cert volume mounts
if grep -q "config/certs" testbed/docker-compose.yml; then
    pass "TLS certificates mounted in compose"
else
    fail "TLS certificates NOT mounted in compose" "EAP-TLS will fail"
fi

# ═══════════════════════════════════════════════════════════
section "5. Container image build"

echo "  Building Docker image (if needed)..."
if docker compose -f testbed/docker-compose.yml --profile eap build --quiet 2>&1 | tail -3; then
    pass "testbed Docker image builds"
else
    fail "testbed Docker image build failed"
fi

# ═══════════════════════════════════════════════════════════
section "6. EAP authentication tests"

cd testbed

# Ensure clean state
docker compose --profile identus --profile eap down 2>/dev/null || true

# 6.1 Start Identus stack
echo "  Starting Identus Cloud Agents..."
if docker compose --profile identus up -d --wait 2>&1 | tail -3; then
    pass "Identus stack started"
else
    fail "Identus stack failed to start"
    echo "  Aborting auth tests."
    docker compose --profile identus --profile eap down 2>/dev/null || true
    print_summary
    exit 1
fi

# 6.2 Provision (if env.test missing or stale)
if [ ! -f env.test ] || ! grep -q "^SCHEMA_ID=." env.test; then
    echo "  Running provisioning..."
    if ./provision.sh --no-agents 2>&1 | tail -5; then
        pass "Provisioning succeeded"
    else
        fail "Provisioning failed"
    fi
else
    pass "env.test already provisioned"
fi

set -a; source env.test 2>/dev/null || true; set +a

# ── Test each method ──
for METHOD in md5 tls did; do
    echo ""
    echo "  ── EAP-$(echo $METHOD | tr 'a-z' 'A-Z') ──"

    # Clean EAP layer
    docker compose --profile eap down 2>/dev/null || true
    sleep 1

    # For DID, ensure Identus is up
    if [ "$METHOD" = "did" ]; then
        docker compose --profile identus up -d --wait 2>&1 | tail -1
        sleep 2
    fi

    echo "$METHOD" > config/hostapd/.method

    TIMEOUT=60
    [ "$METHOD" = "did" ] && TIMEOUT=120

    AUTH_OUTPUT=$(timeout $((TIMEOUT + 30)) ./auth.sh --method "$METHOD" --rounds 1 --timeout "$TIMEOUT" 2>&1 || true)
    echo "$AUTH_OUTPUT" | tail -20
    if echo "$AUTH_OUTPUT" | grep -qE "SUCCESS.*succeeded|✅.*SUCCESS"; then
        pass "EAP-$METHOD authentication SUCCESS"
    else
        fail "EAP-$METHOD authentication FAILED"
        echo "  --- authradius tail ---"
        docker logs swarm-authradius --tail 5 2>&1 || true
        echo "  --- supplicant tail ---"
        docker logs swarm-supplicant --tail 5 2>&1 || true
    fi

    docker compose --profile eap down 2>/dev/null || true
done

# ═══════════════════════════════════════════════════════════
section "7. Cleanup"

docker compose --profile identus --profile eap down 2>/dev/null || true
pass "Cleanup done"

# ═══════════════════════════════════════════════════════════
print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  SMOKE TEST SUMMARY                          ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    printf "  ✅ Passed: %d\n" "$PASS"
    printf "  ❌ Failed: %d\n" "$FAIL"
    printf "  ⏭️  Skipped: %d\n" "$SKIP"
    echo ""

    if [ "$FAIL" -gt 0 ]; then
        echo "── Failures ──"
        echo -e "$RESULTS" | grep '^FAIL|' | while IFS='|' read -r _ name detail; do
            echo "  ❌ $name" ${detail:+": $detail"}
        done
    fi
}

print_summary

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "All checks passed. ✅"
exit 0
