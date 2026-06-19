#!/usr/bin/env bash
# Build Cloudflare quiche as QAudionApp/Vendor/quiche.xcframework, exposing the
# `Cquiche` Clang module imported by AppMasqueQuicheTransport (MASQUE backend).
#
# Runs in CI ("Build quiche xcframework" step) on macos-latest BEFORE
# `xcodegen generate`, and can be run locally on macOS + Rust. Idempotent:
# skips the build if the xcframework already exists (CI caches it).
#
# quiche is wire-compatible with the Android Cronet MASQUE client and the
# server's masque-go (RFC 9298 over QUIC DATAGRAM, RFC 9221/9297).
set -euo pipefail

QUICHE_REF="${QUICHE_REF:-0.22.0}"
ROOT="${ROOT:-$(pwd)}"
OUT_XC="$ROOT/QAudionApp/Vendor/quiche.xcframework"
WORK="${WORK:-$ROOT/.quiche-build}"

if [ -d "$OUT_XC" ]; then
  echo "quiche.xcframework already present at $OUT_XC — skipping build."
  exit 0
fi

command -v cargo >/dev/null || { echo "ERROR: Rust (rustup/cargo) required"; exit 1; }
command -v xcodebuild >/dev/null || { echo "ERROR: macOS + Xcode required"; exit 1; }

# Device-only (aarch64-apple-ios). The TestFlight pipeline archives for a
# generic iOS device, so a device slice is all the build needs. We skip the
# simulator slice on purpose: cargo's C deps (BoringSSL/ring) for the
# *-ios-sim target get tagged with the iOS (device) platform, which makes
# `xcodebuild -create-xcframework` reject the archive with "binaries with
# multiple platforms are not supported". Add the sim slice later only if
# simulator runs are needed (requires per-dep -mios-simulator-version-min).
rustup target add aarch64-apple-ios

rm -rf "$WORK"; mkdir -p "$WORK"
git clone --depth 1 --branch "$QUICHE_REF" --recursive \
  https://github.com/cloudflare/quiche "$WORK/quiche"
cd "$WORK/quiche"

# quiche's [lib] crate-type includes `cdylib`, whose iOS cross-link fails
# ("symbol(s) not found for architecture arm64" — a standalone .dylib must
# resolve every system symbol). We only need the `staticlib` (libquiche.a)
# for the xcframework, so strip cdylib from the crate-type list. Robust to
# token order / spacing.
perl -0pi -e 's/("(?:lib|staticlib)")\s*,\s*"cdylib"/$1/g; s/"cdylib"\s*,\s*//g' quiche/Cargo.toml
echo "--- quiche [lib] crate-type after patch ---"
grep -n "crate-type" quiche/Cargo.toml || true

# FFI feature builds the C API (quiche.h + libquiche.a). BoringSSL builds from
# the bundled submodule — no system OpenSSL needed.
cargo build --release --features ffi --target aarch64-apple-ios -p quiche

DEV_LIB="$WORK/quiche/target/aarch64-apple-ios/release/libquiche.a"

# Headers dir with quiche.h + a module map naming the module `Cquiche`.
# Headers live in a Cquiche/ subdirectory so their module.modulemap does NOT
# collide with other xcframeworks (e.g. QaudionCryptoCore.xcframework) that
# also place a module.modulemap at the root of their Headers/ dir. Xcode 26.3
# made this conflict a hard error ("Multiple commands produce .../include/
# module.modulemap"). Clang discovers module.modulemap in subdirectories of
# include paths, so `import Cquiche` in Swift continues to work.
HDRS="$WORK/include"
QUICHE_HDRS="$HDRS/Cquiche"
mkdir -p "$QUICHE_HDRS"
cp "$WORK/quiche/quiche/include/quiche.h" "$QUICHE_HDRS/quiche.h"
cat > "$QUICHE_HDRS/module.modulemap" <<'MODMAP'
module Cquiche {
    header "quiche.h"
    export *
}
MODMAP

mkdir -p "$(dirname "$OUT_XC")"
rm -rf "$OUT_XC"
xcodebuild -create-xcframework \
  -library "$DEV_LIB" -headers "$HDRS" \
  -output "$OUT_XC"

echo "OK: $OUT_XC"
