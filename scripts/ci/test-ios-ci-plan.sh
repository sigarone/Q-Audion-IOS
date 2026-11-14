#!/bin/sh
# Self-test of scripts/ci/ios-ci-plan.sh: the flags that a change to documentation, to the app, to the engine, to a
# script or to a workflow starts, on a pull request, on a push to main and on a manual dispatch.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PLAN="$HERE/ios-ci-plan.sh"
fails=0

# expect NAME EVENT "PATH PATH..." "app=.. engine=.. scripts=.. signing=.." [FULL_CI]
expect() {
  _name=$1; _event=$2; _paths=$3; _want=$4; _full=${5:-}
  _got=$(printf '%s\n' $_paths | EVENT="$_event" FULL_CI="$_full" sh "$PLAN" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
  if [ "$_got" = "$_want" ]; then
    echo "ok:   $_name"
  else
    echo "FAIL: $_name"
    printf '    wanted: %s\n    got:    %s\n' "$_want" "$_got"
    fails=$((fails + 1))
  fi
}

N="app=false engine=false scripts=false signing=false"
PR=pull_request

expect "documentation only: nothing runs" $PR "docs/handovers/x.md README.md CLAUDE.md maestro/flow.yaml .jules/a.md" "$N"
expect "a root page and a changelog: nothing runs" $PR "call-guardian-reference.html SECURITY.md" "$N"
expect "empty list: nothing runs" $PR "" "$N"
expect "app source: app and engine (the wiring tests read it)" $PR "QAudionApp/Views/HomeView.swift" "app=true engine=true scripts=false signing=false"
expect "app test only: the app job, not the engine job" $PR "QAudionAppTests/FooTests.swift" "app=true engine=false scripts=false signing=false"
expect "an extension only: the app job, not the engine job" $PR "QAudionShare/ShareViewController.swift QAudionIntents/Info.plist" "app=true engine=false scripts=false signing=false"
expect "engine source: app and engine" $PR "QAudionEngine/Sources/QAudionEngine/Crypto/Scrypt.swift" "app=true engine=true scripts=false signing=false"
expect "engine test only: app and engine" $PR "QAudionEngine/Tests/QAudionEngineTests/Crypto/ScryptTests.swift" "app=true engine=true scripts=false signing=false"
expect "vectors read by the engine tests: the engine job only" $PR "tools/kat/kms/kms-roundtrip-kat.json" "app=false engine=true scripts=false signing=false"
expect "the wire spec: the engine job only" $PR "WIRE_SPEC.md" "app=false engine=true scripts=false signing=false"
expect "a path nobody listed: the engine job (never skipped by default)" $PR "somewhere/new/file.txt" "app=false engine=true scripts=false signing=false"
expect "a CI script of the Linux job: scripts only" $PR "scripts/ci/ci-run-reuse.sh scripts/ci/test-ci-run-reuse.sh" "app=false engine=false scripts=true signing=false"
expect "a gate the app job runs on the built app: app and scripts" $PR "scripts/ci/assert-no-vpn.sh" "app=true engine=false scripts=true signing=false"
expect "the Xcode selector, used by both macOS jobs: app, engine, scripts" $PR "scripts/ci/select-xcode.sh" "app=true engine=true scripts=true signing=false"
expect "the signing key check: scripts and signing" $PR "scripts/ci/check-signing-key.sh" "app=false engine=false scripts=true signing=true"
expect "the release workflow: scripts and signing" $PR ".github/workflows/ios-testflight.yml" "app=false engine=false scripts=true signing=true"
expect "another workflow: scripts only" $PR ".github/workflows/kat-cross-platform.yml" "app=false engine=false scripts=true signing=false"
expect "the wire spec lock workflow: the engine tests read it" $PR ".github/workflows/wire-spec-lock.yml" "app=false engine=true scripts=true signing=false"
expect "the log filter: scripts and the engine job (a test reads ship-ios-logs.py)" $PR "scripts/ship-ios-logs.py scripts/test_ship_ios_mesh_vocab.py" "app=false engine=true scripts=true signing=false"
expect "a Swift file the log filter reads: app, engine and scripts" $PR "QAudionApp/Services/MeshRuntime.swift" "app=true engine=true scripts=true signing=false"
expect "the group promotion test the log filter reads: app, engine and scripts" $PR "QAudionEngine/Tests/QAudionEngineTests/GroupCall/GroupPromotionDiagnosticsTests.swift" "app=true engine=true scripts=true signing=false"
expect "the pq level vectors the log filter reads: app, engine and scripts" $PR "QAudionEngine/Tests/QAudionEngineTests/Resources/kat/pqc-hardening-v1-kat.json" "app=true engine=true scripts=true signing=false"
expect "another engine test: not the log filter tests (scripts stays false)" $PR "QAudionEngine/Tests/QAudionEngineTests/GroupCall/GroupCallManagerTests.swift" "app=true engine=true scripts=false signing=false"
expect "the workflow itself: everything" $PR ".github/workflows/ios-ci.yml" "app=true engine=true scripts=true signing=true"
expect "the plan script: everything" $PR "scripts/ci/ios-ci-plan.sh" "app=true engine=true scripts=true signing=true"
expect "the variant script: everything" $PR "scripts/ci/ios-variant-changes.sh" "app=true engine=true scripts=true signing=true"
expect "the label full-ci: everything" $PR "docs/x.md" "app=true engine=true scripts=true signing=true" true
expect "a renamed file is read under both names" $PR "docs/old.md QAudionAppTests/New.swift" "app=true engine=false scripts=false signing=false"

# A push to main: code means both macOS test jobs (the tag gate wants each of them on that commit).
expect "push, documentation only: nothing runs" push "docs/x.md" "$N"
expect "push, app test only: both macOS test jobs" push "QAudionAppTests/FooTests.swift" "app=true engine=true scripts=false signing=false"
expect "push, vectors only: both macOS test jobs" push "tools/kat/kms/kms-roundtrip-kat.json" "app=true engine=true scripts=false signing=false"
expect "push, a CI script only: no macOS job" push "scripts/ci/ci-run-reuse.sh" "app=false engine=false scripts=true signing=false"
expect "push, the workflow: everything" push ".github/workflows/ios-ci.yml" "app=true engine=true scripts=true signing=true"

# Manual dispatch (and any other event) needs everything, whatever the list says.
expect "dispatch: everything" workflow_dispatch "" "app=true engine=true scripts=true signing=true"
expect "schedule: everything" schedule "docs/x.md" "app=true engine=true scripts=true signing=true"

[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
