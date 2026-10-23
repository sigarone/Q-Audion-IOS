#!/bin/sh
# Boot a simulator, set the Italian locale the smoke flow is written for, install the app
# and launch it once. Same sequence as the boot step of ios-ui-smoke.yml, with the simulator
# given by UDID.
#
# usage: ui-smoke-sim.sh UDID APP_PATH BUNDLE_ID
# The locale is written first and the simulator restarted afterwards: a locale change on a
# booted simulator restarts the home screen in the background and would kill an app that is
# installed and launched during it.

set -eu

UDID="${1:?usage: ui-smoke-sim.sh UDID APP_PATH BUNDLE_ID}"
APP_PATH="${2:?usage: ui-smoke-sim.sh UDID APP_PATH BUNDLE_ID}"
BUNDLE_ID="${3:?usage: ui-smoke-sim.sh UDID APP_PATH BUNDLE_ID}"

test -d "$APP_PATH"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl spawn "$UDID" defaults write "Apple Global Domain" AppleLanguages -array it
xcrun simctl spawn "$UDID" defaults write "Apple Global Domain" AppleLocale -string "it_IT"
xcrun simctl shutdown "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 5
