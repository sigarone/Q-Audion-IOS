#!/bin/sh
# ci-run-reuse.sh - the jobs of a workflow that already passed, on the pull request that produced a commit of main.
#
# USAGE   ci-run-reuse.sh WORKFLOW_FILE JOB...        (for example: ci-run-reuse.sh ios-ci.yml ios-simulator-tests)
# ENV     REPO        owner/name of the repository
#         SHA         full id of the commit on main
#         GH_TOKEN    token for gh (actions: read, pull-requests: read, contents: read)
#         KEEP_PATHS  optional, space-separated paths: when the commit changed one of them, nothing is reused (a job that
#                     saves a cache keyed on those files has to run on main)
# STDOUT  one line per reusable job:   JOB <TAB> RUN_ID <TAB> PR_NUMBER <TAB> PR_HEAD_SHA
#         and nothing else. Empty output means: reuse nothing. It is also what comes out when anything could not be read.
# STDERR  the reason for each decision. With GITHUB_STEP_SUMMARY set, a line per run that supplied jobs is added there.
# EXIT    0 once it has decided (the output may be empty), 2 for a bad call.
#
# A job of the workflow is reusable for the commit when ALL of these hold:
#   1. the commit has one parent and is the merge commit of exactly one merged pull request into main, whose head is
#      in this repository (not a fork);
#   2. the root tree of the head commit of that pull request is the root tree of the commit (the same files);
#   3. the head commit contains the parent of the commit, so the merge ref that the pull request run built had that
#      same tree and not a mix of the head with a different base;
#   4. of the runs of the workflow with event pull_request on that head commit, of this repository, that belong to
#      this pull request, the newest one (highest run id) has completed with conclusion success, and the job concluded
#      success in the latest attempt of that run. When the newest run failed or is still going, nothing is reused,
#      whatever an older run did.
#      A run belongs to the pull request when its title is "PR #<number>" (ios-ci.yml gives its pull request runs that
#      run-name, taken from the event, never from text of the author) and, when the run lists pull requests at all
#      (the API lists only OPEN ones: it is empty for a merged pull request, so it can not be required), the number is
#      among them. A run of another pull request on the same head commit is ignored.
# ios-ci.yml uses it on push to main to skip what the pull request already ran; the gate of ios-testflight.yml runs it
# again on the tagged commit for every job that a run skipped.
set -u
LC_ALL=C
export LC_ALL
TAB=$(printf '\t')
NL='
'
note() { printf 'ci-run-reuse: %s\n' "$*" >&2; }
none() { note "nothing reused: $*"; exit 0; }
bad() { printf 'ci-run-reuse: %s\n' "$*" >&2; exit 2; }

[ $# -ge 2 ] || bad "usage: ci-run-reuse.sh WORKFLOW_FILE JOB..."
WF=$1
shift
JOBS="$*"
case "$WF" in ''|*[!A-Za-z0-9._-]*) bad "not a workflow file name: ${WF}" ;; esac
case "${REPO:-}" in */*) ;; *) bad "REPO is not owner/name" ;; esac
case "${SHA:-}" in ''|*[!0-9a-f]*) bad "SHA is not a commit id" ;; esac
[ "${#SHA}" -eq 40 ] || bad "SHA is not a full commit id"

# 1) The commit and its pull request.
META=$(gh api "repos/${REPO}/commits/${SHA}" --jq '[.commit.tree.sha, (.parents | length), (.parents[0].sha // "-")] | @tsv') \
  || none "commit ${SHA} not readable"
IFS=$TAB read -r TREE NPARENTS PARENT <<EOF
$META
EOF
[ "$NPARENTS" = "1" ] || none "commit ${SHA} has ${NPARENTS} parents"
case "${TREE}${PARENT}" in *[!0-9a-f]*) none "tree or parent of ${SHA} not readable" ;; esac

PRS=$(gh api "repos/${REPO}/commits/${SHA}/pulls" --jq '.[] | [.number, (.merged_at // "-"), (.merge_commit_sha // "-"), .base.ref, .head.sha, (.head.repo.full_name // "-")] | @tsv') \
  || none "pull requests of ${SHA} not readable"
PR=""
PRHEAD=""
FOUND=0
while IFS=$TAB read -r _n _merged _merge_sha _base _head _head_repo; do
  [ -n "$_n" ] || continue
  [ "$_merged" != "-" ] && [ "$_merge_sha" = "$SHA" ] && [ "$_base" = "main" ] || continue
  if [ "$_head_repo" != "$REPO" ]; then
    note "pull request #${_n} comes from ${_head_repo}, not from ${REPO}"
    continue
  fi
  FOUND=$((FOUND + 1))
  PR=$_n
  PRHEAD=$_head
done <<EOF
$PRS
EOF
[ "$FOUND" -eq 1 ] || none "${FOUND} merged pull requests of ${REPO} have ${SHA} as merge commit"
case "$PRHEAD" in ''|*[!0-9a-f]*) none "head of pull request #${PR} not a commit id" ;; esac

# 2) The same files.
HEAD_TREE=$(gh api "repos/${REPO}/commits/${PRHEAD}" --jq '.commit.tree.sha') || none "head ${PRHEAD} of #${PR} not readable"
[ "$HEAD_TREE" = "$TREE" ] || none "tree of #${PR} head ${PRHEAD} (${HEAD_TREE}) is not the tree of ${SHA} (${TREE})"

# 3) The head already held everything of main.
CMP=$(gh api "repos/${REPO}/compare/${PARENT}...${PRHEAD}" --jq '[.status, .behind_by] | @tsv') \
  || none "comparison of ${PARENT} with ${PRHEAD} not readable"
IFS=$TAB read -r CSTATUS CBEHIND <<EOF
$CMP
EOF
case "$CSTATUS" in ahead|identical) ;; *) none "head ${PRHEAD} of #${PR} is ${CSTATUS} against ${PARENT}" ;; esac
[ "$CBEHIND" = "0" ] || none "head ${PRHEAD} of #${PR} lacks ${CBEHIND} commits of ${PARENT}"

if [ -n "${KEEP_PATHS:-}" ]; then
  FILES=$(gh api --paginate "repos/${REPO}/commits/${SHA}?per_page=100" --jq '.files[]?.filename') || none "file list of ${SHA} not readable"
  COUNT=$(printf '%s\n' "$FILES" | grep -c . || true)
  # The API lists at most 3000 files; an empty or full list is not trusted.
  { [ "$COUNT" -gt 0 ] && [ "$COUNT" -lt 3000 ]; } || none "file list of ${COUNT} entries is empty or possibly truncated"
  for _p in $KEEP_PATHS; do
    if printf '%s\n' "$FILES" | grep -qxF -- "$_p"; then none "${_p} changed: the run on main refreshes what is cached from it"; fi
  done
fi

# 4) The newest run of the pull request on its head, and the jobs in it. Runs that are not pull request runs of this
# repository on that head, or that belong to another pull request, are ignored; of the others the highest run id is the
# newest, and only that one is read.
RUNS=$(gh api "repos/${REPO}/actions/workflows/${WF}/runs?head_sha=${PRHEAD}&event=pull_request&per_page=100" \
  --jq '.workflow_runs[] | [.id, .status, (.conclusion // "-"), .event, .head_sha, (.head_repository.full_name // "-"), (.display_title // "-"), (if (.pull_requests | length) == 0 then "-" else ([.pull_requests[].number | tostring] | join(",")) end)] | @tsv') \
  || none "runs of ${WF} on ${PRHEAD} not readable"
RUNS=$(printf '%s\n' "$RUNS" | sort -t "$TAB" -k1,1nr)
RUN=""
RUN_STATUS=""
RUN_CONCL=""
while IFS=$TAB read -r _id _status _concl _event _run_head _run_repo _title _prs; do
  [ -n "$_id" ] || continue
  if [ "$_event" != "pull_request" ] || [ "$_run_head" != "$PRHEAD" ] || [ "$_run_repo" != "$REPO" ]; then
    note "run ${_id} of ${WF} is not a pull request run of ${REPO} on ${PRHEAD} (${_event}/${_run_repo}/${_run_head}): ignored"
    continue
  fi
  if [ "$_title" != "PR #${PR}" ]; then
    note "run ${_id} of ${WF} is titled '${_title}', not 'PR #${PR}': ignored"
    continue
  fi
  if [ "$_prs" != "-" ]; then
    case ",${_prs}," in
      *",${PR},"*) ;;
      *) note "run ${_id} of ${WF} lists pull requests ${_prs}, not #${PR}: ignored"; continue ;;
    esac
  fi
  RUN=$_id
  RUN_STATUS=$_status
  RUN_CONCL=$_concl
  break
done <<EOF
$RUNS
EOF
[ -n "$RUN" ] || none "no pull request run of ${WF} of ${REPO} on ${PRHEAD} for #${PR}"
[ "$RUN_STATUS" = "completed" ] || none "the newest run ${RUN} of ${WF} on ${PRHEAD} is ${RUN_STATUS}, not completed"
[ "$RUN_CONCL" = "success" ] || none "the newest run ${RUN} of ${WF} on ${PRHEAD} concluded ${RUN_CONCL}"
JOBLIST=$(gh api "repos/${REPO}/actions/runs/${RUN}/jobs?per_page=100&filter=latest" --jq '.jobs[] | [.name, (.conclusion // "-")] | @tsv') \
  || none "jobs of run ${RUN} not readable"
OUT=""
GOT=""
LEFT=""
for _j in $JOBS; do
  if printf '%s\n' "$JOBLIST" | grep -qxF -- "${_j}${TAB}success"; then
    OUT="${OUT}${_j}${TAB}${RUN}${TAB}${PR}${TAB}${PRHEAD}${NL}"
    GOT="${GOT} ${_j}"
  else
    LEFT="${LEFT} ${_j}"
  fi
done
if [ -n "$GOT" ]; then
  LINE="reused ${WF} run ${RUN} from PR #${PR} head ${PRHEAD} (identical tree):${GOT}"
  note "$LINE"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$LINE" >> "$GITHUB_STEP_SUMMARY"; fi
fi
[ -z "$LEFT" ] || note "not green in the newest run ${RUN} of #${PR}:${LEFT}"
printf '%s' "$OUT"
exit 0
