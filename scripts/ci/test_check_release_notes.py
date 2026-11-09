import copy
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("check_release_notes", os.path.join(HERE, "check_release_notes.py"))
c = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(c)

GOOD = {"version": "1.0.1", "notes": {l: ["A pleasant improvement"] for l in c.LANGUAGES}}


def with_line(text, lang="en"):
    e = copy.deepcopy(GOOD)
    e["notes"][lang] = [text]
    return [e]


class ReleaseNotesGate(unittest.TestCase):
    def test_good_entry_passes(self):
        self.assertEqual(c.violations([GOOD]), [])

    def test_real_file_passes(self):
        import json
        self.assertEqual(c.violations(json.loads(c.NOTES.read_text(encoding="utf-8"))), [])

    def test_negative_or_sensitive_wording_fails(self):
        for text in ("Fixed a crash", "A bug is gone", "Closes a vulnerability", "No more nonce reuse",
                     "Protects against MITM", "Un attacco in meno", "Chiusa una falla"):
            self.assertTrue(c.violations(with_line(text)), text)

    def test_brand_name_fails(self):
        self.assertTrue(c.violations(with_line("Better than whatsapp")))

    def test_missing_language_fails(self):
        e = copy.deepcopy(GOOD)
        del e["notes"]["de"]
        self.assertTrue(c.violations([e]))

    def test_bad_version_and_duplicates_fail(self):
        e = copy.deepcopy(GOOD)
        e["version"] = "v1"
        self.assertTrue(c.violations([e]))
        self.assertTrue(c.violations([GOOD, GOOD]))

    def test_long_line_fails(self):
        self.assertTrue(c.violations(with_line("x" * 200)))


if __name__ == "__main__":
    unittest.main()
