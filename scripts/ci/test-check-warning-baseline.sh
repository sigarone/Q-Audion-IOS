#!/bin/sh
# Self-test of scripts/ci/check-warning-baseline.sh.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
CHECK="$HERE/check-warning-baseline.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
fails=0

printf '0\n' > "$TMP/zero"
printf '2\n' > "$TMP/two"

cat > "$TMP/clean.log" <<'LOG'
/Users/runner/work/r/r/QAudionApp/Foo.swift:1:1: note: something
/Users/runner/work/r/r/QAudionApp/Foo.swift:2:1: warning: x [#A]
LOG
# one counted warning, one more from another architecture (same line), one in a package,
# one in the tests, one without a location
cat > "$TMP/one.log" <<'LOG'
/Users/runner/work/r/r/QAudionApp/Foo.swift:2:1: warning: x [#A]
/Users/runner/work/r/r/QAudionApp/Foo.swift:2:1: warning: x [#A]
/Users/runner/work/r/r/QAudionEngine/Tests/QAudionEngineTests/T.swift:5:1: warning: in tests
/tmp/dd/SourcePackages/checkouts/Dep/Sources/D.swift:3:3: warning: in a package
warning: no location
LOG
printf '' > "$TMP/empty.log"
cat > "$TMP/engine.log" <<'LOG'
   /Users/runner/work/r/r/QAudionEngine/Sources/QAudionEngine/A.swift:9:9: warning: y
/Users/runner/work/r/r/QAudionIntents/I.swift:4:2: warning: z
LOG

expect() { # name wantExit log baseline
  rc=0; sh "$CHECK" "$3" "$4" > "$TMP/out" 2>&1 || rc=$?
  if [ "$rc" != "$2" ]; then
    echo "FAIL: $1 (exit $rc, wanted $2)"; sed 's/^/    /' "$TMP/out"; fails=$((fails + 1))
  else
    echo "ok:   $1"
  fi
}

expect "no warnings, baseline 0"            0 "$TMP/empty.log"  "$TMP/zero"
expect "a note and a counted warning, 0"    1 "$TMP/clean.log"  "$TMP/zero"
expect "duplicates and ignored lines, 0"    1 "$TMP/one.log"    "$TMP/zero"
expect "engine sources and intents count"   1 "$TMP/engine.log" "$TMP/zero"
expect "two warnings, baseline 2"           0 "$TMP/engine.log" "$TMP/two"
expect "missing log"                        2 "$TMP/none.log"   "$TMP/zero"
printf 'abc\n' > "$TMP/bad"
expect "bad baseline file"                  2 "$TMP/empty.log"  "$TMP/bad"

[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
