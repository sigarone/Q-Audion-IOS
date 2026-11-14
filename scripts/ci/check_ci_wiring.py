"""Wiring between .github/workflows/ios-ci.yml, the TestFlight gate of ios-testflight.yml and ci-run-reuse.sh.

The gate (job `gate` of ios-testflight.yml) names a workflow file and the jobs of it that must be green on the commit
it ships; the job `reuse` of ios-ci.yml names the jobs it may take from the pull request; main requires two checks by
name. Nothing in a workflow file ties these names together, so renaming a job in one place leaves the others pointing at
nothing, which the gate reads as "not green" (a release that can not start) or, worse, as nothing to wait for.
This reads the three files as text (no YAML library: the runner has none) and fails on any difference:

  * every job the gate requires is a job of ios-ci.yml, and the gate reads the runs of ios-ci.yml;
  * the jobs that `reuse` may skip on main are exactly the jobs the gate requires;
  * the check `result` waits for every job the gate requires;
  * the two checks that main requires keep their names (a job without `name:` is checked under its id);
  * ios-ci.yml runs on every push to main (no path filter: the gate needs the run of the exact commit), on pull requests
    and on manual dispatch;
  * the run title that ci-run-reuse.sh looks for is the run-name that ios-ci.yml gives a pull request run.

USAGE   check_ci_wiring.py [REPO_ROOT]     (default: the current directory)
EXIT    0 when everything agrees, 1 with one line per difference.
"""
import re
import sys

REQUIRED_CHECKS = ('ios-simulator-tests', 'swiftlint-qaudionapp-print-check')


def jobs_of(ci):
    """job id -> text of its block, for the jobs under the top-level `jobs:` of the workflow."""
    m = re.search(r'^jobs:\s*$', ci, re.M)
    if not m:
        return {}
    body = ci[m.end():]
    ids = list(re.finditer(r'^  ([A-Za-z0-9_][A-Za-z0-9_-]*):\s*$', body, re.M))
    out = {}
    for i, j in enumerate(ids):
        end = ids[i + 1].start() if i + 1 < len(ids) else len(body)
        out[j.group(1)] = body[j.end():end]
    return out


def gate_jobs(flight):
    m = re.search(r'^\s*CI_JOBS="([^"]*)"', flight, re.M)
    return m.group(1).split() if m else []


def reuse_jobs(ci):
    """The jobs named in the calls of ci-run-reuse.sh in ios-ci.yml (after the workflow file name)."""
    names = []
    for m in re.finditer(r'ci-run-reuse\.sh ios-ci\.yml ([^)]*)\)', ci):
        names += m.group(1).split()
    return names


def check(ci, flight, reuse_sh):
    errors = []
    jobs = jobs_of(ci)
    if not jobs:
        return ['ios-ci.yml has no jobs']
    needed = gate_jobs(flight)
    if not needed:
        errors.append('ios-testflight.yml: no CI_JOBS list in the gate')
    for j in needed:
        if j not in jobs:
            errors.append('the gate requires job %s, which ios-ci.yml does not have' % j)
    if not re.search(r'check ios-ci\.yml \$CI_JOBS', flight):
        errors.append('the gate does not read the runs of ios-ci.yml with the CI_JOBS list')
    for old in ('ios-app-tests.yml', 'engine-tests.yml'):
        if re.search(r'gh workflow run %s|check %s' % (re.escape(old), re.escape(old)), flight):
            errors.append('the gate still points at %s' % old)

    reused = reuse_jobs(ci)
    if not reused:
        errors.append('ios-ci.yml: the job reuse calls ci-run-reuse.sh on no job')
    if sorted(set(reused)) != sorted(set(needed)):
        errors.append('the jobs reuse may skip (%s) are not the jobs the gate requires (%s)'
                      % (' '.join(sorted(set(reused))), ' '.join(sorted(set(needed)))))

    result = jobs.get('result', '')
    m = re.search(r'needs:\s*\[([^\]]*)\]', result)
    waits = [x.strip() for x in m.group(1).split(',')] if m else []
    for j in needed:
        if j not in waits:
            errors.append('the job result does not wait for %s' % j)

    for j in REQUIRED_CHECKS:
        if j not in jobs:
            errors.append('main requires the check %s and ios-ci.yml has no such job' % j)
            continue
        nm = re.search(r'^    name:\s*(.+?)\s*$', jobs[j], re.M)
        if nm and nm.group(1) != j:
            errors.append('main requires the check %s but that job is named %s' % (j, nm.group(1)))

    on = re.search(r'^on:\s*\n(.*?)(?=^\S)', ci, re.M | re.S)
    on_text = on.group(1) if on else ''
    for trigger in ('push:', 'pull_request:', 'workflow_dispatch:'):
        if trigger not in on_text:
            errors.append('ios-ci.yml has no %s trigger' % trigger.rstrip(':'))
    if re.search(r'^\s*paths(-ignore)?:', on_text, re.M):
        errors.append('ios-ci.yml has a path filter: the gate needs the run of every push to main')

    rn = re.search(r"^run-name:.*format\('PR #\{0\}', github\.event\.pull_request\.number\)", ci, re.M)
    if not rn:
        errors.append("ios-ci.yml: the run-name of a pull request run is not format('PR #{0}', github.event.pull_request.number)")
    if '"PR #${PR}"' not in reuse_sh:
        errors.append('ci-run-reuse.sh does not look for the run title "PR #${PR}"')
    return errors


def main(argv):
    root = argv[1] if len(argv) > 1 else '.'
    texts = []
    for rel in ('.github/workflows/ios-ci.yml', '.github/workflows/ios-testflight.yml', 'scripts/ci/ci-run-reuse.sh'):
        with open('%s/%s' % (root, rel), encoding='utf-8') as f:
            texts.append(f.read())
    errors = check(*texts)
    for e in errors:
        print('FAIL: ' + e)
    if errors:
        return 1
    print('ios-ci.yml, the TestFlight gate and ci-run-reuse.sh agree')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
