#!/bin/sh
# encrypt-dsyms.sh - encrypt every file of a directory with age, to a public recipient key.
#
# WHY. This repository is public, so a GitHub Actions artifact can be downloaded by anyone with a
# GitHub account. dSYMs carry the full debug info (every symbol, source path and line) of the
# shipped app, so ios-testflight.yml encrypts them before upload and uploads ONLY the .age files.
# The recipient is a public key committed in the workflow; the private key is kept off GitHub
# and scripts/symbolicate.py decrypts where it is.
#
# USAGE   scripts/ci/encrypt-dsyms.sh IN_DIR OUT_DIR RECIPIENT
#   IN_DIR     directory whose regular files (recursively) are encrypted, one .age file each, into
#              OUT_DIR (flat; a path collision is an error). Plaintext files are deleted afterwards.
#   OUT_DIR    created if missing; must be EMPTY of anything but its own previous .age output.
#   RECIPIENT  an age X25519 public key (age1...). Anything else is refused: a typo must not
#              produce files nobody can read.
#   AGE_BIN    optional path of the age binary (default: `age` from PATH).
# The upload step must use OUT_DIR/*.age and never IN_DIR. Nothing is printed about file contents.
# EXIT    0 done (an empty IN_DIR is a warning, not an error) | 1 encryption or verification failed | 2 bad usage
set -eu

say() { printf '%s\n' "$*"; }
err() { say "::error::encrypt-dsyms: $1"; }

if [ "$#" -ne 3 ]; then
  err "usage: encrypt-dsyms.sh IN_DIR OUT_DIR RECIPIENT"
  exit 2
fi
IN="$1"; OUT="$2"; RCPT="$3"
AGE="${AGE_BIN:-age}"

case "$RCPT" in
  age1[0-9a-z]*) ;;
  *) err "the recipient is not an age public key (expected age1...)"; exit 2 ;;
esac
# age X25519 recipients are 62 characters of lowercase bech32.
if [ "${#RCPT}" -ne 62 ] || printf '%s' "$RCPT" | grep -q '[^0-9a-z]'; then
  err "the recipient is not a well-formed age X25519 public key (62 lowercase bech32 characters)"
  exit 2
fi
[ -d "$IN" ] || { err "input directory does not exist: $IN"; exit 2; }
command -v "$AGE" >/dev/null 2>&1 || [ -x "$AGE" ] || { err "age is not installed (scripts/ci/install-age.sh)"; exit 2; }

mkdir -p "$OUT"
# OUT may only hold .age files (a leftover plaintext there would be uploaded by a *.age-less glob).
BAD=$(find "$OUT" -type f ! -name '*.age' 2>/dev/null | head -1)
if [ -n "$BAD" ]; then err "the output directory holds a file that is not .age: $BAD"; exit 2; fi

LIST=$(mktemp "${TMPDIR:-/tmp}/encrypt-dsyms.XXXXXX") || { err "cannot create a temp file"; exit 2; }
trap 'rm -f "$LIST"' EXIT INT TERM
find "$IN" -type f ! -name '*.age' | sort > "$LIST"

COUNT=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  name=$(basename "$f")
  dest="$OUT/$name.age"
  if [ -e "$dest" ]; then err "two inputs map to the same output name: $name"; exit 1; fi
  "$AGE" -r "$RCPT" -o "$dest" "$f" || { err "age failed for $name"; rm -f "$dest"; exit 1; }
  # Verify the result is really an age file (binary format, v1 header) and not empty.
  HEAD=$(head -c 21 "$dest" 2>/dev/null || true)
  if [ "$HEAD" != "age-encryption.org/v1" ]; then
    err "$name.age does not start with the age header"
    rm -f "$dest"
    exit 1
  fi
  SIZE=$(wc -c < "$dest" | tr -d ' ')
  say "encrypt-dsyms: $name -> $name.age ($SIZE bytes)"
  COUNT=$((COUNT + 1))
done < "$LIST"

if [ "$COUNT" -eq 0 ]; then
  say "::warning::encrypt-dsyms: nothing to encrypt in $IN"
  exit 0
fi

# All encrypted: remove the plaintext so nothing else on the runner can upload it by accident.
while IFS= read -r f; do
  [ -n "$f" ] && rm -f "$f"
done < "$LIST"

LEFT=$(find "$OUT" -type f ! -name '*.age' | head -1)
if [ -n "$LEFT" ]; then err "a non-.age file is in the output directory: $LEFT"; exit 1; fi
say "encrypt-dsyms: $COUNT file(s) encrypted; the output directory holds only .age files"
