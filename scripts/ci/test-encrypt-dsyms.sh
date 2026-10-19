#!/bin/sh
# Self-test for scripts/ci/encrypt-dsyms.sh and for the recipient committed in ios-testflight.yml
# (POSIX sh; Linux, macOS). Needs `age` and `age-keygen` on PATH (or AGE_BIN / AGE_KEYGEN_BIN):
# scripts/ci/install-age.sh puts the pinned release there. Run:
#     sh scripts/ci/test-encrypt-dsyms.sh
# Uses throwaway keys generated in a temp dir; the real private key is never involved.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ENC="$HERE/encrypt-dsyms.sh"
AGE="${AGE_BIN:-age}"
KEYGEN="${AGE_KEYGEN_BIN:-age-keygen}"
T=$(mktemp -d "${TMPDIR:-/tmp}/encrypt-dsyms-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail=0

if ! command -v "$AGE" >/dev/null 2>&1 && [ ! -x "$AGE" ]; then echo "FAIL - age not found (run scripts/ci/install-age.sh)"; exit 2; fi
if ! command -v "$KEYGEN" >/dev/null 2>&1 && [ ! -x "$KEYGEN" ]; then echo "FAIL - age-keygen not found"; exit 2; fi
export AGE_BIN="$AGE"

expect() { # name want_rc cmd...
  name=$1; want=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok   - $name (rc=$rc)"; else echo "FAIL - $name: rc=$rc want=$want"; echo "$out" | sed 's/^/       /'; fail=1; fi
  LAST_OUT=$out
}
check() { # name, condition result (0 = pass)
  if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi
}

# throwaway key pair
"$KEYGEN" -o "$T/test.key" >/dev/null 2>&1
RCPT=$("$KEYGEN" -y "$T/test.key")
OTHER=$("$KEYGEN" 2>/dev/null | grep -o 'age1[0-9a-z]*' | head -1)

# --- input tree: a zip-like binary, a nested file, a name with a space ----------------------------
IN="$T/in"; OUT="$T/out"
mkdir -p "$IN/sub"
head -c 5000 /dev/urandom > "$IN/QAudionApp.app.dSYM.zip"
head -c 3000 /dev/urandom > "$IN/sub/QAudionApp.dSYMs.raw.zip"
printf 'with space' > "$IN/a b.zip"
cp "$IN/QAudionApp.app.dSYM.zip" "$T/ref1"; cp "$IN/sub/QAudionApp.dSYMs.raw.zip" "$T/ref2"; cp "$IN/a b.zip" "$T/ref3"

expect "encrypts a tree"                                  0 sh "$ENC" "$IN" "$OUT" "$RCPT"
n=$(find "$OUT" -type f | wc -l | tr -d ' ')
check "three .age files, flat" $([ "$n" = 3 ] && [ -f "$OUT/QAudionApp.app.dSYM.zip.age" ] && [ -f "$OUT/QAudionApp.dSYMs.raw.zip.age" ] && [ -f "$OUT/a b.zip.age" ]; echo $?)
check "the output holds only .age files" $([ -z "$(find "$OUT" -type f ! -name '*.age')" ]; echo $?)
check "the plaintext is gone from the input" $([ -z "$(find "$IN" -type f)" ]; echo $?)
check "no output file contains the plaintext magic" $(! grep -q 'with space' "$OUT/a b.zip.age"; echo $?)
"$AGE" -d -i "$T/test.key" -o "$T/dec1" "$OUT/QAudionApp.app.dSYM.zip.age"
"$AGE" -d -i "$T/test.key" -o "$T/dec2" "$OUT/QAudionApp.dSYMs.raw.zip.age"
"$AGE" -d -i "$T/test.key" -o "$T/dec3" "$OUT/a b.zip.age"
check "round trip: file 1" $(cmp -s "$T/ref1" "$T/dec1"; echo $?)
check "round trip: nested file" $(cmp -s "$T/ref2" "$T/dec2"; echo $?)
check "round trip: name with a space" $(cmp -s "$T/ref3" "$T/dec3"; echo $?)
if [ -n "$OTHER" ]; then
  # a different key must NOT decrypt: encrypt to OTHER and try the test key
  mkdir -p "$T/in2"; printf 'secret' > "$T/in2/f.zip"
  sh "$ENC" "$T/in2" "$T/out2" "$OTHER" >/dev/null 2>&1
  "$AGE" -d -i "$T/test.key" -o "$T/y" "$T/out2/f.zip.age" >/dev/null 2>&1; rc=$?
  check "a file encrypted to another key is unreadable with this one" $([ "$rc" -ne 0 ]; echo $?)
fi

# --- error handling ---------------------------------------------------------------------------------
mkdir -p "$T/in3"; printf 'x' > "$T/in3/f.zip"
expect "recipient is not an age key -> exit 2"           2 sh "$ENC" "$T/in3" "$T/out3" "not-a-key"
expect "recipient has the wrong length -> exit 2"        2 sh "$ENC" "$T/in3" "$T/out3" "age1abc"
UPPER="$(printf '%s' "$RCPT" | cut -c1-9)X$(printf '%s' "$RCPT" | cut -c11-)"
expect "recipient with an uppercase letter -> exit 2"    2 sh "$ENC" "$T/in3" "$T/out3" "$UPPER"
expect "an SSH-style recipient is refused -> exit 2"     2 sh "$ENC" "$T/in3" "$T/out3" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample"
check "nothing was written for a refused recipient" $([ ! -e "$T/out3" ] || [ -z "$(find "$T/out3" -type f)" ]; echo $?)
check "the plaintext is untouched after a refusal" $([ -f "$T/in3/f.zip" ]; echo $?)
expect "missing input dir -> exit 2"                     2 sh "$ENC" "$T/nope" "$T/out4" "$RCPT"
expect "no arguments -> exit 2"                          2 sh "$ENC"
expect "two arguments -> exit 2"                         2 sh "$ENC" "$T/in3" "$T/out5"
expect "age missing -> exit 2"                           2 env AGE_BIN=/nonexistent/age sh "$ENC" "$T/in3" "$T/out6" "$RCPT"

mkdir -p "$T/out7"; printf 'leftover plaintext' > "$T/out7/leftover.zip"
expect "a non-.age file already in OUT_DIR -> exit 2"    2 sh "$ENC" "$T/in3" "$T/out7" "$RCPT"

mkdir -p "$T/in8/a" "$T/in8/b"; printf 'one' > "$T/in8/a/dup.zip"; printf 'two' > "$T/in8/b/dup.zip"
expect "two inputs with the same file name -> exit 1"    1 sh "$ENC" "$T/in8" "$T/out8" "$RCPT"

mkdir -p "$T/empty"
expect "an empty input dir is a warning, not an error"   0 sh "$ENC" "$T/empty" "$T/out9" "$RCPT"
case "$LAST_OUT" in *"nothing to encrypt"*) echo "ok   - the warning says so";; *) echo "FAIL - no warning"; fail=1;; esac

# age that fails: the plaintext must survive and the partial output must not
cat > "$T/badage" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$T/badage"
mkdir -p "$T/in10"; printf 'keepme' > "$T/in10/f.zip"
expect "age failing -> exit 1"                           1 env AGE_BIN="$T/badage" sh "$ENC" "$T/in10" "$T/out10" "$RCPT"
check "plaintext kept when encryption failed" $([ -f "$T/in10/f.zip" ]; echo $?)
check "no output file left when encryption failed" $([ -z "$(find "$T/out10" -type f 2>/dev/null)" ]; echo $?)

# an "age" that exits 0 but writes something that is not an age file
cat > "$T/fakeage" <<'EOF'
#!/bin/sh
# usage: fakeage -r RCPT -o OUT IN
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; -r) shift 2;; *) in=$1; shift;; esac; done
cp "$in" "$out"
EOF
chmod +x "$T/fakeage"
mkdir -p "$T/in11"; printf 'plain' > "$T/in11/f.zip"
expect "an output without the age header -> exit 1"      1 env AGE_BIN="$T/fakeage" sh "$ENC" "$T/in11" "$T/out11" "$RCPT"
check "the unencrypted copy was not kept in OUT_DIR" $([ -z "$(find "$T/out11" -type f 2>/dev/null)" ]; echo $?)

# output carries file names and sizes only
mkdir -p "$T/in12"; printf 'TOPSECRETPAYLOAD' > "$T/in12/f.zip"
out=$(sh "$ENC" "$T/in12" "$T/out12" "$RCPT" 2>&1)
case "$out" in *TOPSECRETPAYLOAD*) echo "FAIL - the output leaked file content"; fail=1;; *) echo "ok   - the output has names and sizes only";; esac

# --- the recipient committed in the workflow ------------------------------------------------------------
WF="$REPO/.github/workflows/ios-testflight.yml"
if [ -f "$WF" ]; then
  # tr -d '\r': a Windows checkout (autocrlf) has CRLF line ends, and a trailing CR would make a valid key look malformed.
  WFR=$(grep -E '^[[:space:]]+DSYM_AGE_RECIPIENT:' "$WF" | head -1 | tr -d '\r' | sed -E "s/^[^:]+:[[:space:]]*//; s/[[:space:]]+#.*$//; s/['\"]//g")
  check "the workflow commits exactly one DSYM_AGE_RECIPIENT" $([ "$(grep -cE '^[[:space:]]+DSYM_AGE_RECIPIENT:' "$WF")" = 1 ]; echo $?)
  mkdir -p "$T/in13"; printf 'probe' > "$T/in13/f.zip"
  expect "the committed recipient is a valid age public key" 0 sh "$ENC" "$T/in13" "$T/out13" "$WFR"
  check "no private key material in the workflow" $(! grep -q 'AGE-SECRET-KEY' "$WF"; echo $?)
else
  echo "skip - ios-testflight.yml not found"
fi

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME TESTS FAILED"
exit "$fail"
