#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Tests for W-HOSTKEY (2026-10-02): the four SSH-using dev/ops scripts
(ship-ios-logs.py, ship-server-logs.py, fetch-ios-live.py, correlate-call.py)
verify the prod VPS host key against a pinned known_hosts file instead of
trusting whatever key the first connection shows (paramiko trust-on-first-use).

What is checked (all offline, no credentials, no prod host contacted):
  * no script references the two trust-on-first-use paramiko policies, none
    calls save_host_keys, the shared helper block is byte-identical in all four;
  * scripts/vps_known_hosts holds exactly ONE entry, ssh-ed25519 for
    195.231.87.110, with the verified SHA-256 fingerprint (also cross-checked
    with `ssh-keygen -lf` when that tool is installed);
  * a fresh client is a RejectPolicy that already knows the pinned key and
    rejects an unknown host; env QAUDION_VPS_KNOWN_HOSTS adds/overrides keys,
    a set-but-missing path is a hard error; the pin wins over a stale
    ~/.ssh/known_hosts entry (HOME is redirected to a temp dir);
  * a missing / changed host key ends in ONE clear error naming the host and
    exit 1, and ssh_connect() makes exactly one connect attempt (no password or
    key fallback after a host-key failure); auth/network errors pass through.

Optional live check (needs an sshd on 127.0.0.1:22, e.g. on the VPS):
    QAUDION_HOSTKEY_LIVE=1 python3 scripts/test_vps_host_key_pin.py
connects to the LOCAL sshd with no credentials: with no pin the helper must
reject; with the sshd's own key pinned under 127.0.0.1 the handshake must pass
host-key verification (authentication then fails, which is expected); a wrong
pin must be rejected; and a pin for ONLY the sshd's ECDSA key (not paramiko's
first-choice type) must still verify, proving the known key type is preferred.

Run:  python3 scripts/test_vps_host_key_pin.py        Exit 0 = all pass.
"""
import base64
import contextlib
import hashlib
import importlib.util
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = ("ship-ios-logs.py", "ship-server-logs.py", "fetch-ios-live.py",
           "correlate-call.py")
PROD_HOST = "195.231.87.110"
PROD_FP = "ssh-ed25519 SHA256:XDDSqerYgzHIFwo2amn4XQWza0DeU0TDJSZjyZBI/ZY"
PROD_LINE = ("195.231.87.110 ssh-ed25519 "
             "AAAAC3NzaC1lZDI1NTE5AAAAIOZe0d2lL8RyZBt7JRS9t1pkQ8XKaFmyK1Xzx0TaRGwR")

try:
    import paramiko
except ImportError:
    print("ERROR: paramiko is required for this test (pip install paramiko)",
          file=sys.stderr)
    sys.exit(1)

checks = 0
failures = []


def check(cond, msg):
    global checks
    checks += 1
    if not cond:
        failures.append(msg)


def synth_line(host, seed):
    """known_hosts line with a SYNTHETIC ssh-ed25519 key (32 fixed bytes)."""
    blob = (struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32)
            + bytes((seed + i) % 256 for i in range(32)))
    return "%s ssh-ed25519 %s" % (host, base64.b64encode(blob).decode("ascii"))


def fp_of_line(line):
    blob = base64.b64decode(line.split()[2])
    sha = base64.b64encode(hashlib.sha256(blob).digest()).decode("ascii").rstrip("=")
    return "%s SHA256:%s" % (line.split()[1], sha)


# ---------------------------------------------------------------------------
# Isolate the process: no real ~/.ssh/known_hosts, no stray env, dummy creds so
# fetch-ios-live.py (loads them at import) can be imported.
# ---------------------------------------------------------------------------
TMP = tempfile.mkdtemp(prefix="vps-hostkey-test-")
os.makedirs(os.path.join(TMP, ".ssh"))
SAVED_ENV = dict(os.environ)
os.environ["HOME"] = TMP
os.environ["USERPROFILE"] = TMP
for k in ("QAUDION_VPS_KNOWN_HOSTS", "QAUDION_VPS_IOS_KEY", "QAUDION_VPS_SERVER_KEY",
          "QAUDION_VPS_KEY", "VPS_SSH_KEY"):
    os.environ.pop(k, None)
os.environ.update({"QAUDION_VPS_HOST": "203.0.113.1", "QAUDION_VPS_USER": "nobody",
                   "QAUDION_VPS_PASS": "not-a-real-password"})


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return path


def load(name):
    spec = importlib.util.spec_from_file_location(
        "hostkey_under_test_" + re.sub(r"\W", "_", name), os.path.join(HERE, name))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@contextlib.contextmanager
def env(**kv):
    old = {k: os.environ.get(k) for k in kv}
    for k, v in kv.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    try:
        yield
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def run_expect_exit(fn, *a, **kw):
    """Run fn; return (exit_code or None, stderr text, raised or None)."""
    err = io.StringIO()
    code = exc = None
    with contextlib.redirect_stderr(err):
        try:
            fn(*a, **kw)
        except SystemExit as e:
            code = e.code
        except BaseException as e:  # noqa: BLE001
            exc = e
    return code, err.getvalue(), exc


# ---------------------------------------------------------------------------
# 1. Source hygiene.
# ---------------------------------------------------------------------------
BAD = ("AutoAdd" + "Policy", "Warning" + "Policy")
all_py = sorted(f for f in os.listdir(HERE) if f.endswith(".py"))
for f in all_py:
    with open(os.path.join(HERE, f), encoding="utf-8", errors="replace") as fh:
        txt = fh.read()
    for b in BAD:
        check(b not in txt, "%s still references %s (trust-on-first-use)" % (f, b))
    if f != os.path.basename(__file__):
        check(re.search(r"\.save_host_keys\(", txt) is None,
              "%s calls save_host_keys (must never write known_hosts)" % f)

blocks = {}
for f in SCRIPTS:
    with open(os.path.join(HERE, f), encoding="utf-8") as fh:
        txt = fh.read().replace("\r\n", "\n")
    m = re.search(r"^# --- BEGIN vps-host-key-verification.*?^# --- END "
                  r"vps-host-key-verification ---\n", txt, re.S | re.M)
    check(m is not None and txt.count("# --- BEGIN vps-host-key-verification") == 1,
          "%s: expected exactly one vps-host-key-verification block" % f)
    blocks[f] = m.group(0) if m else None
check(len(set(blocks.values())) == 1,
      "the vps-host-key-verification block differs between the four scripts")

# ---------------------------------------------------------------------------
# 2. The pinned file.
# ---------------------------------------------------------------------------
PIN = os.path.join(HERE, "vps_known_hosts")
check(os.path.isfile(PIN), "scripts/vps_known_hosts is missing")
lines = []
if os.path.isfile(PIN):
    with open(PIN, encoding="utf-8") as fh:
        lines = [ln.strip() for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
check(len(lines) == 1, "vps_known_hosts must hold exactly one entry, has %d" % len(lines))
if len(lines) == 1:
    check(lines[0] == PROD_LINE, "pinned line differs from the verified key line")
    check(lines[0].split()[0] == PROD_HOST and lines[0].split()[1] == "ssh-ed25519",
          "pinned entry is not 'ssh-ed25519' for %s" % PROD_HOST)
    check(fp_of_line(lines[0]) == PROD_FP,
          "pinned fingerprint %s != expected %s" % (fp_of_line(lines[0]), PROD_FP))
    hk = paramiko.HostKeys(PIN)
    sub = hk.lookup(PROD_HOST)
    check(sub is not None and list(sub.keys()) == ["ssh-ed25519"],
          "paramiko does not parse exactly one ssh-ed25519 key for %s" % PROD_HOST)
    check(paramiko.HostKeys(PIN).lookup("203.0.113.9") is None,
          "pinned file unexpectedly knows another host")
kg = shutil.which("ssh-keygen")
if kg and lines:
    out = subprocess.run([kg, "-lf", PIN], capture_output=True, text=True).stdout
    check(PROD_FP.split()[1] in out and "(ED25519)" in out,
          "ssh-keygen -lf does not report the expected fingerprint: %r" % out)

# ---------------------------------------------------------------------------
# 3. Per-script behaviour of the helper.
# ---------------------------------------------------------------------------
STALE = synth_line(PROD_HOST, 7)          # same host + type, DIFFERENT key
OTHER = synth_line("198.51.100.7", 40)    # an extra host (env / ~/.ssh)
write(os.path.join(TMP, ".ssh", "known_hosts"), STALE + "\n" + synth_line("192.0.2.5", 90) + "\n")


class FakeClient(object):
    def __init__(self, exc):
        self.exc = exc
        self.calls = []
        self.closed = False

    def connect(self, host, **kw):
        self.calls.append((host, kw))
        raise self.exc

    def close(self):
        self.closed = True


prod_key = paramiko.HostKeys(PIN).lookup(PROD_HOST)["ssh-ed25519"] if lines else None

for name in SCRIPTS:
    tag = "[%s]" % name
    mod = load(name)

    # 3a. fresh client: RejectPolicy, pinned key known (and winning over the
    #     stale ~/.ssh entry for the same host + type), unknown host rejected.
    cl = mod._new_ssh_client()
    check(isinstance(cl._policy, paramiko.RejectPolicy),
          "%s client policy is %r, not a RejectPolicy" % (tag, cl._policy))
    sub = cl._system_host_keys.lookup(PROD_HOST)
    check(sub is not None and sub.get("ssh-ed25519") is not None
          and mod._key_fingerprint(sub["ssh-ed25519"]) == PROD_FP,
          "%s the pinned key does not win over a stale ~/.ssh/known_hosts entry" % tag)
    check(cl._system_host_keys.lookup("192.0.2.5") is not None,
          "%s ~/.ssh/known_hosts is not loaded" % tag)
    try:
        cl._policy.missing_host_key(cl, "203.0.113.9", prod_key)
        check(False, "%s an unknown host was NOT rejected" % tag)
    except mod._UnknownHostKey as e:
        check(e.hostname == "203.0.113.9" and e.key is prod_key,
              "%s _UnknownHostKey lost the host/key" % tag)

    # 3b. env: set-but-missing = hard error; a file adds hosts and overrides.
    with env(QAUDION_VPS_KNOWN_HOSTS=os.path.join(TMP, "nope")):
        code, err, exc = run_expect_exit(mod._new_ssh_client)
        check(code == 1 and "QAUDION_VPS_KNOWN_HOSTS" in err and exc is None,
              "%s set-but-missing QAUDION_VPS_KNOWN_HOSTS must exit 1 (got %r)" % (tag, code))
    extra = write(os.path.join(TMP, "extra_known_hosts"), OTHER + "\n")
    with env(QAUDION_VPS_KNOWN_HOSTS=extra):
        c2 = mod._new_ssh_client()
        check(c2._system_host_keys.lookup("198.51.100.7") is not None
              and mod._key_fingerprint(c2._system_host_keys.lookup(PROD_HOST)["ssh-ed25519"]) == PROD_FP,
              "%s env file must ADD hosts and keep the pin" % tag)
    override = write(os.path.join(TMP, "override_known_hosts"), STALE + "\n")
    with env(QAUDION_VPS_KNOWN_HOSTS=override):
        c3 = mod._new_ssh_client()
        check(mod._key_fingerprint(c3._system_host_keys.lookup(PROD_HOST)["ssh-ed25519"])
              == fp_of_line(STALE),
              "%s env file must take precedence over the pinned file" % tag)

    # 3c. _connect_verified error handling.
    other_key = paramiko.HostKeys(extra).lookup("198.51.100.7")["ssh-ed25519"]
    fc = FakeClient(mod._UnknownHostKey("example.invalid", other_key))
    code, err, exc = run_expect_exit(mod._connect_verified, fc, "example.invalid", timeout=1)
    check(code == 1 and exc is None and "example.invalid" in err
          and mod._key_fingerprint(other_key) in err and "vps_known_hosts" in err
          and "no known key" in err and fc.closed and len(fc.calls) == 1,
          "%s unknown host: want exit 1 + message naming host/fingerprint/how to add (got %r %r)"
          % (tag, code, err[:120]))
    fc = FakeClient(paramiko.BadHostKeyException("example.invalid", other_key, prod_key))
    code, err, exc = run_expect_exit(mod._connect_verified, fc, "example.invalid")
    check(code == 1 and exc is None and "example.invalid" in err
          and "does NOT match" in err and mod._key_fingerprint(other_key) in err
          and mod._key_fingerprint(prod_key) in err and fc.closed,
          "%s changed key: want exit 1 + both fingerprints (got %r)" % (tag, code))
    check(all(ord(ch) < 128 for ch in err), "%s host-key error is not pure ASCII" % tag)
    for boom in (paramiko.AuthenticationException("auth failed"), OSError("net down"),
                 paramiko.SSHException("other ssh problem")):
        fc = FakeClient(boom)
        code, err, exc = run_expect_exit(mod._connect_verified, fc, "example.invalid")
        check(code is None and exc is boom,
              "%s %s must propagate unchanged (got code=%r exc=%r)"
              % (tag, type(boom).__name__, code, exc))

    # 3d. ssh_connect(): ONE attempt, no key->password / key->other fallback.
    for keypath in (None, "/nonexistent/key"):
        fc = FakeClient(mod._UnknownHostKey("203.0.113.1", prod_key))
        saved = (mod._new_ssh_client, getattr(mod, "_vps_key_path", None))
        mod._new_ssh_client = lambda fc=fc: fc
        if saved[1] is not None:  # correlate-call.py has no key-auth path
            mod._vps_key_path = lambda kp=keypath: kp
        try:
            if hasattr(mod, "_ensure_creds"):
                mod.VPS_HOST, mod.VPS_USER, mod.VPS_PASS = None, None, None
            code, err, exc = run_expect_exit(mod.ssh_connect)
        finally:
            mod._new_ssh_client = saved[0]
            if saved[1] is not None:
                mod._vps_key_path = saved[1]
        check(code == 1 and exc is None and len(fc.calls) == 1,
              "%s ssh_connect(key=%r): want exit 1 after exactly 1 connect, got code=%r calls=%d exc=%r"
              % (tag, keypath, code, len(fc.calls), exc))

# ---------------------------------------------------------------------------
# 4. Optional live loopback check against the local sshd.
# ---------------------------------------------------------------------------
live_note = "live loopback check: skipped (set QAUDION_HOSTKEY_LIVE=1)"
if SAVED_ENV.get("QAUDION_HOSTKEY_LIVE") == "1":
    mod = load("ship-ios-logs.py")

    def server_key(keytype):
        import socket
        t = None
        try:
            t = paramiko.Transport(("127.0.0.1", 22))
            t.get_security_options().key_types = [keytype]
            t.start_client(timeout=10)
            return t.get_remote_server_key()
        except (paramiko.SSHException, socket.error):
            return None
        finally:
            if t is not None:
                t.close()

    keys = {kt: server_key(kt) for kt in ("ssh-ed25519", "ecdsa-sha2-nistp256")}
    if not any(keys.values()):
        live_note = "live loopback check: no sshd answered on 127.0.0.1:22, skipped"
    else:
        live = []

        def attempt(label, pin_lines):
            """(exit code, stderr, raised exception, negotiated host key type)."""
            kh = write(os.path.join(TMP, "live_known_hosts"), "\n".join(pin_lines) + "\n")
            with env(QAUDION_VPS_KNOWN_HOSTS=kh):
                client = mod._new_ssh_client()
                code, err, exc = run_expect_exit(
                    mod._connect_verified, client, "127.0.0.1", username="hostkey-test-nobody",
                    allow_agent=False, look_for_keys=False, timeout=10)
            tr = client.get_transport()
            kt = getattr(tr, "host_key_type", None) if tr is not None else None
            live.append("%s -> exit=%r exc=%s hostkey=%s" % (
                label, code, type(exc).__name__ if exc else None, kt))
            try:
                client.close()
            except Exception:  # noqa: BLE001
                pass
            return code, err, exc, kt

        # a) no key for 127.0.0.1 anywhere: must be REJECTED before authentication.
        code, err, exc, kt = attempt("no pin", [OTHER])
        check(code == 1 and exc is None and "127.0.0.1" in err and "no known key" in err,
              "live: unknown host must be rejected with exit 1 (got %r %r)" % (code, exc))
        # b) wrong key pinned: rejected as a mismatch.
        code, err, exc, kt = attempt("wrong pin", [synth_line("127.0.0.1", 5)])
        check(code == 1 and exc is None and "does NOT match" in err,
              "live: wrong pin must be rejected as mismatch (got %r %r)" % (code, exc))
        # c) each key type the sshd has, pinned ALONE: verification must pass and
        #    only authentication (no credentials given) may fail.
        for kt_name, key in keys.items():
            if key is None:
                live.append("%s: sshd has no such host key, skipped" % kt_name)
                continue
            line = "127.0.0.1 %s %s" % (key.get_name(), key.get_base64())
            code, err, exc, kt = attempt("only %s pinned" % kt_name, [line])
            check(code is None and isinstance(exc, paramiko.SSHException)
                  and not isinstance(exc, paramiko.BadHostKeyException),
                  "live: %s pin alone must pass host-key verification and then fail at "
                  "authentication (got exit=%r exc=%r err=%r)" % (kt_name, code, exc, err[:200]))
            check(kt == kt_name, "live: negotiated host key type %r != pinned %r" % (kt, kt_name))
        live_note = "live loopback check: ran\n    " + "\n    ".join(live)

# ---------------------------------------------------------------------------
shutil.rmtree(TMP, ignore_errors=True)
print("checks=%d failures=%d  (paramiko %s)" % (checks, len(failures), paramiko.__version__))
print("  " + live_note)
for f in failures:
    print("  FAIL: " + f)
sys.exit(1 if failures else 0)
