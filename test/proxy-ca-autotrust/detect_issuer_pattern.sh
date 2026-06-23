#!/bin/bash
set -e

source dev-container-features-test-lib

check "proxy root CA file installed" \
    test -f "/usr/local/share/ca-certificates/proxy-ca-autotrust/proxy-root.crt"

check "installed cert is a valid PEM certificate" \
    openssl x509 -noout -in "/usr/local/share/ca-certificates/proxy-ca-autotrust/proxy-root.crt"

check "installed cert subject matches test root CA" \
    bash -c 'openssl x509 -noout -subject -nameopt compat -in /usr/local/share/ca-certificates/proxy-ca-autotrust/proxy-root.crt | grep -q "Test Corp Root CA"'

check "installed cert is self-signed" \
    bash -c 'subj=$(openssl x509 -noout -subject -nameopt compat -in /usr/local/share/ca-certificates/proxy-ca-autotrust/proxy-root.crt | sed "s/^subject=//"); iss=$(openssl x509 -noout -issuer -nameopt compat -in /usr/local/share/ca-certificates/proxy-ca-autotrust/proxy-root.crt | sed "s/^issuer=//"); [ "$subj" = "$iss" ]'

check "system CA bundle present" \
    test -f "/etc/ssl/certs/ca-certificates.crt"

reportResults
