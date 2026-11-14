#!/bin/sh
# ios-ci-plan.sh - which parts of .github/workflows/ios-ci.yml a change needs.
#
# USAGE   ios-ci-plan.sh < list-of-changed-paths     (one per line, repo-relative; a renamed file is listed under both
#                                                      its new and its old name)
# ENV     EVENT      pull_request or push; any other event (workflow_dispatch) needs everything
#         FULL_CI    "true" needs everything (the `full-ci` label)
# STDOUT  app=true|false  engine=...  scripts=...  signing=...   (appended to $GITHUB_OUTPUT by the workflow)
# STDERR  one line per path that made a decision, for the log.
#
# WHAT EACH FLAG STARTS
#   app      job app-build-and-tests (macOS: the app build, the gates on the built app, the app tests) and, through
#            ios-variant-changes.sh, the variant builds. Set by the app and extension folders and by the scripts that
#            job runs.
#   engine   job ios-simulator-tests (macOS: the QAudionEngine package tests). Set by every path EXCEPT a list of paths
#            that nothing in that job reads. It is a list of what is irrelevant and not of what matters on purpose:
#            the engine tests read files outside QAudionEngine/ (the wiring tests read QAudionApp/ sources, the vector
#            tests read tools/kat/, WIRE_SPEC.md and scripts/ship-ios-logs.py), so a short list of triggers would miss
#            the next test that reads a new path. A path that is not listed runs the job.
#   scripts  job gates (Linux: the self-tests of the CI scripts and the log filter tests). Set by scripts/ci/,
#            the log filter and its tests, the Swift files whose log lines the filter checks, and every workflow.
#            The job also runs when `app` is set, because the source gates read the app sources.
#   signing  job signing-key-macos (macOS, seconds): the signing key check against the OpenSSL of the runner image.
#
# EVERYTHING (all four true): the workflow itself and the scripts that decide, the label `full-ci`, an event that is
# not a pull request or a push (manual dispatch).
# A PUSH to main is the commit the tag gate looks at, so a push that changes code (app or engine) needs both macOS test
# jobs: the gate wants each of them green on that commit, or reused from the pull request.
# NOTHING: documentation (docs/, root *.md and *.html), maestro/, .jules/ and the like give all four false.
#
# The workflow runs the copy of this script that is on the BASE branch for a pull request (see the step "Decide what the
# change needs" in ios-ci.yml), so a pull request cannot decide with its own version; a change to this file or to the
# workflow is EVERYTHING.
set -u
LC_ALL=C
export LC_ALL

EVENT="${EVENT:-}"
APP=false
ENGINE=false
SCRIPTS=false
SIGNING=false
ALL=false
COUNT=0
NOTE() { printf '%s\n' "$*" >&2; }

if [ "${FULL_CI:-}" = "true" ]; then
  ALL=true
  NOTE "label full-ci: everything"
fi
case "$EVENT" in
  pull_request|push) ;;
  *) ALL=true; NOTE "event '${EVENT}': everything" ;;
esac

while IFS= read -r f; do
  [ -z "$f" ] && continue
  COUNT=$((COUNT + 1))

  # The pipeline and the scripts that decide: a change to them is proved by running everything.
  case "$f" in
    .github/workflows/ios-ci.yml|scripts/ci/ios-ci-plan.sh|scripts/ci/ios-variant-changes.sh)
      ALL=true; NOTE "everything: $f" ;;
  esac

  # app: the folders compiled into the app or its extensions, and the scripts the app job runs.
  case "$f" in
    QAudionApp/*|QAudionAppTests/*|QAudionEngine/*|QAudionIntents/*|QAudionShare/*|QAudionLiveActivity/*|QAudionNotificationService/*|QAudionPacketTunnel/*)
      APP=true; NOTE "app: $f" ;;
    scripts/ci/assert-no-vpn.sh|scripts/ci/test-assert-no-vpn.sh|scripts/ci/assert-no-earbud.sh|scripts/ci/test-assert-no-earbud.sh|scripts/ci/check_earbud_gating.py|scripts/ci/check_carplay_gating.py|scripts/ci/test_check_carplay_gating.py)
      APP=true; NOTE "app: $f" ;;
    scripts/ci/check-warning-baseline.sh|scripts/ci/warning-baseline.txt|scripts/ci/xcode-diagnostics-summary.sh|scripts/ci/select-xcode.sh|scripts/ci/resolve_simulator.py|scripts/ci/xcresult_test_list.py)
      APP=true; NOTE "app: $f" ;;
  esac

  # engine: every path that the engine tests could read, that is every path not named as irrelevant.
  case "$f" in
    .github/workflows/wire-spec-lock.yml|.github/workflows/ios-ci.yml)
      ENGINE=true; NOTE "engine: $f" ;;
    scripts/ci/select-xcode.sh|scripts/ci/resolve_simulator.py|scripts/ci/xcresult_test_list.py)
      ENGINE=true; NOTE "engine: $f" ;;
    docs/*|maestro/*|.jules/*|.github/workflows/*|scripts/ci/*)
      NOTE "not read by the engine job: $f" ;;
    QAudionAppTests/*|QAudionIntents/*|QAudionShare/*|QAudionLiveActivity/*|QAudionNotificationService/*|QAudionPacketTunnel/*)
      NOTE "not read by the engine job: $f" ;;
    WIRE_SPEC.md)
      ENGINE=true; NOTE "engine: $f" ;;
    */*)
      ENGINE=true; NOTE "engine: $f" ;;
    *.md|*.html)
      NOTE "not read by the engine job: $f" ;;
    *)
      ENGINE=true; NOTE "engine: $f" ;;
  esac

  # scripts: the self-tests of the CI scripts, the log filter and what it reads, and every workflow.
  case "$f" in
    scripts/ci/*|scripts/ship-*|scripts/test_*|scripts/symbolicate.py|.github/workflows/*)
      SCRIPTS=true; NOTE "scripts: $f" ;;
    QAudionApp/AppState.swift|QAudionApp/Services/NotificationCenterService.swift|QAudionApp/Services/BleMeshTransport.swift|QAudionApp/Services/MeshRuntime.swift|QAudionApp/Services/MeshOutboxDrain.swift)
      SCRIPTS=true; NOTE "scripts (log filter vocabulary): $f" ;;
    QAudionEngine/Sources/QAudionEngine/Location/LocationLogScrub.swift|QAudionEngine/Sources/QAudionEngine/Sovereign/Proximity/ProximityPairingTypes.swift)
      SCRIPTS=true; NOTE "scripts (log filter vocabulary): $f" ;;
    QAudionEngine/Sources/QAudionEngine/Mesh/MeshLog.swift|QAudionEngine/Sources/QAudionEngine/Mesh/MeshLinkFraming.swift|QAudionEngine/Sources/QAudionEngine/Mesh/MeshRelayGate.swift|QAudionEngine/Sources/QAudionEngine/Mesh/MeshBtCallPause.swift)
      SCRIPTS=true; NOTE "scripts (log filter vocabulary): $f" ;;
    QAudionEngine/Tests/QAudionEngineTests/Resources/kat/location-kat.json|QAudionEngine/Tests/QAudionEngineTests/Diagnostics/DtlsWaitLineTests.swift|QAudionEngine/Tests/QAudionEngineTests/Diagnostics/AudioWireLinesTests.swift)
      SCRIPTS=true; NOTE "scripts (log filter vocabulary): $f" ;;
    QAudionEngine/Tests/QAudionEngineTests/GroupCall/GroupPromotionDiagnosticsTests.swift|QAudionEngine/Tests/QAudionEngineTests/Resources/kat/pqc-hardening-v1-kat.json)
      SCRIPTS=true; NOTE "scripts (log filter vocabulary): $f" ;;
  esac

  # signing: the check of the distribution signing key and the workflow that runs it.
  case "$f" in
    scripts/ci/check-signing-key.sh|scripts/ci/test-check-signing-key.sh|scripts/ci/test-openssl-signing-calls.sh|.github/workflows/ios-testflight.yml)
      SIGNING=true; NOTE "signing: $f" ;;
  esac
done

if [ "$EVENT" = "push" ] && { [ "$APP" = true ] || [ "$ENGINE" = true ]; }; then
  APP=true
  ENGINE=true
  NOTE "push with code: both macOS test jobs"
fi
if [ "$ALL" = true ]; then
  APP=true; ENGINE=true; SCRIPTS=true; SIGNING=true
fi
NOTE "decision from ${COUNT} paths: app=$APP engine=$ENGINE scripts=$SCRIPTS signing=$SIGNING"
printf 'app=%s\nengine=%s\nscripts=%s\nsigning=%s\n' "$APP" "$ENGINE" "$SCRIPTS" "$SIGNING"
