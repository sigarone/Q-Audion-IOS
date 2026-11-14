#!/bin/sh
# Self-test of scripts/ci/ci-run-reuse.sh. A stand-in `gh` answers each endpoint from a file (already in the shape
# the script's --jq expression yields) and fails when there is no file, like an API error; no network, no token.
# The stand-in appends every endpoint it is asked for to a call log, and a case counts only when the log is not empty:
# a stand-in that did not run (so the real gh answered, or none) can not make a case pass by an unrelated failure.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REUSE="$HERE/ci-run-reuse.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
FAKE="$TMP/answers"
CALLS="$TMP/gh-calls"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/sh
for a in "$@"; do case "$a" in api|--*) ;; *) ep=$a; break ;; esac; done
ep=${ep%%\?*}
printf '%s\n' "$ep" >> "$CALLS"
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
chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"
export PATH FAKE CALLS
[ -x "$TMP/bin/gh" ] || { echo "FAIL: the gh stand-in is not executable"; exit 1; }
: > "$CALLS"
gh api probe > /dev/null 2>&1 || true
[ -s "$CALLS" ] || { echo "FAIL: running gh does not run the stand-in"; exit 1; }
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
  : > "$CALLS"
  _out=$(env ${3:-X=1} sh "$REUSE" ios-app-tests.yml app variant 2>"$TMP/err") || _rc=$?
  if [ ! -s "$CALLS" ]; then
    echo "FAIL: $1 (the gh stand-in was never called)"
    sed 's/^/    err: /' "$TMP/err"
    fails=$((fails + 1))
  elif [ "$_rc" != 0 ] || [ "$_out" != "$_want" ]; then
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
expect "the jobs come from the newest run only: skipped there, green in an older run, not reused" "variant${TAB}901${TAB}453${TAB}$HEAD"

good
printf '901\tcompleted\tfailure\tpull_request\t%s\to/r\n900\tcompleted\tsuccess\tpull_request\t%s\to/r\n' "$HEAD" "$HEAD" > "$FAKE/runs"
printf 'app\tfailure\nvariant\tsuccess\n' > "$FAKE/jobs.901"
expect "newest run failed, an older run green: nothing is reused" ""

good
printf '900\tcompleted\tsuccess\tpull_request\t%s\to/r\n901\tcompleted\tfailure\tpull_request\t%s\to/r\n' "$HEAD" "$HEAD" > "$FAKE/runs"
printf 'app\tfailure\nvariant\tsuccess\n' > "$FAKE/jobs.901"
expect "newest run failed, listed after the older green one: nothing is reused" ""

good
printf '901\tcompleted\tfailure\tpull_request\t%s\to/r\n900\tcompleted\tsuccess\tpull_request\t%s\to/r\n' "$HEAD" "$HEAD" > "$FAKE/runs"
printf 'app\tsuccess\nvariant\tsuccess\n' > "$FAKE/jobs.901"
expect "newest run concluded failure although its jobs read success: nothing is reused" ""

good
printf '901\tin_progress\t-\tpull_request\t%s\to/r\n900\tcompleted\tsuccess\tpull_request\t%s\to/r\n' "$HEAD" "$HEAD" > "$FAKE/runs"
expect "newest run still going, an older run green: nothing is reused" ""

good
printf '900\tcompleted\tsuccess\tpull_request\t%s\to/r\n901\tqueued\t-\tpull_request\t%s\to/r\n' "$HEAD" "$HEAD" > "$FAKE/runs"
expect "newest run queued, listed after the older green one: nothing is reused" ""

good
printf '901\tcompleted\tsuccess\tpull_request\t%s\to/r\n900\tcompleted\tfailure\tpull_request\t%s\to/r\n' "$HEAD" "$HEAD" > "$FAKE/runs"
printf 'app\tskipped\nvariant\tsuccess\n' > "$FAKE/jobs.901"
expect "newest run green, an older run failed: the job that passed in the newest run is reused" "variant${TAB}901${TAB}453${TAB}$HEAD"

good
printf '903\tin_progress\t-\tpush\t%s\to/r\n902\tcompleted\tfailure\tpull_request\t%s\tfork/r\n901\tcompleted\tfailure\tpull_request\t%s\to/r\n900\tcompleted\tsuccess\tpull_request\t%s\to/r\n' "$HEAD" "$HEAD" "$OTHER" "$HEAD" > "$FAKE/runs"
expect "newer runs that are not pull request runs of this repository on the head are ignored" "$REUSED"

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
