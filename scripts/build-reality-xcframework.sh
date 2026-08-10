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
# -target=ios -o Reality.xcframework .` gets all the way through module
# resolution + `gobind` lookup and fails ONLY on the expected, final
# `-target="ios" requires Xcode` — i.e. everything below that line is
# genuinely untested pending a real CI/macOS run.
#
# The Reality Go source lives IN THIS REPO (../RealityCore), not an external
# clone — there is no external ref to pin; the cache key below is the hash of
# that module's own go.sum + this script, so any change to either invalidates it.
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

# Universal (device + simulator slices): bare `-target=ios` makes gomobile
# build ios/arm64 (device) AND iossimulator/arm64+amd64, stitching all three
# into one xcframework. Needed because engine-tests.yml's ios-simulator-tests
# job links this into a Simulator xcodebuild — device-only (ios/arm64, the
# original choice here) can only ever be consumed by the TestFlight archive
# job, leaving the wiring completely CI-unverified until the next tag push.
# The extra simulator slices cost
# more build time but let the fast, every-push simulator job actually prove
# the binaryTarget links and RealityManager's real branch compiles.
mkdir -p "$(dirname "$OUT_XC")"
( cd "$CORE_DIR" && gomobile bind -target=ios -o "$OUT_XC" . )

echo "OK: $OUT_XC"
