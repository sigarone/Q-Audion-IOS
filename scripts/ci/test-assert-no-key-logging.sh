#!/bin/sh
# Self-test for scripts/ci/assert-no-key-logging.sh (POSIX sh; macOS, Linux, Git-Bash).
# Builds a fake .app with fake Mach-O files and checks every exit code and the
# scoping rules. Run:  sh scripts/ci/test-assert-no-key-logging.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/assert-no-key-logging.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/keylog-gate-test.XXXXXX")
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
LEAK='secret \000 len \000 slat << \000\n derived_key \000 len \000'
LEAK_RAW='raw_key \000 len \000'
CTRL='Failed to derive HkdfSha256 key from secret.\000'
# the app's own strings that must NOT trigger the gate
APPOWN='derived_key\000supports_raw_key_aes256\000raw_key_capable\000{"derived_key":1}\000'

mkdir -p "$T"
# CLEAN bundle: app binary with only its own look-alike strings, clean frameworks, a Mach-O
# with a space in its name, and NON-Mach-O files that do contain the signatures (must be ignored)
CL="$T/clean/Q.app"
macho "$CL/Q" "$APPOWN"
macho "$CL/Frameworks/WebRTC.framework/WebRTC" "$CTRL"
macho "$CL/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" "$CTRL"
macho "$CL/Frameworks/My Fw.framework/My Fw" "other\000"
macho "$CL/PlugIns/X.appex/X" "$APPOWN"
printf 'plist %b' "$LEAK" > "$CL/Info.plist"
printf '{"input":"secret [1,2] len 32 slat << [] len 0 derived_key x"}' > "$CL/vectors.json"

# LEAKY bundle: leak in a nested framework (thin) and in a fat binary; PBKDF2 variant in the extension
LK="$T/leaky/Q.app"
macho "$LK/Q" "$APPOWN"
macho "$LK/Frameworks/WebRTC.framework/WebRTC" "$CTRL" "$LEAK"
fat   "$LK/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" "$CTRL" "$LEAK"
macho "$LK/PlugIns/X.appex/X" "$LEAK_RAW"

# EMPTY bundle: no Mach-O at all
mkdir -p "$T/empty/Q.app"; printf 'hello' > "$T/empty/Q.app/readme.txt"

expect() { # name want_rc [env assignments via env(1)] cmd...
  name=$1; want=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok   - $name (rc=$rc)"; else echo "FAIL - $name: rc=$rc want=$want"; echo "$out" | sed 's/^/       /'; fail=1; fi
  LAST_OUT=$out
}

# report-only (default and explicit "0"): never fails, still reports
expect "report-only default, leaky bundle -> exit 0"        0 sh "$GATE" "$LK"
case "$LAST_OUT" in *"WebRTC.framework/WebRTC size="*"slat=1"*) echo "ok   - report shows the hit with counts";; *) echo "FAIL - report lacks the WebRTC hit"; echo "$LAST_OUT"; fail=1;; esac
case "$LAST_OUT" in *"::warning::"*) echo "ok   - report-only emits a GitHub warning";; *) echo "FAIL - no warning annotation"; fail=1;; esac
expect "report-only explicit 0, leaky bundle -> exit 0"     0 env WEBRTC_KEYLOG_GATE=0 sh "$GATE" "$LK"
expect "report-only, empty bundle -> exit 0"                0 sh "$GATE" "$T/empty/Q.app"
expect "report-only, no argument -> exit 0"                 0 sh "$GATE"
expect "report-only, missing path -> exit 0"                0 sh "$GATE" "$T/nope"

# enforce
expect "ENFORCE, clean bundle -> exit 0"                    0 env WEBRTC_KEYLOG_GATE=1 sh "$GATE" "$CL"
case "$LAST_OUT" in *"scanned 5 Mach-O"*) echo "ok   - scanned exactly the 5 Mach-O files (Info.plist / json ignored)";; *) echo "FAIL - unexpected scan scope"; echo "$LAST_OUT"; fail=1;; esac
case "$LAST_OUT" in *"My Fw.framework/My Fw size="*) echo "ok   - file name with a space handled";; *) echo "FAIL - space in name not handled"; fail=1;; esac
expect "ENFORCE, leaky bundle -> exit 1"                    1 env WEBRTC_KEYLOG_GATE=1 sh "$GATE" "$LK"
case "$LAST_OUT" in *"3 with key-dump strings"*) echo "ok   - 3 leaking files (thin, fat, appex) reported";; *) echo "FAIL - expected 3 leaking files"; echo "$LAST_OUT"; fail=1;; esac
case "$LAST_OUT" in *"::error::"*) echo "ok   - enforce emits a GitHub error";; *) echo "FAIL - no error annotation"; fail=1;; esac
expect "ENFORCE, empty bundle (nothing scanned) -> exit 2"  2 env WEBRTC_KEYLOG_GATE=1 sh "$GATE" "$T/empty/Q.app"
expect "ENFORCE, no argument -> exit 2"                     2 env WEBRTC_KEYLOG_GATE=1 sh "$GATE"
expect "ENFORCE, missing path -> exit 2"                    2 env WEBRTC_KEYLOG_GATE=1 sh "$GATE" "$T/nope"
expect "ENFORCE, single leaky file as path -> exit 1"       1 env WEBRTC_KEYLOG_GATE=1 sh "$GATE" "$LK/Frameworks/WebRTC.framework/WebRTC"
expect "ENFORCE, two paths (clean + leaky) -> exit 1"       1 env WEBRTC_KEYLOG_GATE=1 sh "$GATE" "$CL" "$LK"

# app's own look-alike strings alone (no WebRTC leak) must be clean
macho "$T/own/Q.app/Q" "$APPOWN"
expect "ENFORCE, app-own derived_key/raw_key strings only -> exit 0" 0 env WEBRTC_KEYLOG_GATE=1 sh "$GATE" "$T/own/Q.app"

# output must never contain the binary payload literals beyond names/counts
out=$(env WEBRTC_KEYLOG_GATE=1 sh "$GATE" "$LK" 2>&1 || true)
case "$out" in *"secret "*|*" len "*) echo "FAIL - output leaked payload text"; fail=1;; *) echo "ok   - output has names and counts only";; esac

# GITHUB_STEP_SUMMARY is written when set
S="$T/summary.md"; : > "$S"
GITHUB_STEP_SUMMARY="$S" sh "$GATE" "$LK" >/dev/null 2>&1
if grep -q "Mach-O files scanned" "$S"; then echo "ok   - step summary written"; else echo "FAIL - no step summary"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME TESTS FAILED"
exit "$fail"
