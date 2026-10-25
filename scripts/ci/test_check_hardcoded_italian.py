#!/usr/bin/env python3
"""Tests for scripts/ci/check_hardcoded_italian.py (stdlib only, offline).

Run:  python3 -I scripts/ci/test_check_hardcoded_italian.py

Two layers: the checks on a small tree built in a temporary directory with one thing changed at a time (each
change must be reported, and the unchanged tree must be clean), and the real repository, which must be clean -
that last test is what fails when somebody writes Italian user-facing text straight into Swift.
"""
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

_spec = importlib.util.spec_from_file_location("check_hardcoded_italian", os.path.join(HERE, "check_hardcoded_italian.py"))
gate = importlib.util.module_from_spec(_spec)
sys.modules["check_hardcoded_italian"] = gate
_spec.loader.exec_module(gate)


def entry(it, en, key_is_text=True):
    def unit(v):
        return {"stringUnit": {"state": "translated", "value": v}}
    return {"localizations": {"it": unit(it), "en": unit(en), "fr": unit(en), "de": unit(en), "es": unit(en), "pt-BR": unit(en)}}


CATALOG = {
    "Riprova": entry("Riprova", "Retry"),
    "Impossibile avviare la chiamata": entry("Impossibile avviare la chiamata", "Couldn't start the call"),
    "Chiamata persa da %@": entry("Chiamata persa da %@", "Missed call from %@"),
    "call.error.camera": entry("Fotocamera non disponibile su questo dispositivo.", "Camera not available on this device."),
}


class Tree:
    """A tiny repository: the catalog, one Swift file per call to swift(), an optional allowlist."""

    def __init__(self, catalog=None):
        self.dir = tempfile.mkdtemp(prefix="hardcoded-italian-gate-")
        self.write("QAudionApp/Localizable.xcstrings", json.dumps({"sourceLanguage": "it", "strings": catalog or CATALOG}))

    def write(self, rel, text):
        path = os.path.join(self.dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def swift(self, text, rel="QAudionApp/Views/Sample.swift"):
        self.write(rel, text)
        return self

    def allow(self, *lines):
        self.write(gate.ALLOWLIST, "\n".join(lines) + "\n")
        return self

    def run(self):
        err = io.StringIO()
        with redirect_stderr(err), redirect_stdout(io.StringIO()):
            code = gate.main(["--root", self.dir])
        return code, err.getvalue()

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class GateOnSmallTrees(unittest.TestCase):
    def check(self, source, expect_ok, needle=None, allow=(), rel="QAudionApp/Views/Sample.swift", catalog=None):
        tree = Tree(catalog)
        try:
            tree.swift(source, rel)
            if allow:
                tree.allow(*allow)
            code, err = tree.run()
        finally:
            tree.close()
        if expect_ok:
            self.assertEqual(code, 0, err)
        else:
            self.assertEqual(code, 1, err)
            if needle:
                self.assertIn(needle, err)

    # ---- clean code -------------------------------------------------------------------------------------------
    def test_localized_code_is_clean(self):
        self.check('''
import SwiftUI
struct V: View {
    var body: some View {
        Text("Riprova")
        Button("Riprova") {}
        Text(String(localized: "call.error.camera", defaultValue: "Fotocamera non disponibile su questo dispositivo."))
    }
}
''', True)

    def test_english_and_identifiers_are_not_italian(self):
        self.check('let a = "Could not start the call"\nlet b = "call.error.camera"\nlet c = "a1b2-uuid"\n', True)

    def test_interpolation_matches_catalog_placeholder(self):
        self.check('struct V: View { var body: some View { Text("Chiamata persa da \\(name)") } }\n', True)

    def test_comments_are_ignored(self):
        self.check('// Impossibile avviare la chiamata\n/* Impossibile avviare la chiamata */\n/// non è disponibile\nlet x = 1\n', True)

    def test_log_calls_are_ignored(self):
        self.check('print("Impossibile avviare la chiamata")\nRTLog.error("dial", "serverUrl non è un URL valido")\n', True)

    def test_debug_and_preview_blocks_are_ignored(self):
        self.check('''
#if DEBUG
let a = "Impossibile avviare la chiamata, riprova più tardi"
#else
let b = String(localized: "call.error.camera", defaultValue: "Fotocamera non disponibile su questo dispositivo.")
#endif
#Preview {
    Text("Chiamata di prova non è disponibile")
}
''', True)

    def test_test_targets_are_not_scanned(self):
        self.check('let a = "Impossibile avviare la chiamata, riprova più tardi"\n', True, rel="QAudionAppTests/ThingTests.swift")

    def test_key_typed_parameter_accepts_a_literal(self):
        self.check('''
struct Row: View {
    let title: LocalizedStringKey
    var body: some View { Text(title) }
}
struct V: View { var body: some View { Row(title: "Riprova") } }
''', True)

    def test_string_parameter_rendered_through_a_key_accepts_a_literal(self):
        self.check('''
struct Row: View {
    let title: String
    var body: some View { Text(LocalizedStringKey(title)) }
}
struct V: View { var body: some View { Row(title: "Riprova") } }
''', True)

    def test_computed_property_typed_as_key(self):
        self.check('''
enum Tab {
    case a
    var label: LocalizedStringKey {
        switch self {
        case .a: return "Riprova"
        }
    }
}
''', True)

    def test_ternary_in_a_localizing_call(self):
        self.check('struct V: View { var body: some View { Text(on ? "Riprova" : "Impossibile avviare la chiamata") } }\n', True)

    # ---- violations -------------------------------------------------------------------------------------------
    def test_assigned_error_message_is_reported(self):
        self.check('final class M { var errorMessage: String?\n func f() { errorMessage = "Impossibile avviare la chiamata, riprova più tardi." } }\n',
                   False, "outside a localization API")

    def test_returned_enum_text_is_reported(self):
        self.check('enum E { var text: String { switch self { default: return "Fotocamera non disponibile" } } }\n', False, "outside a localization API")

    def test_single_word_catalog_text_is_reported(self):
        self.check('let label = "Riprova"\n', False, "outside a localization API")

    def test_verbatim_is_reported(self):
        self.check('struct V: View { var body: some View { Text(verbatim: "Impossibile avviare la chiamata") } }\n', False, "verbatim")

    def test_string_argument_of_a_custom_view_is_reported(self):
        self.check('struct Row: View { let title: String\n var body: some View { Text(title) } }\nlet r = Row(title: "Impossibile avviare la chiamata")\n',
                   False, "outside a localization API")

    def test_swiftui_literal_without_catalog_entry_is_reported(self):
        self.check('struct V: View { var body: some View { Text("Nessun contatto trovato per questa ricerca") } }\n', False, "no catalog entry")

    def test_string_localized_with_unknown_key_is_reported(self):
        self.check('let x = String(localized: "call.error.unknown", defaultValue: "Impossibile avviare la chiamata")\n', False, "not in the catalog")

    def test_default_value_must_match_the_catalog(self):
        self.check('let x = String(localized: "call.error.camera", defaultValue: "Fotocamera spenta su questo dispositivo.")\n', False, "defaultValue differs")

    def test_catalog_entry_missing_a_language_is_reported(self):
        catalog = dict(CATALOG)
        broken = json.loads(json.dumps(CATALOG["Riprova"]))
        del broken["localizations"]["de"]
        catalog["Riprova"] = broken
        self.check('struct V: View { var body: some View { Text("Riprova") } }\n', False, "lacks de", catalog=catalog)

    def test_multi_line_literal_call(self):
        self.check('''
func f() {
    show(
        message:
            "Impossibile avviare la chiamata, riprova più tardi."
    )
}
''', False, "outside a localization API")

    def test_line_number_is_reported(self):
        self.check('\n\nlet x = "Impossibile avviare la chiamata, riprova più tardi."\n', False, "Sample.swift:3")

    # ---- allowlist --------------------------------------------------------------------------------------------
    def test_allowlist_suppresses_a_literal(self):
        self.check('let x = "Impossibile avviare la chiamata, riprova più tardi."\n', True,
                   allow=["QAudionApp/Views/Sample.swift | Impossibile avviare la chiamata, riprova più tardi. | developer screen"])

    def test_allowlist_is_per_file(self):
        self.check('let x = "Impossibile avviare la chiamata, riprova più tardi."\n', False, "outside a localization API",
                   allow=["QAudionApp/Views/Other.swift | Impossibile avviare la chiamata, riprova più tardi. | developer screen"])

    def test_stale_allowlist_entry_is_reported(self):
        self.check('let x = 1\n', False, "matches nothing",
                   allow=["QAudionApp/Views/Sample.swift | Impossibile avviare la chiamata | developer screen"])

    def test_pending_allowlist_entry_may_go_stale(self):
        self.check('let x = 1\n', True,
                   allow=["QAudionApp/Views/Sample.swift | Impossibile avviare la chiamata | pending: waiting for another pull request"])

    def test_malformed_allowlist_line_is_reported(self):
        self.check('let x = 1\n', False, "expected `path | literal | reason`", allow=["just one field"])

    # ---- usage ------------------------------------------------------------------------------------------------
    def test_missing_catalog_cannot_run(self):
        tree = Tree()
        try:
            os.remove(os.path.join(tree.dir, "QAudionApp/Localizable.xcstrings"))
            code, _ = tree.run()
        finally:
            tree.close()
        self.assertEqual(code, 2)


class GateOnTheRealRepository(unittest.TestCase):
    def test_repository_is_clean(self):
        err = io.StringIO()
        with redirect_stderr(err), redirect_stdout(io.StringIO()):
            code = gate.main(["--root", ROOT])
        self.assertEqual(code, 0, err.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=1)
