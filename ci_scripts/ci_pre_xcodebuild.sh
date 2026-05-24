#!/usr/bin/env bash
# Xcode Cloud — runs after SPM dependency resolution, before xcodebuild
# archive. Two responsibilities:
#
#   1. Bump CFBundleShortVersionString (from $CI_TAG, e.g. "v1.0.398") and
#      CFBundleVersion (from $CI_BUILD_NUMBER which Xcode Cloud auto-
#      increments per workflow). plutil writes Info.plist directly so the
#      values land in the IPA — same pattern as the Codemagic step.
#
#   2. Patch onnxruntime.framework Info.plist MinimumOSVersion. The 1.17.0
#      package ships with MinimumOSVersion='' (empty) which Apple's altool
#      rejects with ITMS-90208. We replace it with "16.0" (matching the
#      Mach-O's LC_BUILD_VERSION minos field). The framework is reached
#      from the SPM artifact cache populated by Xcode's resolve step.
#
# Apple-managed signing: Xcode Cloud signs the app for us, so we DO NOT
# touch certs/profiles here. We just modify the binary content; the
# subsequent xcodebuild archive will re-sign automatically.

set -euxo pipefail

echo "=== Xcode Cloud pre_xcodebuild — Q-Audion-IOS ==="
echo "CI_TAG          = ${CI_TAG:-<unset>}"
echo "CI_BUILD_NUMBER = ${CI_BUILD_NUMBER:-<unset>}"
echo ""

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$CI_WORKSPACE}"
cd "$REPO_ROOT/QAudionApp"

# ----------------------------------------------------------------------
# (1) Marketing version + build number
# ----------------------------------------------------------------------
if [ -n "${CI_TAG:-}" ]; then
  MARKETING_VERSION=$(echo "$CI_TAG" | sed -E 's/^v//; s/-[A-Za-z].*$//')
else
  MARKETING_VERSION="1.0.0"
fi
BUILD_NUMBER="${CI_BUILD_NUMBER:-1}"
echo "Marketing version = $MARKETING_VERSION"
echo "Build number      = $BUILD_NUMBER"

echo ""
echo "=== Info.plist BEFORE plutil ==="
plutil -extract CFBundleShortVersionString raw -o - Info.plist || true
plutil -extract CFBundleVersion             raw -o - Info.plist || true

plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" Info.plist
plutil -replace CFBundleVersion            -string "$BUILD_NUMBER"      Info.plist

echo ""
echo "=== Info.plist AFTER plutil ==="
plutil -extract CFBundleShortVersionString raw -o - Info.plist
plutil -extract CFBundleVersion             raw -o - Info.plist

# Keep QAudionPacketTunnel extension version in sync with the app.
# App extensions must have a CFBundleVersion ≤ the containing app's
# version or TestFlight/App Store Connect rejects the upload.
EXT_PLIST="$REPO_ROOT/QAudionPacketTunnel/Info.plist"
if [ -f "$EXT_PLIST" ]; then
  echo ""
  echo "=== Bumping QAudionPacketTunnel Info.plist ==="
  plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$EXT_PLIST"
  plutil -replace CFBundleVersion            -string "$BUILD_NUMBER"      "$EXT_PLIST"
  plutil -extract CFBundleShortVersionString raw -o - "$EXT_PLIST"
  plutil -extract CFBundleVersion             raw -o - "$EXT_PLIST"
fi

# ----------------------------------------------------------------------
# (2) Patch onnxruntime.framework MinimumOSVersion
# ----------------------------------------------------------------------
# Find the onnxruntime.xcframework's iOS device slice in the SPM artifact
# cache. Xcode Cloud's resolve step populates DerivedData; the path
# pattern below catches both DerivedData/SourcePackages and the more
# specific artifacts/onnxruntime-swift-package-manager subdirs.
echo ""
echo "=== Locating onnxruntime.xcframework ==="
ONNX_FW=""
for candidate in \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    "$REPO_ROOT/.build" \
    "$CI_DERIVED_DATA_PATH"
do
  if [ -d "$candidate" ]; then
    found=$(find "$candidate" -path "*/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/Info.plist" 2>/dev/null | head -1 || true)
    if [ -n "$found" ]; then
      ONNX_FW="$found"
      break
    fi
  fi
done

if [ -z "$ONNX_FW" ]; then
  echo "WARN: onnxruntime.framework Info.plist not found in artifact cache."
  echo "     Apple's altool will reject ITMS-90208 if MinimumOSVersion is empty."
  echo "     Falling back to scan SourcePackages directly:"
  find "$HOME/Library/Developer/Xcode" -name "onnxruntime.framework" -type d 2>/dev/null | head -5 || true
  echo "     Build will continue but TestFlight upload may fail."
else
  echo "Found onnxruntime: $ONNX_FW"
  echo "--- BEFORE ---"
  plutil -p "$ONNX_FW" | grep -E "MinimumOS|Platform|Supported" || true
  plutil -replace MinimumOSVersion -string "16.0" "$ONNX_FW"
  echo "--- AFTER ---"
  plutil -p "$ONNX_FW" | grep -E "MinimumOS" || true
fi

echo ""
echo "=== ci_pre_xcodebuild.sh OK ==="
