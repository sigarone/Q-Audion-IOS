#!/bin/sh
# assert-no-key-logging.sh - CI gate: no Mach-O binary of the built app may still
# contain the WebRTC key-dump log format strings. Prints only file names, sizes and
# counts - never binary content.
#
# WHY. Upstream webrtc-sdk/webrtc (api/crypto/frame_crypto_transformer.cc, lines
# ~260 and ~284) writes the frame-cryptor input secret, the salt and the DERIVED
# AES-256 KEY as decimal byte lists at RTC_LOG(LS_INFO):
#     "secret " <list> " len N" " slat << " <list> " len N" "\n derived_key " <list> " len N"   (HKDF)
#     "raw_key " <list> " len N" " slat << " <list> " len N" "\n derived_key " <list> " len N"   (PBKDF2)
# ("slat" is upstream's own typo of "salt"). sigarone/webrtc-aes256-build's
# no-key-log.patch deletes both statements; once the rebuilt WebRTC.xcframework and
# LiveKitWebRTC.xcframework are pinned in QAudionEngine/Package.swift the literals
# are gone from the shipped app. This gate proves that on the SHIPPED artifact and
# keeps it true if someone re-pins an older binary.
#
# USAGE   scripts/ci/assert-no-key-logging.sh PATH [PATH...]
#   PATH  a .app bundle (or any directory, or a single binary). Directories are
#         walked recursively.
#
# SCOPE   EXACTLY the regular files whose first four bytes are a Mach-O magic
#         (thin 32/64-bit, either byte order, or fat/universal). That covers the app
#         executable, Frameworks/*.framework/<binary> (WebRTC, LiveKitWebRTC, ...),
#         PlugIns/*.appex/<binary> and any *.dylib. Everything else (plists, assets,
#         .strings, JSON test vectors, ...) is NOT scanned. Every scanned file is
#         listed in the output with its counts.
#
# SIGNATURES (fixed strings, matched byte-exact with grep -a -F, LC_ALL=C):
#   'slat << '        upstream's typo; exists only in the two log statements.
#   ' derived_key '   space-delimited, as in the "\n derived_key " literal. The bare
#                     word derived_key is NOT used: the app's own
#                     KeyMaterialScrubber.swift carries "derived_key" as a scrub
#                     pattern and would be a permanent false positive.
#   'raw_key '        the PBKDF2 statement's first literal; the trailing space keeps
#                     it apart from the app's own JSON field names
#                     "supports_raw_key_aes256" / "raw_key_capable".
#   Validated on the real shipped WebRTC binaries (libjingle_peerconnection_so.so
#   from libwebrtc-aes256.aar and from the LiveKit-prefixed AAR): each signature
#   matches exactly once, in the log-format strings.
# CONTROL   'Failed to derive HkdfSha256 key from secret' (the RTC_LOG(LS_ERROR)
#   right above the first statement, kept by the patch). Its per-file count is
#   printed so a report shows whether the scan can see WebRTC's strings at all.
#
# MODE    env WEBRTC_KEYLOG_GATE
#   "1"           ENFORCE: exit 1 if any signature is found, exit 2 if nothing could
#                 be scanned (no path, no Mach-O found, grep error). Fails closed.
#   anything else REPORT-ONLY (default "0"): prints the same report and GitHub
#                 warnings, but ALWAYS exits 0 - it can never break a release.
#   While the shipped WebRTC binaries are the old ones, a report-only run is
#   EXPECTED to show hits in WebRTC.framework/WebRTC (and LiveKitWebRTC): that is
#   the detector working on the real iOS binaries. Flip the flag to "1" in the same
#   PR that pins the rebuilt binaries.
set -u
LC_ALL=C
export LC_ALL

GATE="${WEBRTC_KEYLOG_GATE:-0}"
CONTROL='Failed to derive HkdfSha256 key from secret'

say() { printf '%s\n' "$*"; }

# emit a GitHub annotation; level = error when enforcing, warning otherwise
annotate() { # $1 = message
  if [ "$GATE" = "1" ]; then say "::error::assert-no-key-logging: $1"; else say "::warning::assert-no-key-logging (report-only, WEBRTC_KEYLOG_GATE=$GATE): $1"; fi
}

# finish with the right exit code for the mode. $1 = enforce-mode exit code
finish() {
  if [ "$GATE" = "1" ]; then exit "$1"; fi
  exit 0
}

if [ "$#" -eq 0 ]; then
  annotate "no path given - nothing was scanned"
  finish 2
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

LIST=$(mktemp "${TMPDIR:-/tmp}/keylog-gate.XXXXXX") || { annotate "cannot create a temp file"; finish 2; }
trap 'rm -f "$LIST"' EXIT INT TERM

for p in "$@"; do
  if [ -d "$p" ]; then
    find "$p" -type f 2>/dev/null | sort >> "$LIST"
  elif [ -f "$p" ]; then
    printf '%s\n' "$p" >> "$LIST"
  else
    annotate "path does not exist: $p"
    finish 2
  fi
done

scanned=0
hit_files=0
err=0
hit_names=""
say "assert-no-key-logging: mode=$( [ "$GATE" = "1" ] && echo ENFORCE || echo report-only ), scope=Mach-O files only"
# read from the list file (not a pipe) so the counters survive the loop
while IFS= read -r f; do
  is_macho "$f" || continue
  scanned=$((scanned + 1))
  size=$(wc -c < "$f" | tr -d ' ')
  a=$(count 'slat << ' "$f"); b=$(count ' derived_key ' "$f"); c=$(count 'raw_key ' "$f"); k=$(count "$CONTROL" "$f")
  if [ "$a" = ERR ] || [ "$b" = ERR ] || [ "$c" = ERR ] || [ "$k" = ERR ]; then
    say "  $f size=$size SCAN-ERROR"
    err=$((err + 1))
    continue
  fi
  hits=$((a + b + c))
  say "  $f size=$size slat=$a derived_key=$b raw_key=$c control=$k"
  if [ "$hits" -ne 0 ]; then
    hit_files=$((hit_files + 1))
    hit_names="$hit_names $f"
  fi
done < "$LIST"

say "assert-no-key-logging: scanned $scanned Mach-O file(s), $hit_files with key-dump strings, $err scan error(s)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### WebRTC key-dump string gate ($( [ "$GATE" = "1" ] && echo enforce || echo report-only ))"
    echo "Mach-O files scanned: $scanned; with key-dump strings: $hit_files; scan errors: $err"
    if [ -n "$hit_names" ]; then echo; echo "Files with hits:"; for n in $hit_names; do echo "- \`$n\`"; done; fi
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

if [ "$scanned" -eq 0 ]; then
  annotate "no Mach-O file found under: $* - the scan saw nothing, refusing to call it clean"
  finish 2
fi
if [ "$err" -ne 0 ]; then
  annotate "$err file(s) could not be scanned"
  finish 2
fi
if [ "$hit_files" -ne 0 ]; then
  annotate "WebRTC key-dump strings (derived_key / slat << / raw_key) are still compiled into $hit_files file(s):$hit_names"
  finish 1
fi
say "assert-no-key-logging: clean"
finish 0
