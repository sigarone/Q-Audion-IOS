#!/usr/bin/env python3
"""Tests for scripts/ci/check_carplay_gating.py (stdlib only, offline).

Run:  python3 -I scripts/ci/test_check_carplay_gating.py

Two layers: the checks on a small copy of the real files with one thing changed at a time (each change must be
reported, and the unchanged copy must be clean), and the real repository, which must be clean - that last test is
what fails when somebody drops the framework link, the scene from Info.plist or the entitlement, brings back the
old compilation flag, uses a CarPlay type outside the scene file, or writes car-screen text that points at the phone.
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
    "QAudionApp/project-apptests.yml",
    "QAudionApp/project-earbud.yml",
    "QAudionApp/project-vpn.yml",
    "QAudionApp/project-vpn-earbud.yml",
    "QAudionApp/Info.plist",
    "QAudionApp/QAudion.entitlements",
    "QAudionApp/QAudionVPN.entitlements",
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

    def test_default_spec_without_the_framework(self):
        self.tree.replace("QAudionApp/project.yml", "      - sdk: CarPlay.framework\n        weak: true\n", "")
        self.assertReported("project.yml does not link CarPlay.framework weakly")

    def test_default_spec_with_a_strong_link(self):
        self.tree.replace("QAudionApp/project.yml", "      - sdk: CarPlay.framework\n        weak: true\n",
                          "      - sdk: CarPlay.framework\n")
        self.assertReported("project.yml does not link CarPlay.framework weakly")

    def test_framework_named_only_in_a_comment_does_not_count(self):
        self.tree.replace("QAudionApp/project.yml", "      - sdk: CarPlay.framework\n        weak: true\n",
                          "      # - sdk: CarPlay.framework\n      #   weak: true\n")
        self.assertReported("project.yml does not link CarPlay.framework weakly")

    def test_a_variant_spec_is_refused(self):
        self.tree.write("QAudionApp/project-carplay.yml", "include:\n  - project.yml\n")
        self.assertReported("there is no variant")

    def test_old_flag_in_a_spec(self):
        for spec in ("project.yml", "project-vpn.yml", "project-earbud.yml", "project-vpn-earbud.yml", "project-apptests.yml"):
            tree = Tree()
            self.addCleanup(tree.cleanup)
            tree.append("QAudionApp/" + spec, "\n        OTHER_SWIFT_FLAGS: $(inherited) -DQAUDION_CARPLAY\n")
            found = gate.run(tree.dir)
            self.assertTrue(any(("%s mentions QAUDION_CARPLAY" % spec) in p for p in found), (spec, found))

    def test_old_flag_named_only_in_a_comment_of_a_spec_is_fine(self):
        self.tree.append("QAudionApp/project.yml", "\n# QAUDION_CARPLAY used to be set by project-carplay.yml\n")
        self.assertEqual(self.problems(), [])

    def test_old_flag_left_in_a_source(self):
        self.tree.write("QAudionApp/Other.swift", "#if QAUDION_CARPLAY\nlet a = 1\n#endif\n")
        self.assertReported("QAudionApp/Other.swift:1 refers to QAUDION_CARPLAY")

    def test_old_flag_named_only_in_a_swift_comment_is_fine(self):
        self.tree.write("QAudionApp/Other.swift", "// QAUDION_CARPLAY is gone\nlet a = 1\n")
        self.assertEqual(self.problems(), [])

    def test_app_entitlements_without_the_carplay_key(self):
        for rel in ("QAudionApp/QAudion.entitlements", "QAudionApp/QAudionVPN.entitlements"):
            tree = Tree()
            self.addCleanup(tree.cleanup)
            text = tree.read(rel)
            tree.write(rel, text.replace("com.apple.developer.carplay-communication", "com.apple.developer.other"))
            found = gate.run(tree.dir)
            self.assertTrue(any(rel + " does not carry" in p for p in found), (rel, found))

    def test_carplay_key_set_to_false(self):
        path = "QAudionApp/QAudion.entitlements"
        text = self.tree.read(path)
        marker = "<key>com.apple.developer.carplay-communication</key>"
        i = text.index(marker) + len(marker)
        j = text.index("<true/>", i)
        self.tree.write(path, text[:j] + "<false/>" + text[j + len("<true/>"):])
        self.assertReported("QAudion.entitlements does not carry")

    def test_entitlement_in_the_extension_entitlements(self):
        self.tree.replace("QAudionIntents/QAudionIntents.entitlements", "</dict>",
                          "<key>com.apple.developer.carplay-communication</key><true/></dict>")
        self.assertReported("QAudionIntents.entitlements carries a CarPlay entitlement")

    def test_no_scene_role_in_the_app_plist(self):
        self.tree.replace("QAudionApp/Info.plist", "<key>CPTemplateApplicationSceneSessionRoleApplication</key>",
                          "<key>SomethingElse</key>")
        self.assertReported("has no CPTemplateApplicationSceneSessionRoleApplication scene role")

    def test_multiple_scenes_off(self):
        text = self.tree.read("QAudionApp/Info.plist")
        marker = "<key>UIApplicationSupportsMultipleScenes</key>"
        i = text.index(marker) + len(marker)
        j = text.index("<true/>", i)
        self.tree.write("QAudionApp/Info.plist", text[:j] + "<false/>" + text[j + len("<true/>"):])
        self.assertReported("UIApplicationSupportsMultipleScenes is not true")

    def test_scene_delegate_of_another_class(self):
        self.tree.replace("QAudionApp/Info.plist", "$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate",
                          "$(PRODUCT_MODULE_NAME).SomethingElse")
        self.assertReported("the CarPlay scene delegate is")

    def test_scene_role_in_the_intents_plist(self):
        text = self.tree.read("QAudionIntents/Info.plist")
        i = text.rindex("</dict>")
        self.tree.write("QAudionIntents/Info.plist",
                        text[:i] + "<key>CPTemplateApplicationSceneSessionRoleApplication</key><array/>" + text[i:])
        self.assertReported("QAudionIntents/Info.plist has a CarPlay scene role")

    def test_scene_wrapped_in_a_conditional_block(self):
        self.tree.replace("QAudionApp/CarPlay/CarPlayScene.swift", "import CarPlay\n", "#if canImport(CarPlay)\nimport CarPlay\n")
        self.tree.append("QAudionApp/CarPlay/CarPlayScene.swift", "#endif\n")
        self.assertReported("has a conditional compilation block")

    def test_testflight_workflow_that_builds_a_variant(self):
        self.tree.append(".github/workflows/ios-testflight.yml", "\n      - run: xcodegen generate --spec project-carplay.yml\n")
        self.assertReported("CarPlay has no variant spec or flag any more")

    def test_testflight_workflow_that_only_talks_about_it_in_a_comment_is_fine(self):
        self.tree.append(".github/workflows/ios-testflight.yml", "\n      # project-carplay.yml is gone\n")
        self.assertEqual(self.problems(), [])

    def test_testflight_workflow_without_the_profile_check(self):
        text = self.tree.read(".github/workflows/ios-testflight.yml")
        self.tree.write(".github/workflows/ios-testflight.yml", text.replace("verify_profile_entitlements", "verify_nothing"))
        self.assertReported("does not check the main app's provisioning profile")

    def test_import_outside_the_scene_file(self):
        self.tree.write("QAudionApp/Other.swift", "import CarPlay\n")
        self.assertReported("QAudionApp/Other.swift:1 uses CarPlay outside")

    def test_type_outside_the_scene_file(self):
        self.tree.write("QAudionApp/Other.swift", "func f(_ t: CPListTemplate) {}\n")
        self.assertReported("uses CarPlay outside")

    def test_import_in_the_intents_extension(self):
        self.tree.write("QAudionIntents/Other.swift", "import CarPlay\n")
        self.assertReported("QAudionIntents/Other.swift:1 uses CarPlay outside")

    def test_type_in_the_intents_extension(self):
        self.tree.append("QAudionIntents/IntentHandler.swift", "\nfunc f(_ t: CPListTemplate) {}\n")
        self.assertReported("QAudionIntents/IntentHandler.swift")

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
