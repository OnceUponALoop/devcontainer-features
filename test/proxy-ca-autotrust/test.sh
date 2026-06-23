#!/bin/bash
set -e

source dev-container-features-test-lib

check "curl available" which curl
check "openssl available" which openssl
check "ca bundle present" test -f "/etc/ssl/certs/ca-certificates.crt"

reportResults
