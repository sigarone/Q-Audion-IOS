#!/usr/bin/env python3
"""Integration test of ship-ios-logs.py RESTRICTED-EXEC mode against the REAL wrapper script
(qaudion-shipper-ios-ro.sh) on a FAKE data dir. No network except a local 127.0.0.1 HTTP sink.
usage: ro_integration.py SHIPPER.py WRAPPER.sh"""
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import redirect_stdout, redirect_stderr
from http.server import BaseHTTPRequestHandler, HTTPServer

SHIPPER, WRAPPER = sys.argv[1], sys.argv[2]
td = tempfile.mkdtemp()
data = os.path.join(td, "files")
os.makedirs(data)
w = open(WRAPPER).read()
import re
w = re.sub(r"(?m)^DATA_DIR=.*$", "DATA_DIR=" + data, w)
w = re.sub(r"(?m)^LOG=.*$", "LOG=" + td + "/w.log", w)
w = re.sub(r"(?m)^LOCK=.*$", "LOCK=" + td + "/w.lock", w)
wpath = os.path.join(td, "w.sh")
open(wpath, "w").write(w)

sess = "abcdef01-2345-4678-89ab-cdef01234567"
def blob(name, lines, header=True, age=60):
    txt = ""
    if header:
        txt += json.dumps({"type": "header", "session": sess, "app_ver": "1.0.1179", "os": "ios-18.5", "net": "WIFI", "brand": "Apple"}, separators=(",", ":")) + "\n"
    for i, (tag, msg) in enumerate(lines):
        txt += json.dumps({"ts": "2026-09-21T06:00:%02d.000Z" % (i + age % 50), "lvl": "I", "tag": tag, "msg": msg}, separators=(",", ":")) + "\n"
    p = os.path.join(data, name)
    open(p, "w").write(txt)
    t = time.time() - age
    os.utime(p, (t, t))

nums = ",".join(str((i * 37 + 11) % 256) for i in range(32))
blob("11111111-1111-4111-8111-111111111111", [("call", "ice=connected role=caller retry=2"), ("stdout", "derived_key [%s,] len 32" % nums)])
blob("22222222-2222-4222-8222-222222222222", [("net", "state=active ice=connected rtt=35"), ("call", "call_id=91FE5CF7-3572-42F1-9B84-29883F47BAB6 role=callee")], age=30)
open(os.path.join(data, "33333333-3333-4333-8333-333333333333"), "wb").write(os.urandom(200))
open(os.path.join(data, "44444444-4444-4444-8444-444444444444"), "w").write("x" * 300000)
os.symlink("/etc/passwd", os.path.join(data, "55555555-5555-4555-8555-555555555555"))


class FakeStream(object):
    def __init__(self, data, rc):
        self._d = data
        self.channel = type("C", (), {"recv_exit_status": lambda s: rc})()

    def read(self):
        return self._d


class FakeClient(object):
    """emulates sshd running the forced command: SSH_ORIGINAL_COMMAND -> wrapper (as root would)."""
    def __init__(self):
        self.cmds = []

    def exec_command(self, cmd):
        self.cmds.append(cmd)
        r = subprocess.run(["bash", wpath], env=dict(os.environ, SSH_ORIGINAL_COMMAND=cmd), capture_output=True)
        return None, FakeStream(r.stdout, r.returncode), FakeStream(r.stderr, r.returncode)

    def close(self):
        pass


posts = []


class Sink(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        posts.append(self.rfile.read(n).decode())
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


srv = HTTPServer(("127.0.0.1", 0), Sink)
threading.Thread(target=srv.serve_forever, daemon=True).start()
endpoint = "http://127.0.0.1:%d/otlp/v1/logs" % srv.server_port

spec = importlib.util.spec_from_file_location("ship", SHIPPER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.DATA_DIR = data
fc = FakeClient()
m.ssh_connect = lambda: fc
m._ensure_creds = lambda: None
m.VPS_HOST, m.VPS_USER = "fake", "root"
keyfile = os.path.join(td, "dummy_key")
open(keyfile, "w").write("not a real key\n")
os.environ["QAUDION_VPS_IOS_KEY"] = keyfile

fails = []


def run(argv):
    buf, err = io.StringIO(), io.StringIO()
    sys.argv = ["ship-ios-logs.py"] + argv
    with redirect_stdout(buf), redirect_stderr(err):
        try:
            m.main()
        except SystemExit as e:
            if e.code not in (0, None):
                fails.append("exit code %r" % (e.code,))
    return buf.getvalue(), err.getvalue()


st = os.path.join(td, "state.json")
o, e = run(["--dry-run", "--minutes", "120", "--limit", "50", "--state-file", st, "--env", "testflight"])
if "restricted-exec" not in o: fails.append("banner missing restricted-exec")
if "Found 3 candidate blobs" not in o: fails.append("candidate count: %s" % [l for l in o.splitlines() if "Found" in l])
if "derived_key" in o or nums.split(",")[0] + "," + nums.split(",")[1] in o: fails.append("KEY BYTES IN DRY-RUN OUTPUT")
if "91fe5cf7" not in o: fails.append("join key missing in output")
cmds1 = list(fc.cmds)
if not cmds1 or cmds1[0] != "ios-list 120 50": fails.append("first command %r" % cmds1[:1])
if any(not (c.startswith("ios-list ") or c.startswith("ios-cat ")) for c in cmds1): fails.append("unexpected command %r" % cmds1)
if len([c for c in cmds1 if c.startswith("ios-cat ")]) != 3: fails.append("ios-cat count %r" % len(cmds1))
if os.path.exists(st): fails.append("dry-run wrote state")

fc.cmds.clear()
o, e = run(["--minutes", "120", "--limit", "50", "--state-file", st, "--env", "testflight", "--endpoint", endpoint, "--ingest-token", "dummy"])
tail = "\n".join(l for l in o.splitlines() if "HTTP 204" in l or "lines shipped" in l or "blobs read" in l)
if "HTTP 204 (ok):           2" not in o: fails.append("expected 2 HTTP 204: %s" % tail)
body = "\n".join(posts)
if "derived_key" in body or nums[:20] in body: fails.append("KEY BYTES IN SHIPPED OTLP")
if len(posts) != 2: fails.append("posts=%d" % len(posts))
# second run: everything already in state -> nothing shipped, and NO ios-cat for the shipped blobs
# (only the never-shippable binary blob is asked again)
posts.clear()
fc.cmds.clear()
o, e = run(["--minutes", "120", "--limit", "50", "--state-file", st, "--env", "testflight", "--endpoint", endpoint, "--ingest-token", "dummy"])
if posts or "blobs skipped (state):   2" not in o: fails.append("state dedup failed: posts=%d" % len(posts))
cats = [c for c in fc.cmds if c.startswith("ios-cat ")]
if cats != ["ios-cat 33333333-3333-4333-8333-333333333333"]: fails.append("unchanged blobs were re-read: %r" % cats)
# a blob whose mtime changed IS read again (content signature then decides)
p2 = os.path.join(data, "22222222-2222-4222-8222-222222222222")
os.utime(p2, (time.time() - 5, time.time() - 5))
fc.cmds.clear()
o, e = run(["--minutes", "120", "--limit", "50", "--state-file", st, "--env", "testflight", "--endpoint", endpoint, "--ingest-token", "dummy"])
cats = [c for c in fc.cmds if c.startswith("ios-cat ")]
if "ios-cat 22222222-2222-4222-8222-222222222222" not in cats or "ios-cat 11111111-1111-4111-8111-111111111111" in cats:
    fails.append("mtime-changed blob handling wrong: %r" % cats)
if posts: fails.append("same content re-shipped after mtime change")

# QAUDION_VPS_IOS_KEY set but missing -> exit 1 (no silent fallback)
os.environ["QAUDION_VPS_IOS_KEY"] = os.path.join(td, "nope")
m2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m2)
try:
    m2._ios_ro_key_path()
    fails.append("missing key did not exit")
except SystemExit as e2:
    if e2.code != 1: fails.append("missing key exit code %r" % e2.code)

print("wrapper log:", open(td + "/w.log").read().count("ALLOW"), "ALLOW lines,", open(td + "/w.log").read().count("DENY"), "DENY lines")
print("commands seen by the wrapper:", sorted(set(c.split()[0] for c in cmds1)))
if fails:
    print("RO INTEGRATION: FAIL")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("RO INTEGRATION: ALL OK")
