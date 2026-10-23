#!/bin/sh
# List the distinct compiler, linker and test errors and warnings found in xcodebuild logs.
#
# usage: xcode-diagnostics-summary.sh TITLE LOG [LOG ...]
#   DIAG_OUT=FILE   where the full distinct list is written (default: diagnostics.txt in the
#                   current directory)
#
# Prints the counts and the lists to the job log and, when GITHUB_STEP_SUMMARY is set, a short
# block to the job summary. Never fails: it is a reading aid for report-only jobs.

TITLE="${1:-xcodebuild}"
[ "$#" -gt 0 ] && shift
OUT="${DIAG_OUT:-diagnostics.txt}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

for f in "$@"; do
  [ -f "$f" ] && cat "$f"
done > "$TMP/all.log"

# Same message from several architectures or targets counts once; the runner's checkout
# prefix is dropped so the path reads like a path in the repository.
clean() {
  sed -E 's#/Users/runner/work/[^/]+/[^/]+/##; s#^[[:space:]]+##' | sort -u
}

grep -E ': (error|fatal error): |^(error|fatal error): |^ld: error|^clang: error|xcodebuild: error|^Test Case .* failed' "$TMP/all.log" | clean > "$TMP/errors.txt"
grep -E ': warning: |^warning: |^ld: warning|xcodebuild: WARNING' "$TMP/all.log" | clean > "$TMP/warnings.txt"
grep -E '^\*\* (BUILD|TEST) (FAILED|SUCCEEDED)|^Executed [0-9]+ tests?,|^Testing failed' "$TMP/all.log" | clean > "$TMP/results.txt"

E=$(wc -l < "$TMP/errors.txt" | tr -d ' ')
W=$(wc -l < "$TMP/warnings.txt" | tr -d ' ')

{
  echo "== ${TITLE}: ${E} distinct error line(s), ${W} distinct warning line(s)"
  echo "-- result lines"
  cat "$TMP/results.txt"
  echo "-- errors"
  cat "$TMP/errors.txt"
  echo "-- warnings"
  cat "$TMP/warnings.txt"
} > "$OUT"

echo "::group::${TITLE}: ${E} error line(s), ${W} warning line(s)"
cat "$OUT"
echo "::endgroup::"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ${TITLE}"
    echo ""
    echo "${E} distinct error line(s), ${W} distinct warning line(s)."
    echo ""
    echo '```'
    cat "$TMP/results.txt"
    head -n 60 "$TMP/errors.txt"
    echo '--'
    head -n 60 "$TMP/warnings.txt"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit 0
