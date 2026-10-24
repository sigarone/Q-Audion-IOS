#!/usr/bin/env python3
"""Tests for scripts/ci/check_siri_intent_phrases.py (stdlib only, offline).

Run:  python3 -I scripts/ci/test_check_siri_intent_phrases.py

Two layers: the checks on a small tree built in a temporary directory with one thing changed at a time (each change
must be reported, and the unchanged tree must be clean), and the real repository, which must be clean - that last
test is what fails when somebody adds an intent to QAudionIntents/Info.plist without adding its example phrases to
every QAudionApp/<lang>.lproj/AppIntentVocabulary.plist.
"""
import importlib.util
import io
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

_spec = importlib.util.spec_from_file_location("check_siri_intent_phrases", os.path.join(HERE, "check_siri_intent_phrases.py"))
gate = importlib.util.module_from_spec(_spec)
sys.modules["check_siri_intent_phrases"] = gate
_spec.loader.exec_module(gate)

INTENTS = ["INStartCallIntent", "INSendMessageIntent", "INSetMessageAttributeIntent"]
LANGS = ["it", "en", "pt-BR"]
REGION = "it"


def intents_info(intents):
    return {"NSExtension": {"NSExtensionAttributes": {"IntentsSupported": list(intents)}}}


def vocabulary(intents):
    return {"IntentPhrases": [
        {"IntentName": name, "IntentExamples": ["%s one on Q-Audion" % name, "%s two with Q-Audion" % name]}
        for name in intents]}


class Tree:
    """A small tree in a temporary directory: the two Info.plist files and one vocabulary per language."""

    def __init__(self, intents=INTENTS, langs=LANGS, region=REGION, localizations=None):
        self.dir = tempfile.mkdtemp(prefix="siri-phrases-gate-")
        self.write_plist("QAudionIntents/Info.plist", intents_info(intents))
        app_info = {"CFBundleDevelopmentRegion": region}
        if localizations is not None:
            app_info["CFBundleLocalizations"] = localizations
        self.write_plist("QAudionApp/Info.plist", app_info)
        for lang in langs:
            self.write_plist("QAudionApp/%s.lproj/AppIntentVocabulary.plist" % lang, vocabulary(intents))

    def path(self, rel):
        return os.path.join(self.dir, rel)

    def write_plist(self, rel, data):
        dst = self.path(rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            plistlib.dump(data, f)

    def read_plist(self, rel):
        with open(self.path(rel), "rb") as f:
            return plistlib.load(f)

    def vocab(self, lang):
        return "QAudionApp/%s.lproj/AppIntentVocabulary.plist" % lang

    def edit_vocab(self, lang, edit):
        data = self.read_plist(self.vocab(lang))
        edit(data["IntentPhrases"])
        self.write_plist(self.vocab(lang), data)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class GateOnATempTree(unittest.TestCase):
    def setUp(self):
        self.tree = Tree()
        self.addCleanup(self.tree.cleanup)

    def problems(self):
        return gate.run(self.tree.dir)

    def assertReported(self, *needles):
        found = self.problems()
        self.assertTrue(any(all(n in p for n in needles) for p in found),
                        "expected a problem mentioning %r, got %r" % (needles, found))

    def test_the_tree_is_clean(self):
        self.assertEqual(self.problems(), [])

    def test_missing_intent_in_one_language(self):
        self.tree.edit_vocab("en", lambda phrases: phrases.pop())
        found = self.problems()
        self.assertEqual(len(found), 1, found)
        self.assertReported("en.lproj", "INSetMessageAttributeIntent", "has no IntentPhrases entry")

    def test_missing_intent_in_every_language_is_reported_once_per_language(self):
        for lang in LANGS:
            self.tree.edit_vocab(lang, lambda phrases: phrases.pop())
        found = [p for p in self.problems() if "has no IntentPhrases entry" in p]
        self.assertEqual(len(found), len(LANGS), found)
        for lang in LANGS:
            self.assertTrue(any(("%s.lproj" % lang) in p and "INSetMessageAttributeIntent" in p for p in found), lang)

    def test_new_intent_in_the_extension_without_phrases(self):
        self.tree.write_plist("QAudionIntents/Info.plist", intents_info(INTENTS + ["INSearchForMessagesIntent"]))
        found = [p for p in self.problems() if "INSearchForMessagesIntent" in p and "has no IntentPhrases entry" in p]
        self.assertEqual(len(found), len(LANGS), found)

    def test_missing_vocabulary_of_the_development_region(self):
        shutil.rmtree(self.tree.path("QAudionApp/it.lproj"))
        self.assertReported("it.lproj", "development region")

    def test_missing_vocabulary_of_another_language_is_not_a_region_problem(self):
        shutil.rmtree(self.tree.path("QAudionApp/en.lproj"))
        self.assertEqual(self.problems(), [])

    def test_development_region_with_a_dash_matches_its_directory(self):
        tree = Tree(region="pt-BR")
        self.addCleanup(tree.cleanup)
        self.assertEqual(gate.run(tree.dir), [])
        shutil.rmtree(tree.path("QAudionApp/pt-BR.lproj"))
        self.assertTrue(any("development region" in p for p in gate.run(tree.dir)))

    def test_localizations_that_all_ship_a_vocabulary(self):
        tree = Tree(localizations=list(LANGS))
        self.addCleanup(tree.cleanup)
        self.assertEqual(gate.run(tree.dir), [])

    def test_localization_without_a_vocabulary(self):
        tree = Tree(localizations=LANGS + ["ru"])
        self.addCleanup(tree.cleanup)
        found = gate.run(tree.dir)
        self.assertEqual(len(found), 1, found)
        self.assertTrue("ru.lproj" in found[0] and "CFBundleLocalizations" in found[0], found)

    def test_localization_spelled_with_an_underscore_matches_its_directory(self):
        tree = Tree(localizations=["it", "en", "pt_BR"])
        self.addCleanup(tree.cleanup)
        self.assertEqual(gate.run(tree.dir), [])

    def test_missing_region_vocabulary_listed_in_localizations_is_reported_once(self):
        tree = Tree(localizations=list(LANGS))
        self.addCleanup(tree.cleanup)
        shutil.rmtree(tree.path("QAudionApp/it.lproj"))
        found = [p for p in gate.run(tree.dir) if "it.lproj" in p]
        self.assertEqual(len(found), 1, found)
        self.assertIn("development region", found[0])

    def test_localizations_that_are_not_a_list(self):
        self.tree.write_plist("QAudionApp/Info.plist", {"CFBundleDevelopmentRegion": REGION, "CFBundleLocalizations": "it"})
        self.assertReported("CFBundleLocalizations", "not a list")

    def test_root_with_glob_characters(self):
        parent = tempfile.mkdtemp(prefix="siri[gate]-")
        self.addCleanup(shutil.rmtree, parent, True)
        root = os.path.join(parent, "repo[1]")
        shutil.copytree(self.tree.dir, root)
        self.assertEqual(gate.run(root), [])
        shutil.rmtree(os.path.join(root, "QAudionApp", "en.lproj"))
        self.assertEqual(gate.run(root), [])
        self.assertEqual(sorted(gate.vocabularies(root)), ["it", "pt-BR"])

    def test_development_region_that_is_a_build_variable(self):
        self.tree.write_plist("QAudionApp/Info.plist", {"CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)"})
        self.assertReported("CFBundleDevelopmentRegion")

    def test_empty_examples_array(self):
        def edit(phrases):
            phrases[2]["IntentExamples"] = []
        self.tree.edit_vocab("pt-BR", edit)
        self.assertReported("pt-BR.lproj", "INSetMessageAttributeIntent", "no non-empty IntentExamples")

    def test_missing_examples_key(self):
        def edit(phrases):
            del phrases[0]["IntentExamples"]
        self.tree.edit_vocab("it", edit)
        self.assertReported("it.lproj", "INStartCallIntent", "no non-empty IntentExamples")

    def test_blank_example_strings(self):
        def edit(phrases):
            phrases[1]["IntentExamples"] = ["", "   "]
        self.tree.edit_vocab("en", edit)
        self.assertReported("en.lproj", "INSendMessageIntent", "no non-empty IntentExamples")

    def test_one_blank_example_next_to_a_good_one(self):
        def edit(phrases):
            phrases[1]["IntentExamples"].append("")
        self.tree.edit_vocab("en", edit)
        self.assertReported("en.lproj", "INSendMessageIntent", "empty or not a string")

    def test_example_that_is_not_a_string(self):
        def edit(phrases):
            phrases[1]["IntentExamples"] = [7]
        self.tree.edit_vocab("en", edit)
        self.assertReported("en.lproj", "INSendMessageIntent")

    def test_example_without_the_app_name(self):
        def edit(phrases):
            phrases[2]["IntentExamples"][1] = "Mark my messages as read"
        self.tree.edit_vocab("en", edit)
        self.assertReported("en.lproj", "INSetMessageAttributeIntent", "does not name the app")

    def test_app_name_in_the_wrong_case_is_not_the_app_name(self):
        def edit(phrases):
            phrases[0]["IntentExamples"][0] = "Call John on q-audion"
        self.tree.edit_vocab("it", edit)
        self.assertReported("it.lproj", "INStartCallIntent", "does not name the app")

    def test_stale_entry_for_an_intent_that_is_no_longer_supported(self):
        def edit(phrases):
            phrases.append({"IntentName": "INSearchForMessagesIntent", "IntentExamples": ["Search on Q-Audion"]})
        self.tree.edit_vocab("pt-BR", edit)
        self.assertReported("pt-BR.lproj", "INSearchForMessagesIntent", "stale entry")
        self.assertEqual(len(self.problems()), 1)

    def test_entry_without_an_intent_name(self):
        def edit(phrases):
            phrases.append({"IntentExamples": ["Something on Q-Audion"]})
        self.tree.edit_vocab("en", edit)
        self.assertReported("en.lproj", "has no IntentName")

    def test_vocabulary_without_intent_phrases(self):
        self.tree.write_plist(self.tree.vocab("en"), {})
        self.assertReported("en.lproj", "IntentPhrases is missing")

    def test_unparsable_vocabulary(self):
        with open(self.tree.path(self.tree.vocab("en")), "w", encoding="utf-8") as f:
            f.write("<plist><dict>")
        self.assertReported("en.lproj", "cannot be read")

    def test_extension_without_intents_supported(self):
        self.tree.write_plist("QAudionIntents/Info.plist", {"NSExtension": {"NSExtensionAttributes": {}}})
        self.assertReported("IntentsSupported")

    def test_extension_info_missing(self):
        os.remove(self.tree.path("QAudionIntents/Info.plist"))
        self.assertReported("QAudionIntents/Info.plist", "cannot be read")

    def test_no_vocabulary_at_all(self):
        for lang in LANGS:
            shutil.rmtree(self.tree.path("QAudionApp/%s.lproj" % lang))
        found = self.problems()
        self.assertTrue(any("development region" in p for p in found), found)
        self.assertTrue(any("no QAudionApp/*.lproj" in p for p in found), found)


class Command(unittest.TestCase):
    def run_main(self, root):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = gate.main(["--root", root])
        return code, out.getvalue(), err.getvalue()

    def test_exit_codes(self):
        tree = Tree()
        self.addCleanup(tree.cleanup)
        code, out, _ = self.run_main(tree.dir)
        self.assertEqual(code, 0)
        self.assertIn("ok", out)
        tree.edit_vocab("en", lambda phrases: phrases.pop())
        code, out, _ = self.run_main(tree.dir)
        self.assertEqual(code, 1)
        self.assertIn("FAIL", out)
        empty = tempfile.mkdtemp(prefix="siri-phrases-empty-")
        self.addCleanup(shutil.rmtree, empty, True)
        code, _, err = self.run_main(empty)
        self.assertEqual(code, 2)
        self.assertIn("cannot run", err)


class RealRepository(unittest.TestCase):
    def copy_real_files(self):
        tree_dir = tempfile.mkdtemp(prefix="siri-phrases-real-")
        self.addCleanup(shutil.rmtree, tree_dir, True)
        for rel in ("QAudionIntents/Info.plist", "QAudionApp/Info.plist"):
            os.makedirs(os.path.dirname(os.path.join(tree_dir, rel)), exist_ok=True)
            shutil.copyfile(os.path.join(ROOT, rel), os.path.join(tree_dir, rel))
        for lang, rel in gate.vocabularies(ROOT).items():
            os.makedirs(os.path.dirname(os.path.join(tree_dir, rel)), exist_ok=True)
            shutil.copyfile(os.path.join(ROOT, rel), os.path.join(tree_dir, rel))
        return tree_dir

    def test_the_repository_is_clean(self):
        self.assertEqual(gate.run(ROOT), [])

    def test_a_copy_of_the_repository_files_is_clean(self):
        self.assertEqual(gate.run(self.copy_real_files()), [])

    def test_dropping_the_phrases_of_one_intent_from_the_real_files_is_reported_in_every_language(self):
        tree_dir = self.copy_real_files()
        intent = "INSetMessageAttributeIntent"
        langs = gate.vocabularies(tree_dir)
        for rel in langs.values():
            path = os.path.join(tree_dir, rel)
            with open(path, "rb") as f:
                data = plistlib.load(f)
            data["IntentPhrases"] = [e for e in data["IntentPhrases"] if e["IntentName"] != intent]
            with open(path, "wb") as f:
                plistlib.dump(data, f)
        found = [p for p in gate.run(tree_dir) if intent in p and "has no IntentPhrases entry" in p]
        self.assertEqual(len(found), len(langs), found)


if __name__ == "__main__":
    unittest.main()
