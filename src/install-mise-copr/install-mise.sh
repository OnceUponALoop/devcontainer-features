#!/usr/bin/env bash
set -euo pipefail

# mise-install: install or update mise from the jdxcode/mise COPR repository.
#
# Called by the install-mise-copr devcontainer feature at build time, and
# installed in the container as mise-update for subsequent use.
#
# Usage (as mise-update):  sudo mise-update [version]
#
# Variable resolution (first wins):
#   VERSION        — $1 | VERSION env (set by devcontainer CLI) | "latest"
#   FEDORA_RELEASE — MISE_FEDORA_RELEASE env | FEDORA_RELEASE env | "44"
#   ARCH           — MISE_ARCH env | ARCH env | uname -m

VERSION="${1:-${VERSION:-latest}}"
FEDORA_RELEASE="${MISE_FEDORA_RELEASE:-${FEDORA_RELEASE:-44}}"
ARCH="${MISE_ARCH:-${ARCH:-}}"

readonly OWNER="jdxcode"
readonly PROJECT="mise"
readonly PACKAGE="mise"
readonly INSTALL_PREFIX="/usr/local"

log() { echo "[mise-install] $*"; }
die() { echo "[mise-install][ERROR] ⛔ $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "must be run as root — try: sudo $(basename "$0") $*"

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

fetch_primary_metadata() {
    local base_url="$1"

    curl -fsSL "${base_url}/repodata/repomd.xml" -o "${WORK_DIR}/repomd.xml"

    local primary_rel_path
    primary_rel_path="$(
        sed -n '/<data type="primary"/,/<\/data>/p' "${WORK_DIR}/repomd.xml" \
            | sed -n 's/.*href="\([^"]*\)".*/\1/p' \
            | head -n1
    )"

    [[ -n "${primary_rel_path}" ]] || die "failed to locate primary metadata in repomd.xml"

    curl -fsSL "${base_url}/${primary_rel_path}" -o "${WORK_DIR}/primary.xml.gz"
}

find_rpm_path() {
    local arch="$1"

    local version_pat
    [[ "${VERSION}" == "latest" ]] \
        && version_pat="[^\"]*" \
        || version_pat="${VERSION}-[^\"]*"

    local rpm_rel_path
    rpm_rel_path="$(
        gzip -cd "${WORK_DIR}/primary.xml.gz" \
            | sed -n "s/.*href=\"\([^\"]*\/${PACKAGE}-${version_pat}\.${arch}\.rpm\)\".*/\1/p" \
            | sort -V \
            | tail -n1
    )"

    [[ -n "${rpm_rel_path}" ]] \
        || die "no ${PACKAGE} RPM found for version '${VERSION}' (fedora-${FEDORA_RELEASE}-${arch})"

    echo "${rpm_rel_path}"
}

install_payload() {
    local extract_dir="$1"

    while IFS= read -r src; do
        local rel="${src#"${extract_dir}/usr/"}"
        local dst="${INSTALL_PREFIX}/${rel}"
        mkdir -p "$(dirname "${dst}")"
        cp -a "${src}" "${dst}"
    done < <(find "${extract_dir}/usr" -type f)
}

# Re-applied after every install so the RPM never restores the dnf instructions.
replace_update_instructions() {
    local f
    for f in \
        "/usr/lib64/${PACKAGE}/mise-self-update-instructions.toml" \
        "${INSTALL_PREFIX}/lib64/${PACKAGE}/mise-self-update-instructions.toml"; do
        [[ -e "${f}" || "${f}" == "/usr/lib64/${PACKAGE}/mise-self-update-instructions.toml" ]] || continue
        mkdir -p "$(dirname "${f}")"
        cat > "${f}" << 'EOF'
# mise in this devcontainer is managed by the install-mise-copr feature.
# Use mise-update to update instead of dnf.

message = """
mise was installed via the install-mise-copr devcontainer feature.

To update, run:
  sudo mise-update              # latest release
  sudo mise-update 2024.12.19  # specific version
"""
EOF
        log "📝 Replaced self-update instructions: ${f}"
    done
}

main() {
    if [[ -z "${ARCH}" ]]; then
        ARCH="$(uname -m)"
        log "🖥️  Auto-detected architecture: ${ARCH}"
    fi

    local base_url="https://download.copr.fedorainfracloud.org/results/${OWNER}/${PROJECT}/fedora-${FEDORA_RELEASE}-${ARCH}"

    log "🔍 Resolving mise ${VERSION} (fedora-${FEDORA_RELEASE}-${ARCH})"
    fetch_primary_metadata "${base_url}"

    local rpm_rel_path
    rpm_rel_path="$(find_rpm_path "${ARCH}")"

    log "⏬ Downloading $(basename "${rpm_rel_path}")"
    curl -fsSL "${base_url}/${rpm_rel_path}" -o "${WORK_DIR}/mise.rpm"

    local extract_dir="${WORK_DIR}/extract"
    mkdir -p "${extract_dir}"
    bsdtar -xf "${WORK_DIR}/mise.rpm" -C "${extract_dir}"

    log "📦 Installing payload to ${INSTALL_PREFIX}"
    install_payload "${extract_dir}"

    replace_update_instructions

    [[ -x "${INSTALL_PREFIX}/bin/${PACKAGE}" ]] \
        || die "binary not found at ${INSTALL_PREFIX}/bin/${PACKAGE} after install"

    log "✅ $("${INSTALL_PREFIX}/bin/${PACKAGE}" --version)"
}

main "$@"
