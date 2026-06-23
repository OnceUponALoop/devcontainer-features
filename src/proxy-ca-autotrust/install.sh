#!/usr/bin/env bash
set -euo pipefail

# proxy-ca-autotrust devcontainer feature
#
# Detects a TLS trust gap by probing TLS_TEST_URL. If verification fails,
# fetches the certificate chain and scans it for a CA matching CERT_PATTERN
# and/or KEY_FINGERPRINT. When found, installs the root CA (or the full
# non-leaf chain if TRUST_CHAIN is set) and runs update-ca-certificates.
# EXTRA_CERTS installs additional CA sources regardless of detection.
#
# Options (injected by the devcontainer CLI):
#   TLS_TEST_URL    - HTTPS URL probed to detect a trust gap; empty skips detection
#   CERT_PATTERN    - case-insensitive regex matched against full cert text
#   KEY_FINGERPRINT - SHA-256 SPKI fingerprint (base64) for key pinning
#   TRUST_CHAIN     - trust all non-leaf certs in the chain (default: false)
#   EXTRA_CERTS     - comma-separated CA sources (URL or absolute path)

# Fallback defaults for standalone invocation — devcontainer CLI uses devcontainer-feature.json
TLS_TEST_URL="${TLS_TEST_URL-https://example.com}"
CERT_PATTERN="${CERT_PATTERN-Subject:.*O=Zscaler Inc\.}"
KEY_FINGERPRINT="${KEY_FINGERPRINT-}"
TRUST_CHAIN="${TRUST_CHAIN-false}"
EXTRA_CERTS="${EXTRA_CERTS-}"

readonly CERT_DIR="/usr/local/share/ca-certificates/proxy-ca-autotrust"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

log()  { echo "[proxy-ca-autotrust] $*"; }
warn() { echo "[proxy-ca-autotrust][WARN] ⚠️  $*" >&2; }
die()  { echo "[proxy-ca-autotrust][ERROR] ⛔ $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Chain Parsing
# -----------------------------------------------------------------------------

# split_chain_certs
#
# Reads TMP_DIR/chain.txt and extracts each PEM-encoded certificate block into
# a separate file named TMP_DIR/chain-cert-N.pem (zero-indexed, preserving
# chain order: leaf at 0, root at count-1).
#
# Globals read:  TMP_DIR
# Outputs:       stdout - the number of certificates written
split_chain_certs() {
    local count=0
    local in_cert=false
    local -a cert_lines=()

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

# find_root_cert
#
# Walks the chain from the end toward the leaf, looking for the first
# self-signed certificate (subject DN == issuer DN). Self-signed certs appear
# at the tail of a well-formed chain, so iterating in reverse finds the root
# without scanning past it. Falls back to the last cert if none is self-signed.
#
# Arguments:
#   $1  count - total number of chain certs (as returned by split_chain_certs)
# Globals read:  TMP_DIR
# Outputs:       stdout - absolute path to the root cert PEM file
find_root_cert() {
    local -r count="$1"
    local i f subj iss

    for i in $(seq $((count - 1)) -1 0); do
        f="${TMP_DIR}/chain-cert-${i}.pem"
        subj=$(openssl x509 -noout -subject -nameopt compat -in "${f}" 2>/dev/null | sed 's/^subject=//' || true)
        iss=$(openssl x509 -noout -issuer  -nameopt compat -in "${f}" 2>/dev/null | sed 's/^issuer=//'  || true)
        if [[ -n "${subj}" && "${subj}" == "${iss}" ]]; then
            log "🔐 Root CA: ${subj}" >&2
            echo "${f}"
            return
        fi
    done

    warn "No self-signed cert found; falling back to last cert in chain"
    echo "${TMP_DIR}/chain-cert-$((count - 1)).pem"
}

# cert_get_issuer_url
#
# Extracts all CA Issuers URIs from the Authority Information Access extension
# of cert_file, one per line. Used by fetch_chain to complete a chain when the
# server omits the root CA (common — servers routinely stop at the last
# intermediate). Prints nothing if the AIA extension is absent, which is
# typical for self-signed corporate root CAs.
#
# Arguments:
#   $1  cert_file - path to a PEM-encoded certificate
# Outputs:  stdout - CA Issuers URIs, one per line; empty if none present
cert_get_issuer_url() {
    local -r cert_file="$1"
    openssl x509 -noout -text -in "${cert_file}" 2>/dev/null \
        | awk 'BEGIN {FS="CA Issuers - URI:"} NF==2 {print $2}'
}

# cert_spki_fingerprint
#
# Computes the SHA-256 digest of the DER-encoded SubjectPublicKeyInfo of a
# certificate and prints it as a lowercase hex string. Pinning to the public
# key rather than the certificate survives re-issuance when the CA reuses its
# key pair, which most corporate CAs do.
#
# Arguments:
#   $1  cert_file - path to a PEM-encoded certificate
# Outputs:         stdout - lowercase hex SHA-256 SPKI fingerprint
cert_spki_fingerprint() {
    local -r cert_file="$1"
    openssl x509 -noout -pubkey -in "${cert_file}" 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -r \
        | cut -d ' ' -f1
}

# install_chain_certs
#
# Copies chain-cert-1 through chain-cert-(count-1) from TMP_DIR into CERT_DIR
# as chain-cert-N.crt. Skips index 0 (the server leaf certificate), which
# should never be trusted as a CA.
#
# Arguments:
#   $1  count - total number of chain certs (as returned by split_chain_certs)
# Globals read:  TMP_DIR, CERT_DIR
install_chain_certs() {
    local -r count="$1"
    local i f subj

    for i in $(seq 1 $((count - 1))); do
        f="${TMP_DIR}/chain-cert-${i}.pem"
        subj=$(openssl x509 -noout -subject -nameopt compat -in "${f}" 2>/dev/null | sed 's/^subject=//' || true)
        cp "${f}" "${CERT_DIR}/chain-cert-${i}.crt"
        chmod 0644 "${CERT_DIR}/chain-cert-${i}.crt"
        log "✅ Trusted chain certificate: ${subj}"
    done
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------

# can_verify_tls
#
# Attempts an HTTPS GET of TLS_TEST_URL using curl's default CA bundle to
# determine whether the current trust store is sufficient. Success means there
# is no trust gap and no action is needed. Network failures are treated the
# same as SSL failures - both signal that trust cannot be established.
#
# Globals read:  TLS_TEST_URL
# Returns:       0 - TLS verification succeeded; trust store is complete
#                1 - TLS verification failed or network error; trust gap likely
can_verify_tls() {
    local url="${TLS_TEST_URL}"
    [[ "${url}" =~ ^https?:// ]] || url="https://${url}"
    log "🔍 Probing ${url}"
    curl -fsSL --max-time 10 "${url}" -o /dev/null 2>/dev/null
}

# fetch_chain
#
# Connects to the host and port extracted from TLS_TEST_URL using
# openssl s_client -showcerts, captures the full PEM output to
# TMP_DIR/chain.txt, then calls split_chain_certs to split it into
# individual files. Always succeeds — connection failures produce an
# empty chain.txt and CHAIN_CERT_COUNT=0.
#
# After splitting, if the last cert in the chain is not self-signed (i.e.
# the server omitted the root CA), attempts to fetch it via the CA Issuers
# URIs in the last cert's AIA extension, trying each in order. On success,
# the fetched root is appended as chain-cert-N.pem and CHAIN_CERT_COUNT is
# incremented. If no AIA is present or all fetches fail, the chain is left
# as-is and find_root_cert falls back to the last cert.
#
# Globals read:   TLS_TEST_URL, TMP_DIR
# Globals set:    CHAIN_CERT_COUNT - number of certificates in the chain
fetch_chain() {
    CHAIN_CERT_COUNT=0

    local url="${TLS_TEST_URL}"
    [[ "${url}" =~ ^https?:// ]] || url="https://${url}"

    local hostport="${url#https://}"
    hostport="${hostport%%/*}"

    local host port
    if [[ "${hostport}" == *:* ]]; then
        host="${hostport%:*}"
        port="${hostport##*:}"
    else
        host="${hostport}"
        port="443"
    fi

    log "🔗 Fetching certificate chain from ${host}:${port}"

    openssl s_client \
        -connect "${host}:${port}" \
        -servername "${host}" \
        -showcerts \
        </dev/null 2>/dev/null \
        > "${TMP_DIR}/chain.txt" || true

    CHAIN_CERT_COUNT=$(split_chain_certs)

    (( CHAIN_CERT_COUNT == 0 )) && return

    local last="${TMP_DIR}/chain-cert-$((CHAIN_CERT_COUNT - 1)).pem"
    local last_subj last_iss
    last_subj=$(openssl x509 -noout -subject -nameopt compat -in "${last}" 2>/dev/null | sed 's/^subject=//' || true)
    last_iss=$(openssl x509 -noout -issuer  -nameopt compat -in "${last}" 2>/dev/null | sed 's/^issuer=//'  || true)

    [[ -n "${last_subj}" && "${last_subj}" == "${last_iss}" ]] && return

    local aia_url aia_raw aia_pem
    aia_raw="${TMP_DIR}/aia-root.source"
    aia_pem="${TMP_DIR}/chain-cert-${CHAIN_CERT_COUNT}.pem"

    while IFS= read -r aia_url; do
        [[ -n "${aia_url}" ]] || continue
        log "🔗 Root CA absent from chain; trying AIA: ${aia_url}"
        if fetch_cert_source "${aia_url}" "${aia_raw}" && \
           convert_to_pem "${aia_raw}" "${aia_pem}"; then
            CHAIN_CERT_COUNT=$((CHAIN_CERT_COUNT + 1))
            log "🔗 Root CA appended to chain via AIA"
            return
        fi
    done < <(cert_get_issuer_url "${last}")
}

# cert_matches_pattern
#
# Runs openssl x509 -text on cert_file and pipes the output through grep
# against CERT_PATTERN (case-insensitive BRE). Intended to identify a
# known proxy CA by a distinguishing field such as its Subject or Issuer.
#
# Arguments:
#   $1  cert_file - path to a PEM-encoded certificate
# Globals read:  CERT_PATTERN
# Returns:       0 - pattern matched
#                1 - no match or openssl error
cert_matches_pattern() {
    local -r cert_file="$1"
    local cert_text
    cert_text=$(openssl x509 -noout -text -in "${cert_file}" 2>/dev/null || true)
    echo "${cert_text}" | grep -qi -- "${CERT_PATTERN}"
}

# cert_matches_fingerprint
#
# Computes the SPKI fingerprint of cert_file via cert_spki_fingerprint and
# compares it to KEY_FINGERPRINT. Emits a warning on mismatch showing both
# the expected and actual values to aid debugging.
#
# Arguments:
#   $1  cert_file - path to a PEM-encoded certificate
# Globals read:  KEY_FINGERPRINT
# Returns:       0 - fingerprint matched
#                1 - mismatch (warning emitted) or openssl error
cert_matches_fingerprint() {
    local -r cert_file="$1"
    local fp
    fp=$(cert_spki_fingerprint "${cert_file}")
    if [[ "${fp}" == "${KEY_FINGERPRINT}" ]]; then
        return 0
    fi
    warn "🔑 Fingerprint mismatch - found: ${fp}"
    return 1
}

# scan_chain_for_ca
#
# Walks the already-fetched chain certs (TMP_DIR/chain-cert-N.pem, 0-indexed)
# looking for the first cert that satisfies the configured matching policy:
#
#   CERT_PATTERN only:    cert[i] text must match CERT_PATTERN
#   KEY_FINGERPRINT only: cert[i] SPKI fingerprint must match KEY_FINGERPRINT
#   Both set:             cert[i] text must match CERT_PATTERN AND cert[i+1]
#                         SPKI fingerprint must match KEY_FINGERPRINT
#                         (i+1 is the issuer of the matched cert, enabling
#                         two-factor pinning: identify by content, verify by key)
#
# Globals read:  CHAIN_CERT_COUNT, TMP_DIR, CERT_PATTERN, KEY_FINGERPRINT
# Returns:       0 - a cert satisfying the policy was found in the chain
#                1 - no cert matched
scan_chain_for_ca() {
    local i f issuer_cert
    for i in $(seq 0 $((CHAIN_CERT_COUNT - 1))); do
        f="${TMP_DIR}/chain-cert-${i}.pem"

        if [[ -n "${CERT_PATTERN}" ]]; then
            cert_matches_pattern "${f}" || continue
            log "🔍 Pattern matched cert at chain index ${i}"
        fi

        if [[ -n "${KEY_FINGERPRINT}" ]]; then
            if [[ -n "${CERT_PATTERN}" ]]; then
                # Both options set: cert[i] matched the pattern, so fingerprint cert[i+1] -
                # the cert that *issued* cert[i]. This verifies the root CA (what we're about
                # to trust) rather than the intermediate we identified by content.
                issuer_cert="${TMP_DIR}/chain-cert-$((i + 1)).pem"
                if [[ ! -f "${issuer_cert}" ]]; then
                    warn "Pattern matched at chain index ${i} but no issuer cert at index $((i + 1)) - skipping"
                    continue
                fi
                cert_matches_fingerprint "${issuer_cert}" || continue
            else
                # Fingerprint only: no pattern to anchor on, so check cert[i] directly.
                cert_matches_fingerprint "${f}" || continue
            fi
        fi

        log "🎯 Matched proxy CA at chain index ${i}"
        return 0
    done

    warn "No matching certificate found in chain - skipping auto-trust"
    return 1
}

# -----------------------------------------------------------------------------
# Extra Certs
# -----------------------------------------------------------------------------

# fetch_cert_source
#
# Retrieves a certificate from source and writes the raw bytes to output.
# source may be an HTTP/HTTPS URL (fetched with curl) or an absolute path to
# a local file. The output is not validated or converted here - call
# convert_to_pem afterwards.
#
# Arguments:
#   $1  source - HTTPS URL or absolute path to a certificate file
#   $2  output - destination path for the raw certificate bytes
fetch_cert_source() {
    local -r source="$1"
    local -r output="$2"

    if [[ "${source}" =~ ^https?:// ]]; then
        curl -fsSL "${source}" -o "${output}"
        return
    fi

    [[ -f "${source}" ]] || die "Certificate source '${source}' not found"
    cp "${source}" "${output}"
}

# convert_to_pem
#
# Detects whether input is DER- or PEM-encoded by probing with openssl x509,
# then writes a PEM-encoded copy to output. Dies if the file is neither.
#
# Arguments:
#   $1  input  - path to a DER- or PEM-encoded certificate
#   $2  output - destination path for the PEM-encoded certificate
convert_to_pem() {
    local -r input="$1"
    local -r output="$2"

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

# install_extra_certs
#
# Iterates the comma-separated EXTRA_CERTS list. For each entry, fetches the
# source via fetch_cert_source, normalises it to PEM via convert_to_pem, and
# installs it as CERT_DIR/extra-N.crt. Supports URLs and local paths in both
# PEM and DER formats.
#
# Globals read:  EXTRA_CERTS, TMP_DIR, CERT_DIR
install_extra_certs() {
    mkdir -p "${CERT_DIR}"

    local counter=0
    local raw pem source
    local -a sources
    IFS=',' read -r -a sources <<< "${EXTRA_CERTS}"

    for source in "${sources[@]}"; do
        [[ -n "${source}" ]] || continue

        raw="${TMP_DIR}/extra-${counter}.source"
        pem="${CERT_DIR}/extra-${counter}.crt"

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
    if [[ -n "${TLS_TEST_URL}" ]]; then
        [[ -n "${CERT_PATTERN}" || -n "${KEY_FINGERPRINT}" ]] \
            || die "at least one of cert_pattern or key_fingerprint must be set when tls_test_url is set"

        if can_verify_tls; then
            log "✅ TLS verification succeeded - no trust gap"
        else
            fetch_chain
            if (( CHAIN_CERT_COUNT == 0 )); then
                warn "No certificates in chain - skipping auto-trust"
            elif scan_chain_for_ca; then
                mkdir -p "${CERT_DIR}"

                if [[ "${TRUST_CHAIN}" == "true" ]]; then
                    install_chain_certs "${CHAIN_CERT_COUNT}"
                else
                    local root
                    root=$(find_root_cert "${CHAIN_CERT_COUNT}")
                    cp "${root}" "${CERT_DIR}/proxy-root.crt"
                    chmod 0644 "${CERT_DIR}/proxy-root.crt"
                    log "🔐 Proxy root CA installed"
                fi

                # update now so extra_certs HTTPS downloads work through the proxy
                update-ca-certificates
            fi
        fi
    fi

    if [[ -n "${EXTRA_CERTS}" ]]; then
        install_extra_certs
        update-ca-certificates
    fi

    log "✅ Done"
}

main "$@"
