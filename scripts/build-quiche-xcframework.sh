#!/usr/bin/env bash
# Build libquiche as an iOS XCFramework for the MASQUE CONNECT-UDP backend.
#
# MUST run on macOS with Rust + the iOS SDK. Produces:
#   QAudionEngine/Vendor/quiche.xcframework   (device arm64 + sim arm64)
#   QAudionEngine/Sources/CQuiche/include/quiche.h
#
# After this succeeds, finish wiring per QAudionEngine/Sources/QAudionEngine/
# Transport/Masque/MasqueDatagramTransport.swift (add the SwiftPM targets,
# implement MasqueQuicheTransport, compile with -D QAUDION_MASQUE_QUICHE).
#
# quiche is wire-compatible with the Android Cronet MASQUE client and the
# server's masque-go (RFC 9298 over QUIC DATAGRAM, RFC 9221/9297).
set -euo pipefail

QUICHE_REF="${QUICHE_REF:-0.22.0}"          # pin an audited tag, not a moving branch
WORK="${WORK:-$(pwd)/.quiche-build}"
OUT_XC="$(pwd)/QAudionEngine/Vendor/quiche.xcframework"
OUT_HDR_DIR="$(pwd)/QAudionEngine/Sources/CQuiche/include"

command -v cargo >/dev/null || { echo "ERROR: install Rust (rustup) first"; exit 1; }
command -v xcodebuild >/dev/null || { echo "ERROR: run on macOS with Xcode"; exit 1; }

rustup target add aarch64-apple-ios aarch64-apple-ios-sim

rm -rf "$WORK"; mkdir -p "$WORK"
git clone --depth 1 --branch "$QUICHE_REF" --recursive \
  https://github.com/cloudflare/quiche "$WORK/quiche"
cd "$WORK/quiche"

# FFI feature exposes the C API (quiche.h + libquiche.a). BoringSSL builds
# from the bundled submodule; no system OpenSSL needed.
for TARGET in aarch64-apple-ios aarch64-apple-ios-sim; do
  cargo build --release --features ffi,pkg-config-meta --target "$TARGET" -p quiche
done

DEV_LIB="$WORK/quiche/target/aarch64-apple-ios/release/libquiche.a"
SIM_LIB="$WORK/quiche/target/aarch64-apple-ios-sim/release/libquiche.a"
HDR="$WORK/quiche/quiche/include/quiche.h"

rm -rf "$OUT_XC"
xcodebuild -create-xcframework \
  -library "$DEV_LIB" -headers "$WORK/quiche/quiche/include" \
  -library "$SIM_LIB" -headers "$WORK/quiche/quiche/include" \
  -output "$OUT_XC"

mkdir -p "$OUT_HDR_DIR"
cp "$HDR" "$OUT_HDR_DIR/quiche.h"

echo "OK: $OUT_XC"
echo "Next: add CQuiche + quiche binaryTarget to Package.swift, implement"
echo "      MasqueQuicheTransport, build with -D QAUDION_MASQUE_QUICHE."
