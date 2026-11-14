"""Tests of check_ci_wiring.py: the real files agree, and each way of breaking the wiring is reported."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_ci_wiring as w  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding='utf-8') as f:
        return f.read()


CI = read('.github/workflows/ios-ci.yml')
FLIGHT = read('.github/workflows/ios-testflight.yml')
REUSE = read('scripts/ci/ci-run-reuse.sh')


def once(text, old, new):
    assert text.count(old) >= 1, 'the fixture text is gone: %r' % old
    return text.replace(old, new, 1)


class RealFiles(unittest.TestCase):
    def test_the_real_files_agree(self):
        self.assertEqual(w.check(CI, FLIGHT, REUSE), [])

    def test_the_gate_requires_the_six_jobs_of_the_tag_gate(self):
        self.assertEqual(sorted(w.gate_jobs(FLIGHT)), sorted([
            'ios-simulator-tests', 'app-build-and-tests', 'share-variant-build', 'vpn-variant-build',
            'earbud-variant-build', 'release-config-build']))


class Breakages(unittest.TestCase):
    def errors(self, ci=CI, flight=FLIGHT, reuse=REUSE):
        return w.check(ci, flight, reuse)

    def test_gate_names_a_job_that_does_not_exist(self):
        e = self.errors(flight=once(FLIGHT, 'ios-simulator-tests app-build-and-tests', 'ios-simulator-test app-build-and-tests'))
        self.assertTrue(any('job ios-simulator-test, which' in x for x in e), e)

    def test_gate_reads_the_old_workflow(self):
        e = self.errors(flight=once(FLIGHT, 'check ios-ci.yml $CI_JOBS', 'check ios-app-tests.yml $CI_JOBS'))
        self.assertTrue(any('does not read the runs of ios-ci.yml' in x for x in e), e)
        self.assertTrue(any('still points at ios-app-tests.yml' in x for x in e), e)

    def test_reuse_skips_a_job_the_gate_does_not_require(self):
        e = self.errors(ci=once(CI, 'app-build-and-tests share-variant-build vpn-variant-build earbud-variant-build release-config-build)',
                                'app-build-and-tests share-variant-build vpn-variant-build earbud-variant-build)'))
        self.assertTrue(any('are not the jobs the gate requires' in x for x in e), e)

    def test_result_does_not_wait_for_a_required_job(self):
        e = self.errors(ci=once(CI, 'needs: [plan, reuse, ios-simulator-tests, app-build-and-tests,', 'needs: [plan, reuse, app-build-and-tests,'))
        self.assertTrue(any('result does not wait for ios-simulator-tests' in x for x in e), e)

    def test_required_check_is_renamed(self):
        marker = '  ios-simulator-tests:\n'
        e = self.errors(ci=once(CI, marker, marker + '    name: Engine tests\n'))
        self.assertTrue(any('main requires the check ios-simulator-tests but that job is named Engine tests' in x for x in e), e)

    def test_required_check_is_gone(self):
        e = self.errors(ci=once(CI, '  swiftlint-qaudionapp-print-check:\n', '  swiftlint-print-check:\n'))
        self.assertTrue(any('swiftlint-qaudionapp-print-check' in x for x in e), e)

    def test_push_gets_a_path_filter(self):
        e = self.errors(ci=once(CI, '    branches: [main]\n  pull_request:', '    branches: [main]\n    paths: [QAudionApp/**]\n  pull_request:'))
        self.assertTrue(any('path filter' in x for x in e), e)

    def test_pull_request_trigger_is_gone(self):
        e = self.errors(ci=once(CI, '  pull_request:\n    branches: [main]\n', ''))
        self.assertTrue(any('no pull_request trigger' in x for x in e), e)

    def test_run_name_changes(self):
        e = self.errors(ci=once(CI, "format('PR #{0}', github.event.pull_request.number)", "format('pull request {0}', github.event.pull_request.number)"))
        self.assertTrue(any('run-name' in x for x in e), e)

    def test_reuse_script_looks_for_another_title(self):
        e = self.errors(reuse=once(REUSE, '"PR #${PR}"', '"pull request #${PR}"'))
        self.assertTrue(any('run title' in x for x in e), e)

    def test_no_jobs_at_all(self):
        self.assertEqual(w.check('name: x\n', FLIGHT, REUSE), ['ios-ci.yml has no jobs'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
