#!/bin/sh
# ios-variant-changes.sh - which of the four variant builds of ios-app-tests.yml a pull request needs.
#
# USAGE   ios-variant-changes.sh < list-of-changed-paths     (one per line, repo-relative; a renamed file is
#                                                             listed under both its new and its old name)
# ENV     BASE_REV   a revision that holds the base side of the pull request (optional). With it, a deleted or
#                    rewritten file is also read as it was, so removing the last mention of a flag still counts.
#         HEAD_REV   a revision to read the head side from instead of the working tree (for trying the rules).
#         FULL_CI    "true" forces every variant (the `full-ci` label).
# STDOUT  share=true|false  vpn=...  earbud=...  release=...   (appended to $GITHUB_OUTPUT by the workflow)
# STDERR  one line per path that made the decision, for the log.
#
# WHAT EACH VARIANT COMPILES (read from the jobs of ios-app-tests.yml, not guessed):
#   share-variant-build   project-share.yml = project.yml + QAUDION_SHARE + the QAudionShare extension
#                         (../QAudionShare, QAudionApp/Share/ShareQueue.swift); also reads QAudionShareApp.entitlements
#   vpn-variant-build     project-vpn.yml = project.yml + QAUDION_VPN + QAudionPacketTunnel + WireGuardKit; its
#                         "Entitlements variants agree" step reads QAudion.entitlements, QAudionVPN.entitlements and
#                         QAudionShareApp.entitlements
#   earbud-variant-build  project-earbud.yml and project-vpn-earbud.yml (+ project-vpn.yml, which the flag check
#                         generates), built with QAUDION_EARBUD and again with QAUDION_DEV_TOOLS
#   release-config-build  the default spec in Release: whole-module optimisation, `#if DEBUG` code left out
# All four compile the same app sources; what differs is which `#if` regions are active. So a source file can
# break a variant only if it holds that variant's flag (or, for release, a DEBUG condition): those are found by
# reading the file. The default Debug build, the app tests and the gate scripts run on every pull request anyway.
#
# FORCES ALL FOUR: project.yml and every project-*.yml, *.xcconfig, *.entitlements and Info.plist outside the two
# extension folders, *.xcprivacy, *.xcassets, *.xcstrings and Localizable files, Package.swift / Package.resolved,
# scripts/ci/**, the workflow ios-app-tests.yml, the `full-ci` label, a Swift file that cannot be read on either
# side, and ANY other path under QAudionApp, QAudionEngine, QAudionShare, QAudionPacketTunnel, QAudionIntents,
# QAudionLiveActivity or QAudionNotificationService that no rule below names (an unknown path is never skipped).
# NOTHING: docs/**, maestro/**, .jules/**, the other workflows, and Swift files of the two test folders, which no
# variant compiles (the default build runs the app tests on every pull request).
#
# The workflow runs the copy of this script that is on the BASE branch, not the one of the pull request, so a pull
# request cannot decide with its own version; a change to this file is under scripts/ci/ and forces all four.
#
# Known limits, stated plainly:
#  - A symbol removed from a file without a flag, but still used inside a flagged region of ANOTHER file, breaks
#    only that variant and is not seen here.
#  - release-config-build is skipped for a Swift file that has no `#if DEBUG` / `#if RELEASE`, so a warning that
#    only the optimised Release build reports can slip through the pull request. It surfaces on main, where all
#    four variants run after the merge, and the TestFlight gate (ios-testflight.yml, job `gate`) refuses to ship a
#    commit on which any of them failed.
set -u
LC_ALL=C
export LC_ALL

BASE="${BASE_REV:-}"
ALL=false
SHARE=false
VPN=false
EARBUD=false
REL=false
NOTE() { printf '%s\n' "$*" >&2; }

# The head side is the working tree, or the revision HEAD_REV when that is set (used to try the rules on a
# pull request without checking it out).
HEAD_SIDE="${HEAD_REV:-}"
side_text() { # side_text REV FILE: the file as it is in that revision, empty and failing when it is not there
  git cat-file -e "$1:$2" 2>/dev/null && git show "$1:$2" 2>/dev/null
}
head_text() {
  if [ -n "$HEAD_SIDE" ]; then side_text "$HEAD_SIDE" "$1"; else [ -f "$1" ] && cat -- "$1"; fi
}
base_text() { [ -n "$BASE" ] && side_text "$BASE" "$1"; }

# content_has FILE REGEX: the file as it is now, or as it was on the base side, matches.
content_has() {
  head_text "$1" | grep -I -E -q -e "$2" && return 0
  base_text "$1" | grep -I -E -q -e "$2" && return 0
  return 1
}
readable() { head_text "$1" >/dev/null 2>&1 || base_text "$1" >/dev/null 2>&1; }

if [ "${FULL_CI:-}" = "true" ]; then
  ALL=true
  NOTE "label full-ci: all variants"
fi

COUNT=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  COUNT=$((COUNT + 1))
  case "$f" in
    # the entitlements that only some variants read
    QAudionApp/QAudionShareApp.entitlements) SHARE=true; VPN=true; NOTE "share+vpn: $f" ;;
    QAudionApp/QAudionVPN.entitlements)      VPN=true; NOTE "vpn: $f" ;;
    # build configuration and resources that every variant takes in: all variants
    *project-*.yml|*project.yml|.github/workflows/ios-app-tests.yml|scripts/ci/*|*Package.swift|*Package.resolved|*.xcconfig|*.xcassets|*.xcassets/*|*.xcstrings|*Localizable*|*.xcprivacy)
      ALL=true; NOTE "all: $f" ;;
    # the extensions, each in its own variant (their own entitlements and Info.plist included)
    QAudionShare/*|QAudionApp/Share/*)       SHARE=true; NOTE "share: $f" ;;
    QAudionPacketTunnel/*)                   VPN=true; NOTE "vpn: $f" ;;
    *.entitlements|*Info.plist)              ALL=true; NOTE "all: $f" ;;
    # paths no variant reads
    docs/*|maestro/*|.jules/*|.github/workflows/*) NOTE "none: $f" ;;
    # Swift tests: no variant compiles them
    QAudionEngine/Tests/*.swift|QAudionAppTests/*.swift) NOTE "none (tests): $f" ;;
    # Swift sources compiled into the app: only the regions of a variant can differ
    QAudionApp/*.swift|QAudionEngine/Sources/*.swift|QAudionIntents/*.swift|QAudionLiveActivity/*.swift|QAudionNotificationService/*.swift)
      if ! readable "$f"; then
        ALL=true; NOTE "all: $f cannot be read on either side"
        continue
      fi
      if content_has "$f" 'QAUDION_SHARE'; then SHARE=true; NOTE "share: $f"; fi
      if content_has "$f" 'QAUDION_VPN'; then VPN=true; NOTE "vpn: $f"; fi
      if content_has "$f" 'QAUDION_EARBUD|QAUDION_DEV_TOOLS'; then EARBUD=true; NOTE "earbud: $f"; fi
      if content_has "$f" '^[[:space:]]*#(if|elseif)[[:space:]].*\b(DEBUG|RELEASE)\b'; then REL=true; NOTE "release: $f"; fi
      ;;
    # anything else in the code folders is unknown: never skipped
    QAudionApp/*|QAudionEngine/*|QAudionShare/*|QAudionPacketTunnel/*|QAudionIntents/*|QAudionLiveActivity/*|QAudionNotificationService/*)
      ALL=true; NOTE "all (unknown path): $f" ;;
    *) NOTE "none: $f" ;;
  esac
done

if [ "$ALL" = true ]; then
  SHARE=true; VPN=true; EARBUD=true; REL=true
fi
NOTE "decision from ${COUNT} paths: share=$SHARE vpn=$VPN earbud=$EARBUD release=$REL"
printf 'share=%s\nvpn=%s\nearbud=%s\nrelease=%s\n' "$SHARE" "$VPN" "$EARBUD" "$REL"
