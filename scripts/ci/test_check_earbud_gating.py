#!/usr/bin/env python3
"""Tests for scripts/ci/check_earbud_gating.py (stdlib only, offline).

Run:  python3 -I scripts/ci/test_check_earbud_gating.py

Two layers: the scanner on small synthetic Swift snippets (each rule of the three-valued
`#if` evaluation, comments, strings), and the real repository, which must be clean - that
last test is what fails when somebody adds a reference to the earbud stack outside
`#if QAUDION_EARBUD`.
"""
import importlib.util
import os
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

_spec = importlib.util.spec_from_file_location("check_earbud_gating", os.path.join(HERE, "check_earbud_gating.py"))
gate = importlib.util.module_from_spec(_spec)
sys.modules["check_earbud_gating"] = gate
_spec.loader.exec_module(gate)


def hits(src):
    h, e = gate.scan_text(textwrap.dedent(src))
    return [(line, what) for (line, what, _text) in h], e


class ConditionTests(unittest.TestCase):
    def ev(self, expr):
        return gate.eval_condition(expr)

    def test_flag_is_false_everything_else_unknown(self):
        self.assertEqual(self.ev("QAUDION_EARBUD"), "F")
        self.assertEqual(self.ev("QAUDION_DEV_TOOLS"), "U")
        self.assertEqual(self.ev("DEBUG"), "U")
        self.assertEqual(self.ev("canImport(UIKit)"), "U")
        self.assertEqual(self.ev("os(iOS)"), "U")
        self.assertEqual(self.ev("swift(>=5.9)"), "U")

    def test_boolean_combinations(self):
        self.assertEqual(self.ev("QAUDION_DEV_TOOLS && QAUDION_EARBUD"), "F")
        self.assertEqual(self.ev("QAUDION_EARBUD && QAUDION_DEV_TOOLS"), "F")
        self.assertEqual(self.ev("QAUDION_EARBUD || QAUDION_DEV_TOOLS"), "U")
        self.assertEqual(self.ev("!QAUDION_EARBUD"), "T")
        self.assertEqual(self.ev("!(QAUDION_EARBUD || QAUDION_VPN)"), "U")
        self.assertEqual(self.ev("(QAUDION_EARBUD)"), "F")
        self.assertEqual(self.ev("true"), "T")
        self.assertEqual(self.ev("false || QAUDION_EARBUD"), "F")
        self.assertEqual(self.ev("QAUDION_EARBUD && canImport(CoreBluetooth)"), "F")

    def test_unreadable_expression_is_possibly_active(self):
        self.assertEqual(self.ev(""), "U")


class ScanTests(unittest.TestCase):
    def test_gated_code_is_clean(self):
        h, e = hits("""\
            #if QAUDION_EARBUD
            final class IOSEarbudGattProxy {}
            #endif
            """)
        self.assertEqual((h, e), ([], []))

    def test_ungated_symbol_is_a_hit(self):
        h, e = hits("""\
            let x = 1
            let p = IOSEarbudGattProxy()
            """)
        self.assertEqual(h, [(2, "IOSEarbudGattProxy")])
        self.assertEqual(e, [])

    def test_dev_tools_alone_does_not_gate(self):
        h, _ = hits("""\
            #if QAUDION_DEV_TOOLS
            let p = IOSEarbudGattProxy()
            #endif
            """)
        self.assertEqual(h, [(2, "IOSEarbudGattProxy")])

    def test_dev_tools_and_earbud_gates(self):
        h, _ = hits("""\
            #if QAUDION_DEV_TOOLS && QAUDION_EARBUD
            struct EarbudDiagScreen {}
            #endif
            """)
        self.assertEqual(h, [])

    def test_or_does_not_gate(self):
        h, _ = hits("""\
            #if QAUDION_EARBUD || DEBUG
            let p = IOSEarbudGattProxy()
            #endif
            """)
        self.assertEqual(h, [(2, "IOSEarbudGattProxy")])

    def test_else_branch_of_the_flag(self):
        h, _ = hits("""\
            #if QAUDION_EARBUD
            let relay: EarbudAckPopRelay? = EarbudAckPopRelay(gatt: earbudGattProxy)
            #else
            let relay: EarbudAckPopRelay? = nil
            #endif
            """)
        self.assertEqual(h, [])

    def test_negated_flag_branch_is_live(self):
        h, _ = hits("""\
            #if !QAUDION_EARBUD
            let p = IOSEarbudGattProxy()
            #else
            let q = IOSEarbudGattProxy()
            #endif
            """)
        self.assertEqual(h, [(2, "IOSEarbudGattProxy")])

    def test_elseif_chain(self):
        h, _ = hits("""\
            #if QAUDION_EARBUD
            let a = IOSEarbudGattProxy()
            #elseif DEBUG
            let b = IOSEarbudGattProxy()
            #else
            let c = IOSEarbudGattProxy()
            #endif
            """)
        # the DEBUG branch can be live; the final #else is live only if DEBUG is false -> unknown -> live
        self.assertEqual(h, [(4, "IOSEarbudGattProxy"), (6, "IOSEarbudGattProxy")])

    def test_nested_regions(self):
        h, _ = hits("""\
            #if QAUDION_DEV_TOOLS
            let p3 = 1
            #if QAUDION_EARBUD
            NavigationLink { EarbudDiagScreen() }
            #endif
            let bad = Fe5ExchangeService()
            #endif
            """)
        self.assertEqual(h, [(6, "Fe5ExchangeService")])

    def test_comments_are_ignored(self):
        h, _ = hits("""\
            // IOSEarbudGattProxy is gone
            /// see IOSEarbudGattProxy
            /* IOSEarbudGattProxy
               still a comment CoreBluetoothSovereignRelay */
            let ok = 1 // Fe5ExchangeService
            /* a /* nested IOSEarbudGattProxy */ still comment */ let fine = 2
            """)
        self.assertEqual(h, [])

    def test_slashes_inside_a_string_do_not_start_a_comment(self):
        h, _ = hits("""\
            let url = "https://example.com/api/v1/diag/fe5/publish"
            """)
        self.assertEqual(h, [(1, "/api/v1/diag/fe5")])

    def test_string_literal_uuid_is_a_hit(self):
        h, _ = hits('let u = "f2c0aaaa-bcc0-4001-8000-0000000000c3"\n')
        self.assertEqual(h, [(1, "f2c0aaaa-bcc0-4001")])

    def test_userdefaults_key_is_a_hit(self):
        h, _ = hits('UserDefaults.standard.set(x, forKey: "qaudion_paired_earbud_uuid")\n')
        self.assertEqual(h, [(1, "qaudion_paired_earbud_uuid")])

    def test_engine_uuid_constant_is_a_hit_but_sizes_are_not(self):
        h, _ = hits("""\
            let a = EarbudGattConstants.SERVICE_UUID
            let b = EarbudGattConstants.KEYIMPORT_PKG_LEN
            let c = EarbudGattConstants.KEY_IMPORT_UUID
            """)
        self.assertEqual([line for line, _ in h], [1, 3])

    def test_substring_of_another_identifier_is_not_a_hit(self):
        h, _ = hits("let a = MyIOSEarbudGattProxyHelper()\n")
        self.assertEqual(h, [])

    def test_engine_relay_logic_is_allowed(self):
        h, _ = hits("""\
            let r = EarbudAckPopRelay(gatt: g)
            let p = EarbudPairingRelay(gatt: g)
            protocol P: EarbudPairingGattProxy {}
            """)
        self.assertEqual(h, [])

    def test_unbalanced_directives_are_errors(self):
        _, e = hits("#endif\n")
        self.assertTrue(e)
        _, e = hits("#if QAUDION_EARBUD\nlet a = 1\n")
        self.assertTrue(e)
        _, e = hits("#else\n")
        self.assertTrue(e)

    def test_multiline_string_is_scanned_as_code(self):
        h, _ = hits('let s = """\n  IOSEarbudGattProxy\n"""\n')
        self.assertEqual(h, [(2, "IOSEarbudGattProxy")])


class RepositoryTests(unittest.TestCase):
    def test_the_repository_is_clean(self):
        rc = gate.main(["--root", ROOT])
        self.assertEqual(rc, 0, "a reference to the earbud stack outside #if QAUDION_EARBUD, or a spec/workflow check, failed (output above)")

    def test_the_gated_files_exist_and_are_wrapped(self):
        # Every file that declares part of the stack must contain the flag, otherwise the scan above
        # could pass only because the file is empty or was renamed.
        for rel in ["QAudionApp/Services/IOSEarbudGattProxy.swift",
                    "QAudionApp/Services/CoreBluetoothSovereignRelay.swift",
                    "QAudionApp/Services/EarbudKeyImportService.swift",
                    "QAudionApp/Services/Fe5ExchangeService.swift",
                    "QAudionApp/Views/Settings/EarbudDiagScreen.swift"]:
            with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
                text = f.read()
            self.assertIn("#if", text, rel)
            self.assertIn("QAUDION_EARBUD", text, rel)
            h, e = gate.scan_text(text, rel)
            self.assertEqual((h, e), ([], []), rel)

    def test_the_engine_package_no_longer_holds_the_gatt_client(self):
        self.assertFalse(os.path.exists(os.path.join(
            ROOT, "QAudionEngine/Sources/QAudionEngine/Integration/IOSEarbudGattProxy.swift")),
            "the CoreBluetooth earbud client must live in the app target, behind QAUDION_EARBUD")


class MutationTests(unittest.TestCase):
    """The scanner must actually fail on the repository when a gate is removed."""

    def test_removing_the_flag_from_a_file_is_caught(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "QAudionApp"))
            path = os.path.join(tmp, "QAudionApp", "X.swift")
            with open(os.path.join(ROOT, "QAudionApp/Services/Fe5ExchangeService.swift"), encoding="utf-8") as f:
                text = f.read().replace("QAUDION_EARBUD", "SOMETHING_ELSE")
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            rc = gate.main(["--root", tmp, "--no-specs"])
            self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
