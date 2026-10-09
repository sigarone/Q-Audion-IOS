#!/bin/sh
# assert-no-vpn.sh - CI gate: a build without VPN support must not contain any.
# Prints only file names, sizes, counts and the fixed signature names - never
# binary content.
#
# WHY. VPN support is a compile-time switch (QAUDION_VPN, see
# QAudionApp/project-vpn.yml). The default build is generated from
# QAudionApp/project.yml and must have no packet-tunnel extension, no Network
# Extension / vpn.api entitlement (in the signed binaries or in the embedded
# provisioning profile), no NetworkExtension.framework load command and no
# WireGuard code. This gate proves that on the BUILT artifact, so a regression
# in the spec, an entitlements file or a stray dependency cannot ship unnoticed.
#
# USAGE   scripts/ci/assert-no-vpn.sh [--require-entitlements] PATH [PATH...]
#   PATH  a .app bundle (or any directory, or a single file). Directories are
#         walked recursively.
#   --require-entitlements  also fail (exit 2) when `codesign` cannot read any
#         entitlements from the main bundle (PATH must then be a .app): a scan
#         that cannot see the entitlements proves nothing. Use it on the signed
#         release bundle; a simulator build is ad-hoc signed and does not need it.
#
# CHECKS
#   1. STRUCTURE  no *.appex named QAudionPacketTunnel*, and no *.appex whose
#      Info.plist declares a com.apple.networkextension extension point.
#   2. SIGNED ENTITLEMENTS  (codesign -d --entitlements, when codesign exists)
#      of every .app / .appex bundle found: neither entitlement key below.
#   3. FILE CONTENT (fixed strings, grep -a -F, LC_ALL=C), on
#        - every Mach-O file (first 4 bytes are a Mach-O / fat magic): the app
#          executable, debug dylibs, Frameworks/*, PlugIns/*: ENTITLEMENT and
#          CODE signatures;
#        - every embedded.mobileprovision: ENTITLEMENT signatures only.
#      ENTITLEMENT signatures:
#        com.apple.developer.networking.networkextension
#        com.apple.developer.networking.vpn.api
#      CODE signatures:
#        NetworkExtension.framework/NetworkExtension  (the load command)
#        WireGuardKit   wg_private_key_b64   NETunnelProviderManager
#        com.qaudion.app.packet-tunnel
#
# EXIT    0 clean | 1 a VPN trace was found | 2 inconclusive (no path, no
#         Mach-O found, scan error, --require-entitlements not satisfied).
set -u
LC_ALL=C
export LC_ALL

REQUIRE_ENT=0
if [ "${1:-}" = "--require-entitlements" ]; then
  REQUIRE_ENT=1
  shift
fi

ENT_SIGS='com.apple.developer.networking.networkextension
com.apple.developer.networking.vpn.api'
CODE_SIGS='NetworkExtension.framework/NetworkExtension
WireGuardKit
wg_private_key_b64
NETunnelProviderManager
com.qaudion.app.packet-tunnel'

say() { printf '%s\n' "$*"; }
err() { say "::error::assert-no-vpn: $1"; }

if [ "$#" -eq 0 ]; then
  err "no path given - nothing was scanned"
  exit 2
fi

is_macho() { # 0 if the first 4 bytes are a Mach-O / fat magic
  _m=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
  case "$_m" in
    feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|cafebabf|bebafeca|bfbafeca) return 0 ;;
  esac
  return 1
}

# grep -c prints the count and exits 1 when it is 0; only rc >= 2 is an error.
count() { # $1 = fixed string, $2 = file -> count, or ERR
  _n=$(grep -a -c -F -e "$1" "$2" 2>/dev/null) && _rc=0 || _rc=$?
  case "$_rc" in
    0|1) printf '%s' "${_n:-0}" ;;
    *) printf 'ERR' ;;
  esac
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/novpn-gate.XXXXXX") || { err "cannot create a temp dir"; exit 2; }
trap 'rm -rf "$TMP"' EXIT INT TERM
LIST="$TMP/files"
DIRS="$TMP/dirs"
: > "$LIST"
: > "$DIRS"

for p in "$@"; do
  if [ -d "$p" ]; then
    find "$p" -type f 2>/dev/null | sort >> "$LIST"
    { printf '%s\n' "$p"; find "$p" -type d \( -name '*.appex' -o -name '*.app' \) 2>/dev/null | sort; } >> "$DIRS"
  elif [ -f "$p" ]; then
    printf '%s\n' "$p" >> "$LIST"
  else
    err "path does not exist: $p"
    exit 2
  fi
done

hits=""     # one "path: what" line per finding
scanned=0
machos=0
errors=0

add_hit() { hits="$hits$1
"; }

say "assert-no-vpn: scope = structure, signed entitlements, Mach-O files, embedded.mobileprovision"

# 1. STRUCTURE -------------------------------------------------------------------
while IFS= read -r d; do
  case "$d" in
    *.appex)
      base=${d##*/}
      case "$base" in
        QAudionPacketTunnel*) add_hit "$d: packet-tunnel extension bundle present" ;;
      esac
      if [ -f "$d/Info.plist" ]; then
        n=$(count 'com.apple.networkextension' "$d/Info.plist")
        if [ "$n" = ERR ]; then errors=$((errors + 1)); say "  $d/Info.plist SCAN-ERROR"
        elif [ "$n" != 0 ]; then add_hit "$d: declares a Network Extension extension point"; fi
      fi
      ;;
  esac
done < "$DIRS"

# 2. SIGNED ENTITLEMENTS (codesign) ----------------------------------------------
main_ent_bytes=0
if command -v codesign >/dev/null 2>&1; then
  first=1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    dump="$TMP/ent.dump"
    codesign -d --entitlements :- --xml "$d" > "$dump" 2>/dev/null || true
    [ -s "$dump" ] || codesign -d --entitlements :- "$d" > "$dump" 2>/dev/null || true
    bytes=$(wc -c < "$dump" | tr -d ' ')
    [ "$first" -eq 1 ] && main_ent_bytes=$bytes
    first=0
    say "  codesign entitlements of $d: $bytes byte(s)"
    for s in $ENT_SIGS; do
      n=$(count "$s" "$dump")
      if [ "$n" = ERR ]; then errors=$((errors + 1));
      elif [ "$n" != 0 ]; then add_hit "$d: signed entitlements contain $s"; fi
    done
  done < "$DIRS"
else
  say "  codesign not available - signed-entitlement check skipped"
fi
if [ "$REQUIRE_ENT" -eq 1 ] && [ "$main_ent_bytes" -eq 0 ]; then
  err "--require-entitlements: codesign returned no entitlements for the main bundle - the scan cannot see them"
  exit 2
fi

# 3. FILE CONTENT -----------------------------------------------------------------
while IFS= read -r f; do
  kind=""
  if is_macho "$f"; then kind=macho
  elif [ "${f##*/}" = "embedded.mobileprovision" ]; then kind=profile
  else continue; fi
  scanned=$((scanned + 1))
  [ "$kind" = macho ] && machos=$((machos + 1))
  size=$(wc -c < "$f" | tr -d ' ')
  found=""
  bad=0
  for s in $ENT_SIGS; do
    n=$(count "$s" "$f")
    if [ "$n" = ERR ]; then bad=1; elif [ "$n" != 0 ]; then found="$found $s"; fi
  done
  if [ "$kind" = macho ]; then
    for s in $CODE_SIGS; do
      n=$(count "$s" "$f")
      if [ "$n" = ERR ]; then bad=1; elif [ "$n" != 0 ]; then found="$found $s"; fi
    done
  fi
  if [ "$bad" -eq 1 ]; then
    say "  $f ($kind) size=$size SCAN-ERROR"
    errors=$((errors + 1))
  elif [ -n "$found" ]; then
    say "  $f ($kind) size=$size HIT:$found"
    add_hit "$f: contains$found"
  else
    say "  $f ($kind) size=$size clean"
  fi
done < "$LIST"

hit_count=0
if [ -n "$hits" ]; then hit_count=$(printf '%s' "$hits" | grep -c .); fi
say "assert-no-vpn: scanned $scanned file(s) (Mach-O + provisioning profiles), $hit_count finding(s), $errors scan error(s)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### No-VPN gate"
    echo "Files scanned: $scanned; findings: $hit_count; scan errors: $errors"
    if [ -n "$hits" ]; then echo; echo "Findings:"; printf '%s' "$hits" | while IFS= read -r h; do [ -n "$h" ] && echo "- \`$h\`"; done; fi
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

if [ "$machos" -eq 0 ]; then
  err "no Mach-O file found under: $* - the scan saw nothing, refusing to call it clean"
  exit 2
fi
if [ "$errors" -ne 0 ]; then
  err "$errors file(s) could not be scanned"
  exit 2
fi
if [ "$hit_count" -ne 0 ]; then
  err "VPN support found in a build that must not have it:"
  printf '%s' "$hits" | while IFS= read -r h; do [ -n "$h" ] && say "  - $h"; done
  exit 1
fi
say "assert-no-vpn: clean"
exit 0
