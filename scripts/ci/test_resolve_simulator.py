#!/usr/bin/env python3
"""Tests of scripts/ci/resolve_simulator.py on simulator lists shaped like the runner images."""

import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("resolve_simulator", os.path.join(HERE, "resolve_simulator.py"))
rs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rs)


def dev(name, udid, available=True):
    return {"name": name, "udid": udid, "isAvailable": available, "state": "Shutdown"}


XCODE27_IMAGE = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            dev("iPhone 17", "A0000000-0000-0000-0000-000000000017"),
            dev("iPhone Air", "A0000000-0000-0000-0000-0000000000A1"),
            dev("iPad (A16)", "A0000000-0000-0000-0000-000000000016"),
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
            dev("iPhone Duo", "B0000000-0000-0000-0000-0000000000D0"),
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
            dev("iPhone 17", "C0000000-0000-0000-0000-00000000FFFF"),
        ],
    }
}

TWO_RUNTIMES = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-6": [dev("iPhone 17", "D0000000-0000-0000-0000-000000002606")],
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [dev("iPhone 17", "D0000000-0000-0000-0000-000000002700")],
        "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [dev("iPhone 17", "D0000000-0000-0000-0000-000000002701", False)],
    }
}


class ResolveSimulatorTests(unittest.TestCase):
    def test_device_that_only_the_older_runtime_has(self):
        # "OS=latest" would pick iOS 27.1, which has no iPhone 17.
        udid, runtime, _ = rs.resolve(XCODE27_IMAGE, "iPhone 17", 27)
        self.assertEqual(udid, "A0000000-0000-0000-0000-000000000017")
        self.assertTrue(runtime.endswith("iOS-27-0"))

    def test_device_on_the_newest_runtime(self):
        udid, runtime, _ = rs.resolve(XCODE27_IMAGE, "iPhone Duo", 27)
        self.assertEqual(udid, "B0000000-0000-0000-0000-0000000000D0")
        self.assertTrue(runtime.endswith("iOS-27-1"))

    def test_other_platforms_are_ignored(self):
        self.assertIsNone(rs.resolve({"devices": {"com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [dev("iPhone 17", "X")]}}, "iPhone 17", 26))

    def test_minimum_major(self):
        self.assertIsNone(rs.resolve(XCODE27_IMAGE, "iPhone 17", 28))
        self.assertIsNotNone(rs.resolve(TWO_RUNTIMES, "iPhone 17", 26))
        udid, _, _ = rs.resolve(TWO_RUNTIMES, "iPhone 17", 27)
        self.assertTrue(udid.endswith("2700"))

    def test_highest_available_runtime_wins(self):
        # iOS 27.1 lists the device but it is not available: iOS 27.0 is used.
        udid, _, _ = rs.resolve(TWO_RUNTIMES, "iPhone 17", 26)
        self.assertTrue(udid.endswith("2700"))

    def test_exact_name_only(self):
        self.assertIsNone(rs.resolve(XCODE27_IMAGE, "iPhone", 27))
        self.assertIsNone(rs.resolve(XCODE27_IMAGE, "iPhone 1", 27))

    def test_listing_names_the_runtimes(self):
        text = rs.listing(XCODE27_IMAGE)
        self.assertIn("iOS-27-0: iPad (A16), iPhone 17, iPhone Air", text)
        self.assertIn("iOS-27-1: iPhone Duo", text)
        self.assertNotIn("tvOS", text)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
