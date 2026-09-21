#!/bin/bash
# qaudion-shipper-ios-ro.sh -- forced-command wrapper for the restricted SSH key used by the
# QAudion iOS-log shipper (cron on fi-1: ship-ios-logs.py in restricted-exec mode).
# Read-only, least privilege: this key can run NOTHING except two verbs, in exactly the shape
# the shipper emits:
#   ios-list <minutes> <limit>   list recent small uuid-named regular files under data/files
#   ios-cat  <uuid>              print ONE file, only if it is a W417 telemetry chunk
# The client string is never eval'd / sh -c'd: it is matched against anchored regexes and the
# captured pieces are passed as argv. No SFTP, no shell, no write access, no forwarding.
# Files under data/files are owned by bcrypto with mode 0600, hence this runs as root through
# root's authorized_keys (same pattern as qaudion-shipper-journal-ro.sh).
#
# Audit 2026-09-21 of the first draft (all fixed here):
#  - ios-cat opened the path twice (check, then read): a symlink / FIFO swapped in between
#    (or a FIFO named like a uuid, which HANGS an open) could be followed. The read now goes
#    through ONE python3 open with O_NOFOLLOW|O_NONBLOCK + fstat (regular file only, 1..256 KiB).
#  - the W417 check was `grep '^...'` over 64 bytes, which also matched a LATER line in those
#    bytes; it now anchors on the FIRST line only.
#  - files over 256 KiB were silently truncated by `head -c`; they are now refused (like the list).
#  - ios-list matched any regular file name (newlines, rsync temp names ".<uuid>.XXXX"): it now
#    lists only <uuid36> names, runs under timeout+nice+ionice and one at a time (flock).
#  - the audit log echoed the raw client string (control characters / log injection): it is now
#    truncated and reduced to a safe charset; the log rotates at 4 MiB; find errors exit 2.
#  - command length capped (64), embedded newlines refused, umask 077, fixed PATH and locale.
set -u
umask 077
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
DATA_DIR=/opt/bcrypto/data/files
LOG=/var/log/qaudion-shipper-ios-ro.log
LOCK=/run/lock/qaudion-shipper-ios-ro.lock
MAX_BYTES=262144                       # the shipper skips blobs > 256 KiB anyway
MAX_LOG_BYTES=4194304
cmd="${SSH_ORIGINAL_COMMAND:-}"
exec </dev/null

clean() { printf '%s' "${1:0:100}" | tr -c 'A-Za-z0-9 ._/:=,;()+@-' '?'; }
log() {
  local sz
  sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$MAX_LOG_BYTES" ] 2>/dev/null; then mv -f "$LOG" "$LOG.1" 2>/dev/null; fi
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG" 2>/dev/null
}
deny() {
  log "DENY(${1:-cmd}): $(clean "$cmd")"
  echo "rejected: command not allow-listed for this restricted key" >&2
  exit 1
}

[[ "$cmd" == *$'\n'* || "$cmd" == *$'\r'* ]] && deny "ctl"
(( ${#cmd} > 64 )) && deny "long"

re_list='^ios-list ([0-9]{1,6}) ([0-9]{1,5})$'
re_cat='^ios-cat ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'

if [[ "$cmd" =~ $re_list ]]; then
  minutes=$((10#${BASH_REMATCH[1]})); limit=$((10#${BASH_REMATCH[2]}))
  (( minutes >= 1 && minutes <= 20160 && limit >= 1 && limit <= 5000 )) || deny "range"
  # one listing at a time (slow disk on the prod box); a second concurrent call is refused.
  if { exec 9>"$LOCK"; } 2>/dev/null; then
    flock -n 9 || { log "BUSY: ios-list"; echo "busy" >&2; exit 3; }
  fi
  log "ALLOW: ios-list $minutes $limit"
  runner=(timeout 60)
  command -v nice >/dev/null 2>&1 && runner+=(nice -n 10)
  command -v ionice >/dev/null 2>&1 && runner+=(ionice -c3)
  # same line format as the shipper's original `find ... -printf '%T@ %s %p'`
  list=$("${runner[@]}" find "$DATA_DIR" -maxdepth 1 -type f -regextype posix-extended \
         -regex '.*/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
         -size +0c -size "-$((MAX_BYTES + 1))c" -mmin "-$minutes" \
         -printf '%T@ %s %p\n' 2>/dev/null) || { log "ERR: ios-list find rc=$?"; echo "error: listing failed" >&2; exit 2; }
  [[ -n "$list" ]] && printf '%s\n' "$list" | sort -nr | head -n "$limit"
  exit 0
fi

if [[ "$cmd" =~ $re_cat ]]; then
  id="${BASH_REMATCH[1]}"
  # Open ONCE with O_NOFOLLOW|O_NONBLOCK, then judge the OPEN file (fstat): regular, 1..MAX_BYTES,
  # first line looks like W417 (same heuristic as the shipper). Nothing is written before every check
  # passed, so a non-zero exit means no output at all.
  read -r -d '' PYCAT <<'PY'
import os, re, stat, sys
path, cap = sys.argv[1], int(sys.argv[2])
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_size == 0 or st.st_size > cap:
        sys.exit(1)
    head = os.pread(fd, 64, 0)
    if not re.match(rb'(\{"type":"header"|\{"ts"|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})', head):
        sys.exit(1)
    data = os.pread(fd, cap, 0)
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
except SystemExit:
    raise
except Exception:
    sys.exit(1)
PY
  timeout 20 /usr/bin/python3 -I -c "$PYCAT" "$DATA_DIR/$id" "$MAX_BYTES"
  rc=$?
  if [ "$rc" -ne 0 ]; then deny "cat-refused"; fi
  log "ALLOW: ios-cat ${id:0:8}"
  exit 0
fi

deny "no-match"
