#!/usr/bin/env python3
"""check_siri_intent_phrases.py - source gate: every Siri intent the Intents extension declares has example
phrases, in every language the app ships.

WHY. QAudionIntents/Info.plist lists the intents the extension handles (NSExtension > NSExtensionAttributes >
IntentsSupported). For each of them the app ships, in QAudionApp/<lang>.lproj/AppIntentVocabulary.plist, an
IntentPhrases entry with example utterances, for the development language of the app (CFBundleDevelopmentRegion
of QAudionApp/Info.plist) and for every language in its CFBundleLocalizations. Adding an intent to
IntentsSupported, or a language to CFBundleLocalizations, without adding the phrases compiles and runs, so nothing
else catches it. This script checks, on any machine with Python 3 and in a second, that:

  1. a vocabulary exists for the development region of the app and for every language in its
     CFBundleLocalizations, and every other QAudionApp/*.lproj vocabulary is read as well;
  2. every intent in IntentsSupported has an IntentPhrases entry in every vocabulary, with at least one
     non-empty example;
  3. every example names the app (it contains "Q-Audion"), because Siri routes an utterance to the app by that
     name;
  4. no vocabulary lists an IntentName that is missing from IntentsSupported (a stale entry left behind when an
     intent was dropped).

USAGE   python3 -I scripts/ci/check_siri_intent_phrases.py [--root DIR]
EXIT    0 clean | 1 a check failed | 2 cannot run
"""
import argparse
import glob
import os
import plistlib
import sys
from xml.parsers.expat import ExpatError

APP_NAME = "Q-Audion"

INTENTS_INFO = "QAudionIntents/Info.plist"
APP_INFO = "QAudionApp/Info.plist"
VOCABULARY = "AppIntentVocabulary.plist"


def load_plist(root, rel):
    """Reads a property list, refusing any path that resolves outside `root` (a symbolic link, a `..`)."""
    path = os.path.join(root, rel)
    root_real = os.path.realpath(root)
    real = os.path.realpath(path)
    if os.path.commonpath([root_real, real]) != root_real:
        raise ValueError("%s is outside %s" % (rel, root))
    with open(real, "rb") as f:
        data = plistlib.load(f)
    if not isinstance(data, dict):
        raise ValueError("%s is not a dictionary" % rel)
    return data


def supported_intents(root, problems):
    """IntentsSupported of the Intents extension, or None when it cannot be read."""
    try:
        info = load_plist(root, INTENTS_INFO)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as e:
        problems.append("%s cannot be read: %s" % (INTENTS_INFO, e))
        return None
    attributes = (info.get("NSExtension") or {}).get("NSExtensionAttributes") or {}
    intents = attributes.get("IntentsSupported")
    if not isinstance(intents, list) or not intents or not all(isinstance(i, str) and i for i in intents):
        problems.append("%s has no usable NSExtension > NSExtensionAttributes > IntentsSupported list" % INTENTS_INFO)
        return None
    return intents


def development_region(root, problems):
    """CFBundleDevelopmentRegion of the app, or None when it cannot be read or is not a literal region."""
    try:
        info = load_plist(root, APP_INFO)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as e:
        problems.append("%s cannot be read: %s" % (APP_INFO, e))
        return None
    region = info.get("CFBundleDevelopmentRegion")
    if not isinstance(region, str) or not region or region.startswith("$("):
        problems.append("%s has no literal CFBundleDevelopmentRegion (found %r)" % (APP_INFO, region))
        return None
    return region


def localizations(root, problems):
    """CFBundleLocalizations of the app ([] when the key is absent or the file cannot be read; the latter is
    already reported by development_region)."""
    try:
        info = load_plist(root, APP_INFO)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
        return []
    langs = info.get("CFBundleLocalizations")
    if langs is None:
        return []
    if not isinstance(langs, list) or not all(isinstance(l, str) and l for l in langs):
        problems.append("%s has a CFBundleLocalizations that is not a list of language names (found %r)"
                        % (APP_INFO, langs))
        return []
    return langs


def vocabularies(root):
    """{language: relative path} of every QAudionApp/<language>.lproj/AppIntentVocabulary.plist."""
    found = {}
    pattern = os.path.join(glob.escape(root), "QAudionApp", "*.lproj", VOCABULARY)
    for path in sorted(glob.glob(pattern)):
        lang = os.path.basename(os.path.dirname(path))[: -len(".lproj")]
        found[lang] = "QAudionApp/%s.lproj/%s" % (lang, VOCABULARY)
    return found


def region_vocabulary(languages, region):
    """The language key of `languages` that names `region` (pt-BR and pt_BR are the same region), or None."""
    wanted = region.replace("_", "-").lower()
    for lang in languages:
        if lang.replace("_", "-").lower() == wanted:
            return lang
    return None


def examples_by_intent(data, label, problems):
    """{IntentName: [examples]} of one vocabulary. Malformed entries are reported and skipped."""
    phrases = data.get("IntentPhrases")
    if not isinstance(phrases, list):
        problems.append("%s: IntentPhrases is missing or not an array" % label)
        return {}
    found = {}
    for index, entry in enumerate(phrases):
        name = entry.get("IntentName") if isinstance(entry, dict) else None
        if not isinstance(name, str) or not name:
            problems.append("%s: IntentPhrases entry %d has no IntentName" % (label, index))
            continue
        examples = entry.get("IntentExamples")
        found.setdefault(name, [])
        if isinstance(examples, list):
            found[name].extend(examples)
    return found


def check_vocabulary(root, lang, rel, intents, problems):
    try:
        data = load_plist(root, rel)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as e:
        problems.append("%s cannot be read: %s" % (rel, e))
        return
    label = "%s [%s]" % (rel, lang)
    by_intent = examples_by_intent(data, label, problems)
    for intent in intents:
        examples = by_intent.get(intent)
        if examples is None:
            problems.append("%s: %s has no IntentPhrases entry" % (label, intent))
            continue
        usable = [e for e in examples if isinstance(e, str) and e.strip()]
        if not usable:
            problems.append("%s: %s has no non-empty IntentExamples string" % (label, intent))
        elif len(usable) != len(examples):
            problems.append("%s: %s has an IntentExamples item that is empty or not a string" % (label, intent))
        for example in usable:
            if APP_NAME not in example:
                problems.append("%s: %s example does not name the app (%s): %r" % (label, intent, APP_NAME, example))
    for name in by_intent:
        if name not in intents:
            problems.append("%s: %s is not in IntentsSupported of %s (stale entry)" % (label, name, INTENTS_INFO))


def run(root):
    problems = []
    intents = supported_intents(root, problems)
    region = development_region(root, problems)
    langs = vocabularies(root)
    if region is not None and region_vocabulary(langs, region) is None:
        problems.append(
            "QAudionApp/%s.lproj/%s is missing: %s is the development region of the app (%s), so the vocabulary "
            "of that language is required" % (region, VOCABULARY, region, APP_INFO))
    for loc in localizations(root, problems):
        if region is not None and region_vocabulary([loc], region) is not None:
            continue
        if region_vocabulary(langs, loc) is None:
            problems.append(
                "QAudionApp/%s.lproj/%s is missing: %s is in CFBundleLocalizations of %s, so the vocabulary of "
                "that language is required" % (loc, VOCABULARY, loc, APP_INFO))
    if intents is None:
        return problems
    if not langs:
        problems.append("no QAudionApp/*.lproj/%s found" % VOCABULARY)
    for lang, rel in langs.items():
        check_vocabulary(root, lang, rel, intents, problems)
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
    intents = supported_intents(args.root, [])
    print("Siri intent phrases: ok (%d intents, %d languages, every example names %s)"
          % (len(intents), len(vocabularies(args.root)), APP_NAME))
    return 0


if __name__ == "__main__":
    sys.exit(main())
