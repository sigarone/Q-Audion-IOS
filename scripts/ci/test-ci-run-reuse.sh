#!/bin/sh
# Self-test of scripts/ci/ci-run-reuse.sh. A stand-in `gh` answers each endpoint from a file (already in the shape
# the script's --jq expression yields) and fails when there is no file, like an API error; no network, no token.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REUSE="$HERE/ci-run-reuse.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
FAKE="$TMP/answers"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/sh
for a in "$@"; do case "$a" in api|--*) ;; *) ep=$a; break ;; esac; done
ep=${ep%%\?*}
case " $* " in
  *" --paginate "*) f=files ;;
  *) case "$ep" in
       repos/*/commits/*/pulls) f=pulls ;;
       repos/*/commits/*) f=commit.${ep##*/} ;;
       repos/*/compare/*) f=compare ;;
       repos/*/actions/workflows/*/runs) f=runs ;;
       repos/*/actions/runs/*/jobs) p=${ep%/jobs}; f=jobs.${p##*/} ;;
       *) f=unknown ;;
     esac ;;
esac
[ -f "$FAKE/$f" ] || { echo "gh: no answer for $ep" >&2; exit 1; }
cat "$FAKE/$f"
GH
PATH="$TMP/bin:$PATH"
export PATH FAKE
export REPO=o/r
SHA=1111111111111111111111111111111111111111
PARENT=2222222222222222222222222222222222222222
HEAD=3333333333333333333333333333333333333333
TREE=4444444444444444444444444444444444444444
OTHER=5555555555555555555555555555555555555555
export SHA
TAB=$(printf '\t')
fails=0

# A pull request that is up to date, was squash merged, and whose run on its head is green.
good() {
  rm -rf "$FAKE"
  mkdir -p "$FAKE"
  printf '%s\t1\t%s\n' "$TREE" "$PARENT" > "$FAKE/commit.$SHA"
  printf '%s\n' "$TREE" > "$FAKE/commit.$HEAD"
  printf '453\t2026-11-14T13:38:03Z\t%s\tmain\t%s\to/r\n' "$SHA" "$HEAD" > "$FAKE/pulls"
  printf 'ahead\t0\n' > "$FAKE/compare"
  printf '900\tcompleted\tsuccess\tpull_request\t%s\to/r\n' "$HEAD" > "$FAKE/runs"
  printf 'changes\tsuccess\napp\tsuccess\nvariant\tskipped\n' > "$FAKE/jobs.900"
  printf 'QAudionApp/A.swift\ndocs/x.md\n' > "$FAKE/files"
}

expect() { # expect NAME WANTED_STDOUT [ENV=VALUE] -- the script is run on the jobs "app variant"
  _want=$2
  _rc=0
  _out=$(env ${3:-X=1} sh "$REUSE" ios-app-tests.yml app variant 2>"$TMP/err") || _rc=$?
  if [ "$_rc" != 0 ] || [ "$_out" != "$_want" ]; then
    echo "FAIL: $1 (exit $_rc)"
    printf '    wanted: %s\n    got:    %s\n' "$_want" "$_out"
    sed 's/^/    err: /' "$TMP/err"
    fails=$((fails + 1))
  else
    echo "ok:   $1"
  fi
}

REUSED="app${TAB}900${TAB}453${TAB}$HEAD"

good
expect "identical tree and a green run: the job that passed is reused, the skipped one is not" "$REUSED"

good; printf '%s\n' "$OTHER" > "$FAKE/commit.$HEAD"
expect "different tree: nothing is reused" ""

good; rm "$FAKE/pulls"
expect "API failure on the pull request lookup: nothing is reused" ""

good; rm "$FAKE/runs"
expect "API failure on the run lookup: nothing is reused" ""

good; rm "$FAKE/jobs.900"
expect "API failure on the jobs of the run: nothing is reused" ""

good; rm "$FAKE/compare"
expect "API failure on the comparison: nothing is reused" ""

good; printf '453\t2026-11-14T13:38:03Z\t%s\tmain\t%s\tfork/r\n' "$SHA" "$HEAD" > "$FAKE/pulls"
expect "pull request from a fork: nothing is reused" ""

good; printf '453\t-\t-\tmain\t%s\to/r\n' "$HEAD" > "$FAKE/pulls"
expect "pull request not merged: nothing is reused" ""

good; printf '453\t2026-11-14T13:38:03Z\t%s\tmain\t%s\to/r\n' "$OTHER" "$HEAD" > "$FAKE/pulls"
expect "pull request merged as another commit: nothing is reused" ""

good; printf '%s\t2\t%s\n' "$TREE" "$PARENT" > "$FAKE/commit.$SHA"
expect "commit with two parents: nothing is reused" ""

good; printf 'diverged\t2\n' > "$FAKE/compare"
expect "pull request head lacks commits of main: nothing is reused" ""

good; printf '900\tcompleted\tfailure\tpull_request\t%s\to/r\n' "$HEAD" > "$FAKE/runs"
expect "run of the pull request failed: nothing is reused" ""

good; printf '900\tin_progress\t-\tpull_request\t%s\to/r\n' "$HEAD" > "$FAKE/runs"
expect "run of the pull request still going: nothing is reused" ""

good; printf '900\tcompleted\tsuccess\tpull_request\t%s\to/r\n' "$OTHER" > "$FAKE/runs"
expect "run on another commit: nothing is reused" ""

good; printf '900\tcompleted\tsuccess\tpull_request\t%s\tfork/r\n' "$HEAD" > "$FAKE/runs"
expect "run of a fork: nothing is reused" ""

good; printf '900\tcompleted\tsuccess\tpush\t%s\to/r\n' "$HEAD" > "$FAKE/runs"
expect "run that is not a pull request run: nothing is reused" ""

good; printf 'changes\tsuccess\napp\tfailure\nvariant\tsuccess\n' > "$FAKE/jobs.900"
expect "each job is judged on its own result" "variant${TAB}900${TAB}453${TAB}$HEAD"

good
printf '901\tcompleted\tsuccess\tpull_request\t%s\to/r\n900\tcompleted\tsuccess\tpull_request\t%s\to/r\n' "$HEAD" "$HEAD" > "$FAKE/runs"
printf 'app\tskipped\nvariant\tsuccess\n' > "$FAKE/jobs.901"
expect "a job comes from the run that has it green" "variant${TAB}901${TAB}453${TAB}$HEAD
app${TAB}900${TAB}453${TAB}$HEAD"

good; printf 'QAudionEngine/Package.swift\n' > "$FAKE/files"
expect "a kept path changed: nothing is reused" "" "KEEP_PATHS=QAudionEngine/Package.swift"

good
expect "a kept path unchanged: the job is reused" "$REUSED" "KEEP_PATHS=QAudionEngine/Package.swift"

good; rm "$FAKE/files"
expect "kept paths set and the file list unreadable: nothing is reused" "" "KEEP_PATHS=QAudionEngine/Package.swift"

rc=0
sh "$REUSE" ios-app-tests.yml >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then echo "ok:   no job named: bad call"; else echo "FAIL: no job named (exit $rc, wanted 2)"; fails=$((fails + 1)); fi
rc=0
SHA=abc sh "$REUSE" ios-app-tests.yml app >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then echo "ok:   short commit id: bad call"; else echo "FAIL: short commit id (exit $rc, wanted 2)"; fails=$((fails + 1)); fi

[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
