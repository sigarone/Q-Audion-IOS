#!/usr/bin/env python3
"""Pick an iOS simulator by exact device name.

usage: resolve_simulator.py NAME [--min-ios MAJOR]

Reads `xcrun simctl list -j devices available` and chooses, among the iOS runtimes whose
major version is at least MAJOR (default 26), the highest one that has a device called
exactly NAME. Prints "UDID<TAB>RUNTIME<TAB>NAME" and, when GITHUB_OUTPUT is
set, appends udid=, runtime= and name= to it. Exits 1 with the list of devices when no
runtime has the device.

A destination of "name=iPhone 17,OS=latest" fails when the newest runtime does not carry
that device; resolving the UDID first avoids depending on which runtime is the newest.
"""

import json
import os
import re
import subprocess
import sys

RUNTIME_RE = re.compile(r"SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?$")


def runtime_version(key):
    m = RUNTIME_RE.search(key)
    if not m:
        return None
    return tuple(int(g) if g is not None else 0 for g in m.groups())


def resolve(data, name, min_ios):
    """Return (udid, runtime_key, version) or None."""
    best = None
    for key, devices in data.get("devices", {}).items():
        version = runtime_version(key)
        if version is None or version[0] < min_ios:
            continue
        for dev in devices:
            if dev.get("name") != name or dev.get("isAvailable") is False:
                continue
            if best is None or version > best[2]:
                best = (dev["udid"], key, version)
    return best


def listing(data):
    lines = []
    for key, devices in sorted(data.get("devices", {}).items()):
        if runtime_version(key) is None:
            continue
        lines.append("%s: %s" % (key, ", ".join(sorted(d.get("name", "?") for d in devices)) or "(none)"))
    return "\n".join(lines)


def main(argv):
    args = list(argv)
    min_ios = 26
    if "--min-ios" in args:
        i = args.index("--min-ios")
        min_ios = int(args[i + 1])
        del args[i : i + 2]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    name = args[0]

    out = subprocess.run(
        ["xcrun", "simctl", "list", "-j", "devices", "available"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    data = json.loads(out)

    found = resolve(data, name, min_ios)
    if found is None:
        print("::error::no iOS %d+ simulator named '%s' is installed. Installed:" % (min_ios, name))
        print(listing(data))
        return 1

    udid, runtime, _ = found
    print("%s\t%s\t%s" % (udid, runtime, name))
    out_file = os.environ.get("GITHUB_OUTPUT")
    if out_file:
        with open(out_file, "a", encoding="utf-8") as f:
            f.write("udid=%s\nruntime=%s\nname=%s\n" % (udid, runtime, name))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
