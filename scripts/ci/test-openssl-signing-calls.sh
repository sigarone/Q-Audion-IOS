#!/bin/sh
# Exercises, against throwaway data, the openssl command lines that the signing tooling
# runs on the release runner (codemagic-cli-tools 0.70, app-store-connect fetch-signing-files):
#   * openssl smime -inform der -verify -noverify -in PROFILE      (read a provisioning profile)
#   * openssl pkcs12 -noenc|-nodes -passin pass:... -in P12 -out PEM   (unwrap a certificate container)
# The container is built the way that tool builds it (3DES key and certificate encryption,
# SHA-1 MAC), so the unwrap runs on the same algorithms.
#
# usage: test-openssl-signing-calls.sh [OPENSSL ...]
#   Without arguments it uses the openssl on PATH. Every argument is an openssl executable
#   tested in turn (the versioned installs on a macOS runner image, for example).
# Meant to run report-only: it shows how a given openssl build handles those calls.

set -eu

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0
[ "$#" -gt 0 ] || set -- openssl

for bin in "$@"; do
  echo "=== $bin: $("$bin" version) ==="
  D="$TMP/$(echo "$bin" | tr -c 'A-Za-z0-9\n' '_')"
  mkdir -p "$D"

  "$bin" genrsa -out "$D/key.pem" 2048 2> /dev/null
  "$bin" req -new -x509 -key "$D/key.pem" -subj "/CN=ci-throwaway" -days 1 -out "$D/cert.pem"

  # smime: a signed message in DER, read back without verifying the chain.
  printf 'profile-payload-%s\n' "$$" > "$D/payload.txt"
  if "$bin" smime -sign -in "$D/payload.txt" -signer "$D/cert.pem" -inkey "$D/key.pem" \
    -outform der -nodetach -binary -out "$D/profile.der" 2> "$D/err" \
    && "$bin" smime -inform der -verify -noverify -in "$D/profile.der" > "$D/payload.out" 2>> "$D/err" \
    && cmp -s "$D/payload.txt" "$D/payload.out"; then
    echo "ok:   smime -inform der -verify -noverify"
  else
    echo "FAIL: smime -inform der -verify -noverify"
    sed 's/^/      /' "$D/err"
    fails=$((fails + 1))
  fi

  # pkcs12: build the container with 3DES and a SHA-1 MAC, then unwrap it.
  if "$bin" pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -passout pass:temporary-password \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -out "$D/container.p12" 2> "$D/err"; then
    if "$bin" pkcs12 -help 2>&1 | grep -q -- '-noenc'; then
      NOENC=-noenc
    else
      NOENC=-nodes
    fi
    if "$bin" pkcs12 "$NOENC" -passin pass:temporary-password -in "$D/container.p12" -out "$D/unwrapped.pem" 2>> "$D/err" \
      && grep -q 'BEGIN CERTIFICATE' "$D/unwrapped.pem" \
      && grep -q 'PRIVATE KEY' "$D/unwrapped.pem"; then
      echo "ok:   pkcs12 $NOENC (3DES container, SHA-1 MAC)"
    else
      echo "FAIL: pkcs12 $NOENC (3DES container, SHA-1 MAC)"
      sed 's/^/      /' "$D/err"
      fails=$((fails + 1))
    fi
  else
    echo "FAIL: pkcs12 -export with 3DES and a SHA-1 MAC"
    sed 's/^/      /' "$D/err"
    fails=$((fails + 1))
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "$fails call(s) failed"
  exit 1
fi
echo "openssl signing calls: all passed"
