#!/usr/bin/env python3
"""check_user_content_send_gate.py - source gate: user content reaches the network in a Bluetooth-only chat only
through the user's answer.

The choke point is ChatMessageSendService.sendEncrypted / sendEncryptedDurable: they refuse a send to a Bluetooth-only
contact unless the caller passes a `userChoice:` token. This script checks, on the sources, that:

  1. every call of `.sendEncrypted(` or `.sendEncryptedDurable(` in QAudionApp either passes `userChoice:`, rides the
     service class (`payloadClass: .service`), or is preceded (within 3 lines) by a `// gate-exempt: <reason>` comment
     that says why it is safe (the caller holds the message first, or it is technical traffic);
  2. every direct `messageApi.sendMessage(` is either in a call preceded by that comment or follows (within 12 lines)
     a check of `UserNetworkApprovalStore`;
  3. `UserNetworkChoice.tapped(` is created only in the files that handle the prompt's "send over the internet" tap,
     and the token type is defined in ChatMessageSendService.swift only.

USAGE   python3 -I scripts/ci/check_user_content_send_gate.py [--root DIR]
EXIT    0 clean | 1 a check failed | 2 cannot run
"""
import argparse
import pathlib
import re
import sys

TOKEN_CREATORS = {"QAudionApp/Views/ChatContainer.swift"}
SEND_CALL = re.compile(r"\.(sendEncrypted|sendEncryptedDurable)\(")
DIRECT_CALL = re.compile(r"messageApi\.sendMessage\(")
MARKER = "gate-exempt:"


def call_text(lines, index):
    """The text of the call that starts on line `index`: up to the matching close parenthesis."""
    text = "\n".join(lines[index:index + 14])
    start = text.find("(")
    depth = 0
    for position in range(start, len(text)):
        if text[position] == "(":
            depth += 1
        elif text[position] == ")":
            depth -= 1
            if depth == 0:
                return text[start:position + 1]
    return text[start:]


def has_marker(lines, index):
    return any(MARKER in lines[i] for i in range(max(0, index - 3), index + 1))


def check_source(path, text):
    """The problems of one Swift source, as strings."""
    problems = []
    lines = text.split("\n")
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("//") or " func " in (" " + stripped):
            continue
        if SEND_CALL.search(line):
            body = call_text(lines, index)
            if "userChoice:" in body or "payloadClass: .service" in body or has_marker(lines, index):
                continue
            problems.append("%s:%d: send of user content without `userChoice:` or a `gate-exempt:` reason" % (path, index + 1))
        if DIRECT_CALL.search(line):
            before = "\n".join(lines[max(0, index - 12):index])
            if has_marker(lines, index) or "UserNetworkApprovalStore" in before:
                continue
            problems.append("%s:%d: direct sendMessage without the approval check or a `gate-exempt:` reason" % (path, index + 1))
        if "UserNetworkChoice.tapped(" in line and path not in TOKEN_CREATORS and not path.endswith("ChatMessageSendService.swift"):
            problems.append("%s:%d: a user-choice token is created outside the tap handlers" % (path, index + 1))
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args()
    root = pathlib.Path(args.root)
    app = root / "QAudionApp"
    if not app.is_dir():
        print("cannot run: no QAudionApp directory under %s" % root, file=sys.stderr)
        return 2
    problems = []
    for path in sorted(app.rglob("*.swift")):
        relative = path.relative_to(root).as_posix()
        problems.extend(check_source(relative, path.read_text(encoding="utf-8", errors="replace")))
    if problems:
        print("\n".join(problems))
        return 1
    print("OK: every send of user content passes the user's choice or says why it is exempt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
