#!/usr/bin/env python3
"""Check the app-level rules of the iOS 27 SDK on the sources.

usage: check_sdk27_requirements.py [REPO_ROOT]

Rules (all on files in the repository, no build needed):
  * QAudionApp/Info.plist declares UIApplicationSceneManifest (the app is scene based) and a
    launch screen (UILaunchScreen or UILaunchStoryboardName);
  * no Info.plist of the app or its extensions sets UIDesignRequiresCompatibility (the SDK
    ignores it, the Liquid Glass design can no longer be opted out of) or UIRequiresFullScreen
    (windows are resizable);
  * the Swift sources do not read the deprecated window lists UIApplication.shared.windows /
    .keyWindow, and the app does not create its own UIWindow outside a scene.
Exits 1 with one line per violation.
"""

import os
import plistlib
import re
import sys

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
PLISTS = ["QAudionApp/Info.plist", "QAudionIntents/Info.plist", "QAudionPacketTunnel/Info.plist"]
FORBIDDEN_KEYS = ["UIDesignRequiresCompatibility", "UIRequiresFullScreen"]
SOURCE_DIRS = ["QAudionApp", "QAudionIntents", "QAudionPacketTunnel", "QAudionEngine/Sources"]
SOURCE_RULES = [
    (re.compile(r"UIApplication\.shared\.(windows|keyWindow)\b"), "uses the deprecated UIApplication window list"),
    (re.compile(r"\bUIWindow\(\s*frame\b"), "creates a UIWindow outside a window scene"),
]


def load(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return plistlib.load(f)


def main():
    problems = []
    app = load("QAudionApp/Info.plist")
    if app is None:
        problems.append("QAudionApp/Info.plist not found")
    else:
        if "UIApplicationSceneManifest" not in app:
            problems.append("QAudionApp/Info.plist: UIApplicationSceneManifest is missing")
        if "UILaunchScreen" not in app and "UILaunchStoryboardName" not in app:
            problems.append("QAudionApp/Info.plist: no launch screen (UILaunchScreen or UILaunchStoryboardName)")
    for rel in PLISTS:
        data = load(rel)
        if data is None:
            continue
        for key in FORBIDDEN_KEYS:
            if key in data:
                problems.append(f"{rel}: {key} is set")
    for d in SOURCE_DIRS:
        for dirpath, _, files in os.walk(os.path.join(ROOT, d)):
            for name in files:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
                with open(path, encoding="utf-8", errors="replace") as f:
                    for n, line in enumerate(f, 1):
                        code = line.split("//", 1)[0]
                        for rx, why in SOURCE_RULES:
                            if rx.search(code):
                                problems.append(f"{rel}:{n}: {why}")
    for p in problems:
        print(f"::error::{p}" if os.environ.get("GITHUB_ACTIONS") else p)
    if problems:
        return 1
    print("iOS 27 SDK app-level rules: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
