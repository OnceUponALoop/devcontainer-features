#!/usr/bin/env bash
set -euo pipefail

# install-mise-copr devcontainer feature
#
# Installs mise by delegating to mise-install, then copies it into the
# container as mise-update for subsequent use.
#
# Options (injected by the devcontainer CLI as environment variables):
#   VERSION        — mise version to install, or "latest" (default: latest)
#   FEDORA_RELEASE — Fedora release for COPR build artifacts (default: 44)
#   ARCH           — CPU architecture; auto-detected from uname -m if empty

export DEBIAN_FRONTEND=noninteractive

FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------

apt-get update -y
apt-get install -y --no-install-recommends \
    curl \
    libarchive-tools

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------

# VERSION / FEDORA_RELEASE / ARCH are already in the environment from the
# devcontainer CLI — mise-install picks them up directly.
bash "${FEATURE_DIR}/install-mise.sh"

install -Dm755 "${FEATURE_DIR}/install-mise.sh" /usr/local/bin/mise-update
