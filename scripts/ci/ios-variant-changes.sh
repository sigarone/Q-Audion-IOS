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
# EVERYTHING ELSE FORCES ALL FOUR: project.yml, *.xcconfig, *.entitlements and Info.plist outside the two extension
# folders, *.xcprivacy, Package.swift / Package.resolved, scripts/ci/**, this workflow, the `full-ci` label, and any
# file that cannot be read on either side.
# Known limit: a symbol removed from a file without a flag, but still used inside a flagged region of ANOTHER
# file, breaks only that variant and is not seen here; the run on main builds all four after the merge.
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
    # the extensions and the specs that belong to one variant
    QAudionApp/QAudionShareApp.entitlements) SHARE=true; VPN=true; NOTE "share+vpn: $f" ;;
    QAudionApp/QAudionVPN.entitlements)      VPN=true; NOTE "vpn: $f" ;;
    QAudionApp/project-share.yml)            SHARE=true; NOTE "share: $f" ;;
    QAudionApp/project-vpn.yml)              VPN=true; EARBUD=true; NOTE "vpn+earbud: $f" ;;
    QAudionApp/project-vpn-earbud.yml|QAudionApp/project-earbud.yml) EARBUD=true; NOTE "earbud: $f" ;;
    QAudionApp/project-apptests.yml)         NOTE "none (app tests only): $f" ;;
    QAudionShare/*)                          SHARE=true; NOTE "share: $f" ;;
    QAudionApp/Share/*)                      SHARE=true; NOTE "share: $f" ;;
    QAudionPacketTunnel/*)                   VPN=true; NOTE "vpn: $f" ;;
    # build configuration: all variants
    .github/workflows/ios-app-tests.yml|scripts/ci/*|*Package.swift|*Package.resolved|*.xcconfig|*.entitlements|*Info.plist|*.xcprivacy|QAudionApp/project.yml|project.yml)
      ALL=true; NOTE "all: $f" ;;
    # sources compiled into the app: only the regions of a variant can differ
    QAudionApp/*|QAudionEngine/Sources/*|QAudionIntents/*|QAudionLiveActivity/*|QAudionNotificationService/*)
      if ! readable "$f"; then
        ALL=true; NOTE "all: $f cannot be read on either side"
        continue
      fi
      if content_has "$f" 'QAUDION_SHARE'; then SHARE=true; NOTE "share: $f"; fi
      if content_has "$f" 'QAUDION_VPN'; then VPN=true; NOTE "vpn: $f"; fi
      if content_has "$f" 'QAUDION_EARBUD|QAUDION_DEV_TOOLS'; then EARBUD=true; NOTE "earbud: $f"; fi
      if content_has "$f" '^[[:space:]]*#(if|elseif)[[:space:]].*\b(DEBUG|RELEASE)\b'; then REL=true; NOTE "release: $f"; fi
      ;;
    *) ;;
  esac
done

if [ "$ALL" = true ]; then
  SHARE=true; VPN=true; EARBUD=true; REL=true
fi
NOTE "decision from ${COUNT} paths: share=$SHARE vpn=$VPN earbud=$EARBUD release=$REL"
printf 'share=%s\nvpn=%s\nearbud=%s\nrelease=%s\n' "$SHARE" "$VPN" "$EARBUD" "$REL"
