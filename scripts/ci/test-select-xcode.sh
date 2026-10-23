#!/bin/sh
# Self-test of scripts/ci/select-xcode.sh against fake /Applications trees that copy the
# layouts of the runner images (real installs, version aliases, release candidates and
# aliases that point at them). Runs anywhere with sh, bash and coreutils; nothing is
# selected on the machine (XCODE_SELECT_DRY_RUN=1).

set -eu

# A leftover value would stand in for a missing argument.
unset XCODE_VERSION

HERE=$(cd "$(dirname "$0")" && pwd)
SELECT="$HERE/select-xcode.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
TMP=$(cd -P "$TMP" && pwd -P)

fails=0

# expect_ok ROOT SPEC EXPECTED_BASENAME
expect_ok() {
  root=$1 spec=$2 want=$3
  out="$TMP/github-output"
  : > "$out"
  if ! XCODE_APPS_DIR="$root" XCODE_SELECT_DRY_RUN=1 GITHUB_OUTPUT="$out" bash "$SELECT" "$spec" > "$TMP/log" 2>&1; then
    echo "FAIL: $spec in $(basename "$root"): expected $want, the script failed"
    sed 's/^/    /' "$TMP/log"
    fails=$((fails + 1))
    return
  fi
  got=$(sed -n 's/^path=//p' "$out")
  if [ "$got" != "$root/$want" ]; then
    echo "FAIL: $spec in $(basename "$root"): expected $root/$want, got ${got:-nothing}"
    fails=$((fails + 1))
    return
  fi
  echo "ok:   $spec in $(basename "$root") -> $want"
}

# expect_fail ROOT SPEC EXPECTED_EXIT_CODE
expect_fail() {
  root=$1 spec=$2 code=$3
  set +e
  XCODE_APPS_DIR="$root" XCODE_SELECT_DRY_RUN=1 bash "$SELECT" "$spec" > "$TMP/log" 2>&1
  rc=$?
  set -e
  if [ "$rc" != "$code" ]; then
    echo "FAIL: $spec in $(basename "$root"): expected exit $code, got $rc"
    sed 's/^/    /' "$TMP/log"
    fails=$((fails + 1))
    return
  fi
  echo "ok:   $spec in $(basename "$root") is refused (exit $rc)"
}

install_dir() { mkdir -p "$1/$2"; }
alias_to()    { ln -s "$2" "$1/$3"; }

# Image with Xcode 27.1 released and 27.2 still a release candidate.
A="$TMP/a"; mkdir -p "$A"
install_dir "$A" Xcode_27.2_Release_Candidate.app
alias_to "$A" Xcode_27.2_Release_Candidate.app Xcode_27.2.app
alias_to "$A" Xcode_27.2_Release_Candidate.app Xcode_27.2.0.app
install_dir "$A" Xcode_27.1.app
alias_to "$A" Xcode_27.1.app Xcode_27.1.0.app
alias_to "$A" Xcode_27.1.app Xcode.app
install_dir "$A" Xcode_27.app
alias_to "$A" Xcode_27.app Xcode_27.0.app
alias_to "$A" Xcode_27.app Xcode_27.0.0.app

expect_ok   "$A" 27     Xcode_27.1.app
expect_ok   "$A" 27.1   Xcode_27.1.app
expect_ok   "$A" 27.1.0 Xcode_27.1.app
expect_ok   "$A" 27.0   Xcode_27.app
expect_fail "$A" 27.2   1
expect_fail "$A" 28     1

# Image where 27.1 is still a release candidate and the plain name is an alias to it.
B="$TMP/b"; mkdir -p "$B"
install_dir "$B" Xcode_27.2_beta_2.app
alias_to "$B" Xcode_27.2_beta_2.app Xcode_27.2.app
install_dir "$B" Xcode_27.1_Release_Candidate.app
alias_to "$B" Xcode_27.1_Release_Candidate.app Xcode_27.1.app
install_dir "$B" Xcode_27.app
alias_to "$B" Xcode_27.app Xcode_27.0.app

expect_ok   "$B" 27     Xcode_27.app
expect_fail "$B" 27.1   1
expect_fail "$B" 27.2   1

# Image with the Xcode 26 line and a beta on top of it.
C="$TMP/c"; mkdir -p "$C"
install_dir "$C" Xcode_26.7_beta.app
alias_to "$C" Xcode_26.7_beta.app Xcode_26.7.app
install_dir "$C" Xcode_26.6.app
alias_to "$C" Xcode_26.6.app Xcode_26.6.0.app
install_dir "$C" Xcode_26.5.app
install_dir "$C" Xcode_26.4.1.app
install_dir "$C" Xcode_26.0.1.app

expect_ok   "$C" 26     Xcode_26.6.app
expect_ok   "$C" 26.6   Xcode_26.6.app
expect_ok   "$C" 26.5   Xcode_26.5.app
expect_ok   "$C" 26.4.1 Xcode_26.4.1.app
expect_fail "$C" 26.4   1
expect_fail "$C" 26.7   1
expect_fail "$C" 25     1
expect_fail "$C" 27     1

# Bad input, and an image without any Xcode.
expect_fail "$C" abc    2
expect_fail "$C" 26.x   2
expect_fail "$C" ''     2
D="$TMP/d"; mkdir -p "$D"
expect_fail "$D" 26     1

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "select-xcode.sh: all checks passed"
