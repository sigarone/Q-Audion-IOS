#!/usr/bin/env python3
"""
W417 — fetch live-log chunks uploaded by the iOS LiveLogStreamer.

The server (bcrypto-server) discards original filenames and stores files
under server-generated UUIDs. There's no list-files API endpoint yet, so
we SSH to the VPS and read directly from /opt/bcrypto/data/files/.

Usage:
  python scripts/fetch-ios-live.py [--minutes 60] [--user-prefix abc12345] [--limit 50]

  --minutes       Look back N minutes (default 60)
  --user-prefix   Filter to chunks whose UTF-8 contents include the
                  given user-id prefix (LiveLogStreamer embeds the
                  filename in chunk names like
                  "qaudion-live-<userPrefix8>-<bootSession>-<seq6>.log"
                  but the server discards those — we instead search
                  the chunk BODY for the userPrefix). Optional.
  --limit         Max number of chunks to download (default 50)

Output:
  - Concatenated chunk bodies to .cache/ios-logs/live-<timestamp>.log
  - Summary: file count, total bytes, time range, ERROR/WARN tags hit

Requires:
  - paramiko (`pip install paramiko`)
  - Server SSH password from VPS_ACCESS.md
"""

import os
import re
import sys
import time
import argparse
import io
from pathlib import Path

try:
    import paramiko
except ImportError:
    print("ERROR: paramiko not installed. `pip install paramiko`", file=sys.stderr)
    sys.exit(1)


VPS_HOST = "217.160.65.35"
VPS_USER = "root"
VPS_PASS = "REDACTED"
DATA_DIR = "/opt/bcrypto/data/files"
SERVICE_LOG_LINES = 50  # also fetch last N journalctl lines for context


def ssh_connect():
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(VPS_HOST, username=VPS_USER, password=VPS_PASS, timeout=15)
    return client


def run(client, cmd):
    stdin, stdout, stderr = client.exec_command(cmd)
    return stdout.read().decode("utf-8", errors="replace"), stderr.read().decode("utf-8", errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=int, default=60, help="lookback window in minutes")
    ap.add_argument("--user-prefix", type=str, default="", help="filter chunks containing this user-id prefix in body")
    ap.add_argument("--limit", type=int, default=50, help="max chunks to download")
    ap.add_argument("--service-log", action="store_true", help="also pull bcrypto-server journalctl tail")
    args = ap.parse_args()

    print(f"=== bcrypto-server SSH @ {VPS_HOST} ===")
    client = ssh_connect()
    print("Connected.")

    # 1) List files modified in last N minutes across all shards.
    print(f"\n=== Listing files modified in last {args.minutes} minutes ===")
    cmd = (
        f"find {DATA_DIR} -type f -mmin -{args.minutes} "
        f"-printf '%T@ %s %p\\n' | sort -nr | head -{args.limit}"
    )
    out, err = run(client, cmd)
    if err:
        print("STDERR:", err)
    files = []
    for line in out.strip().split("\n"):
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) != 3:
            continue
        mtime_s, size_s, path = parts
        files.append((float(mtime_s), int(size_s), path))

    if not files:
        print(f"No files modified in last {args.minutes} minutes.")
        print("LiveLogStreamer may not have started, or no auth/upload yet.")
        client.close()
        return

    print(f"Found {len(files)} candidate files:")
    for mtime_s, size_s, path in files[:20]:
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(mtime_s))
        print(f"  {ts}  {size_s:>8} bytes  {path}")
    if len(files) > 20:
        print(f"  ... +{len(files)-20} more")

    # 2) Download each, look for W417 chunks (UTF-8 .log content).
    out_dir = Path(__file__).parent.parent / ".cache" / "ios-logs"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"live-{int(time.time())}.log"

    sftp = client.open_sftp()
    matched = 0
    total_bytes = 0
    err_count = 0
    warn_count = 0
    tag_hits = {}

    print(f"\n=== Downloading + filtering chunks ===")
    with open(out_path, "wb") as out_f:
        for mtime_s, size_s, path in files:
            if size_s == 0:
                continue
            if size_s > 256 * 1024:  # skip large blobs (probably user attachments)
                continue
            try:
                with sftp.open(path, "rb") as rf:
                    blob = rf.read()
            except Exception as e:
                print(f"  skip {path}: {e}")
                continue
            # Heuristic: a W417 chunk is UTF-8 plain text starting with
            # an ISO8601 timestamp.
            try:
                txt = blob.decode("utf-8")
            except UnicodeDecodeError:
                continue
            first_line = txt.split("\n", 1)[0] if txt else ""
            iso_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
            if not iso_re.match(first_line):
                continue  # not a W417 chunk
            if args.user_prefix and args.user_prefix not in txt:
                continue
            # Match!
            ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(mtime_s))
            header = f"\n\n========== chunk {os.path.basename(path)} (mtime {ts}, {size_s}B) ==========\n"
            out_f.write(header.encode("utf-8"))
            out_f.write(blob)
            matched += 1
            total_bytes += size_s
            for line in txt.split("\n"):
                if " ERROR " in line:
                    err_count += 1
                if " WARN " in line:
                    warn_count += 1
                m = re.search(r"\[([a-z][a-zA-Z0-9._-]+)\]", line)
                if m:
                    tag = m.group(1)
                    tag_hits[tag] = tag_hits.get(tag, 0) + 1

    sftp.close()

    # 3) Optional: bcrypto-server journalctl tail.
    if args.service_log:
        print("\n=== bcrypto-server journalctl tail ===")
        out, _ = run(client, f"journalctl -u bcrypto-server -n {SERVICE_LOG_LINES} --no-pager")
        print(out)

    client.close()

    # 4) Summary.
    print(f"\n=== W417 chunk match summary ===")
    print(f"Matched W417 chunks: {matched}")
    print(f"Total bytes:         {total_bytes:,}")
    if matched:
        print(f"ERROR lines:         {err_count}")
        print(f"WARN lines:          {warn_count}")
        if tag_hits:
            top = sorted(tag_hits.items(), key=lambda kv: kv[1], reverse=True)[:15]
            print(f"Top tags:")
            for tag, cnt in top:
                print(f"  {tag:20} {cnt}")
        print(f"\nFull dump: {out_path}")
    else:
        print("\nNo W417 chunks found in window. Possible reasons:")
        print("  1. v1.0.398+ not yet installed on iPhone")
        print("  2. App not launched / not authenticated since install")
        print("  3. iPhone has no network (chunks dropped silently)")
        print("  4. Apple TestFlight processing not yet complete (~5-15 min)")


if __name__ == "__main__":
    main()
