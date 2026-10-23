#!/bin/sh
# Adds the CarPlay scene configuration to a built Info.plist.
#
# Used by the build phase of QAudionApp/project-carplay.yml, which is the only build that has this entry. The
# source QAudionApp/Info.plist never carries it, so the default build and every release build are without it.
#
#   carplay-add-scene.sh <built Info.plist> <module name>
#
# The result, as CarPlay documents it:
#   UIApplicationSceneManifest
#     UIApplicationSupportsMultipleScenes = true
#     UISceneConfigurations
#       CPTemplateApplicationSceneSessionRoleApplication = [ { UISceneConfigurationName = QAudionCarPlay,
#                                                              UISceneDelegateClassName = <module>.CarPlaySceneDelegate } ]
#
# Safe to run more than once: the CarPlay role is removed before it is added.

set -eu

PLIST="${1:?usage: carplay-add-scene.sh <built Info.plist> <module name>}"
MODULE="${2:?usage: carplay-add-scene.sh <built Info.plist> <module name>}"
PB=/usr/libexec/PlistBuddy
ROLE="CPTemplateApplicationSceneSessionRoleApplication"
MANIFEST=":UIApplicationSceneManifest"

test -f "$PLIST" || { echo "carplay-add-scene: no such file: $PLIST" >&2; exit 1; }

# The manifest comes from the source Info.plist. Create it if a future change removes it there.
if ! "$PB" -c "Print $MANIFEST" "$PLIST" >/dev/null 2>&1; then
  "$PB" -c "Add $MANIFEST dict" "$PLIST"
fi

if "$PB" -c "Print $MANIFEST:UIApplicationSupportsMultipleScenes" "$PLIST" >/dev/null 2>&1; then
  "$PB" -c "Set $MANIFEST:UIApplicationSupportsMultipleScenes true" "$PLIST"
else
  "$PB" -c "Add $MANIFEST:UIApplicationSupportsMultipleScenes bool true" "$PLIST"
fi

if ! "$PB" -c "Print $MANIFEST:UISceneConfigurations" "$PLIST" >/dev/null 2>&1; then
  "$PB" -c "Add $MANIFEST:UISceneConfigurations dict" "$PLIST"
fi
"$PB" -c "Delete $MANIFEST:UISceneConfigurations:$ROLE" "$PLIST" >/dev/null 2>&1 || true
"$PB" -c "Add $MANIFEST:UISceneConfigurations:$ROLE array" "$PLIST"
"$PB" -c "Add $MANIFEST:UISceneConfigurations:$ROLE:0 dict" "$PLIST"
"$PB" -c "Add $MANIFEST:UISceneConfigurations:$ROLE:0:UISceneConfigurationName string QAudionCarPlay" "$PLIST"
"$PB" -c "Add $MANIFEST:UISceneConfigurations:$ROLE:0:UISceneDelegateClassName string ${MODULE}.CarPlaySceneDelegate" "$PLIST"

echo "carplay-add-scene: CarPlay scene configuration added to $PLIST"
