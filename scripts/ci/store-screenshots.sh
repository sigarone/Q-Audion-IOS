#!/bin/sh
# Capture the store screenshot scenes of the demo build on one simulator.
#
# usage: store-screenshots.sh UDID APP_PATH BUNDLE_ID OUT_DIR "<locale list>" "<display list>"
#   locale list   space separated  <name>:<AppleLanguages>:<AppleLocale>  e.g. "it:it:it_IT pt-BR:pt-BR:pt_BR"
#   display list  space separated display numbers to capture (a single-display phone: "-"; the foldable
#                 simulator has two displays and simctl needs one named)
#
# The app is the build made with -DSCREENSHOT_DEMO (see QAudionApp/Views/ScreenshotDemo): it starts on
# the scene given by -qaDemoScene, on seeded local data, with no account and no network. The language of
# a run is set with launch arguments, so the simulator is booted once.
# Output: OUT_DIR/<locale>/<scene>.png (OUT_DIR/<locale>/<scene>-d<display>.png for several displays).

set -u

UDID="${1:?usage: store-screenshots.sh UDID APP_PATH BUNDLE_ID OUT_DIR LOCALES DISPLAYS}"
APP_PATH="${2:?}"
BUNDLE_ID="${3:?}"
OUT_DIR="${4:?}"
LOCALES="${5:?}"
DISPLAYS="${6:--}"

# scene:scroll offset in points (empty = none)
SCENES="chat: settings: call-sas:560 call: chatlist: privacy: location:"

test -d "$APP_PATH" || { echo "app not found: $APP_PATH"; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP_PATH"
# The sign-in of the demo turns the Siri authorization request on; grant it so no system sheet covers a scene.
xcrun simctl privacy "$UDID" grant siri "$BUNDLE_ID" || true
xcrun simctl privacy "$UDID" grant microphone "$BUNDLE_ID" || true
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" || true

status=0
for loc in $LOCALES; do
  name="${loc%%:*}"; rest="${loc#*:}"; langs="${rest%%:*}"; region="${rest#*:}"
  mkdir -p "$OUT_DIR/$name"
  for sc in $SCENES; do
    scene="${sc%%:*}"; scroll="${sc#*:}"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    sleep 1
    scroll_val="0"
    if [ -n "$scroll" ]; then scroll_val="$scroll"; fi
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -qaDemoScene "$scene" -qaDemoScroll "$scroll_val" \
      -AppleLanguages "($langs)" -AppleLocale "$region" || { echo "launch failed: $name $scene"; status=1; continue; }
    case "$scene" in chat|location) sleep 45 ;; *) sleep 12 ;; esac
    for d in $DISPLAYS; do
      if [ "$d" = "-" ]; then
        out="$OUT_DIR/$name/$scene.png"
        xcrun simctl io "$UDID" screenshot --type=png "$out" || { echo "screenshot failed: $name $scene"; status=1; }
      else
        out="$OUT_DIR/$name/$scene-d$d.png"
        xcrun simctl io "$UDID" screenshot --type=png "--display=$d" "$out" || echo "no display $d: $name $scene"
      fi
    done
  done
done
ls -lR "$OUT_DIR" | head -100
exit $status
