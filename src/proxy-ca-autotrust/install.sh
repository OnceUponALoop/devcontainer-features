#!/usr/bin/env bash
set -euo pipefail

# proxy-ca-autotrust devcontainer feature
#
# Probes DETECT_URL for SSL inspection. If the chain matches ISSUER_PATTERN
# and/or KEY_FINGERPRINT, the proxy root CA is automatically trusted.
# TRUST_CHAIN installs all non-leaf certs instead of just the root.
# EXTRA_CERTS installs additional CA sources on top of any detected cert.
#
# Options (injected by the devcontainer CLI):
#   DETECT_URL      — HTTPS URL to probe; empty skips detection
#   ISSUER_PATTERN  — case-insensitive issuer match
#   KEY_FINGERPRINT — SHA-256 SPKI fingerprint (base64) for key pinning
#   TRUST_CHAIN     — trust all non-leaf certs in the chain (default: false)
#   EXTRA_CERTS     — comma-separated CA sources (URL or absolute path)

DETECT_URL="${DETECT_URL:-https://example.com}"
ISSUER_PATTERN="${ISSUER_PATTERN:-O=Zscaler Inc.}"
KEY_FINGERPRINT="${KEY_FINGERPRINT:-}"
TRUST_CHAIN="${TRUST_CHAIN:-false}"
EXTRA_CERTS="${EXTRA_CERTS:-}"

CERT_DIR="/usr/local/share/ca-certificates/proxy-ca-autotrust"
TMP_DIR="$(mktemp -d)"

cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

log()  { echo "[proxy-ca-autotrust] $*"; }
warn() { echo "[proxy-ca-autotrust][WARN] ⚠️  $*" >&2; }
die()  { echo "[proxy-ca-autotrust][ERROR] ⛔ $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Chain Parsing
# -----------------------------------------------------------------------------

# Splits PEM blocks from TMP_DIR/chain.txt into individual
# TMP_DIR/chain-cert-N.pem files. Prints the number of certs found.
split_chain_certs() {
    local count=0
    local in_cert=false
    local cert_lines=()

    while IFS= read -r line; do
        if [[ "${line}" == "-----BEGIN CERTIFICATE-----" ]]; then
            in_cert=true
            cert_lines=("${line}")
        elif [[ "${line}" == "-----END CERTIFICATE-----" ]]; then
            cert_lines+=("${line}")
            printf '%s\n' "${cert_lines[@]}" > "${TMP_DIR}/chain-cert-${count}.pem"
            count=$((count + 1))
            in_cert=false
            cert_lines=()
        elif [[ "${in_cert}" == true ]]; then
            cert_lines+=("${line}")
        fi
    done < "${TMP_DIR}/chain.txt"

    echo "${count}"
}

# Walks the chain looking for a self-signed cert (subject == issuer).
# Falls back to the last cert in the chain if none is self-signed.
# Prints the path to the root cert file.
find_root_cert() {
    local count="$1"
    local root=""

    for i in $(seq 0 $((count - 1))); do
        local f="${TMP_DIR}/chain-cert-${i}.pem"
        local subj iss
        subj=$(openssl x509 -noout -subject -in "${f}" 2>/dev/null | sed 's/^subject=//')
        iss=$(openssl x509 -noout -issuer -in "${f}" 2>/dev/null | sed 's/^issuer=//')
        if [[ "${subj}" == "${iss}" ]]; then
            root="${f}"
            log "🔐 Root CA: ${subj}" >&2
        fi
    done

    if [[ -z "${root}" ]]; then
        root="${TMP_DIR}/chain-cert-$((count - 1)).pem"
        warn "No self-signed cert found, falling back to last cert in chain"
    fi

    echo "${root}"
}

# SHA-256 of the public key in base64.
# Pinning to the key rather than the cert survives renewal when the CA
# reuses its key pair, which most corporate CAs do.
cert_spki_fingerprint() {
    local cert_file="$1"
    openssl x509 -noout -pubkey -in "${cert_file}" 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary \
        | base64
}

# Installs chain certs at indices 1..count-1, skipping the leaf at index 0.
install_chain_certs() {
    local count="$1"

    for i in $(seq 1 $((count - 1))); do
        local f="${TMP_DIR}/chain-cert-${i}.pem"
        local subj
        subj=$(openssl x509 -noout -subject -in "${f}" 2>/dev/null | sed 's/^subject=//')
        cp "${f}" "${CERT_DIR}/chain-cert-${i}.crt"
        chmod 0644 "${CERT_DIR}/chain-cert-${i}.crt"
        log "✅ Trusted chain certificate: ${subj}"
    done
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------

# Returns 0 if a cert was installed, 1 if detection was skipped.
detect_and_trust_proxy_ca() {
    local url="${DETECT_URL}"
    [[ "${url}" =~ ^https?:// ]] || url="https://${url}"

    local hostport="${url#https://}"
    hostport="${hostport#http://}"
    hostport="${hostport%%/*}"

    local host port
    if [[ "${hostport}" == *:* ]]; then
        host="${hostport%:*}"
        port="${hostport##*:}"
    else
        host="${hostport}"
        port="443"
    fi

    log "🔍 Probing ${url}"

    if curl -fsSL --max-time 10 "${url}" -o /dev/null 2>/dev/null; then
        log "✅ SSL verification succeeded — no proxy CA needed"
        return 1
    fi

    log "🔗 SSL verification failed, fetching certificate chain from ${host}:${port}"

    openssl s_client \
        -connect "${host}:${port}" \
        -servername "${host}" \
        -showcerts \
        </dev/null 2>/dev/null \
        > "${TMP_DIR}/chain.txt" || true

    local count
    count=$(split_chain_certs)

    if ((count == 0)); then
        warn "No certificates in chain — skipping auto-trust"
        return 1
    fi

    local matched=false
    for i in $(seq 0 $((count - 1))); do
        local f="${TMP_DIR}/chain-cert-${i}.pem"
        local issuer_ok=true
        local key_ok=true

        if [[ -n "${ISSUER_PATTERN}" ]]; then
            local issuer
            issuer=$(openssl x509 -noout -issuer -in "${f}" 2>/dev/null || true)
            echo "${issuer}" | grep -qi "${ISSUER_PATTERN}" || issuer_ok=false
        fi

        if [[ -n "${KEY_FINGERPRINT}" ]]; then
            local fp
            fp=$(cert_spki_fingerprint "${f}")
            [[ "${fp}" == "${KEY_FINGERPRINT}" ]] || key_ok=false
        fi

        if [[ "${issuer_ok}" == true && "${key_ok}" == true ]]; then
            matched=true
            log "🎯 Matched proxy CA at chain index ${i}"
            break
        fi
    done

    if [[ "${matched}" != true ]]; then
        warn "No matching certificate found in chain — skipping auto-trust"
        return 1
    fi

    mkdir -p "${CERT_DIR}"

    if [[ "${TRUST_CHAIN}" == "true" ]]; then
        install_chain_certs "${count}"
    else
        local root
        root=$(find_root_cert "${count}")
        cp "${root}" "${CERT_DIR}/proxy-root.crt"
        chmod 0644 "${CERT_DIR}/proxy-root.crt"
        log "🔐 Proxy root CA installed"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Extra Certs
# -----------------------------------------------------------------------------

fetch_cert_source() {
    local source="$1"
    local output="$2"

    if [[ "${source}" =~ ^https?:// ]]; then
        curl -fsSL "${source}" -o "${output}"
        return
    fi

    [[ -f "${source}" ]] || die "Certificate source '${source}' not found"
    cp "${source}" "${output}"
}

# Accepts both PEM and DER; converts DER to PEM when needed.
convert_to_pem() {
    local input="$1"
    local output="$2"

    if openssl x509 -inform DER -in "${input}" -noout >/dev/null 2>&1; then
        openssl x509 -inform DER -in "${input}" -outform PEM -out "${output}"
        return
    fi

    if openssl x509 -in "${input}" -noout >/dev/null 2>&1; then
        openssl x509 -in "${input}" -outform PEM -out "${output}"
        return
    fi

    die "Source '${input}' is not a valid DER or PEM certificate"
}

install_extra_certs() {
    mkdir -p "${CERT_DIR}"

    local counter=0
    IFS=',' read -r -a sources <<< "${EXTRA_CERTS}"

    for source in "${sources[@]}"; do
        [[ -n "${source}" ]] || continue

        local raw="${TMP_DIR}/extra-${counter}.source"
        local pem="${CERT_DIR}/extra-${counter}.crt"

        log "⏬ Installing extra certificate ${counter}: ${source}"
        fetch_cert_source "${source}" "${raw}"
        convert_to_pem "${raw}" "${pem}"
        chmod 0644 "${pem}"

        counter=$((counter + 1))
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    if [[ -n "${DETECT_URL}" ]]; then
        [[ -n "${ISSUER_PATTERN}" || -n "${KEY_FINGERPRINT}" ]] \
            || die "at least one of issuer_pattern or key_fingerprint must be set when detect_url is set"

        if detect_and_trust_proxy_ca; then
            # update now so extra_certs HTTPS downloads work through the proxy
            update-ca-certificates
        fi
    fi

    if [[ -n "${EXTRA_CERTS}" ]]; then
        install_extra_certs
        update-ca-certificates
    fi

    log "✅ Done"
}

main "$@"
