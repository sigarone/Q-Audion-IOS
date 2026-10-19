#!/bin/sh
# install-age.sh - install the pinned age release binary, verified by SHA-256.
#
# WHY. The dSYMs of a build are uploaded as a GitHub Actions artifact, and this repository is
# public, so any artifact can be downloaded by anyone with a GitHub account. ios-testflight.yml
# therefore encrypts them with age (https://age-encryption.org) to a public key committed in the
# workflow; only the private key, which is kept off GitHub, can read them. This script puts the
# age binary on the runner without trusting a package manager's latest version: the release
# tarball of one fixed version, whose SHA-256 is pinned below. A tarball that does not match is
# deleted and the script fails; it never falls back to another source.
#
# USAGE   scripts/ci/install-age.sh DEST_DIR
#   installs DEST_DIR/age and DEST_DIR/age-keygen and prints the DEST_DIR path on the last line.
# TEST    AGE_INSTALL_LOCAL_TARBALL=/path/to/tarball skips ONLY the download (the self-test uses it
#         to feed a tampered file); the SHA-256 check and everything after it still run.
# EXIT    0 installed | 1 checksum or version mismatch | 2 unsupported platform, download failure or bad usage
#
# Pins (age v1.2.1, FiloSottile/age). Computed 2026-10-19 from the release assets
# downloaded over HTTPS from github.com/FiloSottile/age/releases/tag/v1.2.1; the sizes (4758557,
# 4987312, 5194720 bytes) match what the GitHub releases API reports for the same assets. To bump
# age: change AGE_VERSION and the three hashes together, and run scripts/ci/test-install-age.sh.
set -eu

AGE_VERSION="v1.2.1"
SHA_DARWIN_ARM64="cf79875bd5970dc2dac60c87fa50cee1ff1f9a41b0eb273f65e174aff37c367a"
SHA_DARWIN_AMD64="424e1d64438a730626540b2e01e98d132a64214442ca9465b3e82336d12e633e"
SHA_LINUX_AMD64="7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50"

say() { printf '%s\n' "$*"; }
err() { say "::error::install-age: $1"; }

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  err "usage: install-age.sh DEST_DIR"
  exit 2
fi
DEST="$1"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  PLAT="darwin-arm64";  WANT="$SHA_DARWIN_ARM64" ;;
  Darwin-x86_64) PLAT="darwin-amd64";  WANT="$SHA_DARWIN_AMD64" ;;
  Linux-x86_64)  PLAT="linux-amd64";   WANT="$SHA_LINUX_AMD64" ;;
  *) err "no pinned age release for $(uname -s)-$(uname -m)"; exit 2 ;;
esac

sha256_of() { # prints the SHA-256 of $1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    err "neither shasum nor sha256sum is available"
    return 1
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/install-age.XXXXXX") || { err "cannot create a temp dir"; exit 2; }
trap 'rm -rf "$TMP"' EXIT INT TERM
TARBALL="$TMP/age.tar.gz"

if [ -n "${AGE_INSTALL_LOCAL_TARBALL:-}" ]; then
  cp "$AGE_INSTALL_LOCAL_TARBALL" "$TARBALL" || { err "cannot read AGE_INSTALL_LOCAL_TARBALL"; exit 2; }
else
  URL="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-${PLAT}.tar.gz"
  say "install-age: downloading age ${AGE_VERSION} (${PLAT})"
  curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 180 -o "$TARBALL" "$URL" \
    || { err "download failed: $URL"; exit 2; }
fi

GOT=$(sha256_of "$TARBALL") || exit 2
if [ "$GOT" != "$WANT" ]; then
  err "SHA-256 mismatch for age ${AGE_VERSION} ${PLAT}: got ${GOT}, pinned ${WANT} - refusing to use it"
  exit 1
fi
say "install-age: SHA-256 verified (${PLAT})"

mkdir -p "$TMP/x" "$DEST"
tar -xzf "$TARBALL" -C "$TMP/x" age/age age/age-keygen || { err "unexpected tarball layout"; exit 1; }
cp "$TMP/x/age/age" "$DEST/age"
cp "$TMP/x/age/age-keygen" "$DEST/age-keygen"
chmod 0755 "$DEST/age" "$DEST/age-keygen"

REPORTED=$("$DEST/age" --version 2>&1 | head -1)
if [ "$REPORTED" != "$AGE_VERSION" ]; then
  err "the installed binary reports '${REPORTED}', expected ${AGE_VERSION}"
  exit 1
fi
say "install-age: age ${REPORTED} installed in ${DEST}"
say "$DEST"
