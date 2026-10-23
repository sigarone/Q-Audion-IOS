#!/bin/bash
# Select an installed Xcode release and print what was selected.
#
# usage: select-xcode.sh VERSION      (or XCODE_VERSION in the environment)
#   VERSION  "26"    the newest installed release of the 26 family
#            "27.1"  exactly 27.1 (27.1.0 is the same thing); fails when only
#                    another version is installed
#
# Only release installs qualify. A name such as Xcode_27.2_Release_Candidate.app or
# Xcode_27.3_beta.app is never chosen, and neither is an alias (Xcode_27.2.app) that
# points at one: the install each name resolves to has to be Xcode_<digits and dots>.app.
# The script fails when nothing matches, so a build never moves to another toolchain
# without the job failing first.
#
# Prints the exact path, `xcodebuild -version` and `xcodebuild -showsdks`. Writes `path`,
# `build` (for example 17F113) and `version` to $GITHUB_OUTPUT and a short block to
# $GITHUB_STEP_SUMMARY when those are set.
#
# For tests: XCODE_APPS_DIR replaces /Applications, and XCODE_SELECT_DRY_RUN=1 only prints
# and records the selection (no xcode-select, no xcodebuild).
# Self-test: scripts/ci/test-select-xcode.sh.

set -eu

APPS="${XCODE_APPS_DIR:-/Applications}"
SPEC="${1:-${XCODE_VERSION:-}}"
VERSION_RE='^[0-9]+(\.[0-9]+){0,2}$'

if [ -z "$SPEC" ] || ! printf '%s\n' "$SPEC" | grep -Eq "$VERSION_RE"; then
  echo "::error::Xcode version '${SPEC}' is not valid: use a major such as 26, or major.minor such as 27.1"
  exit 2
fi

# "27.1" -> "27.1.0", "27" -> "27.0.0"
norm() {
  printf '%s\n' "$1" | awk -F. '{ printf "%d.%d.%d\n", $1, $2 + 0, $3 + 0 }'
}

case "$SPEC" in
  *.*) FAMILY=0; WANT=$(norm "$SPEC") ;;
  *)   FAMILY=1; WANT=$SPEC ;;
esac

echo "=== Runner ==="
sw_vers 2>/dev/null || uname -a
echo ""
echo "=== Wanted: Xcode ${SPEC} ($([ "$FAMILY" = 1 ] && echo "newest release of the ${SPEC} family" || echo "exactly ${WANT}")) ==="
echo "=== Installed in ${APPS} ==="

CANDIDATES=""
for app in "$APPS"/Xcode_*.app; do
  [ -d "$app" ] || continue
  name=${app##*/}
  real=$(cd -P "$app" 2>/dev/null && pwd -P) || { echo "  ${name}: unreadable, skipped"; continue; }
  rname=${real##*/}
  case "$rname" in
    Xcode_*.app) ;;
    *) echo "  ${name} -> ${rname}: not an Xcode_<version>.app install, skipped"; continue ;;
  esac
  rver=${rname#Xcode_}
  rver=${rver%.app}
  if ! printf '%s\n' "$rver" | grep -Eq "$VERSION_RE"; then
    echo "  ${name} -> ${rname}: not a release install, skipped"
    continue
  fi
  n=$(norm "$rver")
  if [ "$name" = "$rname" ]; then
    echo "  ${name}: release ${n}"
  else
    echo "  ${name} -> ${rname}: release ${n}"
  fi
  if [ "$FAMILY" = 1 ]; then
    [ "${n%%.*}" = "$WANT" ] || continue
  else
    [ "$n" = "$WANT" ] || continue
  fi
  CANDIDATES="${CANDIDATES}${n} ${real}
"
done
echo ""

PICK=$(printf '%s' "$CANDIDATES" | grep -v '^$' | sort -V -u | tail -1 || true)
if [ -z "$PICK" ]; then
  echo "::error::No installed Xcode release matches '${SPEC}' in ${APPS}."
  exit 1
fi
N=${PICK%% *}
MATCH=${PICK#* }

echo "Selecting: $MATCH (release $N)"

if [ "${XCODE_SELECT_DRY_RUN:-}" = 1 ]; then
  BUILD=dry-run
else
  if [ -n "${DEVELOPER_DIR:-}" ] && [ "$DEVELOPER_DIR" != "$MATCH/Contents/Developer" ]; then
    echo "::error::DEVELOPER_DIR is set to ${DEVELOPER_DIR} and would override the selection."
    exit 1
  fi
  sudo xcode-select -s "$MATCH"
  echo ""
  echo "=== Active Xcode ==="
  xcodebuild -version
  ACTIVE=$(xcodebuild -version | awk 'NR == 1 { print $2 }')
  if [ "$(norm "$ACTIVE")" != "$N" ]; then
    echo "::error::xcodebuild reports ${ACTIVE}, expected ${N} from ${MATCH}"
    exit 1
  fi
  BUILD=$(xcodebuild -version | awk '/^Build version/ { print $3 }')
  echo ""
  echo "=== SDKs ==="
  xcodebuild -showsdks
  echo ""
  xcrun swift --version 2>&1 | head -2 || true
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "path=$MATCH"
    echo "build=$BUILD"
    echo "version=$N"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "${XCODE_SELECT_DRY_RUN:-}" != 1 ]; then
  {
    echo "### Xcode"
    echo ""
    echo "- Path: \`$MATCH\`"
    echo "- Version: \`$N\` (build \`$BUILD\`)"
    echo ""
    echo '```'
    xcodebuild -showsdks
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
