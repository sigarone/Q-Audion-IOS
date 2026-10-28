#!/usr/bin/env python3
"""Tests of check_notify_entitlements.py on throwaway trees and on mutations of the real files."""

import copy
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "check_notify_entitlements.py")
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
FILES = [
    "QAudionApp/QAudion.entitlements",
    "QAudionApp/QAudionVPN.entitlements",
    "QAudionApp/QAudionShareApp.entitlements",
]

GOOD = {
    "com.apple.developer.usernotifications.time-sensitive": True,
    "keychain-access-groups": ["$(AppIdentifierPrefix)com.qaudion.app", "$(AppIdentifierPrefix)com.qaudion.notify"],
    "com.apple.security.application-groups": ["group.com.bcrypto.qaudion.notify"],
    "com.apple.developer.default-data-protection": "NSFileProtectionComplete",
}


def run(root):
    return subprocess.run([sys.executable, "-I", SCRIPT, root], capture_output=True, text=True)


class Check(unittest.TestCase):
    def tree(self, first=GOOD, second=GOOD, third=GOOD):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        for rel, data in zip(FILES, (first, second, third)):
            path = os.path.join(d.name, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                plistlib.dump(data, f)
        return d.name

    def mutated(self, mutate):
        data = copy.deepcopy(GOOD)
        mutate(data)
        return data

    def test_good_tree_passes(self):
        self.assertEqual(run(self.tree()).returncode, 0)

    def test_each_missing_piece_fails(self):
        mutations = [
            lambda d: d.pop("com.apple.developer.usernotifications.time-sensitive"),
            lambda d: d.pop("keychain-access-groups"),
            lambda d: d.__setitem__("keychain-access-groups", list(reversed(d["keychain-access-groups"]))),
            lambda d: d.__setitem__("keychain-access-groups", d["keychain-access-groups"][:1]),
            lambda d: d.__setitem__("com.apple.security.application-groups", []),
            lambda d: d.__setitem__("com.apple.developer.default-data-protection", "NSFileProtectionNone"),
        ]
        for mutate in mutations:
            result = run(self.tree(second=self.mutated(mutate)))
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("QAudionVPN.entitlements", result.stdout)
            result = run(self.tree(third=self.mutated(mutate)))
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("QAudionShareApp.entitlements", result.stdout)

    def test_missing_file_fails(self):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        self.assertEqual(run(d.name).returncode, 1)

    def test_real_files_pass(self):
        result = run(REPO)
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
