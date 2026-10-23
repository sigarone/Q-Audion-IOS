#!/usr/bin/env python3
"""Tests for scripts/ci/check_carplay_gating.py (stdlib only, offline).

Run:  python3 -I scripts/ci/test_check_carplay_gating.py

Two layers: the checks on a small copy of the real files with one thing changed at a time (each change must be
reported, and the unchanged copy must be clean), and the real repository, which must be clean - that last test is
what fails when somebody adds a CarPlay reference outside `#if QAUDION_CARPLAY`, puts the entitlement into an
entitlements file, switches the flag on in the default spec, or writes car-screen text that points at the phone.
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

_spec = importlib.util.spec_from_file_location("check_carplay_gating", os.path.join(HERE, "check_carplay_gating.py"))
gate = importlib.util.module_from_spec(_spec)
sys.modules["check_carplay_gating"] = gate
_spec.loader.exec_module(gate)

FILES = [
    "QAudionApp/project.yml",
    "QAudionApp/project-carplay.yml",
    "QAudionApp/project-apptests.yml",
    "QAudionApp/project-earbud.yml",
    "QAudionApp/project-vpn.yml",
    "QAudionApp/project-vpn-earbud.yml",
    "QAudionApp/Info.plist",
    "QAudionApp/QAudion.entitlements",
    "QAudionApp/Localizable.xcstrings",
    "QAudionApp/CarPlay/CarPlayScene.swift",
    "QAudionApp/CarPlay/CarPlayListModel.swift",
    "QAudionApp/CarPlay/CarPlayBridge.swift",
    "QAudionIntents/Info.plist",
    "QAudionIntents/IntentHandler.swift",
    "QAudionIntents/QAudionIntents.entitlements",
    ".github/workflows/ios-testflight.yml",
]


class Tree:
    """A copy of the files the gate reads, in a temporary directory."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="carplay-gate-")
        for rel in FILES:
            dst = os.path.join(self.dir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(ROOT, rel), dst)

    def path(self, rel):
        return os.path.join(self.dir, rel)

    def read(self, rel):
        with open(self.path(rel), encoding="utf-8") as f:
            return f.read()

    def write(self, rel, text):
        with open(self.path(rel), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)

    def replace(self, rel, old, new, count=1):
        text = self.read(rel)
        self.assertion = old in text
        assert old in text, "fixture text not found in %s: %r" % (rel, old)
        self.write(rel, text.replace(old, new, count))

    def append(self, rel, text):
        self.write(rel, self.read(rel) + text)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class GateOnACopy(unittest.TestCase):
    def setUp(self):
        self.tree = Tree()
        self.addCleanup(self.tree.cleanup)

    def problems(self):
        return gate.run(self.tree.dir)

    def assertReported(self, needle):
        found = self.problems()
        self.assertTrue(any(needle in p for p in found), "expected a problem mentioning %r, got %r" % (needle, found))

    def test_the_copy_is_clean(self):
        self.assertEqual(self.problems(), [])

    def test_flag_in_the_default_spec(self):
        self.tree.replace("QAudionApp/project.yml",
                          "SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited)",
                          "SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) QAUDION_CARPLAY")
        self.assertReported("default build must not compile the CarPlay scene")

    def test_flag_named_only_in_a_comment_of_the_default_spec_is_fine(self):
        self.tree.append("QAudionApp/project.yml", "\n# QAUDION_CARPLAY is set by project-carplay.yml\n")
        self.assertEqual(self.problems(), [])

    def test_flag_in_another_spec(self):
        for spec in ("project-vpn.yml", "project-earbud.yml", "project-vpn-earbud.yml", "project-apptests.yml"):
            tree = Tree()
            self.addCleanup(tree.cleanup)
            tree.append("QAudionApp/" + spec, "\n        OTHER_SWIFT_FLAGS: $(inherited) -DQAUDION_CARPLAY\n")
            found = gate.run(tree.dir)
            self.assertTrue(any(("%s sets QAUDION_CARPLAY" % spec) in p for p in found), (spec, found))

    def test_flag_named_only_in_a_comment_of_another_spec_is_fine(self):
        self.tree.append("QAudionApp/project-vpn.yml", "\n# QAUDION_CARPLAY is set by project-carplay.yml\n")
        self.assertEqual(self.problems(), [])

    def test_entitlement_in_another_spec(self):
        self.tree.append("QAudionApp/project-earbud.yml",
                         "\n        X: com.apple.developer.carplay-communication\n")
        self.assertReported("project-earbud.yml adds the CarPlay entitlement")

    def test_framework_linked_by_the_default_spec(self):
        self.tree.replace("QAudionApp/project.yml", "      - sdk: Intents.framework\n",
                          "      - sdk: Intents.framework\n      - sdk: CarPlay.framework\n        weak: true\n")
        self.assertReported("project.yml links CarPlay.framework")

    def test_framework_linked_by_another_spec_through_a_flag(self):
        self.tree.append("QAudionApp/project-vpn.yml", "\n        OTHER_LDFLAGS: $(inherited) -weak_framework CarPlay\n")
        self.assertReported("project-vpn.yml links CarPlay.framework")

    def test_variant_without_the_weak_link(self):
        self.tree.replace("QAudionApp/project-carplay.yml", "$(inherited) -lc++ -weak_framework CarPlay", "$(inherited) -lc++")
        self.assertReported("does not link CarPlay.framework weakly")

    def test_variant_that_links_the_framework_strongly(self):
        self.tree.replace("QAudionApp/project-carplay.yml", "$(inherited) -lc++ -weak_framework CarPlay",
                          "$(inherited) -lc++ -framework CarPlay")
        self.assertReported("does not link CarPlay.framework weakly")

    def test_variant_that_drops_a_linker_flag_of_the_default_spec(self):
        self.tree.replace("QAudionApp/project-carplay.yml", "$(inherited) -lc++ -weak_framework CarPlay",
                          "$(inherited) -weak_framework CarPlay")
        self.assertReported("drops the linker flag -lc++")

    def test_variant_without_the_flag(self):
        self.tree.replace("QAudionApp/project-carplay.yml", "-DQAUDION_CARPLAY", "-DSOMETHING_ELSE")
        self.assertReported("does not set -DQAUDION_CARPLAY")

    def test_variant_that_does_not_include_the_default_spec(self):
        self.tree.replace("QAudionApp/project-carplay.yml", "include:\n  - project.yml", "include:\n  - other.yml")
        self.assertReported("does not include project.yml")

    def test_entitlement_in_the_app_entitlements(self):
        self.tree.replace("QAudionApp/QAudion.entitlements", "</dict>",
                          "<key>com.apple.developer.carplay-communication</key><true/></dict>")
        self.assertReported("carries a CarPlay entitlement")

    def test_entitlement_in_the_extension_entitlements(self):
        self.tree.replace("QAudionIntents/QAudionIntents.entitlements", "</dict>",
                          "<key>com.apple.developer.carplay-communication</key><true/></dict>")
        self.assertReported("QAudionIntents.entitlements carries a CarPlay entitlement")

    def test_scene_role_in_the_source_plist(self):
        self.tree.replace("QAudionApp/Info.plist", "<key>UIApplicationSupportsMultipleScenes</key>",
                          "<key>CPTemplateApplicationSceneSessionRoleApplication</key><array/>"
                          "<key>UIApplicationSupportsMultipleScenes</key>")
        self.assertReported("has a CarPlay scene role")

    def test_testflight_workflow_that_builds_the_variant(self):
        self.tree.append(".github/workflows/ios-testflight.yml", "\n      - run: xcodegen generate --spec project-carplay.yml\n")
        self.assertReported("no release build may enable CarPlay")

    def test_testflight_workflow_that_names_the_bare_flag(self):
        self.tree.append(".github/workflows/ios-testflight.yml", "\n      - run: echo QAUDION_CARPLAY\n")
        self.assertReported("no release build may enable CarPlay")

    def test_testflight_workflow_that_only_talks_about_it_in_a_comment_is_fine(self):
        self.tree.append(".github/workflows/ios-testflight.yml", "\n      # project-carplay.yml is not used here\n")
        self.assertEqual(self.problems(), [])

    def test_import_outside_the_flag(self):
        self.tree.write("QAudionApp/Other.swift", "import CarPlay\n")
        self.assertReported("QAudionApp/Other.swift:1 uses CarPlay outside")

    def test_type_outside_the_flag(self):
        self.tree.write("QAudionApp/Other.swift", "func f(_ t: CPListTemplate) {}\n")
        self.assertReported("uses CarPlay outside")

    def test_import_in_the_intents_extension_outside_the_flag(self):
        self.tree.write("QAudionIntents/Other.swift", "import CarPlay\n")
        self.assertReported("QAudionIntents/Other.swift:1 uses CarPlay outside")

    def test_type_in_the_intents_extension_outside_the_flag(self):
        self.tree.append("QAudionIntents/IntentHandler.swift", "\nfunc f(_ t: CPListTemplate) {}\n")
        self.assertReported("QAudionIntents/IntentHandler.swift")

    def test_import_inside_the_flag_is_fine(self):
        self.tree.write("QAudionApp/Other.swift", textwrap.dedent("""\
            #if QAUDION_CARPLAY
            import CarPlay
            func f(_ t: CPListTemplate) {}
            #endif
            """))
        self.assertEqual(self.problems(), [])

    def test_type_in_the_else_branch_is_outside(self):
        self.tree.write("QAudionApp/Other.swift", textwrap.dedent("""\
            #if QAUDION_CARPLAY
            let a = 1
            #else
            func f(_ t: CPListTemplate) {}
            #endif
            """))
        self.assertReported("uses CarPlay outside")

    def test_flag_combined_with_another_condition_counts(self):
        self.tree.write("QAudionApp/Other.swift", textwrap.dedent("""\
            #if QAUDION_CARPLAY && canImport(CarPlay)
            import CarPlay
            #endif
            """))
        self.assertEqual(self.problems(), [])

    def test_a_comment_naming_a_type_is_not_a_reference(self):
        self.tree.write("QAudionApp/Other.swift", "// the CPListTemplate is drawn elsewhere\n/* CPTabBarTemplate */\nlet a = 1\n")
        self.assertEqual(self.problems(), [])

    def test_catalog_text_that_points_at_the_phone(self):
        path = "QAudionApp/Localizable.xcstrings"
        data = json.loads(self.tree.read(path))
        data["strings"]["carplay.contacts.empty.subtitle"]["localizations"]["en"]["stringUnit"]["value"] = \
            "Add contacts from the app on your phone"
        self.tree.write(path, json.dumps(data, indent=2, ensure_ascii=False))
        self.assertReported("carplay.contacts.empty.subtitle [en] points at the phone")

    def test_catalog_text_in_every_language_is_checked(self):
        path = "QAudionApp/Localizable.xcstrings"
        data = json.loads(self.tree.read(path))
        loc = data["strings"]["carplay.notice.not_ready"]["localizations"]
        for lang, word in (("it", "telefono"), ("es", "teléfono"), ("fr", "téléphone"), ("de", "Telefon"), ("pt-BR", "celular")):
            loc[lang]["stringUnit"]["value"] = "Usa il %s" % word
        self.tree.write(path, json.dumps(data, indent=2, ensure_ascii=False))
        found = self.problems()
        for lang in ("it", "es", "fr", "de", "pt-BR"):
            self.assertTrue(any("carplay.notice.not_ready [%s]" % lang in p for p in found), lang)

    def test_other_catalog_keys_may_mention_the_phone(self):
        path = "QAudionApp/Localizable.xcstrings"
        data = json.loads(self.tree.read(path))
        data["strings"]["settings.somewhere"] = {"localizations": {"en": {"stringUnit": {"value": "Use your phone"}}}}
        self.tree.write(path, json.dumps(data, indent=2, ensure_ascii=False))
        self.assertEqual(self.problems(), [])

    def test_default_text_in_the_scene_that_points_at_the_phone(self):
        self.tree.replace("QAudionApp/CarPlay/CarPlayScene.swift",
                          'defaultValue: "I contatti Q-Audion compaiono qui"',
                          'defaultValue: "Aggiungi contatti dal telefono"')
        self.assertReported("default text points at the phone")


class RealRepository(unittest.TestCase):
    def test_the_repository_is_clean(self):
        self.assertEqual(gate.run(ROOT), [])


if __name__ == "__main__":
    unittest.main()
