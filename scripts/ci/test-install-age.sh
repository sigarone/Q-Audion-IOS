#!/bin/sh
# Self-test for scripts/ci/install-age.sh (POSIX sh; Linux x86_64, macOS). Run:
#     sh scripts/ci/test-install-age.sh
# The "real download" cases need network access to github.com; set NO_NETWORK=1 to skip them.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
INST="$HERE/install-age.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/install-age-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail=0

expect() { # name want_rc cmd...
  name=$1; want=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok   - $name (rc=$rc)"; else echo "FAIL - $name: rc=$rc want=$want"; echo "$out" | sed 's/^/       /'; fail=1; fi
  LAST_OUT=$out
}
check() { if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

expect "no argument -> exit 2"                      2 sh "$INST"
expect "empty argument -> exit 2"                   2 sh "$INST" ""

# unsupported platform: shim uname
mkdir -p "$T/shim"
cat > "$T/shim/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Plan9;; -m) echo mips;; *) echo Plan9;; esac
EOF
chmod +x "$T/shim/uname"
expect "an unsupported platform -> exit 2"          2 env PATH="$T/shim:$PATH" sh "$INST" "$T/dest0"
case "$LAST_OUT" in *"no pinned age release"*) echo "ok   - says why";; *) echo "FAIL - message"; echo "$LAST_OUT"; fail=1;; esac

# tampered tarball (any bytes): the pinned hash must reject it, nothing installed
head -c 4096 /dev/urandom > "$T/fake.tar.gz"
expect "a tarball that does not match the pin -> exit 1" 1 env AGE_INSTALL_LOCAL_TARBALL="$T/fake.tar.gz" sh "$INST" "$T/dest1"
case "$LAST_OUT" in *"SHA-256 mismatch"*) echo "ok   - says SHA-256 mismatch";; *) echo "FAIL - message"; echo "$LAST_OUT"; fail=1;; esac
check "nothing was installed after a mismatch" $([ ! -e "$T/dest1/age" ]; echo $?)

expect "a missing local tarball -> exit 2"          2 env AGE_INSTALL_LOCAL_TARBALL="$T/nope.tar.gz" sh "$INST" "$T/dest2"

if [ "${NO_NETWORK:-0}" = 1 ]; then
  echo "skip - real download cases (NO_NETWORK=1)"
else
  # real download through the script itself
  expect "the pinned release downloads, verifies and installs -> exit 0" 0 sh "$INST" "$T/dest3"
  check "age and age-keygen are installed and executable" $([ -x "$T/dest3/age" ] && [ -x "$T/dest3/age-keygen" ]; echo $?)
  check "age reports the pinned version" $([ "$("$T/dest3/age" --version 2>&1 | head -1)" = "v1.2.1" ]; echo $?)
  check "the last output line is the install dir" $([ "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "$T/dest3" ]; echo $?)

  # reuse the verified bytes: fetch once more by hand to flip a bit
  URLPLAT=""
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) URLPLAT=darwin-arm64;; Darwin-x86_64) URLPLAT=darwin-amd64;; Linux-x86_64) URLPLAT=linux-amd64;;
  esac
  if [ -n "$URLPLAT" ] && curl -fsSL --max-time 120 -o "$T/real.tar.gz" "https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-$URLPLAT.tar.gz"; then
    expect "the verified tarball from a local path -> exit 0" 0 env AGE_INSTALL_LOCAL_TARBALL="$T/real.tar.gz" sh "$INST" "$T/dest4"
    # one extra byte at the end: a gzip reader would not even notice, the pinned hash must
    cp "$T/real.tar.gz" "$T/flipped.tar.gz"
    printf 'x' >> "$T/flipped.tar.gz"
    expect "the same tarball with one byte appended -> exit 1" 1 env AGE_INSTALL_LOCAL_TARBALL="$T/flipped.tar.gz" sh "$INST" "$T/dest5"
    check "nothing was installed from the changed tarball" $([ ! -e "$T/dest5/age" ]; echo $?)
  else
    echo "FAIL - could not fetch the release for the bit-flip case"; fail=1
  fi
fi

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME TESTS FAILED"
exit "$fail"
