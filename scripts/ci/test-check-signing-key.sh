#!/bin/sh
# Self-test of scripts/ci/check-signing-key.sh with throwaway keys.
#
# usage: test-check-signing-key.sh [OPENSSL ...]
#   Without arguments it uses the openssl on PATH. Every argument is an openssl
#   executable that is tested in turn (for example the versioned installs on a macOS
#   runner image: /opt/homebrew/opt/openssl@3/bin/openssl and .../openssl@4/bin/openssl).
#
# Per executable: an RSA key as PKCS#8 and as traditional PEM must be accepted; an empty
# file, text, a truncated PEM, a key with a changed byte, an EC key and a public key
# must be refused; and the second way of accepting a key (for a CLI whose pkey has no
# -check, such as LibreSSL) is exercised through a wrapper that rejects that option.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
CHECK="$HERE/check-signing-key.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0

# run_check OPENSSL FILE -> 0 accepted, 1 refused
run_check() {
  SIGNING_CHECK_OPENSSL=$1 sh "$CHECK" "$2" > "$TMP/out" 2>&1
}

expect_accept() {
  if run_check "$1" "$2"; then
    echo "ok:   accepted  $3"
  else
    echo "FAIL: refused   $3"
    sed 's/^/      /' "$TMP/out"
    fails=$((fails + 1))
  fi
}

expect_refuse() {
  if run_check "$1" "$2"; then
    echo "FAIL: accepted  $3 (must be refused)"
    fails=$((fails + 1))
  else
    echo "ok:   refused   $3"
  fi
}

[ "$#" -gt 0 ] || set -- openssl

for bin in "$@"; do
  echo "=== $bin: $("$bin" version) ==="
  D="$TMP/$(echo "$bin" | tr -c 'A-Za-z0-9\n' '_')"
  mkdir -p "$D"

  "$bin" genrsa -out "$D/rsa.pem" 2048 2> /dev/null
  "$bin" pkcs8 -topk8 -nocrypt -in "$D/rsa.pem" -out "$D/pkcs8.pem"
  if ! "$bin" rsa -in "$D/rsa.pem" -traditional -out "$D/trad.pem" 2> /dev/null; then
    "$bin" rsa -in "$D/rsa.pem" -out "$D/trad.pem" 2> /dev/null
  fi
  grep -q 'BEGIN PRIVATE KEY' "$D/pkcs8.pem"
  grep -q 'BEGIN RSA PRIVATE KEY' "$D/trad.pem"

  expect_accept "$bin" "$D/pkcs8.pem" "RSA key, PKCS#8"
  expect_accept "$bin" "$D/trad.pem" "RSA key, traditional PEM"

  : > "$D/empty.pem"
  expect_refuse "$bin" "$D/empty.pem" "empty file"
  expect_refuse "$bin" "$D/missing.pem" "missing file"

  echo "not a key" > "$D/text.pem"
  expect_refuse "$bin" "$D/text.pem" "text"

  head -n 8 "$D/pkcs8.pem" > "$D/truncated.pem"
  expect_refuse "$bin" "$D/truncated.pem" "truncated PEM"

  # One changed character in the middle of the key body: either the structure no longer
  # parses or the key is no longer consistent. Both must be refused.
  awk 'NR == 12 { $0 = (substr($0, 1, 9) == "AAAAAAAAA" ? "B" : "A") substr($0, 2) } { print }' "$D/trad.pem" > "$D/changed.pem"
  if cmp -s "$D/trad.pem" "$D/changed.pem"; then
    echo "FAIL: could not change the test key"
    fails=$((fails + 1))
  else
    expect_refuse "$bin" "$D/changed.pem" "RSA key with a changed byte"
  fi

  if "$bin" ecparam -name prime256v1 -genkey -noout -out "$D/ec.pem" 2> /dev/null; then
    expect_refuse "$bin" "$D/ec.pem" "EC key"
  else
    echo "skip: no EC key from this openssl"
  fi

  "$bin" rsa -in "$D/rsa.pem" -pubout -out "$D/pub.pem" 2> /dev/null
  expect_refuse "$bin" "$D/pub.pem" "public key only"

  # A CLI whose pkey takes no -check: the "RSA key ok" line of rsa -check has to decide.
  cat > "$D/openssl-nocheck" <<EOF
#!/bin/sh
if [ "\$1" = pkey ]; then
  for a in "\$@"; do
    if [ "\$a" = -check ]; then echo "pkey: unknown option -check" >&2; exit 1; fi
  done
fi
exec "$bin" "\$@"
EOF
  chmod +x "$D/openssl-nocheck"
  expect_accept "$D/openssl-nocheck" "$D/pkcs8.pem" "RSA key, PKCS#8, second form"
  expect_accept "$D/openssl-nocheck" "$D/trad.pem" "RSA key, traditional PEM, second form"
  expect_refuse "$D/openssl-nocheck" "$D/ec.pem" "EC key, second form"
  expect_refuse "$D/openssl-nocheck" "$D/changed.pem" "RSA key with a changed byte, second form"
  expect_refuse "$D/openssl-nocheck" "$D/pub.pem" "public key only, second form"
done

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "check-signing-key.sh: all checks passed"
