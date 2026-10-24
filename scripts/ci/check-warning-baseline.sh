#!/bin/sh
# Fail when an xcodebuild log holds more compiler warnings in the project's own sources than
# the counted baseline allows.
#
# usage: check-warning-baseline.sh LOG [BASELINE_FILE]
#   LOG            an xcodebuild log (the Debug simulator build of the app)
#   BASELINE_FILE  a file whose first line is the allowed number of distinct warnings
#                  (default: scripts/ci/warning-baseline.txt next to this script)
#
# Counted: distinct "file:line:col: warning: message" lines whose file is in QAudionApp/,
# QAudionIntents/ or QAudionEngine/Sources/ (the app, its extensions and the engine). Warnings
# of packages in SourcePackages/checkouts and warnings without a source location are listed
# by xcode-diagnostics-summary.sh but not counted. The same line from several architectures or
# targets counts once. When the count is below the baseline the script says so; lower the
# number in the baseline file then, so the improvement cannot be lost again.
# Self-test: scripts/ci/test-check-warning-baseline.sh.

set -eu

LOG="${1:?usage: check-warning-baseline.sh LOG [BASELINE_FILE]}"
HERE=$(cd "$(dirname "$0")" && pwd)
BASELINE_FILE="${2:-$HERE/warning-baseline.txt}"

if [ ! -f "$LOG" ]; then
  echo "::error::log file $LOG not found"
  exit 2
fi
ALLOWED=$(head -n 1 "$BASELINE_FILE" | tr -d '[:space:]')
case "$ALLOWED" in
  ''|*[!0-9]*) echo "::error::$BASELINE_FILE must start with a number"; exit 2 ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

grep -E '^[[:space:]]*[^[:space:]]+:[0-9]+:[0-9]+: warning: ' "$LOG" \
  | grep -v '/SourcePackages/checkouts/' \
  | sed -E 's#^[[:space:]]*##; s#^.*/(QAudionApp|QAudionIntents|QAudionEngine/Sources)/#\1/#' \
  | grep -E '^(QAudionApp|QAudionIntents|QAudionEngine/Sources)/' \
  | sort -u > "$TMP/warnings.txt" || true

COUNT=$(wc -l < "$TMP/warnings.txt" | tr -d ' ')
echo "Compiler warnings in the project's sources: ${COUNT} (baseline ${ALLOWED})"

if [ "$COUNT" -gt "$ALLOWED" ]; then
  echo "::error::${COUNT} compiler warning(s) in the project's sources, the baseline allows ${ALLOWED}. Fix them; do not raise the baseline."
  cat "$TMP/warnings.txt"
  exit 1
fi
if [ "$COUNT" -lt "$ALLOWED" ]; then
  echo "::notice::fewer warnings than the baseline: lower scripts/ci/warning-baseline.txt to ${COUNT}."
fi
exit 0
