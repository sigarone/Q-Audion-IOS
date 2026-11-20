#!/usr/bin/env bash
# Installs a pinned xcodegen for the CI jobs that generate the Xcode project.
#
# Why pinned: xcodegen 2.47.0 (the version Homebrew installs since November 2026) resolves the
# "../QAudionApp/<folder>/<file>.swift" source paths of the extension targets in project.yml to
# "QAudionApp/<file>.swift", so the share, VPN and earbud specs fail with "Build input files cannot be
# found". 2.46.0 builds them. The archive is checked against the SHA-256 that the release publishes.
set -euo pipefail

VERSION="2.46.0"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip"

if command -v xcodegen >/dev/null 2>&1 && xcodegen --version 2>/dev/null | grep -q "${VERSION}"; then
  echo "xcodegen ${VERSION} already installed"
  exit 0
fi

dir="${RUNNER_TEMP:-/tmp}/xcodegen-${VERSION}"
rm -rf "${dir}"
mkdir -p "${dir}"
curl -fsSL --retry 3 -o "${dir}/xcodegen.zip" "${URL}"
echo "${SHA256}  ${dir}/xcodegen.zip" | shasum -a 256 -c -
unzip -q -o "${dir}/xcodegen.zip" -d "${dir}"

bin="$(find "${dir}" -type f -name xcodegen -perm -u+x | head -n 1)"
if [ -z "${bin}" ]; then
  echo "::error::xcodegen binary not found in the ${VERSION} archive"
  exit 1
fi
bin_dir="$(cd "$(dirname "${bin}")" && pwd)"
echo "${bin_dir}" >> "${GITHUB_PATH:-/dev/null}"
"${bin}" --version
