#!/usr/bin/env bash
# Build the Reality (VLESS+REALITY over xray-core, via github.com/xtls/libxray)
# Go module in ../RealityCore as QAudionApp/Vendor/Reality.xcframework, exposing
# the `Reality` Clang/Swift module (Start/Stop/IsRunning/Version) consumed by
# RealityManager.swift.
#
# THIS SCRIPT REQUIRES macOS + Xcode + a real iOS SDK (gomobile bind shells out
# to `xcodebuild -create-xcframework`) and cannot run on this dev machine
# (Windows). It is meant to run in CI ("Build reality xcframework" step in
# .github/workflows/ios-testflight.yml) or on a macOS workstation. Every step
# up to the Xcode-gated bind itself (module/tool resolution, gobind lookup)
# WAS verified while writing this script on a non-macOS box: `go build`/`go
# vet`/`go test` all pass against ../RealityCore, and `gomobile bind
# -target=ios/arm64 -o Reality.xcframework .` gets all the way through module
# resolution + `gobind` lookup and fails ONLY on the expected, final
# `-target="ios/arm64" requires Xcode` — i.e. everything below that line is
# genuinely untested pending a real CI/macOS run.
#
# Unlike build-quiche-xcframework.sh (which clones an EXTERNAL repo pinned by
# QUICHE_REF), the Reality Go source lives IN THIS REPO (../RealityCore) —
# there is no external ref to pin; the cache key below is the hash of that
# module's own go.sum + this script, so any change to either invalidates it.
set -euo pipefail

ROOT="${ROOT:-$(pwd)}"
CORE_DIR="$ROOT/RealityCore"
OUT_XC="$ROOT/QAudionApp/Vendor/Reality.xcframework"

if [ -d "$OUT_XC" ]; then
  echo "Reality.xcframework already present at $OUT_XC — skipping build."
  exit 0
fi

command -v go >/dev/null || { echo "ERROR: Go toolchain required (CI: actions/setup-go, same step WireGuardKitGo already needs)"; exit 1; }
command -v xcodebuild >/dev/null || { echo "ERROR: macOS + Xcode required — gomobile bind shells out to xcodebuild -create-xcframework"; exit 1; }
[ -d "$CORE_DIR" ] || { echo "ERROR: $CORE_DIR not found — Reality Go module missing"; exit 1; }

# gomobile/gobind are ordinary `go install`ed CLI tools (GOBIN), NOT vendored
# into RealityCore/go.mod as a runtime dependency — only the `tool` directive
# in RealityCore/go.mod (golang.org/x/mobile/cmd/gobind) matters for module
# resolution; `gomobile init` below additionally installs the `gobind` binary
# gomobile shells out to by name (exec.LookPath("gobind")). Both steps are
# idempotent — safe to re-run every CI invocation.
if ! command -v gomobile >/dev/null 2>&1; then
  echo "Installing gomobile..."
  go install golang.org/x/mobile/cmd/gomobile@latest
fi
export PATH="$(go env GOPATH)/bin:$PATH"

if ! command -v gobind >/dev/null 2>&1; then
  echo "Running gomobile init (installs gobind)..."
  gomobile init
fi

# Device-only (ios/arm64), same call as build-quiche-xcframework.sh's
# aarch64-apple-ios-only choice — this pipeline only ever archives for a
# generic iOS device (no simulator runs), and skipping the simulator slice
# roughly halves gomobile's build time. `-target=ios` (bare) would ALSO
# build iossimulator/arm64+amd64 into the same xcframework (gomobile handles
# the multi-slice stitching itself, unlike quiche's manual cargo+xcodebuild
# dance) — add it back here if a simulator target is ever needed.
mkdir -p "$(dirname "$OUT_XC")"
( cd "$CORE_DIR" && gomobile bind -target=ios/arm64 -o "$OUT_XC" . )

echo "OK: $OUT_XC"
