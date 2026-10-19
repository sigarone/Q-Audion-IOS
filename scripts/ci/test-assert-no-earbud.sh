#!/bin/sh
# Self-test for scripts/ci/assert-no-earbud.sh (POSIX sh; macOS, Linux, Git-Bash).
# Builds fake .app bundles with fake Mach-O files and checks every exit code and the scoping
# rules. Run:  sh scripts/ci/test-assert-no-earbud.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/assert-no-earbud.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/noearbud-gate-test.XXXXXX")
trap 'rm -rf "$T"' EXIT INT TERM
fail=0

# --- fake binaries: 4-byte Mach-O magic (cf fa ed fe) + payload ----------------------
macho() { # $1 = path, rest = printf payloads
  _p=$1; shift
  mkdir -p "$(dirname "$_p")"
  { printf '\317\372\355\376'; head -c 2048 /dev/zero; for _x in "$@"; do printf "$_x"; done; head -c 2048 /dev/zero; } > "$_p"
}
fat() { # fat/universal magic (ca fe ba be)
  _p=$1; shift
  mkdir -p "$(dirname "$_p")"
  { printf '\312\376\272\276'; head -c 2048 /dev/zero; for _x in "$@"; do printf "$_x"; done; } > "$_p"
}
plain() { # $1 = path, rest = printf payloads (NOT a Mach-O)
  _p=$1; shift
  mkdir -p "$(dirname "$_p")"
  { for _x in "$@"; do printf "$_x"; done; } > "$_p"
}
CLS='_TtC10QAudionApp18IOSEarbudGattProxy\000'
RELAY='_TtC10QAudionApp27CoreBluetoothSovereignRelay\000'
KEYIMP='$s10QAudionApp22EarbudKeyImportServiceC\000'
FE5='$s10QAudionApp18Fe5ExchangeServiceC\000/api/v1/diag/fe5/publish\000'
DIAG='_TtC10QAudionApp19EarbudDiagViewModel\000'
UUID='f2c0aaaa-bcc0-4001-8000-000000000001\000'
KEY='qaudion_paired_earbud_uuid\000'
# strings the default build legitimately has and that must NOT trigger the gate: the engine's
# hardware-independent earbud relay logic and wire names, the mesh BLE transport, the P3 board
# constants, "earbud" in prose.
# What a Debug build's debug map keeps: the object file paths of every source file the project compiled,
# including the ones that are empty because their whole content is #if-ed out. They carry the BARE names.
OBJ='/Build/Intermediates.noindex/QAudionApp.build/Debug-iphonesimulator/QAudionApp.build/Objects-normal/arm64/IOSEarbudGattProxy.o\000/x/Fe5ExchangeService.o\000/x/EarbudKeyImportService.o\000/x/CoreBluetoothSovereignRelay.o\000/x/EarbudDiagScreen.o\000'
OWN='EarbudAckPopRelay\000EarbudPairingRelay\000EarbudPairingGattProxy\000EarbudKeyGattProxy\000EarbudGattConstants\000hw_only\000earbud_pair\000earbud-relay-v1\000EARBUDPDU:\000BleMeshTransport\000MeshBluetoothCapabilityProbe\000the earbud is not connected\000'

# CLEAN bundle: app binary + debug dylib + frameworks + a Mach-O with a space in its name +
# the Intents appex; text files that mention the signatures are NOT scanned
CL="$T/clean/Q.app"
macho "$CL/Q" "$OWN"
macho "$CL/Q.debug.dylib" "$OWN"
macho "$CL/Frameworks/WebRTC.framework/WebRTC" "other\000"
macho "$CL/Frameworks/My Fw.framework/My Fw" "other\000"
macho "$CL/PlugIns/QAudionIntents.appex/QAudionIntents" "$OWN"
plain "$CL/PlugIns/QAudionIntents.appex/Info.plist" 'com.apple.intents-service\000'
plain "$CL/readme.txt" "$CLS$UUID$KEY"

# every kind of earbud trace, one bundle each
mk() { # $1 = name; creates $T/$1/Q.app with a clean app binary
  macho "$T/$1/Q.app/Q" "$OWN"
  macho "$T/$1/Q.app/Frameworks/WebRTC.framework/WebRTC" "other\000"
}
mk cls_in_app;      macho "$T/cls_in_app/Q.app/Q" "$OWN" "$CLS"
mk relay_in_app;    macho "$T/relay_in_app/Q.app/Q" "$OWN" "$RELAY"
mk keyimp_in_app;   macho "$T/keyimp_in_app/Q.app/Q" "$OWN" "$KEYIMP"
mk fe5_in_app;      macho "$T/fe5_in_app/Q.app/Q" "$OWN" "$FE5"
mk diag_in_app;     macho "$T/diag_in_app/Q.app/Q" "$OWN" "$DIAG"
mk uuid_in_app;     macho "$T/uuid_in_app/Q.app/Q" "$OWN" "$UUID"
mk key_in_app;      macho "$T/key_in_app/Q.app/Q" "$OWN" "$KEY"
mk cls_in_dylib;    macho "$T/cls_in_dylib/Q.app/Q.debug.dylib" "$CLS"
mk uuid_in_fw;      fat   "$T/uuid_in_fw/Q.app/Frameworks/WebRTC.framework/WebRTC" "$UUID"
mk cls_in_appex;    macho "$T/cls_in_appex/Q.app/PlugIns/X.appex/X" "$CLS"

# the build that HAS the stack (class + UUID both there)
mk full;            macho "$T/full/Q.app/Q" "$OWN" "$CLS" "$UUID" "$RELAY" "$OBJ"
mk split;           macho "$T/split/Q.app/Q" "$OWN" "$CLS"; macho "$T/split/Q.app/Frameworks/WebRTC.framework/WebRTC" "$UUID"
mk only_cls;        macho "$T/only_cls/Q.app/Q" "$OWN" "$CLS"
mk only_uuid;       macho "$T/only_uuid/Q.app/Q" "$OWN" "$UUID"

# EMPTY bundle: no Mach-O at all
mkdir -p "$T/empty/Q.app"; printf 'hello' > "$T/empty/Q.app/readme.txt"

expect() { # name want_rc cmd...
  name=$1; want=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok   - $name (rc=$rc)"; else echo "FAIL - $name: rc=$rc want=$want"; echo "$out" | sed 's/^/       /'; fail=1; fi
  LAST_OUT=$out
}

expect "clean bundle -> exit 0"                          0 sh "$GATE" "$CL"
case "$LAST_OUT" in *"scanned 5 Mach-O file(s)"*) echo "ok   - scanned the 5 Mach-O files only (plists and text ignored)";; *) echo "FAIL - unexpected scan scope"; echo "$LAST_OUT"; fail=1;; esac
case "$LAST_OUT" in *"My Fw.framework/My Fw "*) echo "ok   - file name with a space handled";; *) echo "FAIL - space in name not handled"; fail=1;; esac

# a Debug build of the default spec: empty objects of the compiled-out files are in the debug map
mkdir -p "$T/debugmap"; macho "$T/debugmap/Q.app/Q.debug.dylib" "$OWN" "$OBJ"; macho "$T/debugmap/Q.app/Q" "stub\000"
expect "object file paths of the compiled-out sources are not a trace -> exit 0" 0 sh "$GATE" "$T/debugmap/Q.app"

expect "GATT client class in the app binary -> exit 1"   1 sh "$GATE" "$T/cls_in_app/Q.app"
case "$LAST_OUT" in *"IOSEarbudGattProxy"*) echo "ok   - the matched signature is named";; *) echo "FAIL - signature not named"; echo "$LAST_OUT"; fail=1;; esac
expect "sovereign relay driver -> exit 1"                1 sh "$GATE" "$T/relay_in_app/Q.app"
expect "key import service -> exit 1"                    1 sh "$GATE" "$T/keyimp_in_app/Q.app"
expect "pairing exchange service -> exit 1"              1 sh "$GATE" "$T/fe5_in_app/Q.app"
expect "diagnostics view model -> exit 1"                1 sh "$GATE" "$T/diag_in_app/Q.app"
expect "GATT service UUID -> exit 1"                     1 sh "$GATE" "$T/uuid_in_app/Q.app"
expect "remembered-earbud defaults key -> exit 1"        1 sh "$GATE" "$T/key_in_app/Q.app"
expect "class in a debug dylib -> exit 1"                1 sh "$GATE" "$T/cls_in_dylib/Q.app"
expect "UUID in a fat framework binary -> exit 1"        1 sh "$GATE" "$T/uuid_in_fw/Q.app"
expect "class in an extension binary -> exit 1"          1 sh "$GATE" "$T/cls_in_appex/Q.app"
expect "single leaking file as path -> exit 1"           1 sh "$GATE" "$T/cls_in_app/Q.app/Q"
expect "two paths (clean + leaking) -> exit 1"           1 sh "$GATE" "$CL" "$T/uuid_in_app/Q.app"

expect "empty bundle (nothing scanned) -> exit 2"        2 sh "$GATE" "$T/empty/Q.app"
expect "no argument -> exit 2"                           2 sh "$GATE"
expect "missing path -> exit 2"                          2 sh "$GATE" "$T/nope"
expect "--require-present, no path -> exit 2"            2 sh "$GATE" --require-present

# --require-present: the opposite check
expect "--require-present on a full build -> exit 0"     0 sh "$GATE" --require-present "$T/full/Q.app"
expect "--require-present, class and UUID in different files -> exit 0" 0 sh "$GATE" --require-present "$T/split/Q.app"
expect "--require-present on a clean build -> exit 1"    1 sh "$GATE" --require-present "$CL"
case "$LAST_OUT" in *"did not take effect"*) echo "ok   - the failure says the condition did not take effect";; *) echo "FAIL - message"; echo "$LAST_OUT"; fail=1;; esac
expect "--require-present, class only -> exit 1"         1 sh "$GATE" --require-present "$T/only_cls/Q.app"
expect "--require-present, UUID only -> exit 1"          1 sh "$GATE" --require-present "$T/only_uuid/Q.app"
expect "--require-present on an empty bundle -> exit 2"  2 sh "$GATE" --require-present "$T/empty/Q.app"
expect "the default mode on a full build still fails -> exit 1" 1 sh "$GATE" "$T/full/Q.app"

# the output carries names and counts only, never the payload text
out=$(sh "$GATE" "$T/cls_in_app/Q.app" 2>&1 || true)
case "$out" in *"other"*|*"hw_only"*) echo "FAIL - output leaked payload text"; fail=1;; *) echo "ok   - output has names, counts and signature names only";; esac

# GITHUB_STEP_SUMMARY is written when set
S="$T/summary.md"; : > "$S"
GITHUB_STEP_SUMMARY="$S" sh "$GATE" "$T/cls_in_app/Q.app" >/dev/null 2>&1
if grep -q "No-earbud gate" "$S"; then echo "ok   - step summary written"; else echo "FAIL - no step summary"; fail=1; fi
: > "$S"
GITHUB_STEP_SUMMARY="$S" sh "$GATE" --require-present "$T/full/Q.app" >/dev/null 2>&1
if grep -q "Earbud stack present" "$S"; then echo "ok   - step summary written (require-present)"; else echo "FAIL - no step summary (require-present)"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME TESTS FAILED"
exit "$fail"
