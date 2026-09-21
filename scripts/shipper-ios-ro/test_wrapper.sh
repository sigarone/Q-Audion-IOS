#!/bin/bash
# Local test of qaudion-shipper-ios-ro.sh against a FAKE data dir (nothing touches any server).
# Needs Linux (mkfifo, GNU find/stat/timeout, flock, python3). Run: bash test_wrapper.sh [path-to-wrapper]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/qaudion-shipper-ios-ro.sh}"
TD="$(mktemp -d)"
DATA="$TD/files"; mkdir -p "$DATA"
sed -e "s#^DATA_DIR=.*#DATA_DIR=$DATA#" -e "s#^LOG=.*#LOG=$TD/w.log#" -e "s#^LOCK=.*#LOCK=$TD/w.lock#" "$SRC" > "$TD/w.sh"
U1=11111111-1111-4111-8111-111111111111   # W417 header chunk
U2=22222222-2222-4222-8222-222222222222   # W417 iso-first-line chunk (2 h old)
U3=33333333-3333-4333-8333-333333333333   # binary attachment
U4=44444444-4444-4444-8444-444444444444   # text but not W417
U5=55555555-5555-4555-8555-555555555555   # symlink -> U1
U6=66666666-6666-4666-8666-666666666666   # 400000 bytes (> 256 KiB)
U7=77777777-7777-4777-8777-777777777777   # empty
U8=88888888-8888-4888-8888-888888888888   # FIFO
U9=99999999-9999-4999-8999-999999999999   # directory
UA=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa   # W417 only on the SECOND line
UB=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb   # exactly 262144 bytes, W417
UC=cccccccc-cccc-4ccc-8ccc-cccccccccccc   # 262145 bytes, W417
UD=dddddddd-dddd-4ddd-8ddd-dddddddddddd   # symlink to /etc/passwd (target does not look like W417 anyway)
printf '{"type":"header","x":1}\n{"ts":"2026-01-01T00:00:01.000Z","msg":"a"}\n' > "$DATA/$U1"
printf '2026-01-01T00:00:01 line\n' > "$DATA/$U2"
head -c 300 /dev/urandom > "$DATA/$U3"
printf 'hello world not telemetry\n' > "$DATA/$U4"
ln -s "$DATA/$U1" "$DATA/$U5"
head -c 400000 /dev/zero | tr '\0' 'x' > "$DATA/$U6"
: > "$DATA/$U7"
mkfifo "$DATA/$U8"
mkdir "$DATA/$U9"
printf 'junk first line\n{"ts":"2026-01-01T00:00:01.000Z","msg":"a"}\n' > "$DATA/$UA"
{ printf '{"type":"header"}\n'; head -c 262144 /dev/zero | tr '\0' 'y'; } | head -c 262144 > "$DATA/$UB"
{ printf '{"type":"header"}\n'; head -c 262144 /dev/zero | tr '\0' 'y'; } | head -c 262145 > "$DATA/$UC"
ln -s /etc/passwd "$DATA/$UD"
printf '{"type":"header"}\n' > "$DATA/.11111111-1111-4111-8111-111111111111.abc123"     # rsync temp name
printf '{"type":"header"}\n' > "$DATA/notes.txt"
printf '{"type":"header"}\n' > "$DATA/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"              # upper case
touch -d '2 hours ago' "$DATA/$U2"
fail=0; n=0
ok()   { n=$((n+1)); echo "ok   $1"; }
bad()  { n=$((n+1)); echo "FAIL $1"; fail=1; }
t() { # label expected_rc command-string
  local label="$1" want="$2" c="$3" rc
  LAST=$(SSH_ORIGINAL_COMMAND="$c" timeout 15 bash "$TD/w.sh" 2>"$TD/err"); rc=$?
  if [ "$rc" = "$want" ]; then ok "$label"; else bad "$label (rc=$rc want=$want)"; fi
}
names() { echo "$LAST" | awk 'NF{print $3}' | sed "s#$DATA/##" | sort | tr '\n' ' '; }

# ---- ios-list
t "list 60 10 ok" 0 "ios-list 60 10"
[ "$(names)" = "$U1 $U3 $U4 $UA $UB " ] && ok "list = only small uuid regular files inside the window" || { bad "list content: $(names)"; }
echo "$LAST" | grep -qE '^[0-9]+\.[0-9]+ [0-9]+ /' && ok "list line format '<mtime> <size> <path>'" || bad "list format"
echo "$LAST" | grep -q "$U2" && bad "list window (U2 is 2h old)" || ok "window excludes 2h-old"
for x in $U5 $U6 $U7 $U8 $U9 $UC $UD notes.txt AAAAAAAA .11111111; do echo "$LAST" | grep -qF -- "$x" && bad "list leaked $x"; done; ok "list excludes symlink/>256K/empty/fifo/dir/non-uuid/rsync-temp/upper"
t "list 180 includes old" 0 "ios-list 180 10"; echo "$LAST" | grep -q "$U2" && ok "window 180 includes U2" || bad "window 180"
t "list limit=2" 0 "ios-list 180 2"; [ "$(echo "$LAST" | grep -c .)" = 2 ] && ok "limit honoured" || bad "limit not honoured"
t "list max bounds ok" 0 "ios-list 20160 5000"
t "list leading zeros ok" 0 "ios-list 0060 0010"
t "list minutes 20161 DENIED" 1 "ios-list 20161 10"
t "list limit 5001 DENIED" 1 "ios-list 60 5001"
t "list zero minutes DENIED" 1 "ios-list 0 10"
t "list zero limit DENIED" 1 "ios-list 60 0"
t "list huge DENIED" 1 "ios-list 999999 10"
t "list 7 digits DENIED" 1 "ios-list 1234567 10"
t "list injection ; DENIED" 1 "ios-list 60 10; id"
t "list injection && DENIED" 1 "ios-list 60 10 && id"
t "list injection \$() DENIED" 1 'ios-list $(id) 10'
t "list injection backtick DENIED" 1 'ios-list `id` 10'
t "list negative DENIED" 1 "ios-list -1 10"
t "list extra arg DENIED" 1 "ios-list 60 10 -x"
t "list double space DENIED" 1 "ios-list  60 10"
t "list trailing space DENIED" 1 "ios-list 60 10 "
t "list trailing newline DENIED" 1 $'ios-list 60 10\n'
t "list embedded newline DENIED" 1 $'ios-list 60 10\nid'
t "list CR DENIED" 1 $'ios-list 60 10\r'
t "list upper-case verb DENIED" 1 "IOS-LIST 60 10"
t "list unicode digits DENIED" 1 "ios-list ６０ 10"

# ---- ios-cat
t "cat header chunk" 0 "ios-cat $U1"; [ "$(echo "$LAST" | head -c 16)" = '{"type":"header"' ] && ok "cat content" || bad "cat content"
t "cat iso chunk" 0 "ios-cat $U2"
t "cat exactly 256 KiB ok" 0 "ios-cat $UB"; [ "$(printf '%s' "$LAST" | wc -c)" -ge 262100 ] && ok "cat 256K length" || bad "cat 256K length"
t "cat 256 KiB + 1 DENIED" 1 "ios-cat $UC"
t "cat >256K DENIED" 1 "ios-cat $U6"
t "cat empty DENIED" 1 "ios-cat $U7"
t "cat binary DENIED" 1 "ios-cat $U3"
t "cat non-W417 DENIED" 1 "ios-cat $U4"
t "cat W417 only on line 2 DENIED" 1 "ios-cat $UA"
t "cat symlink DENIED" 1 "ios-cat $U5"
t "cat symlink to /etc/passwd DENIED" 1 "ios-cat $UD"
t "cat FIFO DENIED without hanging" 1 "ios-cat $U8"
t "cat directory DENIED" 1 "ios-cat $U9"
t "cat missing DENIED" 1 "ios-cat eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
t "cat traversal DENIED" 1 "ios-cat ../../etc/passwd"
t "cat traversal in uuid slot DENIED" 1 "ios-cat ../../../../../../etc/passwd/00000000-0000-0000-0000-000000000000"
t "cat absolute path DENIED" 1 "ios-cat /etc/passwd"
t "cat uppercase uuid DENIED" 1 "ios-cat 1111111A-1111-4111-8111-111111111111"
t "cat short uuid DENIED" 1 "ios-cat 11111111-1111-4111-8111-11111111111"
t "cat long uuid DENIED" 1 "ios-cat 11111111-1111-4111-8111-1111111111111"
t "cat injection ; DENIED" 1 "ios-cat $U1; id"
t "cat injection \$() DENIED" 1 'ios-cat $(id)'
t "cat injection backtick DENIED" 1 'ios-cat `id`'
t "cat injection | DENIED" 1 "ios-cat $U1 | id"
t "cat two uuids DENIED" 1 "ios-cat $U1 $U2"
t "cat option-like DENIED" 1 "ios-cat --help"
t "cat no arg DENIED" 1 "ios-cat"
t "cat double space DENIED" 1 "ios-cat  $U1"
t "cat trailing newline DENIED" 1 "ios-cat $U1"$'\n'
t "cat embedded newline DENIED" 1 "ios-cat $U1"$'\nid'

# ---- everything else
t "shell DENIED" 1 "bash"
t "sh -c DENIED" 1 "sh -c id"
t "id DENIED" 1 "id"
t "cat /etc/passwd DENIED" 1 "cat /etc/passwd"
t "empty (interactive) DENIED" 1 ""
t "find arbitrary DENIED" 1 "find / -name x"
t "sftp subsystem string DENIED" 1 "internal-sftp"
t "sftp-server path DENIED" 1 "/usr/lib/openssh/sftp-server"
t "scp DENIED" 1 "scp -f /etc/passwd"
t "rsync DENIED" 1 "rsync --server -logDtpre.iLsfxC . /etc"
t "oversize command (100 KB) DENIED" 1 "$(head -c 100000 /dev/zero | tr '\0' 'a')"

# ---- concurrency: a second ios-list while one holds the lock is refused (exit 3), cat is unaffected
( exec 9>"$TD/w.lock"; flock 9; sleep 4 ) & sleep 1
t "list while busy -> exit 3" 3 "ios-list 60 10"
t "cat while list busy still ok" 0 "ios-cat $U1"
wait
t "list after lock released" 0 "ios-list 60 10"

# ---- audit log
echo "--- audit log (first lines):"; cut -c22-110 "$TD/w.log" | head -6
[ "$(stat -c %a "$TD/w.log")" = 600 ] && ok "audit log mode 600" || bad "audit log mode $(stat -c %a "$TD/w.log")"
awk '{ if (length($0) > 260) exit 1 }' "$TD/w.log" && ok "no over-long audit line (client string truncated)" || bad "audit line too long"
grep -c $'\r' "$TD/w.log" | grep -q '^0$' && ok "no CR in audit log" || bad "CR in audit log"
grep -q 'ALLOW: ios-cat 11111111' "$TD/w.log" && ok "allow logged with 8-char uuid prefix only" || bad "allow log format"
! grep -q "ALLOW: ios-cat 11111111-" "$TD/w.log" && ok "full uuid not logged on allow" || bad "full uuid logged"
# forged line injection attempt: the log must not gain a fake ALLOW line
SSH_ORIGINAL_COMMAND=$'id\n2026-01-01T00:00:00Z ALLOW: ios-cat FAKE' bash "$TD/w.sh" 2>/dev/null
grep -q '^2026-01-01T00:00:00Z ALLOW' "$TD/w.log" && bad "log injection worked" || ok "log injection neutralised"
# log rotation
head -c 4300000 /dev/zero | tr '\0' 'z' > "$TD/w.log"; SSH_ORIGINAL_COMMAND="id" bash "$TD/w.sh" 2>/dev/null
[ -f "$TD/w.log.1" ] && [ "$(stat -c %s "$TD/w.log")" -lt 1000 ] && ok "log rotated at 4 MiB" || bad "log rotation"

rm -rf "$TD"
echo "tests run: $n"
[ "$fail" = 0 ] && echo "WRAPPER TESTS: ALL OK" || echo "WRAPPER TESTS: FAILURES"
exit "$fail"
