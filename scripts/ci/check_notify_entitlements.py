#!/usr/bin/env python3
"""Check that the app's entitlements files carry the notification groundwork.

usage: check_notify_entitlements.py [REPO_ROOT]

The app entitlements files (QAudion.entitlements, QAudionVPN.entitlements, QAudionShareApp.entitlements) must have:
  * com.apple.developer.usernotifications.time-sensitive = true;
  * keychain-access-groups whose FIRST entry is $(AppIdentifierPrefix)com.qaudion.app (the group of every item the
    app already has) and which also lists $(AppIdentifierPrefix)com.qaudion.notify;
  * the App Group group.com.bcrypto.qaudion.notify;
  * com.apple.developer.default-data-protection = NSFileProtectionComplete;
  * com.apple.developer.usernotifications.communication = true (sender photo and name in message notifications).
The notification service extension (QAudionNotificationService/QAudionNotificationService.entitlements) must carry
exactly the notify App Group and the notify keychain group, and nothing else.
Exits 1 with one line per violation.
"""

import os
import plistlib
import sys

ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
FILES = [
    "QAudionApp/QAudion.entitlements",
    "QAudionApp/QAudionVPN.entitlements",
    "QAudionApp/QAudionShareApp.entitlements",
]
EXTENSION_FILE = "QAudionNotificationService/QAudionNotificationService.entitlements"
APP_GROUP = "$(AppIdentifierPrefix)com.qaudion.app"
NOTIFY_GROUP = "$(AppIdentifierPrefix)com.qaudion.notify"
NOTIFY_APP_GROUP = "group.com.bcrypto.qaudion.notify"


def check(rel, data):
    problems = []
    if data.get("com.apple.developer.usernotifications.time-sensitive") is not True:
        problems.append(f"{rel}: com.apple.developer.usernotifications.time-sensitive is not true")
    groups = data.get("keychain-access-groups")
    if not isinstance(groups, list) or not groups or groups[0] != APP_GROUP:
        problems.append(f"{rel}: the first keychain-access-groups entry is not {APP_GROUP}")
    if not isinstance(groups, list) or NOTIFY_GROUP not in groups:
        problems.append(f"{rel}: keychain-access-groups lacks {NOTIFY_GROUP}")
    if NOTIFY_APP_GROUP not in (data.get("com.apple.security.application-groups") or []):
        problems.append(f"{rel}: the App Group {NOTIFY_APP_GROUP} is missing")
    if data.get("com.apple.developer.default-data-protection") != "NSFileProtectionComplete":
        problems.append(f"{rel}: com.apple.developer.default-data-protection is not NSFileProtectionComplete")
    if data.get("com.apple.developer.usernotifications.communication") is not True:
        problems.append(f"{rel}: com.apple.developer.usernotifications.communication is not true")
    return problems


def check_extension(rel, data):
    problems = []
    if data.get("keychain-access-groups") != [NOTIFY_GROUP]:
        problems.append(f"{rel}: keychain-access-groups must be exactly [{NOTIFY_GROUP}]")
    if data.get("com.apple.security.application-groups") != [NOTIFY_APP_GROUP]:
        problems.append(f"{rel}: application-groups must be exactly [{NOTIFY_APP_GROUP}]")
    extra = sorted(set(data) - {"keychain-access-groups", "com.apple.security.application-groups"})
    if extra:
        problems.append(f"{rel}: unexpected entitlements {extra}")
    return problems


def main():
    problems = []
    for rel in FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            problems.append(f"{rel} not found")
            continue
        with open(path, "rb") as f:
            problems.extend(check(rel, plistlib.load(f)))
    ext_path = os.path.join(ROOT, EXTENSION_FILE)
    if not os.path.isfile(ext_path):
        problems.append(f"{EXTENSION_FILE} not found")
    else:
        with open(ext_path, "rb") as f:
            problems.extend(check_extension(EXTENSION_FILE, plistlib.load(f)))
    for line in problems:
        print(line)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
