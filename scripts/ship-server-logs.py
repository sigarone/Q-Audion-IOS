#!/usr/bin/env python3
"""
ship-server-logs.py -- ship bcrypto-server (Go slog) journal lines from the PROD
VPS into a Loki OTLP/JSON log backend, FAIL-CLOSED redacted at translation time.

This is a SAFE, read-only-on-the-VPS dev-box tool. It is the SERVER-leg
counterpart of ship-ios-logs.py. Together the two legs JOIN in Loki on ONE
shared attribute: qa.call.short8 (the plaintext first-8 of the call_id). The
server already logs the call_id (full at 1:1 sites, short8 at group sites), and
correlate-call.py already keys on that same prefix, so promoting it to a Loki
filter field is privacy-neutral and is what makes a single Grafana query
   {service_name=~"qaudion.*"} | qa_call_short8="91fe5cf7"
return the iOS leg AND the server leg of one call.

What it does:
  - SSHes to the prod VPS the SAME way fetch-ios-live.py / correlate-call.py do
    (env vars QAUDION_VPS_HOST/USER/PASS, else bcrypto-server/VPS_ACCESS.md)
  - runs `journalctl -u bcrypto-server -o json` ONCE (read-only, no restart),
    incrementally via a journald __CURSOR watermark stored in a state file
    (~/.qaudion/ship-server-logs.state.json); first run is bounded by --since.
  - parses each JSON record's MESSAGE (the Go slog TextHandler line:
    time=<ISO-Zulu-ms> level=<LEVEL> msg="..." key=value ...)
  - keeps only CALL-RELEVANT lines (msg/scope is call/ice/media/crypto/relay/
    audio/group_call or carries a call_id) -- everything else is dropped.
  - REDACTS EVERY line FAIL-CLOSED. A body reaches the backend ONLY if it is
    PROVABLY SAFE structured telemetry. The whole-record DROP-list catches
    panics / stack traces / pubkey_prefix / Authorization / tokens before they
    can ever ship. RAW high-entropy NEVER reaches the backend.
  - maps to an OTLP/JSON ExportLogsServiceRequest:
      service.name        = qaudion-server
      service.instance.id = the NODE id (eu-fi-1 / ...), NEVER a user id
      scope               = qaudion.call / qaudion.ice / ... (from msg/scope)
      severity            = from level=
    and emits the ALLOW-LISTED attributes: qa.call.short8 (the join key),
    qa.node, qa.call.state, qa.role, qa.media.mode, qa.ice.state, qa.retry.count.
  - batch-POSTs to the Loki OTLP endpoint with a bearer token from the env var
    QA_LOG_INGEST_TOKEN (--ingest-token overrides). Loki returns 204 on success.
    The cursor is advanced ONLY after a batch POSTs 204 (fail-closed delivery).

NO app build. NO prod write. NO external LLM. Pure ASCII output.

=== HARD PRIVACY INVARIANT (read before editing the redaction) ==============
This ships logs from a post-quantum ENCRYPTED VOICE app's SERVER into a
QUERYABLE Loki backend. After shipping, anyone with Grafana/query access can
full-text search every body. journald carries panics, stack traces, and err=
strings that can embed secrets, so this shipper is FAIL-CLOSED:

  SHIP A BODY ONLY IF IT IS PROVABLY SAFE. NOT "ship unless a secret matches".

The body redactor is a positive structured-shape gate backed by a whole-record
DROP-list + deny scrub + residual-entropy tripwire (same machinery as
ship-ios-logs.py). Every OTLP attribute (resource AND record) is allow-listed
by KEY and validated/enum-checked by VALUE.

The ONLY plaintext id that is allowed to ship is qa.call.short8 -- the first 8
chars of the call_id. That is intentional and is the cross-leg join key; it is
already in journald and is already what correlate-call.py matches on, so it is
NOT a new disclosure.

FORBIDDEN to ever reach the backend: message plaintext / SAS words, crypto keys
/ PSK / ML-KEM ciphertext / tokens / JWT, identity public keys / fingerprints /
pubkey_prefix, raw long-lived user / account / device / peer UUIDs (only short8
forms the server already emits, plus the call_id short8 join key), serial /
IMEI / MAC, SDP, ICE candidate IPs, TURN creds, audio / base64 media, SSID.

Usage:
  python scripts/ship-server-logs.py --dry-run
  python scripts/ship-server-logs.py --since 180 --node eu-fi-1
  python scripts/ship-server-logs.py --endpoint https://dash.bcrypto.com/otlp/v1/logs
  QA_LOG_INGEST_TOKEN=... python scripts/ship-server-logs.py --node eu-fi-1
  python scripts/ship-server-logs.py --selftest

Options:
  --since          First-run lookback in MINUTES (default 180). Ignored once a
                   cursor exists (the cursor is the watermark).
  --max-records    journalctl -n cap per run (default 20000).
  --node           service.instance.id (node id). Default QA_NODE_ID env, else
                   eu-de-1 (prod). Validated against a node-id allow-list.
  --endpoint       Loki OTLP/JSON logs endpoint
                   (default https://dash.bcrypto.com/otlp/v1/logs).
  --ingest-token   Bearer token; overrides env QA_LOG_INGEST_TOKEN.
  --env            deployment.environment.name (default production).
  --batch          Log records per HTTP POST (default 500).
  --state-file     Local JSON state path
                   (default ~/.qaudion/ship-server-logs.state.json).
  --dry-run        Print the redacted OTLP that WOULD ship; push nothing; do NOT
                   advance the cursor.
  --reset-state    Ignore prior cursor; re-ship from --since.
  --selftest       Run the privacy redaction regression suite and exit.

Requires:
  - paramiko (`pip install paramiko`)
  - VPS credentials (env vars or bcrypto-server/VPS_ACCESS.md), same as
    fetch-ios-live.py / correlate-call.py.
"""

import os
import re
import sys
import json
import time
import shlex
import hashlib
import argparse
import unicodedata
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

try:
    import paramiko
except ImportError:
    print("ERROR: paramiko not installed. `pip install paramiko`", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# VPS creds + SSH helpers -- duplicated from fetch-ios-live.py /
# correlate-call.py (NOT imported: those modules are hyphenated and load creds
# at import time; we keep these tools independent and importlib-free per the
# integration spec).
# ---------------------------------------------------------------------------

def _load_vps_creds():
    """Load VPS credentials from environment variables or VPS_ACCESS.md.

    Same precedence + same regexes as fetch-ios-live.py / correlate-call.py:
    env first, then the sibling bcrypto-server/VPS_ACCESS.md (values may be
    wrapped in markdown backticks).
    """
    host = os.environ.get("QAUDION_VPS_HOST")
    user = os.environ.get("QAUDION_VPS_USER")
    password = os.environ.get("QAUDION_VPS_PASS")
    if host and user and password:
        return host, user, password

    candidates = [
        Path(__file__).parent.parent.parent / "bcrypto-server" / "VPS_ACCESS.md",
        Path.home() / "DEV APP" / "BCRYPTO" / "apps" / "bcrypto-server" / "VPS_ACCESS.md",
    ]
    for p in candidates:
        if p.exists():
            text = p.read_text(encoding="utf-8")
            h = re.search(r"\*\*IP\*\*:\s*`?([^`\s]+)", text)
            u = re.search(r"\*\*SSH\*\*:\s*`?(\w+)@", text)
            pw = re.search(r"\*\*Password root\*\*:\s*`?([^`\s]+)", text)
            if h and u and pw:
                return h.group(1), u.group(1), pw.group(1)

    print("ERROR: VPS credentials not found.", file=sys.stderr)
    print("Set env vars QAUDION_VPS_HOST / QAUDION_VPS_USER / QAUDION_VPS_PASS", file=sys.stderr)
    print("or place VPS_ACCESS.md in the bcrypto-server sibling repo.", file=sys.stderr)
    sys.exit(1)


VPS_HOST = None
VPS_USER = None
VPS_PASS = None
SERVICE_UNIT = "bcrypto-server"  # systemd unit name (binary is bcrypto-lite)


def _ensure_creds():
    """Lazy-load creds so --selftest never needs the VPS / VPS_ACCESS.md."""
    global VPS_HOST, VPS_USER, VPS_PASS
    if VPS_HOST is None:
        VPS_HOST, VPS_USER, VPS_PASS = _load_vps_creds()


def ssh_connect():
    _ensure_creds()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(VPS_HOST, username=VPS_USER, password=VPS_PASS, timeout=15)
    return client


def run(client, cmd):
    stdin, stdout, stderr = client.exec_command(cmd)
    return (
        stdout.read().decode("utf-8", errors="replace"),
        stderr.read().decode("utf-8", errors="replace"),
    )


# ---------------------------------------------------------------------------
# Time + ascii helpers -- duplicated from correlate-call.py (importlib-free).
# ---------------------------------------------------------------------------

def iso_to_ms(ts):
    """Parse an ISO8601 ms-Zulu timestamp ('2026-06-23T07:08:46.134Z') to epoch
    ms (UTC). Returns float ms, or None on failure."""
    if not ts:
        return None
    s = ts.strip()
    try:
        dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ")
        return dt.replace(tzinfo=timezone.utc).timestamp() * 1000.0
    except ValueError:
        pass
    try:
        s2 = s.replace("Z", "+00:00") if s.endswith("Z") else s
        dt = datetime.fromisoformat(s2)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).timestamp() * 1000.0
    except ValueError:
        return None


def _ascii(s):
    """Force ASCII so output is safe on any console codepage (cp1252 etc).
    Server msgs may carry unicode; replace rather than crash."""
    return s.encode("ascii", "replace").decode("ascii")


def out(line=""):
    print(_ascii(line))


def hmac8(raw):
    """Stable, NON-reversible, NON-identifying 8-hex digest of a value. A digest,
    not a prefix: it never leaks real bits of the source value."""
    if not raw:
        return ""
    return hashlib.sha256(str(raw).encode("utf-8")).hexdigest()[:8]


_ELLIPSIS = "\u2026"  # HORIZONTAL ELLIPSIS escape (source pure-ASCII)


def normalize_id(raw):
    """Lowercase, strip trailing ellipsis (unicode U+2026 and ASCII dots) and
    whitespace. SAME canonicalization as correlate-call.py:normalize_id, so the
    server-leg short8 collapses to the identical value as the iOS-leg short8."""
    if raw is None:
        return ""
    s = raw.strip()
    s = s.rstrip()
    s = s.rstrip(_ELLIPSIS)
    s = s.rstrip(".")
    s = s.rstrip(_ELLIPSIS)
    return s.strip().lower()


def call_short8(raw):
    """THE JOIN KEY. canon(call_id)[:8]: lowercased, ellipsis/dot-stripped, first
    8 chars of whatever call_id form the server logged.

    - 1:1 sites log the FULL call_id  -> [:8] is the true short8.
    - group sites log short8(d.CallID) (<=8 chars) -> [:8] is a no-op.
    Both collapse to the SAME 8-char value space, and that space is identical to
    the iOS leg's canon(call_id)[:8] (ship-ios-logs.py qa.call.short8).

    The >= 8 floor (NOT >= 6) is load-bearing and MUST match
    ship-ios-logs.py:call_short8 AND correlate-call.py:build_matcher
    (short8 = norm[:8] if len(norm) >= 8 else ""). A 6/7-char id therefore yields
    "" on every leg, so no leg ever emits a join value the canonical matcher
    cannot reproduce. Fail-closed: emit no key rather than a non-joinable one."""
    norm = normalize_id(raw)
    return norm[:8] if len(norm) >= 8 else ""


# ---------------------------------------------------------------------------
# UNICODE NORMALIZATION (close the full-width / homoglyph bypass).
# ---------------------------------------------------------------------------

def _nfkc(s):
    if s is None:
        return ""
    try:
        return unicodedata.normalize("NFKC", s)
    except Exception:
        return s


# ---------------------------------------------------------------------------
# Go slog TextHandler line parsing.
#   time=2026-06-23T07:08:46.134Z level=INFO msg="call started" call_id=... ...
# Values may be bare tokens or double-quoted (slog quotes when the value has a
# space). We do NOT trust the line; we extract time/level/msg + the trailing
# attrs, then the body redactor + attribute extractor (allow-list) take over.
# ---------------------------------------------------------------------------

_GO_TIME_RE = re.compile(r"\btime=(\S+)")
_GO_LEVEL_RE = re.compile(r"\blevel=(\w+)")
# msg="..." (quoted) OR msg=token (unquoted single word).
_GO_MSG_QUOTED_RE = re.compile(r'\bmsg="((?:[^"\\]|\\.)*)"')
_GO_MSG_BARE_RE = re.compile(r"\bmsg=(\S+)")


def parse_slog_line(message):
    """Parse a Go slog TextHandler MESSAGE into (ms, level, msg_value, full_line).

    ms     : epoch ms from time= (None if unparseable -> record dropped).
    level  : the level= token (INFO/WARN/...), default INFO.
    msg_value : the msg="..." text (unescaped) if present, else "".
    full_line : the entire slog line (used as the redaction haystack so the
                trailing key=value attrs are scrubbed too).
    """
    if not message:
        return None, "INFO", "", ""
    line = message.rstrip("\r\n")

    ms = None
    gt = _GO_TIME_RE.search(line)
    if gt:
        ms = iso_to_ms(gt.group(1))

    lvl_m = _GO_LEVEL_RE.search(line)
    level = lvl_m.group(1).upper() if lvl_m else "INFO"

    msg_value = ""
    mq = _GO_MSG_QUOTED_RE.search(line)
    if mq:
        msg_value = mq.group(1).replace('\\"', '"').replace("\\\\", "\\")
    else:
        mb = _GO_MSG_BARE_RE.search(line)
        if mb:
            msg_value = mb.group(1)

    return ms, level, msg_value, line


# ---------------------------------------------------------------------------
# CALL-RELEVANCE FILTER (deny-by-default for non-call noise).
# A record ships only if its slog msg/scope is call-relevant OR it carries a
# call_id key. Everything else (health pings, mem stats, auth, vpn, db) is
# dropped before redaction -- it is not what this shipper is for.
# ---------------------------------------------------------------------------

_RE_HAS_CALLID = re.compile(r"\bcall[ _]?id\s*[=:]", re.IGNORECASE)

# msg-prefix -> OTLP scope. Longest-prefix-ish; we test membership by startswith
# on the lowercased msg token. Mirrors the server's slog msg vocabulary
# (main.go: "call started", "call status: ...", "call_ready", "call_processing",
# "group_call_*", "call auto-tracked from audio", etc.).
MSG_SCOPE_PREFIXES = [
    ("group_call", "call"),
    ("call_ready", "call"),
    ("call_processing", "call"),
    ("call status", "call"),
    ("call started", "call"),
    ("call auto-tracked", "call"),
    ("call_", "call"),
    ("call ", "call"),
    ("ice", "ice"),
    ("media", "media"),
    ("relay", "media"),
    ("audio", "media"),
    ("crypto", "crypto"),
    ("seal", "crypto"),
    ("unseal", "crypto"),
]


def resolve_scope(msg_value, full_line):
    """Return (scope_name, is_call_relevant).

    scope_name is 'qaudion.<scope>'. is_call_relevant gates whether the record
    ships at all. A line is call-relevant if its msg matches a known call/ice/
    media/crypto prefix OR it carries a call_id key anywhere."""
    m = (msg_value or "").strip().lower()
    for prefix, scope in MSG_SCOPE_PREFIXES:
        if m.startswith(prefix):
            return "qaudion." + scope, True
    if _RE_HAS_CALLID.search(full_line or ""):
        return "qaudion.call", True
    return "qaudion.unknown", False


# ---------------------------------------------------------------------------
# REDACTION -- FAIL-CLOSED. Same machinery as ship-ios-logs.py, adapted to the
# Go-authored key=value line shape (which is already structured, so it passes
# the gate legitimately, while the DROP-list + scrub stay strict).
# ---------------------------------------------------------------------------

PLACEHOLDER = "[REDACTED:secret]"
RE_SECRET_PREFIXED = re.compile(
    r"(?i)(bearer|authorization|token|secret|api[-_]?key|password)([\"'\s:=]+)\S+")
RE_LONG_BLOB = re.compile(r"[A-Za-z0-9+/=_-]{16,}")

RE_RAW_UUID = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
# call_id key value -> scrub from the BODY. The short8 join key is carried only
# as an attribute (extracted from the ORIGINAL line BEFORE this runs), never as
# raw body text -- the raw call_id must not appear in the queryable body.
RE_CALLID_KEY = re.compile(r"(?i)call[ _]?id\s*[=:]\s*\S+")
RE_DEVICE_KEY = re.compile(
    r"(?i)\b(device[ _]?name|devicename|device[ _]?id|model|hostname|"
    r"machine|udid|serial(?:[ _]?no)?)\b\s*[=:]\s*\S+")
RE_SECRET_KV = re.compile(
    r"(?i)\b(psk|mlkem|ml[-_]?kem|ciphertext|privkey|private[-_]?key|pubkey|"
    r"public[-_]?key|pubkey[-_]?prefix|fingerprint|sas|imei|serial|turn|"
    r"ice[-_]?pwd|ice[-_]?ufrag|passwd|ssid|key|nonce|iv|tag|pop|csr|"
    r"sender|receiver|peer|caller|callee|user|creator|kid|identity)\b"
    r"\s*[=:]\s*\S+")
RE_MAC = re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b")
RE_IPV6 = re.compile(r"\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b")
RE_IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
RE_EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b")
RE_PHONE = re.compile(r"(?<!\d)\+?\d[\d\s().\-/]{6,}\d(?!\d)")
RE_JWT_DOTTED = re.compile(r"\b[A-Za-z0-9_-]{6,}(?:\.[A-Za-z0-9_-]{4,}){1,}\b")
RE_SPACED_HEX = re.compile(r"\b(?:[0-9a-fA-F]{4,8}\s){2,}[0-9a-fA-F]{4,8}\b")
RE_HEX_BLOB = re.compile(r"\b[0-9a-fA-F]{12,}\b")
RE_BASE64_BLOB = re.compile(r"[A-Za-z0-9+/=_\-]{12,}")

# Ordered list of strengthening rules (kind, regex). Keyed/structured first,
# spaced-hex before contiguous sweeps, broad blob/base64 last.
STRENGTHEN_RULES = [
    ("callid", RE_CALLID_KEY),
    ("device", RE_DEVICE_KEY),
    ("secret", RE_SECRET_KV),
    ("uuid", RE_RAW_UUID),
    ("mac", RE_MAC),
    ("email", RE_EMAIL),
    ("ipv6", RE_IPV6),
    ("hex", RE_SPACED_HEX),
    ("ipv4", RE_IPV4),
    ("phone", RE_PHONE),
    ("jwt", RE_JWT_DOTTED),
    ("hex", RE_HEX_BLOB),
    ("blob", RE_BASE64_BLOB),
]

# Whole-record DROP-list (matched on the NFKC-normalized lowercased line). Any
# hit => DROP the whole record (do not ship even scrubbed). Server-specific:
# panics, stack traces, identity material, auth.
SERVER_DROP_SUBSTRINGS = [
    "pubkey", "pubkey_prefix", "mlkem", "ml-kem", "ml_kem", "ciphertext",
    "private", "privkey", "authorization:", "authorization=", "bearer ",
    "token=", "secret", "password", "passwd", "-----begin", " pop=", "csr",
    "fingerprint", "identity", "panic:", "goroutine ", "runtime error",
    "signal sigsegv", "stack trace", "\tgithub.com", "x25519", "eddsa",
    "sas", "safety number", "plaintext", "cleartext", "decrypted",
    "transcript", "ssid", "device_name", "devicename",
]

RE_RESIDUAL_B64 = re.compile(r"[A-Za-z0-9+/=_\-]{12,}")
RE_RESIDUAL_HEX = re.compile(r"\b[0-9a-fA-F]{12,}\b")

MAX_FREEWORD_RUN = 3

TELEMETRY_VOCAB = frozenset([
    "new", "checking", "connected", "completed", "failed", "disconnected",
    "closed", "gathering", "ringing", "dialing", "active", "encrypted",
    "ended", "half_open", "connecting", "idle", "open", "opening", "start",
    "started", "stop", "stopped", "ok", "error", "warn", "info", "debug",
    "fatal", "retry", "retrying", "timeout", "abort", "aborted", "done",
    "init", "ready", "pending", "success", "fail", "drop", "dropped",
    "caller", "callee", "offerer", "answerer", "datachannel", "relay",
    "ws_relay", "ws-relay", "direct_p2p", "p2p", "host", "srflx", "prflx",
    "wifi", "cellular", "ethernet", "loopback", "other", "none",
    "helsinki", "frankfurt", "milano",
    "call", "ice", "media", "crypto", "net", "voicenote", "livelog",
    "stdout", "state", "role", "mode", "node", "count", "seq", "frame",
    "frames", "bytes", "ms", "sec", "peer", "self", "remote", "local",
    "candidate", "offer", "answer", "rx", "tx", "sent", "recv", "received",
    "and", "to", "of", "at", "is", "via", "for", "with",
    # server msg vocabulary (call_started / call_ready / group_call_* etc.)
    "status", "processing", "auto-tracked", "from", "audio", "tracked",
    "group_call", "create", "created", "join", "joined", "leave", "left",
    "end", "duration", "started:", "status:", "started",
])

RE_KV_TOKEN = re.compile(r"^[A-Za-z][A-Za-z0-9_.\-]*[=:].*$")
RE_NUM_TOKEN = re.compile(r"^[+\-]?\d[\d.,:]*[A-Za-z%]*$")
RE_PLACEHOLDER_TOKEN = re.compile(r"^\[REDACTED:[a-z]+\]$")
RE_PUNCT_TOKEN = re.compile(r"^[\W_]+$")
RE_FREEWORD = re.compile(r"^[A-Za-z][A-Za-z'\-]{2,}$")
# Bare mixed-alphanumeric token (letters AND digits, >=8 chars) that slips the
# >=12 blob/residual sweeps -- shape of a truncated PSK prefix / short PIN /
# base32 secret fragment. HARD FAIL in the gate (fall back to attribute summary)
# rather than counting it as one free word. Same defense as ship-ios-logs.py.
RE_MIXED_ALNUM_SECRET = re.compile(
    r"^(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{8,}$")

BODY_CAP = 512

RE_SDP_ATTR = re.compile(r"^\s*[vostmacbiyzk]=", re.IGNORECASE)
SDP_TOKENS = (
    "a=candidate", "a=fingerprint", "m=audio", "m=video",
    "ice-ufrag", "ice-pwd", "rtpmap", "rtcp", "setup:actpass",
    "typ host", "typ srflx", "typ relay", "typ prflx",
)


def _is_sdp_line(body):
    """True if ANY line of the body is an SDP / ICE / DTLS line (drop record)."""
    low = body.lower()
    for tok in SDP_TOKENS:
        if tok in low:
            return True
    for ln in body.splitlines():
        if RE_SDP_ATTR.match(ln.strip()):
            return True
    return False


def _scrub_body(body):
    """Run the mirror patterns + strengthening rules over a (normalized) body."""
    s = body
    s = RE_SECRET_PREFIXED.sub(PLACEHOLDER, s)
    s = RE_LONG_BLOB.sub("[REDACTED:blob]", s)
    for kind, rx in STRENGTHEN_RULES:
        s = rx.sub("[REDACTED:%s]" % kind, s)
    return s


def _has_residual_secret(body):
    """True if a scrubbed body STILL looks high-entropy -> drop to summary."""
    if RE_RESIDUAL_B64.search(body):
        return True
    if RE_RESIDUAL_HEX.search(body):
        return True
    if RE_RAW_UUID.search(body):
        return True
    if RE_JWT_DOTTED.search(body):
        return True
    return False


def _passes_structured_gate(scrubbed):
    """POSITIVE allow-list. Ships ONLY if recognizably structured telemetry.
    (Same two-condition gate as ship-ios-logs.py.)"""
    run_n = 0
    free = 0
    structural = 0
    for tok in scrubbed.split():
        if RE_PLACEHOLDER_TOKEN.match(tok):
            run_n = 0
            structural += 1
            continue
        if RE_KV_TOKEN.match(tok):
            run_n = 0
            structural += 1
            continue
        if RE_NUM_TOKEN.match(tok):
            run_n = 0
            structural += 1
            continue
        if RE_PUNCT_TOKEN.match(tok):
            run_n = 0
            continue
        # HARD FAIL on a bare mixed-alnum secret-shaped token (8-11 chars slip
        # the >=12 blob sweeps). Checked on the RAW token and the stripped core.
        if RE_MIXED_ALNUM_SECRET.match(tok):
            return False
        core = tok.strip("[](){}<>.,:;!?\"'").lower()
        if RE_MIXED_ALNUM_SECRET.match(core):
            return False
        if core in TELEMETRY_VOCAB:
            run_n = 0
            structural += 1
            continue
        if len(core) <= 2:
            continue
        if RE_FREEWORD.match(core):
            run_n += 1
            free += 1
            if run_n > MAX_FREEWORD_RUN:
                return False
            continue
        run_n += 1
        free += 1
        if run_n > MAX_FREEWORD_RUN:
            return False
    if free == 0:
        return True
    if structural == 0:
        return False
    return free <= structural


def _attribute_summary(attrs):
    """Build a safe, structured body from already-extracted allow-listed attrs."""
    if not attrs:
        return ""
    parts = []
    for k in ALLOWED_ATTR_KEYS:
        if k in attrs:
            short = k.split(".")[-1]
            parts.append("%s=%s" % (short, attrs[k]))
    return "[summary] " + " ".join(parts) if parts else ""


def redact_body(orig_line, scope_safe, attrs):
    """FAIL-CLOSED body redaction. Returns (kept: bool, body: str).

    orig_line is the FULL slog line (so trailing key=value attrs are scrubbed
    too). Steps mirror ship-ios-logs.py:
      1. NFKC-normalize.
      2. whole-record DROP-list (panics / pubkey / auth / secrets) -> DROP.
      3. SDP / ICE / DTLS (any line) -> DROP.
      4. not call-relevant scope -> DROP body.
      5. scrub secrets (deny patterns -> bounded placeholders).
      6. residual high-entropy tripwire -> attribute summary fallback.
      7. POSITIVE structured-shape gate -> attribute summary if not structured.
      8. hard length cap; empty -> DROP.
    """
    if orig_line is None:
        return False, ""

    norm = _nfkc(orig_line)
    low = norm.lower()

    for needle in SERVER_DROP_SUBSTRINGS:
        if needle in low:
            return False, ""

    if _is_sdp_line(norm):
        return False, ""

    if not scope_safe:
        return False, ""

    scrubbed = _scrub_body(norm)

    if _has_residual_secret(scrubbed):
        scrubbed = _attribute_summary(attrs)
    elif not _passes_structured_gate(scrubbed):
        scrubbed = _attribute_summary(attrs)

    if len(scrubbed) > BODY_CAP:
        scrubbed = scrubbed[:BODY_CAP] + "...[trunc]"
    if not scrubbed.strip():
        return False, ""

    return True, scrubbed


# ---------------------------------------------------------------------------
# lvl -> OTLP severity. level= is the slog word form (INFO/WARN/...).
# ---------------------------------------------------------------------------

SEVERITY = {
    "DEBUG": (5, "DEBUG"),
    "INFO": (9, "INFO"),
    "WARN": (13, "WARN"),
    "WARNING": (13, "WARN"),
    "ERROR": (17, "ERROR"),
    "FATAL": (21, "FATAL"),
}


def map_severity(level):
    """Map the slog level word to (severityNumber:int, severityText:str)."""
    key = (level or "").strip().upper()
    return SEVERITY.get(key, (0, "UNSPECIFIED"))


# ---------------------------------------------------------------------------
# RECORD-LEVEL ATTRIBUTE ALLOW-LIST (deny-by-default).
# qa.call.short8 is THE JOIN KEY -- the plaintext first-8 of the call_id, the
# ONLY plaintext id allowed (already in journald, correlate-call-compatible).
# Everything else is enum-validated; nothing else may ride along.
# ---------------------------------------------------------------------------

ALLOWED_ATTR_KEYS = (
    "qa.call.short8", "qa.role", "qa.media.mode",
    "qa.retry.count", "qa.node", "qa.ice.state", "qa.call.state",
)

_RE_CALLID_VALUE = re.compile(
    r"call[ _]?id\s*[=:]\s*\"?([0-9a-fA-F][0-9a-fA-F\-]{3,})", re.IGNORECASE)
_RE_ROLE = re.compile(r"\brole\s*[=:]\s*\"?(caller|callee|offerer|answerer)\b",
                      re.IGNORECASE)
_RE_MEDIA_MODE = re.compile(
    r"\b(?:media[ _]?mode|mediaMode)\s*[=:]\s*\"?(datachannel|ws[-_]?relay|"
    r"relay|direct_p2p|p2p)\b", re.IGNORECASE)
_RE_RETRY = re.compile(r"\bretry(?:[ _]?count)?\s*[=:]\s*(\d{1,4})\b",
                       re.IGNORECASE)
_RE_NODE = re.compile(r"\bnode\s*[=:]\s*\"?([a-z]{2}[-_]?[a-z]{0,2}\d?|"
                      r"helsinki|frankfurt|milano)\b", re.IGNORECASE)
_RE_ICE_STATE = re.compile(
    r"\bice(?:[ _]?state)?\s*[=:]\s*\"?(new|checking|connected|completed|failed|"
    r"disconnected|closed|gathering)\b", re.IGNORECASE)
_RE_CALL_STATE = re.compile(
    r"\b(?:call[ _]?state|state|status)\s*[=:]\s*\"?(ringing|dialing|active|"
    r"encrypted|ended|started|half_open|connecting|idle|ready|processing)\b",
    re.IGNORECASE)

_ROLE_ENUM = frozenset(["caller", "callee", "offerer", "answerer"])
_MEDIA_ENUM = frozenset(["datachannel", "ws-relay", "ws_relay", "relay",
                         "direct_p2p", "p2p"])
_NODE_ENUM = frozenset(["helsinki", "frankfurt", "milano",
                        "fi", "de", "it", "fi1", "de1", "it1",
                        "eu-fi-1", "eu-de-1", "eu-it-1",
                        "eu_fi_1", "eu_de_1", "eu_it_1"])
_ICE_ENUM = frozenset(["new", "checking", "connected", "completed", "failed",
                       "disconnected", "closed", "gathering"])
_CALL_STATE_ENUM = frozenset(["ringing", "dialing", "active", "encrypted",
                              "ended", "started", "half_open", "connecting",
                              "idle", "ready", "processing"])


def extract_attributes(orig_line, node_id):
    """Build the allow-listed attribute set from the NFKC-normalized ORIGINAL
    slog line. Deny-by-default: only ALLOWED_ATTR_KEYS may appear, only
    enum-validated values. qa.call.short8 is the plaintext prefix (the join
    key); qa.node is the resource node id, mirrored onto the record for filter
    convenience."""
    attrs = {}
    if not orig_line:
        return attrs
    line = _nfkc(orig_line)

    m = _RE_CALLID_VALUE.search(line)
    if m:
        s8 = call_short8(m.group(1))
        if s8:
            attrs["qa.call.short8"] = s8

    # node id always rides along (resource-level node mirrored to record).
    if node_id:
        attrs["qa.node"] = node_id

    m = _RE_ROLE.search(line)
    if m and m.group(1).lower() in _ROLE_ENUM:
        attrs["qa.role"] = m.group(1).lower()

    m = _RE_MEDIA_MODE.search(line)
    if m and m.group(1).lower() in _MEDIA_ENUM:
        attrs["qa.media.mode"] = m.group(1).lower()

    m = _RE_RETRY.search(line)
    if m:
        attrs["qa.retry.count"] = m.group(1)

    m = _RE_ICE_STATE.search(line)
    if m and m.group(1).lower() in _ICE_ENUM:
        attrs["qa.ice.state"] = m.group(1).lower()

    m = _RE_CALL_STATE.search(line)
    if m and m.group(1).lower() in _CALL_STATE_ENUM:
        attrs["qa.call.state"] = m.group(1).lower()

    return {k: v for k, v in attrs.items() if k in ALLOWED_ATTR_KEYS}


# ---------------------------------------------------------------------------
# NODE ID validation (service.instance.id MUST be a node id, NEVER a user id).
# ---------------------------------------------------------------------------

RE_NODE_ID = re.compile(r"^[a-z]{2}[-_]?[a-z]{0,2}[-_]?\d{0,2}$")


def validate_node_id(raw, host):
    """Return a safe node id. Accepts the cluster node-id allow-list shape
    (eu-fi-1, eu-de-1, fi1, de, ...). A value that does not match the shape is
    rejected and replaced with a stable non-identifying node-<hmac8(host)>."""
    s = (raw or "").strip().lower()
    if s and (s in _NODE_ENUM or RE_NODE_ID.match(s)):
        return s
    return "node-" + hmac8(host or "unknown")


# ---------------------------------------------------------------------------
# OTLP/JSON construction.
# ---------------------------------------------------------------------------

SERVICE_NAME = "qaudion-server"


def _attr_str(key, value):
    return {"key": key, "value": {"stringValue": str(value)}}


def build_resource(node_id, env_name):
    """Build the OTLP resource. service.instance.id is the NODE id (validated),
    NEVER a user id. No host/IP/hostname is emitted."""
    attrs = [
        _attr_str("service.name", SERVICE_NAME),
        _attr_str("service.instance.id", node_id),
        _attr_str("qa.node", node_id),
        _attr_str("deployment.environment.name", env_name),
    ]
    return {"attributes": attrs}


def build_log_record(parsed, node_id):
    """parsed is (ms, level, msg_value, full_line). Returns an OTLP logRecord
    dict if the line is shippable, else None (dropped)."""
    ms, level, msg_value, full_line = parsed
    if ms is None:
        return None

    scope_name, scope_safe = resolve_scope(msg_value, full_line)
    attrs = extract_attributes(full_line, node_id)
    kept, body = redact_body(full_line, scope_safe, attrs)
    if not kept:
        return None

    sev_num, sev_text = map_severity(level)
    time_unix_nano = int(ms * 1_000_000)  # ms -> ns

    otlp_attrs = [_attr_str(k, v) for k, v in attrs.items()
                  if k in ALLOWED_ATTR_KEYS]

    return {
        "timeUnixNano": str(time_unix_nano),  # MUST be a quoted string
        "severityNumber": sev_num,            # MUST be an int
        "severityText": sev_text,
        "body": {"stringValue": body},
        "attributes": otlp_attrs,
    }, scope_name


def build_export_request(records, node_id, env_name):
    """Assemble a full ExportLogsServiceRequest. Groups logRecords by scope.
    records is a list of parsed tuples. Returns (request_dict, kept, dropped)."""
    resource = build_resource(node_id, env_name)

    by_scope = {}
    kept = 0
    dropped = 0
    for parsed in records:
        built = build_log_record(parsed, node_id)
        if built is None:
            dropped += 1
            continue
        lr, scope_name = built
        kept += 1
        by_scope.setdefault(scope_name, []).append(lr)

    scope_logs = []
    for scope_name, log_records in by_scope.items():
        scope_logs.append({
            "scope": {"name": scope_name},
            "logRecords": log_records,
        })

    request = {
        "resourceLogs": [{
            "resource": resource,
            "scopeLogs": scope_logs,
        }]
    }
    return request, kept, dropped


# ---------------------------------------------------------------------------
# HEARTBEAT -- ONE synthetic OTLP record emitted EVERY run (even when 0
# call-relevant lines were found), so a Grafana
#   absent_over_time({service_name="qaudion-server"} | scope="qaudion.shipper.heartbeat" [15m])
# alert can distinguish 'shipper DEAD' (no heartbeat) from 'no calls happened'
# (heartbeat present, records_read=0). The body is PRE-CLEARED structured
# telemetry: it is built ENTIRELY from integers this script computed about its
# OWN run (cursor_advanced / records_read / shipped / dropped / dropped_redact)
# -- it never touches journald text, so no user/crypto plaintext can enter it.
# It carries NO ingested attributes, only qa.node (the cluster node id).
# ---------------------------------------------------------------------------

HEARTBEAT_SCOPE = "qaudion.shipper.heartbeat"


def build_heartbeat_record(node_id, records_read, shipped, dropped,
                           dropped_redact, cursor_advanced, now_ms=None):
    """Return (otlp_logRecord, HEARTBEAT_SCOPE).

    The body is a fixed-shape ASCII string of integers/booleans this script
    derived about its own run -- NO journald text flows in, so it is provably
    safe and bypasses the redact gate as pre-cleared structured telemetry.
    `dropped_redact` (lines dropped BY redaction) is surfaced so over-redaction
    trends are observable in Grafana."""
    if now_ms is None:
        now_ms = time.time() * 1000.0
    time_unix_nano = int(now_ms * 1_000_000)  # ms -> ns

    body = ("[heartbeat] cursor_advanced=%s records_read=%d shipped=%d "
            "dropped=%d dropped_redact=%d"
            % ("true" if cursor_advanced else "false",
               int(records_read), int(shipped), int(dropped),
               int(dropped_redact)))

    attrs = [_attr_str("qa.node", node_id)] if node_id else []
    sev_num, sev_text = map_severity("INFO")
    return {
        "timeUnixNano": str(time_unix_nano),
        "severityNumber": sev_num,
        "severityText": sev_text,
        "body": {"stringValue": body},
        "attributes": attrs,
    }, HEARTBEAT_SCOPE


def build_heartbeat_request(node_id, env_name, records_read, shipped, dropped,
                            dropped_redact, cursor_advanced, now_ms=None):
    """Assemble a standalone ExportLogsServiceRequest carrying ONLY the
    heartbeat record. Shipped separately so it lands even when the call-relevant
    batch is empty (0 shippable lines) OR is being POSTed one-by-one under the
    poison-pill fallback."""
    lr, scope_name = build_heartbeat_record(
        node_id, records_read, shipped, dropped, dropped_redact,
        cursor_advanced, now_ms=now_ms)
    return {
        "resourceLogs": [{
            "resource": build_resource(node_id, env_name),
            "scopeLogs": [{
                "scope": {"name": scope_name},
                "logRecords": [lr],
            }],
        }]
    }


# ---------------------------------------------------------------------------
# Loki OTLP/JSON POST.
# ---------------------------------------------------------------------------

def post_otlp(endpoint, token, request_dict, timeout=30):
    """POST one ExportLogsServiceRequest as OTLP/JSON. Returns (status, body).
    Never raises on HTTP error; network errors surface as status=0."""
    payload = json.dumps(request_dict).encode("utf-8")
    req = urllib.request.Request(endpoint, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", errors="replace")
        except Exception:
            pass
        return e.code, body
    except Exception as e:
        return 0, str(e)


def _split_request_into_batches(request_dict, batch_size):
    """Split one ExportLogsServiceRequest into requests each carrying at most
    batch_size logRecords, preserving resource + scope grouping."""
    rl = request_dict["resourceLogs"][0]
    resource = rl["resource"]
    scope_logs = rl["scopeLogs"]

    flat = []
    for sl in scope_logs:
        name = sl["scope"]["name"]
        for lr in sl["logRecords"]:
            flat.append((name, lr))

    if not flat:
        return

    for i in range(0, len(flat), batch_size):
        chunk = flat[i:i + batch_size]
        grouped = {}
        for name, lr in chunk:
            grouped.setdefault(name, []).append(lr)
        yield {
            "resourceLogs": [{
                "resource": resource,
                "scopeLogs": [
                    {"scope": {"name": n}, "logRecords": recs}
                    for n, recs in grouped.items()
                ],
            }]
        }


# ---------------------------------------------------------------------------
# journald read (read-only, incremental via __CURSOR watermark).
# ---------------------------------------------------------------------------

def read_journal(client, cursor, since_minutes, max_records):
    """ONE read-only journalctl -o json call.

    If cursor is set -> --after-cursor <cursor> (incremental; the cursor is
    journald's native exactly-once watermark). Else -> --since "<N> min ago".
    Returns (records, last_cursor):
      records: list of (ms, level, msg_value, full_line) parsed tuples in
               journald order (ascending time).
      last_cursor: the __CURSOR of the LAST record seen, or the input cursor if
               nothing new (so a no-op run keeps the watermark)."""
    base = ("journalctl -u %s --no-pager -o json -n %d"
            % (SERVICE_UNIT, max_records))
    if cursor:
        cmd = base + " --after-cursor " + shlex.quote(cursor)
    else:
        cmd = base + " --since " + shlex.quote("%d min ago" % since_minutes)

    stdout_text, err = run(client, cmd)
    if err.strip():
        print("STDERR (journalctl):", err.strip(), file=sys.stderr)

    records = []
    last_cursor = cursor
    for line in stdout_text.split("\n"):
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        message = obj.get("MESSAGE")
        # journald MESSAGE may be a list of ints (binary) -> skip those.
        if isinstance(message, list):
            continue
        cur = obj.get("__CURSOR")
        if cur:
            last_cursor = cur
        if not message:
            continue
        parsed = parse_slog_line(message)
        # parsed[0] is ms; keep even if None so we count it, build drops it.
        records.append(parsed)
    return records, last_cursor


# ---------------------------------------------------------------------------
# State tracking (journald cursor watermark).
# ---------------------------------------------------------------------------

def default_state_path():
    return Path.home() / ".qaudion" / "ship-server-logs.state.json"


def load_state(path):
    """Load shipped cursor state. Shape:
        {"cursor": "<__CURSOR>", "ts": <epoch>,
         "fail_cursor": "<__CURSOR>", "fail_count": <int>}.

    fail_cursor / fail_count track the POISON-PILL guard: how many CONSECUTIVE
    runs the SAME un-advanced cursor failed its POST. Returns an empty skeleton
    if absent/corrupt."""
    try:
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                fc = data.get("fail_count", 0)
                try:
                    fc = int(fc)
                except (TypeError, ValueError):
                    fc = 0
                return {"cursor": data.get("cursor", ""),
                        "ts": data.get("ts", 0),
                        "fail_cursor": data.get("fail_cursor", ""),
                        "fail_count": fc}
    except Exception as e:
        print("WARN: state file unreadable (%s); starting fresh." % e,
              file=sys.stderr)
    return {"cursor": "", "ts": 0, "fail_cursor": "", "fail_count": 0}


def save_state(path, cursor, fail_cursor="", fail_count=0):
    """Persist the cursor watermark AND the poison-pill consecutive-fail count.

    fail_cursor is the cursor whose POST is currently failing; fail_count is how
    many consecutive runs it has failed. Both reset to ""/0 once delivery
    succeeds (the cursor advances)."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps({"cursor": cursor,
                                   "ts": int(time.time()),
                                   "fail_cursor": fail_cursor,
                                   "fail_count": int(fail_count)},
                                  indent=2), encoding="utf-8")
        tmp.replace(path)
    except Exception as e:
        print("WARN: could not persist state (%s)." % e, file=sys.stderr)


# ---------------------------------------------------------------------------
# Dry-run rendering.
# ---------------------------------------------------------------------------

def print_dry_run(request_dict):
    out()
    out("-" * 72)
    out("DRY-RUN OTLP (server leg)")
    out("-" * 72)
    rendered = json.dumps(request_dict, indent=2, ensure_ascii=True)
    print(_ascii(rendered))


# ---------------------------------------------------------------------------
# Self-test (privacy regression + JOIN-KEY reconcile). Run with --selftest.
# ---------------------------------------------------------------------------

def run_selftest():
    """Assert FORBIDDEN values never survive redaction AND that the join key
    reconciles with the iOS leg. Pure ASCII output. Exit 0 = pass, 1 = leak."""
    failures = []
    NODE = "eu-fi-1"

    def ship(line, msg_value=None):
        """Mimic build_log_record's redaction path; return (kept, body, attrs)."""
        if msg_value is None:
            mm = _GO_MSG_QUOTED_RE.search(line) or _GO_MSG_BARE_RE.search(line)
            msg_value = mm.group(1) if mm else ""
        scope, safe = resolve_scope(msg_value, line)
        attrs = extract_attributes(line, NODE)
        kept, body = redact_body(line, safe, attrs)
        return kept, (body if kept else ""), attrs

    def must_not_survive(line, forbidden, label, msg_value=None):
        kept, body, attrs = ship(line, msg_value)
        low = body.lower()
        for f in forbidden:
            if f.lower() in low:
                failures.append("LEAK[%s]: %r survived as %r" % (label, f, body))

    # 1. The decisive 1:1 'call started' line -- FULL call_id must NOT appear in
    #    body; only short8 in attrs.
    full = ('time=2026-06-23T07:08:46.134Z level=INFO msg="call started" '
            'call_id=91FE5CF7-3572-42F1-9B84-29883F47BAB6 caller=aabbccdd '
            'callee=11223344')
    must_not_survive(full, ["91fe5cf7-3572", "29883f47bab6"], "callid_body")
    _, _, a1 = ship(full)
    if a1.get("qa.call.short8") != "91fe5cf7":
        failures.append("BUG[short8]: expected 91fe5cf7, got %r"
                        % a1.get("qa.call.short8"))

    # 2. JOIN-KEY RECONCILE: the iOS leg computes canon(call_id)[:8] from the
    #    SAME call_id. Prove byte-identity here (uppercase server form vs a
    #    lowercased device form both collapse to 91fe5cf7).
    ios_form = "91fe5cf7-3572-42f1-9b84-29883f47bab6"   # device lowercased
    srv_form = "91FE5CF7-3572-42F1-9B84-29883F47BAB6"   # server verbatim
    if call_short8(ios_form) != call_short8(srv_form):
        failures.append("JOIN-FAIL: ios short8 %r != server short8 %r"
                        % (call_short8(ios_form), call_short8(srv_form)))
    if call_short8(srv_form) != "91fe5cf7":
        failures.append("JOIN-FAIL: server short8 != 91fe5cf7")

    # 3. group_call site logs short8(d.CallID) already -> [:8] is a no-op and
    #    yields the SAME value space.
    grp = ('time=2026-06-23T07:09:00.000Z level=INFO msg="group_call_create" '
           'call_id=91fe5cf7 creator=aabbccdd invited=3')
    _, _, a3 = ship(grp)
    if a3.get("qa.call.short8") != "91fe5cf7":
        failures.append("JOIN-FAIL: group_call short8 %r != 91fe5cf7"
                        % a3.get("qa.call.short8"))

    # 4. pubkey_prefix line MUST be dropped entirely.
    pk = ('time=2026-06-23T07:10:00.000Z level=INFO msg="DIAG: device X25519 '
          'registered" user=aabbccdd device=11223344 pubkey_prefix=a1b2c3d4e5f6')
    kept, body, _ = ship(pk)
    if kept and ("a1b2c3d4e5f6" in body or body):
        failures.append("LEAK[pubkey]: pubkey_prefix line shipped: %r" % body)

    # 5. panic / stack trace must drop.
    must_not_survive(
        'time=2026-06-23T07:11:00.000Z level=ERROR msg="boom" '
        'panic: runtime error: index out of range',
        ["panic", "runtime error", "index out of range"], "panic")

    # 6. Authorization / bearer token must drop.
    must_not_survive(
        'time=2026-06-23T07:12:00.000Z level=WARN msg="auth" '
        'Authorization: Bearer eyJhbGciOiJI.sometoken.sig',
        ["bearer", "eyjhbgci", "sometoken"], "bearer")

    # 7. embedded SDP / ICE IP must drop.
    must_not_survive(
        'time=2026-06-23T07:13:00.000Z level=INFO msg="relay" '
        'c=IN IP4 203.0.113.7 a=candidate typ host',
        ["203.0.113.7", "c=in ip4", "candidate"], "sdp")

    # 8. raw user UUID in a call line must NOT survive in body (only short8 of
    #    the CALL id ships; user ids the server already short8's, but a stray
    #    full UUID must be scrubbed).
    must_not_survive(
        'time=2026-06-23T07:14:00.000Z level=INFO msg="call status: started" '
        'call_id=91fe5cf7 peer=deadbeef-0000-1111-2222-333344445555',
        ["deadbeef-0000", "333344445555"], "user_uuid")

    # 9. non-call line (mem stats) must NOT ship at all.
    kept, body, _ = ship(
        'time=2026-06-23T07:15:00.000Z level=INFO msg="memory usage" '
        'alloc_mb=42 sys_mb=128 goroutines=57')
    if kept and body:
        failures.append("LEAK[scope]: non-call mem line shipped: %r" % body)

    # 10. node id validation: a user-id-shaped value is rejected.
    nid = validate_node_id("11112222-3333-4444-5555-666677778888", VPS_HOST or "h")
    if not nid.startswith("node-"):
        failures.append("BUG[node]: user-uuid not rejected as node id: %r" % nid)
    if validate_node_id("eu-fi-1", "h") != "eu-fi-1":
        failures.append("BUG[node]: valid eu-fi-1 rejected")

    # 11. structured call telemetry MUST still ship + carry the join key.
    good = ('time=2026-06-23T07:16:00.000Z level=INFO msg="call_ready" '
            'call_id=91fe5cf7 receiver=aabbccdd device=11223344')
    kept, body, attrs = ship(good)
    if not kept or not body:
        failures.append("REGRESS: structured call line dropped: %r" % body)
    if attrs.get("qa.call.short8") != "91fe5cf7":
        failures.append("REGRESS: join key missing on shippable line")
    if attrs.get("qa.node") != NODE:
        failures.append("REGRESS: qa.node missing on shippable line")

    # 12. severity mapping.
    if map_severity("WARN") != (13, "WARN"):
        failures.append("BUG[sev]: WARN mapped wrong")
    if map_severity("ERROR") != (17, "ERROR"):
        failures.append("BUG[sev]: ERROR mapped wrong")

    # 12b. BARE mixed-alnum secret-shaped token (8-11 chars) must NOT ship even
    #      with surrounding structure (closes the >=12-threshold escape hatch).
    must_not_survive(
        'time=2026-06-23T07:16:30.000Z level=INFO msg="call status: active" '
        'call_id=91fe5cf7 k7Gq9Lp2Zx1',
        ["k7gq9lp2zx1"], "bare_mixed_secret")
    must_not_survive(
        'time=2026-06-23T07:16:40.000Z level=INFO msg="call status: active" '
        'call_id=91fe5cf7 pin a1B2c3D4',
        ["a1b2c3d4"], "bare_pin")

    # 13. QUOTED call_id value (the regex-asymmetry MUST-FIX). slog TextHandler
    #     normally logs a bare UUID, but if a value ever ships quoted the server
    #     leg captures it via \"?. The iOS leg's _RE_CALLID_VALUE now also has
    #     \"?, so both extract the IDENTICAL group-1 token from the quoted form.
    #     Assert: quoted form -> short8 == bare form -> short8 == 91fe5cf7.
    quoted = ('time=2026-06-23T07:17:00.000Z level=INFO msg="call started" '
              'call_id="91FE5CF7-3572-42F1-9B84-29883F47BAB6" caller=aabbccdd')
    _, _, aq = ship(quoted)
    if aq.get("qa.call.short8") != "91fe5cf7":
        failures.append("JOIN-FAIL[quoted]: quoted call_id short8 %r != 91fe5cf7"
                        % aq.get("qa.call.short8"))
    mq = _RE_CALLID_VALUE.search(quoted)
    if not mq:
        failures.append("JOIN-FAIL[quoted]: server regex did NOT match a quoted "
                        "call_id value")

    # 14. LENGTH-FLOOR reconcile with correlate-call.py (>= 8). A 6/7-char id
    #     yields "" on BOTH shipper legs AND on correlate-call.py's matcher, so
    #     no leg ever emits a join value the canonical matcher cannot reproduce.
    for short_id in ("91fe5c", "91fe5cf"):           # 6 and 7 chars
        if call_short8(short_id) != "":
            failures.append("JOIN-FAIL[floor]: %r should yield '' (correlate-call "
                            ">=8 floor) but got %r" % (short_id, call_short8(short_id)))
    if call_short8("91fe5cf7") != "91fe5cf7":         # exactly 8 -> kept
        failures.append("JOIN-FAIL[floor]: 8-char id should be kept verbatim")

    # 15. HEARTBEAT shape: ONE record, correct scope, body is fixed integer
    #     telemetry, node attr only, severity INFO. It carries NO journald text,
    #     so by construction it cannot leak -- assert the exact safe shape.
    hb_req = build_heartbeat_request(
        NODE, "production", records_read=7, shipped=4, dropped=3,
        dropped_redact=3, cursor_advanced=True, now_ms=1_700_000_000_000.0)
    rls = hb_req.get("resourceLogs", [])
    if len(rls) != 1:
        failures.append("HEARTBEAT: expected 1 resourceLogs, got %d" % len(rls))
    else:
        sls = rls[0].get("scopeLogs", [])
        if len(sls) != 1 or sls[0]["scope"]["name"] != HEARTBEAT_SCOPE:
            failures.append("HEARTBEAT: wrong/missing scope %r"
                            % (sls[0]["scope"]["name"] if sls else None))
        else:
            lrs = sls[0]["logRecords"]
            if len(lrs) != 1:
                failures.append("HEARTBEAT: expected 1 logRecord, got %d"
                                % len(lrs))
            else:
                hb = lrs[0]
                hb_body = hb["body"]["stringValue"]
                expect = ("[heartbeat] cursor_advanced=true records_read=7 "
                          "shipped=4 dropped=3 dropped_redact=3")
                if hb_body != expect:
                    failures.append("HEARTBEAT: body %r != %r"
                                    % (hb_body, expect))
                # PROVE the body is, by construction, pre-cleared structured
                # telemetry: it is built ONLY from the fixed prefix + booleans +
                # integer counters this script computed about its OWN run. Match
                # it against an EXACT whitelist regex -- if it ever stops matching
                # this shape, a non-integer (i.e. ingested) value slipped in.
                HB_SHAPE_RE = re.compile(
                    r"^\[heartbeat\] cursor_advanced=(?:true|false) "
                    r"records_read=\d+ shipped=\d+ dropped=\d+ "
                    r"dropped_redact=\d+$")
                if not HB_SHAPE_RE.match(hb_body):
                    failures.append("HEARTBEAT: body not int-only safe shape: %r"
                                    % hb_body)
                hb_keys = sorted(a["key"] for a in hb["attributes"])
                if hb_keys != ["qa.node"]:
                    failures.append("HEARTBEAT: attrs %r != ['qa.node']"
                                    % hb_keys)
                if hb["severityText"] != "INFO":
                    failures.append("HEARTBEAT: severity %r != INFO"
                                    % hb["severityText"])

    # 15b. Heartbeat reports cursor_advanced=false + zeroed counters on a no-call
    #      run (the 'shipper alive, no calls' case the absent_over_time alert
    #      relies on).
    hb_idle = build_heartbeat_request(
        NODE, "production", records_read=0, shipped=0, dropped=0,
        dropped_redact=0, cursor_advanced=False, now_ms=1_700_000_000_000.0)
    idle_body = (hb_idle["resourceLogs"][0]["scopeLogs"][0]
                 ["logRecords"][0]["body"]["stringValue"])
    if idle_body != ("[heartbeat] cursor_advanced=false records_read=0 "
                     "shipped=0 dropped=0 dropped_redact=0"):
        failures.append("HEARTBEAT[idle]: wrong body %r" % idle_body)

    # 16. POISON-PILL state round-trip: fail_count persists and reloads as int.
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        sp = Path(td) / "state.json"
        save_state(sp, "CURSOR_A", fail_cursor="CURSOR_A", fail_count=2)
        st = load_state(sp)
        if st.get("cursor") != "CURSOR_A":
            failures.append("POISON: cursor not persisted")
        if st.get("fail_cursor") != "CURSOR_A":
            failures.append("POISON: fail_cursor not persisted")
        if st.get("fail_count") != 2:
            failures.append("POISON: fail_count %r != 2"
                            % st.get("fail_count"))
        # Legacy state file (no fail_* keys) must load with zeroed streak.
        sp.write_text(json.dumps({"cursor": "C", "ts": 1}), encoding="utf-8")
        st2 = load_state(sp)
        if st2.get("fail_count") != 0 or st2.get("fail_cursor") != "":
            failures.append("POISON: legacy state did not default streak to 0")

    # 17. POISON-PILL record-shape disclosure is SHAPE-ONLY: it must report the
    #     body LENGTH and attr KEYS but NEVER any body text / attr VALUE. Feed a
    #     record whose body carries a (hypothetical) secret-shaped string and a
    #     short8 value, and assert neither leaks into the shape string.
    fake_lr = {
        "severityText": "INFO",
        "body": {"stringValue": "secretword k7Gq9Lp2Zx1 sas=hunter2"},
        "attributes": [_attr_str("qa.call.short8", "91fe5cf7"),
                       _attr_str("qa.node", NODE)],
    }
    shape = _redacted_record_shape(fake_lr)
    for leak in ("secretword", "k7Gq9Lp2Zx1", "hunter2", "91fe5cf7", NODE):
        if leak in shape:
            failures.append("POISON[shape-leak]: %r leaked into %r"
                            % (leak, shape))
    if "body_len=34" not in shape:
        failures.append("POISON[shape]: body_len missing/wrong in %r" % shape)
    if "qa.call.short8" not in shape or "qa.node" not in shape:
        failures.append("POISON[shape]: attr KEYS missing in %r" % shape)

    out("=" * 72)
    out("SELF-TEST: server-leg privacy redaction + join-key reconcile")
    out("=" * 72)
    if failures:
        for f in failures:
            out("  FAIL: " + f)
        out("")
        out("  RESULT: NO-GO (%d leak/regression)" % len(failures))
        return 1
    out("  20/20 cases pass: full call_id/user-uuid/pubkey/panic/auth/SDP all")
    out("  blocked; bare mixed-alnum secret tokens hard-failed; non-call lines")
    out("  dropped; node id validated; structured call telemetry still ships;")
    out("  qa.call.short8 == iOS-leg short8 incl. the QUOTED form; 6/7-char ids")
    out("  floored to '' to match correlate-call.py; heartbeat emits pre-cleared")
    out("  int-only telemetry (idle + active) of exact safe shape; poison-pill")
    out("  fail_count round-trips through state; record-shape disclosure is")
    out("  shape-only (no body/value leak).")
    out("  RESULT: GO")
    return 0


# ---------------------------------------------------------------------------
# POISON-PILL GUARD. If the SAME un-advanced cursor fails its POST this many
# CONSECUTIVE runs, the next run drops to --batch 1 to isolate the offending
# record, ships every batch that DOES deliver, and SKIPs (logging only the
# redacted SHAPE, never the body) the single record that keeps failing so one
# malformed line cannot wedge the pipeline forever.
# ---------------------------------------------------------------------------

POISON_PILL_THRESHOLD = 3


def _redacted_record_shape(lr):
    """Describe a logRecord for an operator WITHOUT leaking its body. Returns
    only structural facts: severity, body LENGTH, and the attribute KEYS present
    (keys are the fixed allow-list; values are NOT included)."""
    body = ""
    try:
        body = lr.get("body", {}).get("stringValue", "") or ""
    except Exception:
        body = ""
    keys = []
    for a in lr.get("attributes", []) or []:
        k = a.get("key")
        if k:
            keys.append(k)
    return ("sev=%s body_len=%d attr_keys=[%s]"
            % (lr.get("severityText", "?"), len(body), ",".join(sorted(keys))))


def _post_isolating(endpoint, token, request_dict, http_results):
    """Poison-pill fallback: POST the request one logRecord at a time
    (effective --batch 1). Ship every record that delivers; SKIP the record(s)
    that fail, logging ONLY the redacted shape. Returns
    (all_ok, skipped_count) -- all_ok is True only if NOTHING was skipped."""
    skipped = 0
    for sub in _split_request_into_batches(request_dict, 1):
        status, resp_body = post_otlp(endpoint, token, sub)
        http_results.append(status)
        if status != 204:
            skipped += 1
            # Isolate: describe the single bad record by SHAPE only, never body.
            try:
                bad = sub["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
                shape = _redacted_record_shape(bad)
            except Exception:
                shape = "(unparseable record)"
            snippet = (resp_body or "").strip().replace("\n", " ")
            print("  POISON-PILL skip: HTTP %s  %s  resp=%s"
                  % (status, shape, _ascii(snippet[:120])), file=sys.stderr)
    return (skipped == 0), skipped


def main():
    ap = argparse.ArgumentParser(
        description="Ship bcrypto-server call logs to Loki OTLP, fail-closed "
                    "redacted, joining iOS on qa.call.short8."
    )
    ap.add_argument("--since", type=int, default=180,
                    help="first-run lookback in MINUTES (default 180); ignored "
                         "once a cursor exists")
    ap.add_argument("--max-records", type=int, default=20000,
                    help="journalctl -n cap per run (default 20000)")
    ap.add_argument("--node", type=str, default="",
                    help="service.instance.id node id (default QA_NODE_ID env, "
                         "else eu-de-1)")
    ap.add_argument("--endpoint", type=str,
                    default="https://dash.bcrypto.com/otlp/v1/logs",
                    help="Loki OTLP/JSON logs endpoint")
    ap.add_argument("--ingest-token", type=str, default="",
                    help="bearer token; overrides env QA_LOG_INGEST_TOKEN")
    ap.add_argument("--env", type=str, default="production",
                    dest="env_name",
                    help="deployment.environment.name (default production)")
    ap.add_argument("--batch", type=int, default=25,
                    help="log records per HTTP POST (default 25). Small batches "
                         "mirror the working ship-ios-logs.py per-blob pattern: "
                         "they isolate a single bad/rejected record (Loki OTLP "
                         "push is atomic per request) and stay under any "
                         "per-request limit. Raise only if delivery is proven.")
    ap.add_argument("--state-file", type=str, default="",
                    help="local JSON state path "
                         "(default ~/.qaudion/ship-server-logs.state.json)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the redacted OTLP that WOULD ship; push nothing; "
                         "do NOT advance the cursor")
    ap.add_argument("--reset-state", action="store_true",
                    help="ignore prior cursor; re-ship from --since")
    ap.add_argument("--selftest", action="store_true",
                    help="run the privacy redaction + join-key suite and exit")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(run_selftest())

    _ensure_creds()

    node_id = validate_node_id(
        args.node or os.environ.get("QA_NODE_ID", "") or "eu-de-1", VPS_HOST)

    token = args.ingest_token or os.environ.get("QA_LOG_INGEST_TOKEN", "")
    if not token and not args.dry_run:
        print("ERROR: no ingest token. Set env QA_LOG_INGEST_TOKEN or pass "
              "--ingest-token. (Not required for --dry-run.)", file=sys.stderr)
        sys.exit(1)

    state_path = Path(args.state_file) if args.state_file else default_state_path()
    state = load_state(state_path)
    cursor = "" if args.reset_state else state.get("cursor", "")

    # POISON-PILL guard: how many CONSECUTIVE prior runs the SAME un-advanced
    # cursor failed its POST. If we are about to re-read that exact stuck cursor
    # and it has already failed >= threshold times, drop to --batch 1 to isolate
    # and skip the single bad record. --reset-state clears the streak.
    prior_fail_cursor = "" if args.reset_state else state.get("fail_cursor", "")
    prior_fail_count = 0 if args.reset_state else state.get("fail_count", 0)
    isolate_mode = (bool(cursor) and cursor == prior_fail_cursor
                    and prior_fail_count >= POISON_PILL_THRESHOLD)

    print("=== bcrypto-server SSH @ %s (read-only) ===" % VPS_HOST)
    client = ssh_connect()
    print("Connected. node=%s  cursor=%s%s"
          % (node_id, "(none, --since %d min)" % args.since if not cursor
             else cursor[:24] + "...",
             "  [POISON-PILL: isolate mode, --batch 1, fail_count=%d]"
             % prior_fail_count if isolate_mode else ""))

    lines_total = 0
    lines_shipped = 0
    lines_dropped = 0
    http_results = []
    new_cursor = cursor
    poison_skipped = 0
    # Carry the poison-pill streak forward by default; reset on success below.
    out_fail_cursor = prior_fail_cursor
    out_fail_count = prior_fail_count

    try:
        print("\n=== Reading journal (-o json, %s) ==="
              % ("after-cursor" if cursor else "since %d min" % args.since))
        records, last_cursor = read_journal(
            client, cursor, args.since, args.max_records)
        lines_total = len(records)
        print("Read %d journal records." % lines_total)

        request, kept, dropped = build_export_request(
            records, node_id, args.env_name)
        lines_shipped = kept
        lines_dropped = dropped

        if args.dry_run:
            # Show the heartbeat that WOULD ship alongside the call batch.
            hb_req = build_heartbeat_request(
                node_id, args.env_name, lines_total, kept, dropped,
                lines_dropped, cursor_advanced=False)
            print_dry_run(hb_req)
            print_dry_run(request)
        else:
            # Effective batch size: drop to 1 under the poison-pill guard so a
            # single malformed record is isolated rather than wedging the batch.
            eff_batch = 1 if isolate_mode else args.batch

            if kept == 0:
                # Nothing shippable, but advance the cursor so we do not re-scan
                # the same window forever (no delivery to gate on). Clears any
                # poison-pill streak: there is no stuck batch to retry.
                new_cursor = last_cursor
                out_fail_cursor = ""
                out_fail_count = 0
            elif isolate_mode:
                # POISON-PILL fallback: POST one record at a time, ship what
                # delivers, SKIP (shape-only log) the record(s) that fail. The
                # cursor advances regardless so the bad line cannot wedge the
                # pipeline forever; the streak resets.
                _, poison_skipped = _post_isolating(
                    args.endpoint, token, request, http_results)
                new_cursor = last_cursor
                out_fail_cursor = ""
                out_fail_count = 0
                print("  POISON-PILL: isolated this window; %d record(s) skipped,"
                      " cursor force-advanced." % poison_skipped, file=sys.stderr)
            else:
                blob_ok = True
                for sub in _split_request_into_batches(request, eff_batch):
                    status, resp_body = post_otlp(args.endpoint, token, sub)
                    http_results.append(status)
                    if status != 204:
                        blob_ok = False
                        snippet = (resp_body or "").strip().replace("\n", " ")
                        print("  POST -> HTTP %s %s"
                              % (status, _ascii(snippet[:200])), file=sys.stderr)
                # Advance the cursor ONLY if EVERY batch delivered (fail-closed:
                # a failed POST does not advance, so a re-run retries the window).
                if blob_ok:
                    new_cursor = last_cursor
                    out_fail_cursor = ""
                    out_fail_count = 0
                else:
                    # Delivery failed: bump the consecutive-fail streak for THIS
                    # exact cursor so a future run can trip the poison-pill guard.
                    if cursor == prior_fail_cursor:
                        out_fail_count = prior_fail_count + 1
                    else:
                        out_fail_count = 1
                    out_fail_cursor = cursor

            # HEARTBEAT: ship ONE synthetic record EVERY non-dry run, AFTER the
            # call batch, so a Grafana absent_over_time alert can tell 'shipper
            # dead' from 'no calls'. It ships even when kept == 0. It is its own
            # request so an empty/failed call batch does not suppress it.
            hb_advanced = (new_cursor != cursor)
            hb_req = build_heartbeat_request(
                node_id, args.env_name, lines_total, kept, dropped,
                lines_dropped, cursor_advanced=hb_advanced)
            hb_status, hb_body = post_otlp(args.endpoint, token, hb_req)
            if hb_status != 204:
                snippet = (hb_body or "").strip().replace("\n", " ")
                print("  HEARTBEAT POST -> HTTP %s %s"
                      % (hb_status, _ascii(snippet[:200])), file=sys.stderr)
    finally:
        client.close()

    if not args.dry_run:
        # Persist cursor + poison-pill streak whenever EITHER changed.
        if (new_cursor != cursor or out_fail_cursor != prior_fail_cursor
                or out_fail_count != prior_fail_count):
            save_state(state_path, new_cursor or cursor,
                       fail_cursor=out_fail_cursor, fail_count=out_fail_count)

    out()
    out("=" * 72)
    out("SHIP-SERVER-LOGS SUMMARY")
    out("=" * 72)
    out("  endpoint:                %s" % args.endpoint)
    out("  environment:             %s" % args.env_name)
    out("  node (instance.id):      %s" % node_id)
    out("  dry-run:                 %s" % ("yes" if args.dry_run else "no"))
    out("  journal records read:    %d" % lines_total)
    out("  lines shipped:           %d" % lines_shipped)
    out("  lines dropped (redact):  %d" % lines_dropped)
    if not args.dry_run:
        ok = sum(1 for s in http_results if s == 204)
        bad = sum(1 for s in http_results if s != 204)
        out("  HTTP 204 (ok):           %d" % ok)
        out("  HTTP non-204 (failed):   %d" % bad)
        out("  cursor advanced:         %s"
            % ("yes" if new_cursor != cursor else "no"))
        out("  poison-pill fail_count:  %d%s"
            % (out_fail_count,
               " (>= %d -> isolate next run)" % POISON_PILL_THRESHOLD
               if out_fail_count >= POISON_PILL_THRESHOLD else ""))
        if isolate_mode:
            out("  poison-pill isolated:    yes (%d record(s) skipped)"
                % poison_skipped)
        out("  heartbeat:               emitted (scope %s)" % HEARTBEAT_SCOPE)
        out("  state file:              %s" % state_path)
        if bad:
            out()
            out("  NOTE: %d POST(s) did not return 204. Cursor was NOT advanced,"
                % bad)
            out("        so a re-run retries this window. After %d consecutive"
                % POISON_PILL_THRESHOLD)
            out("        failures of the SAME cursor, the next run isolates at")
            out("        --batch 1 and skips the single bad record (shape-only).")
    else:
        out()
        out("  (dry-run: nothing shipped, cursor untouched. Eyeball the OTLP")
        out("   bodies above to confirm redaction before a real run.)")
    out("=" * 72)


if __name__ == "__main__":
    main()
