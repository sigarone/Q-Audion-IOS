#!/usr/bin/env bash
# Xcode Cloud — runs after xcodebuild build/archive completes, before
# Apple's distribute action (TestFlight upload). Diagnostic + size check.
#
# We do NOT re-sign here because Xcode Cloud uses cloud-managed signing:
# the archive is already signed by Apple's flow. Modifying the IPA
# content at this stage is risky.

set -euxo pipefail

echo "=== Xcode Cloud post_xcodebuild — Q-Audion-IOS ==="
echo "CI_ARCHIVE_PATH = ${CI_ARCHIVE_PATH:-<unset>}"
echo "CI_DERIVED_DATA_PATH = ${CI_DERIVED_DATA_PATH:-<unset>}"

if [ -n "${CI_ARCHIVE_PATH:-}" ] && [ -d "$CI_ARCHIVE_PATH" ]; then
  echo ""
  echo "=== Archive contents ==="
  ls -la "$CI_ARCHIVE_PATH" || true
  PLIST="$CI_ARCHIVE_PATH/Info.plist"
  if [ -f "$PLIST" ]; then
    echo ""
    echo "=== Archive Info.plist ==="
    plutil -p "$PLIST" | head -20 || true
  fi
fi

# Verify the embedded onnxruntime.framework Info.plist is correctly
# patched in the final archive. If not, surface a warning — Apple's
# distribute step will reject ITMS-90208.
if [ -n "${CI_ARCHIVE_PATH:-}" ]; then
  ONNX_IN_ARCHIVE=$(find "$CI_ARCHIVE_PATH" -name "onnxruntime.framework" -type d 2>/dev/null | head -1 || true)
  if [ -n "$ONNX_IN_ARCHIVE" ] && [ -f "$ONNX_IN_ARCHIVE/Info.plist" ]; then
    echo ""
    echo "=== Embedded onnxruntime.framework Info.plist (post-archive) ==="
    plutil -p "$ONNX_IN_ARCHIVE/Info.plist" | grep -E "MinimumOS" || true
    MIN_OS=$(plutil -extract MinimumOSVersion raw -o - "$ONNX_IN_ARCHIVE/Info.plist" 2>/dev/null || echo "")
    if [ -z "$MIN_OS" ] || [ "$MIN_OS" = "" ]; then
      echo "WARN: MinimumOSVersion empty in embedded onnxruntime.framework."
      echo "     ITMS-90208 will be triggered on TestFlight upload."
      echo "     The pre_xcodebuild script's patch did not propagate."
    else
      echo "OK: embedded onnxruntime MinimumOSVersion = $MIN_OS"
    fi
  fi
fi

echo ""
echo "=== ci_post_xcodebuild.sh OK ==="
