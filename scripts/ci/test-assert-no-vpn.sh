#!/bin/sh
# Self-test for scripts/ci/assert-no-vpn.sh (POSIX sh; macOS, Linux, Git-Bash).
# Builds fake .app bundles with fake Mach-O files and checks every exit code and
# the scoping rules. Run:  sh scripts/ci/test-assert-no-vpn.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/assert-no-vpn.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/novpn-gate-test.XXXXXX")
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
NE_ENT='com.apple.developer.networking.networkextension\000'
VPN_API='com.apple.developer.networking.vpn.api\000'
NE_FW='/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension\000'
WG='WireGuardKit\000wg_private_key_b64\000NETunnelProviderManager\000'
# strings the default build legitimately has and that must NOT trigger the gate
OWN='com.apple.developer.siri\000com.apple.developer.associated-domains\000group.com.bcrypto.qaudion.siri\000vpn.preferredNodeId\000VpnMlKem\000'

# CLEAN bundle: app binary + debug dylib + frameworks + a Mach-O with a space in its
# name + the Intents appex; text files that mention the signatures are NOT scanned
CL="$T/clean/Q.app"
macho "$CL/Q" "$OWN"
macho "$CL/Q.debug.dylib" "$OWN"
macho "$CL/Frameworks/WebRTC.framework/WebRTC" "other\000"
macho "$CL/Frameworks/My Fw.framework/My Fw" "other\000"
macho "$CL/PlugIns/QAudionIntents.appex/QAudionIntents" "$OWN"
plain "$CL/PlugIns/QAudionIntents.appex/Info.plist" 'com.apple.intents-service\000'
plain "$CL/embedded.mobileprovision" 'com.apple.developer.siri\000'
plain "$CL/readme.txt" "$NE_ENT$WG"

# every kind of VPN trace, one bundle each
mk() { # $1 = name; creates $T/$1/Q.app with a clean app binary
  macho "$T/$1/Q.app/Q" "$OWN"
  macho "$T/$1/Q.app/Frameworks/WebRTC.framework/WebRTC" "other\000"
}
mk ent_in_app;      macho "$T/ent_in_app/Q.app/Q" "$OWN" "$NE_ENT"
mk vpnapi_in_fw;    macho "$T/vpnapi_in_fw/Q.app/Frameworks/WebRTC.framework/WebRTC" "$VPN_API"
mk fw_link;         macho "$T/fw_link/Q.app/Q" "$OWN" "$NE_FW"
mk wg_code;         fat   "$T/wg_code/Q.app/Frameworks/WebRTC.framework/WebRTC" "$WG"
mk tunnel_appex;    macho "$T/tunnel_appex/Q.app/PlugIns/QAudionPacketTunnel.appex/QAudionPacketTunnel" "other\000"
mk ne_point;        macho "$T/ne_point/Q.app/PlugIns/Other.appex/Other" "other\000"
plain "$T/ne_point/Q.app/PlugIns/Other.appex/Info.plist" 'com.apple.networkextension.packet-tunnel\000'
mk profile_ne;      plain "$T/profile_ne/Q.app/embedded.mobileprovision" '<key>com.apple.developer.networking.networkextension</key>'
mk profile_ok;      plain "$T/profile_ok/Q.app/embedded.mobileprovision" "$WG"   # code strings are not looked for in a profile

# EMPTY bundle: no Mach-O at all
mkdir -p "$T/empty/Q.app"; printf 'hello' > "$T/empty/Q.app/readme.txt"
# a bundle with only a profile (no Mach-O) must not count as scanned
mkdir -p "$T/onlyprofile/Q.app"; printf 'x' > "$T/onlyprofile/Q.app/embedded.mobileprovision"

expect() { # name want_rc cmd...
  name=$1; want=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok   - $name (rc=$rc)"; else echo "FAIL - $name: rc=$rc want=$want"; echo "$out" | sed 's/^/       /'; fail=1; fi
  LAST_OUT=$out
}

expect "clean bundle -> exit 0"                         0 sh "$GATE" "$CL"
case "$LAST_OUT" in *"scanned 6 file(s)"*) echo "ok   - scanned the 5 Mach-O files and the profile only (plists and text ignored)";; *) echo "FAIL - unexpected scan scope"; echo "$LAST_OUT"; fail=1;; esac
case "$LAST_OUT" in *"My Fw.framework/My Fw ("*) echo "ok   - file name with a space handled";; *) echo "FAIL - space in name not handled"; fail=1;; esac

expect "entitlement key in the app binary -> exit 1"    1 sh "$GATE" "$T/ent_in_app/Q.app"
expect "vpn.api key in a framework -> exit 1"           1 sh "$GATE" "$T/vpnapi_in_fw/Q.app"
expect "NetworkExtension load command -> exit 1"        1 sh "$GATE" "$T/fw_link/Q.app"
expect "WireGuard code in a fat binary -> exit 1"       1 sh "$GATE" "$T/wg_code/Q.app"
case "$LAST_OUT" in *"WireGuardKit"*) echo "ok   - the matched signature is named";; *) echo "FAIL - signature not named"; echo "$LAST_OUT"; fail=1;; esac
expect "packet-tunnel appex present -> exit 1"          1 sh "$GATE" "$T/tunnel_appex/Q.app"
expect "any appex with a Network Extension point -> 1"  1 sh "$GATE" "$T/ne_point/Q.app"
expect "Network Extension entitlement in the profile -> 1" 1 sh "$GATE" "$T/profile_ne/Q.app"
expect "code strings in a profile only -> exit 0"       0 sh "$GATE" "$T/profile_ok/Q.app"

expect "empty bundle (nothing scanned) -> exit 2"       2 sh "$GATE" "$T/empty/Q.app"
expect "only a profile, no Mach-O -> exit 2"            2 sh "$GATE" "$T/onlyprofile/Q.app"
expect "no argument -> exit 2"                          2 sh "$GATE"
expect "missing path -> exit 2"                         2 sh "$GATE" "$T/nope"
expect "single leaking file as path -> exit 1"          1 sh "$GATE" "$T/ent_in_app/Q.app/Q"
expect "two paths (clean + leaking) -> exit 1"          1 sh "$GATE" "$CL" "$T/fw_link/Q.app"

# --require-entitlements: needs a readable codesign dump of the main bundle. A fake bundle is not
# signed, so it must fail closed (exit 2) when codesign exists, and on a host without codesign too.
expect "--require-entitlements on an unsigned bundle -> exit 2" 2 sh "$GATE" --require-entitlements "$CL"

# the output carries names and counts only, never the payload text
out=$(sh "$GATE" "$T/ent_in_app/Q.app" 2>&1 || true)
case "$out" in *"other"*) echo "FAIL - output leaked payload text"; fail=1;; *) echo "ok   - output has names, counts and signature names only";; esac

# GITHUB_STEP_SUMMARY is written when set
S="$T/summary.md"; : > "$S"
GITHUB_STEP_SUMMARY="$S" sh "$GATE" "$T/ent_in_app/Q.app" >/dev/null 2>&1
if grep -q "No-VPN gate" "$S"; then echo "ok   - step summary written"; else echo "FAIL - no step summary"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME TESTS FAILED"
exit "$fail"
