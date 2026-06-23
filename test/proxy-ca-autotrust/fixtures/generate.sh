#!/usr/bin/env bash
# Generate a 4-tier chain: root → subordinate CA → issuing CA → leaf.
# Fixtures are committed to the repo; re-run only when you need to rotate them.
#
# Chain structure mirrors a real corporate SSL inspection proxy setup:
#   cert[0] leaf      — O=Test Proxy Inc.   (proxy replaced the real site cert)
#   cert[1] issuing   — O=Test Corp         (issued the proxy's fake leaf)
#   cert[2] subordinate — O=Test Corp       (intermediate between root and issuing)
#   cert[3] root      — O=Test Corp, self-signed (what the feature installs)
#
# Detection logic:
#   cert_pattern "O=Test Proxy Inc\." matches cert[0] (the proxy-generated leaf).
#   key_fingerprint pins the issuing CA at cert[1] (issuer of the matched cert).
#
# Usage: ./generate.sh
set -euo pipefail

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${OUT_DIR}"

echo "Generating TLS fixtures in: ${OUT_DIR}"

# Remove old intermediate files from the 3-tier layout if present.
rm -f intermediate.pem intermediate.key intermediate-spki.txt

# -----------------------------------------------------------------------------
# Root CA (self-signed, top of trust chain)
# -----------------------------------------------------------------------------

cat > root.cnf << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no

[ dn ]
CN = Test Corp Root CA
O  = Test Corp

[ v3_ca ]
basicConstraints       = critical,CA:TRUE
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req \
    -new -newkey rsa:2048 -nodes \
    -keyout root.key \
    -x509 -days 3650 \
    -out root.pem \
    -config root.cnf

# -----------------------------------------------------------------------------
# Subordinate CA (signed by root; delegates to issuing CA)
# -----------------------------------------------------------------------------

cat > subordinate.cnf << 'EOF'
[ req ]
distinguished_name = dn
prompt             = no

[ dn ]
CN = Test Corp Subordinate CA
O  = Test Corp

[ v3_sub ]
basicConstraints       = critical,CA:TRUE,pathlen:1
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req \
    -new -newkey rsa:2048 -nodes \
    -keyout subordinate.key \
    -out subordinate.csr \
    -config subordinate.cnf

openssl x509 \
    -req \
    -in subordinate.csr \
    -CA root.pem -CAkey root.key -CAcreateserial \
    -days 1825 \
    -out subordinate.pem \
    -extfile subordinate.cnf -extensions v3_sub

# -----------------------------------------------------------------------------
# Issuing CA (signed by subordinate CA; signs leaf certs directly)
# -----------------------------------------------------------------------------

cat > issuing.cnf << 'EOF'
[ req ]
distinguished_name = dn
prompt             = no

[ dn ]
CN = Test Corp Issuing CA
O  = Test Corp

[ v3_issuing ]
basicConstraints       = critical,CA:TRUE,pathlen:0
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req \
    -new -newkey rsa:2048 -nodes \
    -keyout issuing.key \
    -out issuing.csr \
    -config issuing.cnf

openssl x509 \
    -req \
    -in issuing.csr \
    -CA subordinate.pem -CAkey subordinate.key -CAcreateserial \
    -days 730 \
    -out issuing.pem \
    -extfile issuing.cnf -extensions v3_issuing

# -----------------------------------------------------------------------------
# Leaf (proxy-generated end-entity cert, signed by issuing CA)
#
# O=Test Proxy Inc. simulates a corporate SSL inspection proxy replacing the
# real site cert with one it generated. The issuing CA chain above is the
# corporate PKI — not the proxy's own CA. The cert_pattern "O=Test Proxy Inc\."
# matches this cert; the feature then verifies the issuing CA (cert[1]) by
# key_fingerprint.
# -----------------------------------------------------------------------------

cat > leaf.cnf << 'EOF'
[ req ]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no

[ dn ]
CN = test.example
O  = Test Proxy Inc.

[ v3_req ]
basicConstraints  = critical,CA:FALSE
keyUsage          = critical,digitalSignature,keyEncipherment
extendedKeyUsage  = serverAuth
subjectAltName    = DNS:test.example,DNS:localhost,IP:127.0.0.1
EOF

openssl req \
    -new -newkey rsa:2048 -nodes \
    -keyout leaf.key \
    -out leaf.csr \
    -config leaf.cnf

openssl x509 \
    -req \
    -in leaf.csr \
    -CA issuing.pem -CAkey issuing.key -CAcreateserial \
    -days 30 \
    -out leaf.pem \
    -extfile leaf.cnf -extensions v3_req

# -----------------------------------------------------------------------------
# Derived artifacts
# -----------------------------------------------------------------------------

# Full chain sent by the TLS server: issuing CA → subordinate CA → root.
# Including the root lets find_root_cert identify the self-signed trust anchor.
cat issuing.pem subordinate.pem root.pem > chain.pem

# SPKI fingerprint of the issuing CA (hex-encoded SHA-256 of DER public key).
# The issuing CA sits at chain index 1 in the s_client output (leaf is index 0).
# detect_key_fingerprint pins directly to cert[1]; detect_both matches the
# proxy-generated leaf (O=Test Proxy Inc.) by cert_pattern, then verifies the
# issuing CA (cert[1], the issuer of the matched cert) by key_fingerprint.
openssl x509 -noout -pubkey -in issuing.pem \
    | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -r \
    | cut -d ' ' -f1 > issuing-spki.txt

echo ""
echo "=== chain verification ==="
cat issuing.pem subordinate.pem > intermediates.pem
openssl verify -CAfile root.pem -untrusted intermediates.pem leaf.pem
rm -f intermediates.pem

echo ""
echo "=== leaf issuer (must be O=Test Corp) ==="
openssl x509 -noout -issuer -in leaf.pem

echo ""
echo "=== issuing CA SPKI fingerprint ==="
cat issuing-spki.txt

rm -f root.cnf subordinate.cnf issuing.cnf leaf.cnf \
      subordinate.csr issuing.csr leaf.csr *.srl

echo ""
echo "Fixtures ready."
