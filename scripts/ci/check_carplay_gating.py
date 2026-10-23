#!/usr/bin/env python3
"""check_carplay_gating.py - source gate: the CarPlay scene is compiled only with QAUDION_CARPLAY, and nothing
on the car screen points at the phone.

WHY. CarPlay (Tier B, the in-car app) needs the entitlement com.apple.developer.carplay-communication,
which Apple grants on request. Until it is granted the scene is a compile-time switch that is OFF in every
default and release build. The compiler of the default build cannot tell that a CarPlay reference slipped out of
`#if QAUDION_CARPLAY`, and nothing else stops somebody from putting the entitlement into the entitlements the
app is signed with (which would make the signing step fail on a profile that does not have it) or from
switching the flag on in the spec the TestFlight workflow archives. This script checks, on any machine with
Python 3 and in a second, that:

  1. no spec but the variant (every QAudionApp/project*.yml) sets the flag, links CarPlay.framework or mentions
     the entitlement;
  2. the variant spec (QAudionApp/project-carplay.yml) includes the default spec, sets the flag and links
     CarPlay.framework weakly (-weak_framework CarPlay), keeping the linker flags of the default spec;
  3. no entitlements file of the repository carries a com.apple.developer.carplay-* key;
  4. neither Info.plist (app, Intents extension) has a CarPlay scene role;
  5. ios-testflight.yml never mentions the variant spec, the flag or the entitlement outside comments;
  6. every CarPlay type and `import CarPlay` in the app and Intents extension sources is inside
     `#if QAUDION_CARPLAY`;
  7. the text that can appear on the car screen (the carplay.* strings of the catalog in every language, and the
     default values in the CarPlay sources) never tells the driver to use the phone: a CarPlay flow has to be
     possible without touching it.

The built binaries are checked as well, on macOS, by the steps of ios-app-tests.yml that read the built apps.

USAGE   python3 -I scripts/ci/check_carplay_gating.py [--root DIR]
EXIT    0 clean | 1 a check failed | 2 cannot run
"""
import argparse
import json
import os
import pathlib
import re
import sys

FLAG = "QAUDION_CARPLAY"

SKIP_DIRS = {".git", "graphify-out", ".build", "build", "DerivedData", "node_modules", ".cache"}

# Directories of Swift sources that are compiled into the app or into one of its extensions.
SOURCE_DIRS = ("QAudionApp", "QAudionIntents")

# Types of the CarPlay framework that the app code may use. A reference outside the flag does not compile
# without the framework import, but the import itself is checked separately, so a stray type name is a
# second, independent signal.
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


def ld_flags(text):
    """The tokens of the OTHER_LDFLAGS line of a spec (comments already stripped), without $(inherited)."""
    match = re.search(r"(?m)^\s*OTHER_LDFLAGS:\s*(.*)$", text)
    if not match:
        return []
    return [t for t in match.group(1).split() if t != "$(inherited)"]


def flag_in_stack(stack):
    # Active under the flag only when some enclosing `#if` is exactly `#if QAUDION_CARPLAY` (or a conjunction
    # that includes it) and we are in its true branch.
    for cond, in_true_branch in stack:
        if in_true_branch and re.search(r"(^|&&|\()\s*" + FLAG + r"\s*($|&&|\))", cond):
            return True
    return False


def references_outside_flag(text):
    """Line numbers of CarPlay references (import, CP types) that are not under `#if QAUDION_CARPLAY`."""
    problems = []
    stack = []  # (condition text, in the true branch)
    for number, line in enumerate(strip_swift_comments(text), start=1):
        stripped = line.strip()
        if stripped.startswith("#if "):
            stack.append((stripped[4:].strip(), True))
            continue
        if stripped.startswith("#elseif "):
            if stack:
                stack[-1] = (stripped[8:].strip(), False)
            continue
        if stripped == "#else":
            if stack:
                stack[-1] = (stack[-1][0], False)
            continue
        if stripped.startswith("#endif"):
            if stack:
                stack.pop()
            continue
        mentions = re.match(r"import\s+CarPlay\b", stripped) or CP_TYPE.search(line)
        if mentions and not flag_in_stack(stack):
            problems.append((number, stripped))
    return problems


# What no spec but the variant may contain (outside comments): the flag, a link to the framework.
FRAMEWORK_LINK = re.compile(r"weak_framework\s+CarPlay\b|CarPlay\.framework")


def check_specs(root):
    problems = []
    default_spec = "QAudionApp/project.yml"
    variant_spec = "QAudionApp/project-carplay.yml"
    if not exists(root, default_spec):
        return ["%s is missing" % default_spec]
    for rel in spec_files(root):
        if rel == variant_spec:
            continue
        text = strip_yaml_comments(read(root, rel))
        if FLAG in text:
            problems.append("%s sets %s: only the variant spec may, the default build must not compile the CarPlay scene"
                            % (rel, FLAG))
        if FRAMEWORK_LINK.search(text):
            problems.append("%s links CarPlay.framework: only the variant spec may" % rel)
        if "carplay-communication" in text:
            problems.append("%s adds the CarPlay entitlement" % rel)
    if not exists(root, variant_spec):
        problems.append("%s is missing" % variant_spec)
    else:
        text = strip_yaml_comments(read(root, variant_spec))
        if "-D" + FLAG not in text:
            problems.append("%s does not set -D%s" % (variant_spec, FLAG))
        if not re.search(r"(?m)^include:\s*\n\s*-\s*project\.yml\s*$", text):
            problems.append("%s does not include project.yml" % variant_spec)
        if "carplay-communication" in text:
            problems.append("%s adds the CarPlay entitlement" % variant_spec)
        flags = ld_flags(text)
        if "-weak_framework" not in flags or flags[flags.index("-weak_framework") + 1:][:1] != ["CarPlay"]:
            problems.append("%s does not link CarPlay.framework weakly (-weak_framework CarPlay in OTHER_LDFLAGS)"
                            % variant_spec)
        for flag in ld_flags(strip_yaml_comments(read(root, default_spec))):
            if flag not in flags:
                problems.append("%s drops the linker flag %s of %s (a value in the variant replaces the included one)"
                                % (variant_spec, flag, default_spec))
    return problems


def check_entitlements_and_plists(root):
    problems = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name.endswith(".entitlements"):
                rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
                # A key, not a comment that names it.
                text = read_inside(root, os.path.join(dirpath, name), errors="replace")
                if re.search(r"<key>\s*com\.apple\.developer\.carplay[^<]*</key>", text):
                    problems.append("%s carries a CarPlay entitlement, which this build is not provisioned for" % rel)
    for rel in ("QAudionApp/Info.plist", "QAudionIntents/Info.plist"):
        if exists(root, rel) and "CPTemplateApplicationSceneSessionRoleApplication" in read(root, rel):
            problems.append("%s has a CarPlay scene role: only the variant build adds it" % rel)
    return problems


def check_testflight(root):
    rel = ".github/workflows/ios-testflight.yml"
    if not exists(root, rel):
        return []
    text = strip_yaml_comments(read(root, rel))
    problems = []
    for needle in ("project-carplay", FLAG, "carplay-communication", "weak_framework CarPlay"):
        if needle in text:
            problems.append("%s mentions %s: no release build may enable CarPlay" % (rel, needle))
    return problems


def check_sources(root):
    problems = []
    for rel in swift_files(root):
        text = read(root, rel)
        if "CarPlay" not in text and not CP_TYPE.search(text):
            continue
        for number, line in references_outside_flag(text):
            problems.append("%s:%d uses CarPlay outside #if %s: %s" % (rel, number, FLAG, line))
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
    problems += check_entitlements_and_plists(root)
    problems += check_testflight(root)
    problems += check_sources(root)
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
    print("CarPlay gating: ok (flag only in project-carplay.yml, no entitlement, no scene role, no copy pointing at the phone)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
