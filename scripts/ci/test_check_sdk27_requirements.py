#!/usr/bin/env python3
"""Tests of check_sdk27_requirements.py on throwaway trees."""

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check_sdk27_requirements.py")


def run(root):
    return subprocess.run([sys.executable, "-I", SCRIPT, root], capture_output=True, text=True)


def write_plist(root, rel, data):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        plistlib.dump(data, f)


GOOD = {"UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False}, "UILaunchScreen": {}}


class Check(unittest.TestCase):
    def tree(self, app=GOOD, ext=None, swift=None):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        write_plist(d.name, "QAudionApp/Info.plist", app)
        if ext is not None:
            write_plist(d.name, "QAudionIntents/Info.plist", ext)
        if swift is not None:
            os.makedirs(os.path.join(d.name, "QAudionApp"), exist_ok=True)
            with open(os.path.join(d.name, "QAudionApp/A.swift"), "w") as f:
                f.write(swift)
        return d.name

    def test_ok(self):
        r = run(self.tree(ext={"NSExtension": {}}, swift="let x = 1\n"))
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_missing_scene_manifest(self):
        r = run(self.tree(app={"UILaunchScreen": {}}))
        self.assertEqual(r.returncode, 1)
        self.assertIn("UIApplicationSceneManifest", r.stdout)

    def test_missing_launch_screen(self):
        r = run(self.tree(app={"UIApplicationSceneManifest": {}}))
        self.assertEqual(r.returncode, 1)
        self.assertIn("launch screen", r.stdout)

    def test_opt_out_keys(self):
        for key in ("UIDesignRequiresCompatibility", "UIRequiresFullScreen"):
            r = run(self.tree(app=dict(GOOD, **{key: True})))
            self.assertEqual(r.returncode, 1, key)
            self.assertIn(key, r.stdout)
        r = run(self.tree(ext={"UIRequiresFullScreen": True}))
        self.assertEqual(r.returncode, 1)

    def test_window_list(self):
        r = run(self.tree(swift="let w = UIApplication.shared.windows.first\n"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("A.swift:1", r.stdout)
        r = run(self.tree(swift="// UIApplication.shared.keyWindow is gone\nlet x = 1\n"))
        self.assertEqual(r.returncode, 0, r.stdout)


if __name__ == "__main__":
    unittest.main()
