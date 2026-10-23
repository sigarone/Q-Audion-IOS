#!/bin/sh
# Check that a PEM file holds a usable RSA private key (the distribution signing key).
#
# usage: check-signing-key.sh KEY.pem
#   SIGNING_CHECK_OPENSSL=/path/to/openssl  picks a specific build (default: the openssl on PATH)
#
# "openssl rsa -check" cannot be judged by its exit status: on OpenSSL 3 it exits 0 and
# prints a message even for an inconsistent key. The wording of that message also differs
# between LibreSSL, OpenSSL 3 and OpenSSL 4. So there are two independent ways to accept a key:
#   A. openssl pkey -check -noout succeeds (its exit status is the verdict) and
#      openssl rsa -noout succeeds (the file is an RSA key, not another kind of key);
#   B. for a CLI whose pkey has no -check (LibreSSL): openssl rsa -check -noout succeeds and
#      prints a line that starts with "RSA key ok".
# Everything runs with -noout, so no key material is printed; on a failure the messages of
# openssl itself are shown.
# Self-test: scripts/ci/test-check-signing-key.sh.

set -eu

OPENSSL="${SIGNING_CHECK_OPENSSL:-openssl}"
KEY="${1:-}"

if [ -z "$KEY" ]; then
  echo "usage: check-signing-key.sh KEY.pem" >&2
  exit 2
fi
if [ ! -s "$KEY" ]; then
  echo "::error::the signing key file is missing or empty"
  exit 1
fi

echo "openssl: $("$OPENSSL" version) ($(command -v "$OPENSSL"))"

if OUT_RSA=$("$OPENSSL" rsa -in "$KEY" -noout -passin pass: 2>&1) \
  && OUT_PKEY=$("$OPENSSL" pkey -in "$KEY" -noout -check -passin pass: 2>&1); then
  echo "private key OK (pkey -check)"
  exit 0
fi

if OUT_CHECK=$("$OPENSSL" rsa -in "$KEY" -noout -check -passin pass: 2>&1) \
  && printf '%s\n' "$OUT_CHECK" | grep -q '^RSA key ok'; then
  echo "private key OK (rsa -check: RSA key ok)"
  exit 0
fi

echo "::error::openssl does not accept the signing key as a consistent RSA private key"
echo "--- openssl rsa -noout"
printf '%s\n' "${OUT_RSA:-}"
echo "--- openssl pkey -check -noout"
printf '%s\n' "${OUT_PKEY:-}"
echo "--- openssl rsa -check -noout"
printf '%s\n' "${OUT_CHECK:-}"
exit 1
