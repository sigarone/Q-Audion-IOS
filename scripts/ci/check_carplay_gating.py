#!/usr/bin/env python3
"""check_carplay_gating.py - source gate: CarPlay is part of every build, and nothing on the car screen points at
the phone.

WHY. The app is a CarPlay Communication app. The scene (QAudionApp/CarPlay/CarPlayScene.swift) only runs when all of
the following are in place, and a build that drops one of them either has no CarPlay icon in the car or fails to
sign. This script checks, on any machine with Python 3 and in a second, that:

  1. QAudionApp/project.yml links CarPlay.framework weakly (`weak: true`), there is no CarPlay variant spec any more
     (QAudionApp/project-carplay.yml), and nothing refers to the old compilation flag (QAUDION_CARPLAY): the scene is
     not conditional, so a leftover `#if QAUDION_CARPLAY` would silently compile code out;
  2. the app's Info.plist declares the scene: UIApplicationSupportsMultipleScenes on and the role
     CPTemplateApplicationSceneSessionRoleApplication with the scene delegate class CarPlaySceneDelegate;
  3. every entitlements file the app is signed with (QAudion.entitlements, QAudionVPN.entitlements,
     QAudionShareApp.entitlements) carries
     com.apple.developer.carplay-communication = true, and no other entitlements file (the extensions') does;
  4. the Intents extension's Info.plist has no CarPlay scene role;
  5. the CarPlay framework is used by the scene only (QAudionApp/CarPlay/CarPlayScene.swift): the bridge, the list
     model and everything else stay free of CarPlay types, so they run in unit tests;
  6. ios-testflight.yml checks the main app's provisioning profile against the entitlements file before the archive,
     and never builds a CarPlay variant;
  7. the text that can appear on the car screen (the carplay.* strings of the catalog in every language, and the
     default values in the CarPlay sources) never tells the driver to use the phone: a CarPlay flow has to be
     possible without touching it.

The built app is checked as well, on macOS, by the step "CarPlay scene in the default build" of ios-app-tests.yml.

USAGE   python3 -I scripts/ci/check_carplay_gating.py [--root DIR]
EXIT    0 clean | 1 a check failed | 2 cannot run
"""
import argparse
import json
import os
import pathlib
import plistlib
import re
import sys

OLD_FLAG = "QAUDION_CARPLAY"
ENTITLEMENT = "com.apple.developer.carplay-communication"
ROLE = "CPTemplateApplicationSceneSessionRoleApplication"
SCENE_FILE = "QAudionApp/CarPlay/CarPlayScene.swift"

# Entitlements files the app itself is signed with; each must carry the CarPlay entitlement.
APP_ENTITLEMENTS = ("QAudionApp/QAudion.entitlements", "QAudionApp/QAudionVPN.entitlements",
                    "QAudionApp/QAudionShareApp.entitlements")

SKIP_DIRS = {".git", "graphify-out", ".build", "build", "DerivedData", "node_modules", ".cache"}

# Directories of Swift sources that are compiled into the app or into one of its extensions.
SOURCE_DIRS = ("QAudionApp", "QAudionIntents")

# Types of the CarPlay framework.
CP_TYPE = re.compile(
    r"\bCP(Template|List|Message|Contact|Grid|Interface|Session|Alert|Assistant|TabBar|Window|Maneuver)[A-Za-z]*\b")

# Words that send a driver to the phone, in the languages of the catalog.
PHONE_WORDS = re.compile(
    r"\b(phone|iphone|smartphone|telefon\w*|téléphone|teléfono|telefone|cellulare|celular|portable|handy|móvil)\b",
    re.IGNORECASE)

CARPLAY_SOURCES = [
    "QAudionApp/CarPlay/CarPlayScene.swift",
    "QAudionApp/CarPlay/CarPlayListModel.swift",
    "QAudionApp/CarPlay/CarPlayBridge.swift",
]


def read_inside(root, path, errors="strict"):
    """Reads a text file, refusing any path that resolves outside `root` (a symbolic link, a `..`)."""
    root_real = os.path.realpath(root)
    real = os.path.realpath(path)
    if os.path.commonpath([root_real, real]) != root_real:
        raise ValueError("%s is outside %s" % (path, root))
    return pathlib.Path(real).read_text(encoding="utf-8", errors=errors)


def read(root, rel):
    return read_inside(root, os.path.join(root, rel))


def read_bytes(root, rel):
    path = os.path.join(root, rel)
    root_real = os.path.realpath(root)
    real = os.path.realpath(path)
    if os.path.commonpath([root_real, real]) != root_real:
        raise ValueError("%s is outside %s" % (path, root))
    return pathlib.Path(real).read_bytes()


def exists(root, rel):
    return os.path.isfile(os.path.join(root, rel))


def strip_yaml_comments(text):
    out = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        out.append(line)
    return "\n".join(out)


def strip_swift_comments(text):
    """Blanks // and /* */ comments (keeps line numbers). Strings are left alone."""
    out = []
    in_block = False
    for line in text.splitlines():
        i = 0
        kept = []
        in_string = False
        while i < len(line):
            two = line[i:i + 2]
            ch = line[i]
            if in_block:
                if two == "*/":
                    in_block = False
                    i += 2
                else:
                    i += 1
                continue
            if in_string:
                kept.append(ch)
                if ch == "\\" and i + 1 < len(line):
                    kept.append(line[i + 1])
                    i += 2
                    continue
                if ch == '"':
                    in_string = False
                i += 1
                continue
            if ch == '"':
                in_string = True
                kept.append(ch)
                i += 1
                continue
            if two == "//":
                break
            if two == "/*":
                in_block = True
                i += 2
                continue
            kept.append(ch)
            i += 1
        out.append("".join(kept))
    return out


def swift_files(root):
    for source_dir in SOURCE_DIRS:
        base = os.path.join(root, source_dir)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if name.endswith(".swift"):
                    full = os.path.join(dirpath, name)
                    yield os.path.relpath(full, root).replace(os.sep, "/")


def spec_files(root):
    """Every XcodeGen spec of the app: QAudionApp/project*.yml."""
    base = os.path.join(root, "QAudionApp")
    if not os.path.isdir(base):
        return
    for name in sorted(os.listdir(base)):
        if name.startswith("project") and name.endswith(".yml"):
            yield "QAudionApp/" + name


# CarPlay.framework linked weakly: a dependency with `weak: true`, or the linker flag. A strong link
# (`- sdk: CarPlay.framework` alone, `-framework CarPlay`) does not count: the app may run where the framework is absent.
FRAMEWORK_LINK = re.compile(
    r"(?m)^\s*-\s*sdk:\s*CarPlay\.framework\s*\n\s*weak:\s*true\s*$|weak_framework\s+CarPlay\b")


def check_specs(root):
    problems = []
    default_spec = "QAudionApp/project.yml"
    if not exists(root, default_spec):
        return ["%s is missing" % default_spec]
    if not FRAMEWORK_LINK.search(strip_yaml_comments(read(root, default_spec))):
        problems.append("%s does not link CarPlay.framework weakly (- sdk: CarPlay.framework with weak: true)" % default_spec)
    if exists(root, "QAudionApp/project-carplay.yml"):
        problems.append("QAudionApp/project-carplay.yml exists: CarPlay is part of the default spec, there is no variant")
    for rel in spec_files(root):
        text = strip_yaml_comments(read(root, rel))
        if OLD_FLAG in text:
            problems.append("%s mentions %s: the flag no longer exists, the scene is always compiled" % (rel, OLD_FLAG))
    return problems


def check_flag_in_sources(root):
    problems = []
    for rel in swift_files(root):
        for number, line in enumerate(strip_swift_comments(read(root, rel)), start=1):
            if OLD_FLAG in line:
                problems.append("%s:%d refers to %s: the flag no longer exists, the code is always compiled"
                                % (rel, number, OLD_FLAG))
    return problems


def load_plist(root, rel):
    try:
        return plistlib.loads(read_bytes(root, rel))
    except Exception as exc:  # a plist that does not parse is a failed check, not a crash
        return exc


def check_entitlements(root):
    problems = []
    for rel in APP_ENTITLEMENTS:
        if not exists(root, rel):
            problems.append("%s is missing" % rel)
            continue
        data = load_plist(root, rel)
        if isinstance(data, Exception):
            problems.append("%s cannot be read: %s" % (rel, data))
        elif data.get(ENTITLEMENT) is not True:
            problems.append("%s does not carry %s = true: the build would have no CarPlay scene or fail to sign"
                            % (rel, ENTITLEMENT))
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if not name.endswith(".entitlements"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
            if rel in APP_ENTITLEMENTS:
                continue
            text = read_inside(root, os.path.join(dirpath, name), errors="replace")
            if re.search(r"<key>\s*com\.apple\.developer\.carplay[^<]*</key>", text):
                problems.append("%s carries a CarPlay entitlement: only the app's own entitlements files may" % rel)
    return problems


def check_plists(root):
    problems = []
    rel = "QAudionApp/Info.plist"
    if not exists(root, rel):
        return ["%s is missing" % rel]
    data = load_plist(root, rel)
    if isinstance(data, Exception):
        return ["%s cannot be read: %s" % (rel, data)]
    manifest = data.get("UIApplicationSceneManifest")
    if not isinstance(manifest, dict):
        problems.append("%s has no UIApplicationSceneManifest" % rel)
    else:
        if manifest.get("UIApplicationSupportsMultipleScenes") is not True:
            problems.append("%s: UIApplicationSupportsMultipleScenes is not true, which CarPlay needs" % rel)
        roles = (manifest.get("UISceneConfigurations") or {}).get(ROLE)
        if not isinstance(roles, list) or not roles:
            problems.append("%s has no %s scene role" % (rel, ROLE))
        else:
            delegate = str(roles[0].get("UISceneDelegateClassName", ""))
            if not delegate.endswith(".CarPlaySceneDelegate"):
                problems.append("%s: the CarPlay scene delegate is %r, not <module>.CarPlaySceneDelegate" % (rel, delegate))
    intents = "QAudionIntents/Info.plist"
    if exists(root, intents) and ROLE in read(root, intents):
        problems.append("%s has a CarPlay scene role: only the app does" % intents)
    return problems


def check_scene_source(root):
    if not exists(root, SCENE_FILE):
        return ["%s is missing" % SCENE_FILE]
    lines = strip_swift_comments(read(root, SCENE_FILE))
    text = "\n".join(lines)
    problems = []
    if not re.search(r"(?m)^import\s+CarPlay\b", text):
        problems.append("%s does not import CarPlay" % SCENE_FILE)
    if not re.search(r"\bclass\s+CarPlaySceneDelegate\b", text):
        problems.append("%s does not define CarPlaySceneDelegate, which Info.plist names" % SCENE_FILE)
    if re.search(r"(?m)^\s*#if\b", text):
        problems.append("%s has a conditional compilation block: the scene is always compiled" % SCENE_FILE)
    return problems


def check_framework_use(root):
    """CarPlay types and the import belong to the scene file; the rest stays testable without the framework."""
    problems = []
    for rel in swift_files(root):
        if rel == SCENE_FILE:
            continue
        for number, line in enumerate(strip_swift_comments(read(root, rel)), start=1):
            stripped = line.strip()
            if re.match(r"import\s+CarPlay\b", stripped) or CP_TYPE.search(line):
                problems.append("%s:%d uses CarPlay outside %s: %s" % (rel, number, SCENE_FILE, stripped))
    return problems


def check_testflight(root):
    rel = ".github/workflows/ios-testflight.yml"
    if not exists(root, rel):
        return []
    text = strip_yaml_comments(read(root, rel))
    problems = []
    for needle in ("project-carplay", OLD_FLAG, "carplay-add-scene"):
        if needle in text:
            problems.append("%s mentions %s: CarPlay has no variant spec or flag any more" % (rel, needle))
    if "verify_profile_entitlements" not in text:
        problems.append("%s does not check the main app's provisioning profile against the entitlements file "
                        "(verify_profile_entitlements)" % rel)
    return problems


def default_values(text):
    """The `defaultValue:` string literals of a Swift file."""
    return re.findall(r'defaultValue:\s*"((?:[^"\\]|\\.)*)"', text)


def check_copy(root):
    problems = []
    catalog = "QAudionApp/Localizable.xcstrings"
    if exists(root, catalog):
        data = json.loads(read(root, catalog))
        for key, entry in data.get("strings", {}).items():
            if not key.startswith("carplay."):
                continue
            for lang, loc in entry.get("localizations", {}).items():
                value = loc.get("stringUnit", {}).get("value", "")
                if PHONE_WORDS.search(value):
                    problems.append("%s [%s] points at the phone: %r" % (key, lang, value))
    for rel in CARPLAY_SOURCES:
        if not exists(root, rel):
            continue
        for value in default_values(read(root, rel)):
            if PHONE_WORDS.search(value):
                problems.append("%s default text points at the phone: %r" % (rel, value))
    return problems


def run(root):
    problems = []
    problems += check_specs(root)
    problems += check_flag_in_sources(root)
    problems += check_entitlements(root)
    problems += check_plists(root)
    problems += check_scene_source(root)
    problems += check_framework_use(root)
    problems += check_testflight(root)
    problems += check_copy(root)
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
    args = parser.parse_args(argv)
    if not os.path.isdir(os.path.join(args.root, "QAudionApp")):
        print("cannot run: no QAudionApp directory under %s" % args.root, file=sys.stderr)
        return 2
    problems = run(args.root)
    if problems:
        for p in problems:
            print("FAIL " + p)
        return 1
    print("CarPlay gating: ok (framework linked, scene in Info.plist, entitlement in both app entitlements files, "
          "no copy pointing at the phone)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
