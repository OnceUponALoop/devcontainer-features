#!/usr/bin/env bash
# Generate a 3-tier chain: root -> intermediate -> leaf.
# Fixtures are committed to the repo; re-run only when you need to rotate them.
#
# Usage: ./generate.sh
set -euo pipefail

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${OUT_DIR}"

echo "Generating TLS fixtures in: ${OUT_DIR}"

# -----------------------------------------------------------------------------
# Root CA
# -----------------------------------------------------------------------------

cat > root.cnf << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no

[ dn ]
CN = Test Zscaler Root CA
O  = Zscaler Inc.

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
# Intermediate CA
# -----------------------------------------------------------------------------

cat > intermediate.cnf << 'EOF'
[ req ]
distinguished_name = dn
prompt             = no

[ dn ]
CN = Test Zscaler Intermediate
O  = Zscaler Inc.

[ v3_int ]
basicConstraints       = critical,CA:TRUE,pathlen:0
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl req \
    -new -newkey rsa:2048 -nodes \
    -keyout intermediate.key \
    -out intermediate.csr \
    -config intermediate.cnf

openssl x509 \
    -req \
    -in intermediate.csr \
    -CA root.pem -CAkey root.key -CAcreateserial \
    -days 365 \
    -out intermediate.pem \
    -extfile intermediate.cnf -extensions v3_int

# -----------------------------------------------------------------------------
# Leaf
# -----------------------------------------------------------------------------

cat > leaf.cnf << 'EOF'
[ req ]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no

[ dn ]
CN = test.example

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
    -CA intermediate.pem -CAkey intermediate.key -CAcreateserial \
    -days 30 \
    -out leaf.pem \
    -extfile leaf.cnf -extensions v3_req

# -----------------------------------------------------------------------------
# Derived artifacts
# -----------------------------------------------------------------------------

# Full chain sent by the TLS server (intermediate + root).
# Including the root lets the feature identify the self-signed trust anchor.
cat intermediate.pem root.pem > chain.pem

# SPKI fingerprint of the intermediate — used for key_fingerprint test scenarios.
# The intermediate appears at chain index 1 and its issuer (the root) carries
# O=Zscaler Inc., so both the issuer-pattern and combined tests target it.
openssl x509 -noout -pubkey -in intermediate.pem \
    | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -binary \
    | base64 > intermediate-spki.txt

echo ""
echo "=== chain verification ==="
openssl verify -CAfile root.pem -untrusted intermediate.pem leaf.pem
echo ""
echo "=== leaf issuer (must contain 'O=Zscaler Inc.') ==="
openssl x509 -noout -issuer -in leaf.pem
echo ""
echo "=== intermediate SPKI fingerprint ==="
cat intermediate-spki.txt

rm -f root.cnf intermediate.cnf leaf.cnf intermediate.csr leaf.csr *.srl

echo ""
echo "Fixtures ready."
