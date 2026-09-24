#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Offline test of the Loki URL handling of scripts/correlate-call.py and
scripts/synth-traces.py (W-LOKIURL 2026-09-24): dash.bcrypto.com/loki is not
public any more, so

  * the default --loki-url is the local end of the ssh tunnel (never the public URL);
  * env QAUDION_LOKI_URL, else LOKI_URL, override it; a bare base URL gets
    /loki/api/v1/query_range appended; an explicit --loki-url wins;
  * no password is needed (no Authorization header unless one is given);
  * an unreachable Loki gives a clear message with the ssh-tunnel hint, exit 1,
    no traceback; a 404 from the old public host says the route was removed;
  * --help still works and the other options are still there.

No external network: a throw-away HTTP server on 127.0.0.1 plays Loki.
Run:  python scripts/test_loki_url_default.py        Exit 0 = all pass.
"""
import contextlib
import http.server
import io
import json
import os
import runpy
import sys
import threading
import types

HERE = os.path.dirname(os.path.abspath(__file__))
if "paramiko" not in sys.modules:
    try:
        import paramiko  # noqa: F401
    except ImportError:
        sys.modules["paramiko"] = types.ModuleType("paramiko")

failures = []
checks = 0


def check(cond, label):
    global checks
    checks += 1
    if not cond:
        failures.append(label)


def load(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location("mod_" + name.replace("-", "_"),
                                                  os.path.join(HERE, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run_main(script, argv, env=None):
    """Run a script as __main__ in-process. Returns (exit_code, stdout, stderr)."""
    old_argv, old_env = sys.argv, dict(os.environ)
    sys.argv = [script] + argv
    for k in ("QAUDION_LOKI_URL", "LOKI_URL", "QA_LOKI_QUERY_PW"):
        os.environ.pop(k, None)
    os.environ.update(env or {})
    out, err = io.StringIO(), io.StringIO()
    code = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            runpy.run_path(os.path.join(HERE, script), run_name="__main__")
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    finally:
        sys.argv = old_argv
        os.environ.clear()
        os.environ.update(old_env)
    return code, out.getvalue(), err.getvalue()


class _Fake(http.server.BaseHTTPRequestHandler):
    seen = []
    status = 200

    def do_GET(self):
        _Fake.seen.append((self.path, self.headers.get("Authorization")))
        body = json.dumps({"status": "success",
                           "data": {"resultType": "streams", "result": []}}).encode()
        self.send_response(_Fake.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), _Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % srv.server_address[1]
DEAD = "http://127.0.0.1:9"          # discard port: connection refused

SCRIPTS = (("correlate-call", ["--loki", "--call-id", "91fe5cf7-3572-42f1-9b84-29883f47bab6"]),
           ("synth-traces", ["--call-id", "91fe5cf7", "--dry-run"]))

for name, base_args in SCRIPTS:
    m = load(name)
    tag = name
    # ---- default / env / normalisation
    saved = {k: os.environ.pop(k, None) for k in ("QAUDION_LOKI_URL", "LOKI_URL")}
    try:
        d = m.default_loki_url()
        check(d == m.LOKI_TUNNEL_URL and d.startswith("http://127.0.0.1:"), "%s: default is not the tunnel: %r" % (tag, d))
        check("dash.bcrypto.com" not in d, "%s: default still points at the public host" % tag)
        os.environ["LOKI_URL"] = "http://10.0.0.5:3100"
        check(m.default_loki_url() == "http://10.0.0.5:3100/loki/api/v1/query_range", "%s: LOKI_URL base not normalised" % tag)
        os.environ["QAUDION_LOKI_URL"] = "http://10.0.0.6:3100/"
        check(m.default_loki_url() == "http://10.0.0.6:3100/loki/api/v1/query_range", "%s: QAUDION_LOKI_URL does not win" % tag)
        full = "http://h:1/loki/api/v1/query_range?x=1"
        check(m.normalize_loki_url(full) == full, "%s: a full URL was rewritten" % tag)
        check(m.normalize_loki_url("") == m.LOKI_TUNNEL_URL, "%s: empty -> tunnel" % tag)
    finally:
        for k in ("QAUDION_LOKI_URL", "LOKI_URL"):
            os.environ.pop(k, None)
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v

    # ---- --help works and keeps the other options
    code, out, err = run_main(name + ".py", ["--help"])
    text = out + err
    check(code == 0, "%s: --help exit %r" % (tag, code))
    check("QAUDION_LOKI_URL" in text and "--loki-url" in text and "--call-id" in text,
          "%s: --help lost options / the new env var" % tag)
    check("dash.bcrypto.com/loki/api" not in text, "%s: --help still shows the public Loki URL" % tag)

    # ---- unreachable Loki: clear message, exit 1, no traceback
    code, out, err = run_main(name + ".py", base_args + ["--loki-url", DEAD])
    check(code == 1, "%s: unreachable Loki exit %r (want 1)" % (tag, code))
    check("cannot reach Loki" in err and "ssh -N -L" in err and "QAUDION_LOKI_URL" in err,
          "%s: unreachable message lacks the tunnel hint: %r" % (tag, err[-200:]))
    check("Traceback" not in err + out, "%s: traceback on an unreachable Loki" % tag)

    # ---- fake Loki: base URL from the env var, no password, no Authorization header
    _Fake.seen[:] = []
    _Fake.status = 200
    code, out, err = run_main(name + ".py", base_args, env={"QAUDION_LOKI_URL": BASE})
    check(code in (0, 2), "%s: fake Loki run exit %r: %r" % (tag, code, err[-200:]))
    check(len(_Fake.seen) == 1 and _Fake.seen[0][0].startswith("/loki/api/v1/query_range?"),
          "%s: request path wrong: %r" % (tag, _Fake.seen))
    check(_Fake.seen and _Fake.seen[0][1] is None, "%s: an Authorization header was sent without a password" % tag)
    check("no auth" in out, "%s: banner does not say 'no auth'" % tag)

    # ---- with a password the Basic header is sent
    _Fake.seen[:] = []
    code, out, err = run_main(name + ".py", base_args + ["--loki-url", BASE, "--loki-pw", "x"])
    check(_Fake.seen and (_Fake.seen[0][1] or "").startswith("Basic "), "%s: --loki-pw did not send Basic auth" % tag)

    # ---- 404 from the old public host name is explained (host check is textual)
    _Fake.seen[:] = []
    _Fake.status = 404
    code, out, err = run_main(name + ".py", base_args + ["--loki-url", BASE + "/loki/api/v1/query_range#dash.bcrypto.com"])
    check(code == 1, "%s: HTTP 404 exit %r" % (tag, code))
    _Fake.status = 200

srv.shutdown()
print("checks=%d failures=%d" % (checks, len(failures)))
for f in failures:
    print("  FAIL: " + f)
sys.exit(1 if failures else 0)
