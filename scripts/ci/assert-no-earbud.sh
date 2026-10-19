#!/bin/sh
# assert-no-earbud.sh - CI gate: a build without the earbud (hardware) stack must not contain any of it.
# Prints only file names, sizes, counts and the fixed signature names - never binary content.
#
# WHY. The earbud stack (the CoreBluetooth GATT client for the Q-Audion earbud, its UUIDs and the
# code that exists only to drive it) is a compile-time switch (QAUDION_EARBUD, see
# QAudionApp/project-earbud.yml). The default build, generated from QAudionApp/project.yml and
# produced by every tag push, must not contain it: the stack is for hardware lab builds only
# and is kept out of store builds. This gate proves that on the BUILT artifact, so a
# regression in a spec, a source file that lost its `#if`, or a file moved back into the engine
# package cannot ship unnoticed. scripts/ci/check_earbud_gating.py proves the same on the sources;
# the two are independent on purpose.
#
# USAGE   scripts/ci/assert-no-earbud.sh [--require-present] PATH [PATH...]
#   PATH  a .app bundle (or any directory, or a single file). Directories are walked recursively.
#   --require-present  the opposite check, for the build that is supposed to HAVE the stack
#         (ios-testflight.yml dispatched with earbud=true, the earbud-variant-build job): exit 1
#         unless the class name AND the GATT service UUID are both found, i.e. the compilation
#         condition really took effect. Without it a TestFlight build meant for the hardware lab
#         could silently lack the code.
#
# CHECKS   FILE CONTENT (fixed strings, grep -a -F, LC_ALL=C) of every Mach-O file (first 4 bytes are
#          a Mach-O / fat magic): the app executable, debug dylibs, Frameworks/*, PlugIns/*.
#   signatures:
#     18IOSEarbudGattProxy          the GATT client class, as Swift mangles it (length prefix + name,
#                                   inside the Objective-C class name _TtC<n>QAudionApp18IOSEarbudGattProxy
#                                   and the symbols: an NSObject subclass is kept by the linker even when
#                                   nothing references it)
#     27CoreBluetoothSovereignRelay the KMS sovereign relay driver (same form)
#     22EarbudKeyImportService      its orchestrator (same form)
#     18Fe5ExchangeService          the earbud pairing server exchange (same form)
#     19EarbudDiagViewModel         the earbud diagnostics screen (same form)
#     f2c0aaaa-bcc0-4001            the earbud GATT service UUID base
#     qaudion_paired_earbud_uuid    the UserDefaults key of the remembered earbud
#     /api/v1/diag/fe5              the earbud pairing exchange endpoints
#   The class names are matched WITH their Swift length prefix on purpose. A Debug build keeps, in the
#   debug map of its binary, the path of every object file it linked (.../IOSEarbudGattProxy.o), and the
#   project still compiles the (empty, `#if`-ed out) source file; the bare name would match that path and
#   report a stack that is not there. A mangled name exists only when the class itself was compiled.
#
# EXIT    0 clean (or, with --require-present, present) | 1 a trace was found (or, with
#         --require-present, the stack is missing) | 2 inconclusive (no path, no Mach-O found, scan error).
set -u
LC_ALL=C
export LC_ALL

REQUIRE_PRESENT=0
if [ "${1:-}" = "--require-present" ]; then
  REQUIRE_PRESENT=1
  shift
fi

SIGS='18IOSEarbudGattProxy
27CoreBluetoothSovereignRelay
22EarbudKeyImportService
18Fe5ExchangeService
19EarbudDiagViewModel
f2c0aaaa-bcc0-4001
qaudion_paired_earbud_uuid
/api/v1/diag/fe5'
# --require-present needs these two (the class and the UUID): the minimum that proves the stack is compiled in.
PRESENT_SIGS='18IOSEarbudGattProxy
f2c0aaaa-bcc0-4001'

say() { printf '%s\n' "$*"; }
err() { say "::error::assert-no-earbud: $1"; }

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/noearbud-gate.XXXXXX") || { err "cannot create a temp dir"; exit 2; }
trap 'rm -rf "$TMP"' EXIT INT TERM
LIST="$TMP/files"
: > "$LIST"

for p in "$@"; do
  if [ -d "$p" ]; then
    find "$p" -type f 2>/dev/null | sort >> "$LIST"
  elif [ -f "$p" ]; then
    printf '%s\n' "$p" >> "$LIST"
  else
    err "path does not exist: $p"
    exit 2
  fi
done

hits=""      # one "path: what" line per finding
found_sigs=" " # signatures seen anywhere, space separated (for --require-present)
machos=0
errors=0

add_hit() { hits="$hits$1
"; }

say "assert-no-earbud: scope = Mach-O files (app executable, dylibs, frameworks, plug-ins)"

while IFS= read -r f; do
  is_macho "$f" || continue
  machos=$((machos + 1))
  size=$(wc -c < "$f" | tr -d ' ')
  found=""
  bad=0
  for s in $SIGS; do
    n=$(count "$s" "$f")
    if [ "$n" = ERR ]; then bad=1
    elif [ "$n" != 0 ]; then
      found="$found $s"
      case "$found_sigs" in *" $s "*) ;; *) found_sigs="$found_sigs$s " ;; esac
    fi
  done
  if [ "$bad" -eq 1 ]; then
    say "  $f size=$size SCAN-ERROR"
    errors=$((errors + 1))
  elif [ -n "$found" ]; then
    say "  $f size=$size HIT:$found"
    add_hit "$f: contains$found"
  else
    say "  $f size=$size clean"
  fi
done < "$LIST"

hit_count=0
if [ -n "$hits" ]; then hit_count=$(printf '%s' "$hits" | grep -c .); fi
say "assert-no-earbud: scanned $machos Mach-O file(s), $hit_count with a trace, $errors scan error(s)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    if [ "$REQUIRE_PRESENT" -eq 1 ]; then echo "### Earbud stack present (earbud build)"; else echo "### No-earbud gate"; fi
    echo "Mach-O files scanned: $machos; files with a trace: $hit_count; scan errors: $errors"
    if [ -n "$hits" ]; then echo; echo "Files with a trace:"; printf '%s' "$hits" | while IFS= read -r h; do [ -n "$h" ] && echo "- \`$h\`"; done; fi
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

if [ "$REQUIRE_PRESENT" -eq 1 ]; then
  missing=""
  for s in $PRESENT_SIGS; do
    case "$found_sigs" in *" $s "*) ;; *) missing="$missing $s" ;; esac
  done
  if [ -n "$missing" ]; then
    err "earbud build is missing:$missing - the QAUDION_EARBUD compilation condition did not take effect"
    exit 1
  fi
  say "assert-no-earbud: present (class and GATT UUID found, as required for an earbud build)"
  exit 0
fi

if [ "$hit_count" -ne 0 ]; then
  err "earbud hardware code found in a build that must not have it:"
  printf '%s' "$hits" | while IFS= read -r h; do [ -n "$h" ] && say "  - $h"; done
  exit 1
fi
say "assert-no-earbud: clean"
exit 0
