#!/usr/bin/env bash
set -euo pipefail

# Integration test for proxy-ca-autotrust detection logic.
#
# Starts an openssl s_server using the committed test fixtures, then runs the
# feature's install.sh for each of three matching scenarios and verifies that
# curl can reach the server using the system CA bundle after each install.
#
# Requires: openssl, curl, ca-certificates, sudo (passwordless)

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"
FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../src/proxy-ca-autotrust" && pwd)"
CERT_INSTALL_DIR="/usr/local/share/ca-certificates/proxy-ca-autotrust"
PORT=18443
PASS=0
FAIL=0

# -----------------------------------------------------------------------------
# Server lifecycle
# -----------------------------------------------------------------------------

start_server() {
    openssl s_server \
        -accept "${PORT}" \
        -www \
        -cert "${FIXTURE_DIR}/leaf.pem" \
        -key  "${FIXTURE_DIR}/leaf.key" \
        -cert_chain "${FIXTURE_DIR}/chain.pem" \
        > /tmp/proxy-ca-test-server.log 2>&1 &
    SERVER_PID=$!
    sleep 1
    kill -0 "${SERVER_PID}" 2>/dev/null || { echo "ERROR: s_server failed to start"; exit 1; }
}

stop_server() {
    kill "${SERVER_PID}" 2>/dev/null || true
}

trap stop_server EXIT

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

reset_trust() {
    sudo rm -rf "${CERT_INSTALL_DIR}"
    sudo update-ca-certificates 2>/dev/null
}

run_scenario() {
    local name="$1"
    local issuer_pattern="$2"
    local key_fingerprint="$3"

    echo ""
    echo "--- ${name} ---"

    reset_trust

    sudo env \
        DETECT_URL="https://127.0.0.1:${PORT}" \
        ISSUER_PATTERN="${issuer_pattern}" \
        KEY_FINGERPRINT="${key_fingerprint}" \
        TRUST_CHAIN="false" \
        EXTRA_CERTS="" \
        bash "${FEATURE_DIR}/install.sh"

    if curl -fsSL --max-time 5 "https://127.0.0.1:${PORT}/" > /dev/null 2>&1; then
        echo "PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${name} — curl did not trust the installed root CA"
        FAIL=$((FAIL + 1))
    fi
}

# Expect no cert to be installed — curl must still fail after the feature runs.
run_negative_scenario() {
    local name="$1"
    local issuer_pattern="$2"
    local key_fingerprint="$3"

    echo ""
    echo "--- ${name} (expect no match) ---"

    reset_trust

    sudo env \
        DETECT_URL="https://127.0.0.1:${PORT}" \
        ISSUER_PATTERN="${issuer_pattern}" \
        KEY_FINGERPRINT="${key_fingerprint}" \
        TRUST_CHAIN="false" \
        EXTRA_CERTS="" \
        bash "${FEATURE_DIR}/install.sh"

    if curl -fsSL --max-time 5 "https://127.0.0.1:${PORT}/" > /dev/null 2>&1; then
        echo "FAIL: ${name} — root CA was installed but should not have been"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: ${name} — correctly rejected unrecognised chain"
        PASS=$((PASS + 1))
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight: confirm curl fails before any cert is installed
# -----------------------------------------------------------------------------

echo "--- pre-flight: expect SSL failure without installed CA ---"
if curl -fsSL --max-time 5 "https://127.0.0.1:${PORT}/" > /dev/null 2>&1; then
    echo "FAIL: pre-flight — curl succeeded before CA was installed (root may already be trusted)"
    FAIL=$((FAIL + 1))
else
    echo "PASS: pre-flight — curl correctly rejected untrusted server"
    PASS=$((PASS + 1))
fi

# -----------------------------------------------------------------------------
# Scenario 1: issuer pattern only
#
# Matches the leaf cert (index 0) whose issuer contains "O=Zscaler Inc.".
# Detection triggers; find_root_cert locates the self-signed root at index 2.
# -----------------------------------------------------------------------------

start_server

run_scenario \
    "issuer pattern only" \
    "O=Zscaler Inc." \
    ""

# -----------------------------------------------------------------------------
# Scenario 2: key fingerprint only
#
# Matches the intermediate (index 1) by SPKI fingerprint.
# ISSUER_PATTERN is empty so only the fingerprint check applies.
# -----------------------------------------------------------------------------

INTERMEDIATE_SPKI="$(cat "${FIXTURE_DIR}/intermediate-spki.txt")"

run_scenario \
    "key fingerprint only" \
    "" \
    "${INTERMEDIATE_SPKI}"

# -----------------------------------------------------------------------------
# Scenario 3: both issuer pattern and key fingerprint
#
# Leaf (index 0): issuer matches, but SPKI does not match intermediate — skipped.
# Intermediate (index 1): issuer matches AND SPKI matches — detected here.
# Root CA is then installed.
# -----------------------------------------------------------------------------

run_scenario \
    "issuer pattern + key fingerprint" \
    "O=Zscaler Inc." \
    "${INTERMEDIATE_SPKI}"

# -----------------------------------------------------------------------------
# Scenario 4: wrong issuer pattern — no cert should be installed
#
# ISSUER_PATTERN does not match any cert in the chain.
# The feature should log a "no matching certificate" warning and exit cleanly
# without installing anything. Curl must remain untrusted.
# -----------------------------------------------------------------------------

run_negative_scenario \
    "wrong issuer pattern" \
    "O=AcmeCorp" \
    ""

# -----------------------------------------------------------------------------
# Scenario 5: wrong key fingerprint — no cert should be installed
#
# KEY_FINGERPRINT is a valid base64 string but does not match any cert SPKI.
# Curl must remain untrusted.
# -----------------------------------------------------------------------------

run_negative_scenario \
    "wrong key fingerprint" \
    "" \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# -----------------------------------------------------------------------------
# Results
# -----------------------------------------------------------------------------

reset_trust

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
