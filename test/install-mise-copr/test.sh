#!/bin/bash
set -e

source dev-container-features-test-lib

check "mise is on PATH" which mise
check "mise runs" mise --version

reportResults
