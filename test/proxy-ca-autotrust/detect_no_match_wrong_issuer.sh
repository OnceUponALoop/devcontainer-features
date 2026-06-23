#!/bin/bash
set -e

source dev-container-features-test-lib

check "proxy root CA was NOT installed" \
    test ! -f "/usr/local/share/ca-certificates/proxy-ca-autotrust/proxy-root.crt"

check "system CA bundle present" \
    test -f "/etc/ssl/certs/ca-certificates.crt"

reportResults
