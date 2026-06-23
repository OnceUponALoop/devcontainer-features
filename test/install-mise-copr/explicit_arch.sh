#!/bin/bash
set -e

source dev-container-features-test-lib

check "mise is on PATH" \
    which mise

check "mise version outputs successfully" \
    mise --version

check "mise binary is x86_64" \
    bash -c 'file $(which mise) | grep -q x86-64'

reportResults
