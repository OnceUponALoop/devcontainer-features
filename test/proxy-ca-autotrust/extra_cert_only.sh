#!/bin/bash
set -e

source dev-container-features-test-lib

check "extra cert file installed" \
    test -f "/usr/local/share/ca-certificates/proxy-ca-autotrust/extra-0.crt"

check "extra cert is a valid PEM certificate" \
    openssl x509 -noout -in "/usr/local/share/ca-certificates/proxy-ca-autotrust/extra-0.crt"

check "extra cert subject matches ISRG Root X1" \
    bash -c 'openssl x509 -noout -subject -nameopt compat -in /usr/local/share/ca-certificates/proxy-ca-autotrust/extra-0.crt | grep -qi "ISRG Root X1"'

check "system CA bundle present and updated" \
    test -f "/etc/ssl/certs/ca-certificates.crt"

check "curl reaches letsencrypt.org using installed CA" \
    curl -fsSL --max-time 10 https://letsencrypt.org/ -o /dev/null

reportResults
