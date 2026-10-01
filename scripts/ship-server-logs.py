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
    audio/group_call or carries a call_id) -- everything else is dropped --
    PLUS the OPS LANE: the server's own health signals (ws ping failures,
    zombie sweeps, slow ticks, goroutine counts, slow/5xx HTTP, unit restarts,
    panics) as scope qaudion.ops, bodies ASSEMBLED from a fixed vocabulary +
    bounded integers (never journald text). See the "OPS LANE" block below.
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
  --ops-only       Ship ONLY the ops lane, no heartbeat (history backfill; use
                   with --reset-state --since N and a SEPARATE --state-file).
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
import functools
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

    W-VPSKEYAUTH (2026-09-08, server leg): parity fix with ship-ios-logs.py's
    2026-09-02 change. The prod VPS has been publickey-only since the
    post-migration hardening (password auth disabled), so QAUDION_VPS_PASS is
    optional once a key is available (see _vps_key_path()) -- this script had
    been left on the password-only path, which is why it silently kept
    reading a stale/dead host instead of failing loudly or working at all.
    """
    host = os.environ.get("QAUDION_VPS_HOST")
    user = os.environ.get("QAUDION_VPS_USER")
    password = os.environ.get("QAUDION_VPS_PASS")
    if host and user and (password or _vps_key_path()):
        return host, user, password or ""

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
            if h and u and (pw or _vps_key_path()):
                return h.group(1), u.group(1), (pw.group(1) if pw else "")

    print("ERROR: VPS credentials not found.", file=sys.stderr)
    print("Set env vars QAUDION_VPS_HOST / QAUDION_VPS_USER (+ QAUDION_VPS_PASS if no SSH key)",
          file=sys.stderr)
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


def _vps_key_path():
    """Private key for the prod VPS.

    QAUDION_VPS_SERVER_KEY takes priority: this leg is meant to run under a
    DEDICATED, least-privilege key (forced-command restricted server-side to
    `journalctl -u bcrypto-server` only, see
    /usr/local/sbin/qaudion-shipper-journal-ro.sh on the VPS) rather than the
    shared root-capable QAUDION_VPS_KEY/bcrypto_vps_ed25519 the other prod
    tools use -- the shipper cron box should never hold a key that can do
    more than read this one unit's journal. Falls back to the shared
    QAUDION_VPS_KEY / VPS_SSH_KEY / dev-box default for parity with
    ship-ios-logs.py when no dedicated key is configured. Returns None when no
    readable key exists so callers can fall back to password auth."""
    for cand in (os.environ.get("QAUDION_VPS_SERVER_KEY"),
                 os.environ.get("QAUDION_VPS_KEY"), os.environ.get("VPS_SSH_KEY"),
                 str(Path.home() / ".claude" / "bin" / "bcrypto_vps_ed25519")):
        if cand:
            p = Path(os.path.expanduser(cand))
            if p.is_file():
                return str(p)
    return None


def ssh_connect():
    _ensure_creds()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    # W-VPSKEYAUTH (2026-09-08): key first (the prod VPS is publickey-only
    # after the migration hardening -- password auth returns "Bad
    # authentication type; allowed types: ['publickey']"), password only as a
    # fallback when no key is present. Parity with ship-ios-logs.py.
    key = _vps_key_path()
    if key:
        client.connect(VPS_HOST, username=VPS_USER, key_filename=key,
                       look_for_keys=False, allow_agent=False, timeout=15)
    else:
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

# W-KEYWORDS 2026-09-24 (red-team finding 3, ported from ship-ios-logs.py): the words
# derived key / raw key, and secret / slat / salt / *key(s) followed within a few non-word
# characters by an opening bracket, drop the WHOLE line whatever the group holds.
RE_KEY_MATERIAL = re.compile(
    r"(?:derived|raw)[\s_\-]*key|(?:secret|slat|salt|\w*keys?)\W{0,8}[\[({<]")

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

# ---------------------------------------------------------------------------
# FREE-WORD PLAUSIBILITY (W-FREEWORD 2026-09-24; ported from ship-ios-logs.py,
# red-team finding 1: the positive gate never asked whether a token reads like a
# word, so base26/base52 blocks of 3-11 letters between structural tokens shipped).
#
# The gate above only COUNTED "free" words; it never asked whether a token reads
# like a word. Any alphabetic token of 3-11 letters was accepted as ordinary
# text, so a secret written in base26 / base52 (letters only), cut into
# 11-letter blocks and interleaved with structural tokens ("... <block> active
# <block> ice=connected ...") shipped VERBATIM: the red-team round-tripped 32
# synthetic bytes through the shipped body. Sibling holes in the same gate: a
# 1-2 character token was "neutral" (unlimited), an UNPROTECTED key=value token
# was structural whatever followed the '=' / ':' (`k=abcdefghi`, `abcdefghijk:`),
# a "number" token could carry 5 trailing letters (`1abcdefghij`), a token with
# non-ASCII look-alike letters was judged as free text, and a comma list of
# <= 7 numbers per token (`1,2,3,4,5,6,7 8,9,...`) dodged the byte-list rule.
# Now EVERY token that reaches the gate must earn its place:
#   * a word is KNOWN (TELEMETRY_VOCAB / APP_VOCAB, or a camel/Pascal compound of
#     known words) or it must LOOK like a word: clean case shape (lower,
#     Capitalized, UPPER, or 2-4 camel parts -- aBcDeFgHiJk, the shape of a
#     base52/base62 block, is rejected), a vowel, no run of 5 consonants or 5
#     vowels, no tripled letter, vowels >= 20% of a 5+ letter word, and no
#     bigram that (almost) never occurs in English / app identifiers;
#   * the number of words that are NOT known is capped per body
#     (MAX_UNKNOWN_WORDS). A lexical filter cannot stop an encoder that emits
#     pronounceable words -- the cap bounds what one body can carry;
#   * kv keys and values, number units, "id-like" values (a hex id prefix such as
#     to=8bc24df8 stays readable; so does a number of 6+ digits; at most
#     MAX_IDLIKE_TOKENS of them per body: the 14-day corpus has 2 at most, and 3
#     hex blocks / big numbers per body would carry a third of a 16-byte key), 1-2 letter
#     tokens, runs of number tokens and separator-joined tokens follow the same
#     rules (_gate_kv_ok / _num_token_ok / _ident_ok). A bare number token is one
#     number (or two joined by one separator); 3+ numbers in one token fail.
#   * NOT closed: single numbers between vocabulary words ("rtt 1234 ok 5678 ...",
#     23 bits per number) look exactly like the call-statistics lines that make
#     up much of the corpus; only the key-byte list rules (1c-bis) stop the
#     natural ways of printing a key as numbers. Documented residual.
# A failed check is a HARD FAIL: the body falls back to the attribute summary.
# APP_VOCAB = the words the app itself prints (class / state / enum names),
# here: the server's own slog vocabulary (keys / msg words). The server
# budgets are more generous than the iOS leg (no corpus to tune on: the call lane
# is rare and a failed check only falls back to the attribute summary).
# ---------------------------------------------------------------------------
MAX_UNKNOWN_WORDS = 3     # per body: words that are neither TELEMETRY_VOCAB nor APP_VOCAB
UNKNOWN_MAX_LEN = 9       # an unknown word longer than this is not a plausible word
MAX_IDLIKE_TOKENS = 2     # per body: hex id prefixes (4-8 hex) + numbers of 6+ digits
MAX_NUM_RUN = 3           # consecutive bare number tokens

APP_VOCAB = frozenset("""
    accepted answered api audio auto-tracked busy bytes callee caller calls
    canceled cancelled cause client code conn connection count create
    created creator crypto declined delete device devices dtls duration
    elapsed end epoch err error expired file files get group groups hangup
    http https ice id invited invitees ip join joined key keys kms leave
    left level media method mid missed ms msg node opus participant
    participants patch path pcm peer post processing pt put ready reason
    receiver recipient rejected rekey relay room rtcp rtp rtt rx sdp seal
    sec sender seq server session sfu size srtp ssrc state status stun tcp
    time timeout tls total tracked turn tus tx udp unseal user users video
    ws wss
""".split())

# Second letters that (almost) never follow the first in English / app
# identifiers (fewer than 6 of ~13k distinct words): a random letter block hits
# one of them with high probability (a random 11-letter block passes ~4%).
_BIGRAM_FORBID = {
    "a": "jo",
    "b": "hqxz",
    "c": "jwxz",
    "d": "qxz",
    "f": "hjkqvxz",
    "g": "bjkqvxz",
    "h": "cgjkpqvwxz",
    "i": "wy",
    "j": "bcdfghjklmnpqrtvwxyz",
    "k": "hjkqvxz",
    "l": "hjqwxz",
    "m": "gjqrvwxz",
    "n": "x",
    "o": "q",
    "p": "jqxz",
    "q": "abcdefghijklmnopqrtvwxyz",
    "r": "jqz",
    "s": "jxz",
    "t": "jkqz",
    "u": "hjkqvwy",
    "v": "dghjklmqtwxyz",
    "w": "bfgjkmquvxyz",
    "x": "bgjklnoqrsuvwxz",
    "y": "hjkquvxy",
    "z": "bcdfghjklmnpqrstuvwxy",
}
_RE_CASE_PARTS = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+")
_CAMEL_SHORT_OK = frozenset(
    "of to in on at is as if or by id up no ok do go it my re us".split())
_RE_CONS5 = re.compile(r"[^aeiouy]{5}")
_RE_VOW5 = re.compile(r"[aeiouy]{5}")
_RE_TRIPLE = re.compile(r"(.)\1\1")
_RE_ID_SPLIT = re.compile(r"[^A-Za-z0-9]+")
_RE_ALNUM_RUNS = re.compile(r"[A-Za-z]+|[0-9]+")
_RE_PH_INSIDE = re.compile(r"\[REDACTED:[a-z]+\]")
_RE_KV_GATE = re.compile(r"^([A-Za-z][A-Za-z0-9_.\-]*)[=:](.*)$", re.DOTALL)
_RE_HEX_PREFIX = re.compile(r"^(?:0x)?[0-9a-fA-F]{4,8}$")
_RE_BIGNUM = re.compile(r"\d{6}")
_RE_NUMTOK = re.compile(r"^[+\-]?\d{1,9}(?:[.,:]\d{1,9})?[.,:]?([A-Za-z%]{0,5})$")
_GATE_WRAP = "[](){}<>.,:;!?\"'"          # wrappers stripped before judging a token
_KV_VAL_STRIP = "()[]{}<>,;:.!?\"'`/\\*"
# units a bare number token may carry (35ms 1.5s 64kbps 48khz 20dbfs 3x 12%).
_NUM_UNITS = frozenset(
    "ms us ns s sec secs min mins h hz khz mhz kbps mbps gbps bps fps kb mb gb "
    "b db dbfs dbm px x k m g kib mib pkts pps %".split())


def _word_known(low):
    return low in TELEMETRY_VOCAB or low in APP_VOCAB


def _case_shape_ok(w):
    """w: ASCII letters, case preserved. lower / Capitalized / UPPER, or clean
    camel/Pascal (2-4 parts, every part after the first 3+ letters, or a common
    2-letter word, or a 2-letter acronym)."""
    if len(w) < 2 or w.islower() or w.isupper():
        return True
    if w[0].isupper() and w[1:].islower():
        return True
    parts = _RE_CASE_PARTS.findall(w)
    if len(parts) < 2 or len(parts) > 4:
        return False
    for p in parts[1:]:
        if (len(p) >= 3 or p.lower() in _CAMEL_SHORT_OK or _word_known(p.lower())
                or (p.isupper() and len(p) == 2)):
            continue
        return False
    return True


def _lex_ok(low):
    """True if the lower-case letter string reads like a word (see 1e-bis)."""
    n = len(low)
    if n <= 2 or _word_known(low):
        return True
    vowels = sum(1 for c in low if c in "aeiouy")
    if (vowels == 0 or _RE_CONS5.search(low) or _RE_VOW5.search(low)
            or _RE_TRIPLE.search(low)):
        return False
    if n >= 5 and vowels * 5 < n:
        return False
    for a, b in zip(low, low[1:]):
        if b in _BIGRAM_FORBID.get(a, ""):
            return False
    return True


@functools.lru_cache(maxsize=16384)
def _word_ok(w):
    """(ok, n_unknown) for one ASCII-letter piece: case shape + known/lexical.
    n_unknown = how many of its camel/Pascal parts are not app vocabulary; an
    unknown part must read like a word and is at most UNKNOWN_MAX_LEN letters
    (a long random block is never "a word we have not seen yet")."""
    if len(w) > 24 or not _case_shape_ok(w):
        return False, 0
    low = w.lower()
    if _word_known(low):
        return True, 0
    subs = [s.lower() for s in _RE_CASE_PARTS.findall(w)]
    unknown = 0
    for s in subs:
        if _word_known(s):
            continue
        if len(s) > UNKNOWN_MAX_LEN or not _lex_ok(s):
            return False, 0
        unknown += 1
    return True, unknown


@functools.lru_cache(maxsize=16384)
def _ident_ok(tok):
    """(ok, n_unknown_words) for an identifier-like token (kv key / value, or a
    gate token that is not a placeholder / number / kv). Non-ASCII letters,
    digits or marks (look-alikes) fail; the token splits on non-alphanumerics
    into <= 4 pieces; a piece is digits (<= 5), a word (_word_ok) or a short
    letter/digit mix (h264, p2p, x25519: <= 3 alternations)."""
    for ch in tok:
        if ch > "\x7f" and unicodedata.category(ch)[0] in "LMN":
            return False, 0
    if _word_known(tok.lower()):
        return True, 0                    # the whole token is vocabulary (w-callawake)
    pieces = [p for p in _RE_ID_SPLIT.split(tok) if p]
    if len(pieces) > 8 or sum(1 for p in pieces if p.isdigit()) > 2:
        return False, 0                   # 1,2,3,4,5,6,7 / 1.2.3.4: a number list
    unknown = 0
    for p in pieces:
        if p.isdigit():
            if len(p) > 5:
                return False, 0
            continue
        if p.isalpha():
            ok, n = _word_ok(p)
            if not ok or (n and len(pieces) > 4):
                return False, 0
            unknown += n
            continue
        if _word_known(p.lower()):
            continue
        if len(pieces) > 4:
            return False, 0       # long joined tokens: every piece must be known
        runs = _RE_ALNUM_RUNS.findall(p)
        if len(runs) > 3:
            return False, 0
        for r in runs:
            if r.isdigit():
                if len(r) > 5:
                    return False, 0
            elif len(r) >= 3 and not _word_ok(r)[0]:
                return False, 0
        unknown += 1
    return True, unknown


def _is_bignum(tok):
    """A number token of 6+ digits (an "id-like" value: budgeted per body)."""
    return _RE_BIGNUM.search(tok) is not None


def _num_token_ok(tok):
    """A bare number token: one number, or two joined by ONE '.' ',' ':' (12.5,
    1,234, 1:23), an optional trailing separator and, optionally, a known unit
    suffix. A longer comma list (1,2,3,4,5,6,7) is not a number: the corpus has
    none, and 7 bytes per token dodged the >= 8-number list rule."""
    m = _RE_NUMTOK.match(tok)
    if not m:
        return False
    unit = m.group(1)
    return not unit or unit.lower() in _NUM_UNITS


def _gate_kv_ok(tok):
    """Judge an UNPROTECTED key=value / key:value gate token (the old gate
    trusted everything after the separator). Returns (ok, is_idlike, n_unknown_words):
    is_idlike = the value is a hex id prefix or a number of 6+ digits. The key must read like an identifier; the value must be
    empty, a [REDACTED:*] placeholder, a number (+ known unit), a short hex id
    prefix, or identifier-like."""
    m = _RE_KV_GATE.match(tok)
    if not m:
        return False, False, 0
    ok, unknown = _ident_ok(m.group(1))
    if not ok:
        return False, False, 0
    v = _RE_PH_INSIDE.sub("", m.group(2)).strip(_KV_VAL_STRIP)
    if not v:
        return True, False, unknown
    if _num_token_ok(v):
        return True, _is_bignum(v), unknown
    if _RE_HEX_PREFIX.match(v):
        return True, True, unknown
    ok, n = _ident_ok(v)
    if not ok:
        return False, False, 0
    return True, False, unknown + n


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
    (Same conditions as ship-ios-logs.py: (A) free-word run cap, (B) free words
    must not dominate, (C) W-FREEWORD every token must be plausible: words known
    or word-like with a per-body cap on unknown words, key=value values / numbers
    / hex prefixes / separator-joined tokens checked too.)"""
    run_n = 0
    free = 0
    structural = 0
    unknown = 0
    idlike = 0
    numrun = 0
    for tok in scrubbed.split():
        if RE_PLACEHOLDER_TOKEN.match(tok):
            run_n = 0
            numrun = 0
            structural += 1
            continue
        if RE_KV_TOKEN.match(tok):
            ok, is_idlike, n_unk = _gate_kv_ok(tok)
            if not ok:
                return False
            if is_idlike:
                idlike += 1
                if idlike > MAX_IDLIKE_TOKENS:
                    return False
            unknown += n_unk
            if unknown > MAX_UNKNOWN_WORDS:
                return False
            run_n = 0
            numrun = 0
            structural += 1
            continue
        if RE_NUM_TOKEN.match(tok) and _num_token_ok(tok):
            numrun += 1
            if numrun > MAX_NUM_RUN:
                return False
            if _is_bignum(tok):
                idlike += 1
                if idlike > MAX_IDLIKE_TOKENS:
                    return False
            run_n = 0
            structural += 1
            continue
        numrun = 0
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
        eff = _RE_PH_INSIDE.sub("", tok).strip(_GATE_WRAP + "*")
        if core in TELEMETRY_VOCAB:
            if eff.isalpha() and not _case_shape_ok(eff):
                return False
            run_n = 0
            structural += 1
            continue
        if len(core) <= 2:
            if eff.isalpha() and not _word_known(eff.lower()):
                unknown += 1
                if unknown > MAX_UNKNOWN_WORDS:
                    return False
            continue
        run_n += 1
        free += 1
        if run_n > MAX_FREEWORD_RUN:
            return False
        if eff:
            ok, n_unk = _ident_ok(eff)
            if not ok:
                return False
            unknown += n_unk
            if unknown > MAX_UNKNOWN_WORDS:
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
    if RE_KEY_MATERIAL.search(low):
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
# OPS LANE (W-OPSLANE, 2026-09-20).
# The call lane ships only call/ice/media/crypto lines, so the server's OWN
# health signals -- ws ping failures, zombie sweeps, slow ticks, goroutine
# counts, slow/failing HTTP, unit restarts, panics -- never reached Loki. On
# 2026-09-20 a goroutine leak that made calls impossible for hours (goroutines
# 98 -> 863 over four hours, then a hung stop and a SIGKILL) was invisible
# there. This lane ships THOSE signals without weakening the fail-closed
# privacy invariant:
#
#   * the body is NEVER derived from journald text. It is ASSEMBLED from a fixed
#     event vocabulary + the level word + bounded integers + enum-classified
#     causes / route classes (the same "pre-cleared structured telemetry"
#     construction as the heartbeat). No user/device/peer id, IP, err= text,
#     URL path segment, token, hash_prefix or user-agent can enter it, by
#     construction.
#   * integers are read from properly TOKENISED slog key=value pairs: a key only
#     counts at the start of a token and a quoted value is consumed whole, so
#     `path=/x?status=500` or `ua="a ms=99999"` cannot spoof a field.
#   * a shape tripwire (OPS_SHAPE_RE), built from the SAME closed vocabularies,
#     re-checks every assembled body; anything else is dropped, so a future
#     edit that lets free text slip in fails closed instead of leaking.
#   * an UNKNOWN WARN/ERROR line ships as event=warn_other|error_other with an
#     8-hex fingerprint of its digit-normalised msg literal (msgid): a NEW kind
#     of problem is visible and countable, but no text of it leaves the server.
#     `--dry-run` prints a legend (msgid -> normalised msg literal) for the
#     operator's terminal only.
#   * ops records of one run that share (timestamp, body) get +1ns, +2ns, ...
#     so a burst inside one millisecond (e.g. 50 ws pings failing together) is
#     not silently collapsed by Loki's identical-(timestamp, line) dedup.
# Query:  {service_name="qaudion-server"} | qa_ops_event="ws_ping_failed"
# ---------------------------------------------------------------------------

OPS_SCOPE = "qaudion.ops"

# (lowercased slog msg prefix, event slug). First match wins.
OPS_MSG_EVENTS = (
    ("ws ping failed", "ws_ping_failed"),
    ("ws read error", "ws_read_error"),
    ("ws disconnected", "ws_disconnected"),
    ("ws zombie sweep completed", "ws_zombie_sweep_completed"),
    ("ws zombie swept", "ws_zombie_swept"),
    ("ws: opened", "ws_opened"),
    ("ws authenticated", "ws_authenticated"),
    ("ingestfromoffset: slow tick", "slow_tick"),
    ("audio relay rejected", "relay_rejected"),
    ("refresh token rejected", "refresh_rejected"),
    ("refresh token reuse", "refresh_reuse"),
    ("refresh rotate: collapsed", "refresh_collapsed"),
    ("benign rotation race: collapsed", "refresh_collapsed"),
    ("memory", "memory"),
    ("shutdown signal received", "shutdown_signal"),
    ("bcrypto lite server", "server_start"),
    ("reality-front exited", "reality_front_exited"),
    ("vpn mgmt-reachability probe failed", "vpn_probe_failed"),
)

# The ONLY numeric fields an ops body may carry, each a bounded integer.
OPS_INT_KEYS = ("elapsed_ms", "age_sec", "threshold_sec", "evicted", "lines",
                "alloc_mb", "sys_mb", "goroutines", "ms", "status",
                "restarts", "mem_peak_mb")

# slog TextHandler key=value tokeniser (see the header comment).
_RE_SLOG_KV = re.compile(
    r'(?:^|\s)([A-Za-z_][A-Za-z0-9_.]*)=("(?:[^"\\]|\\.)*"|\S*)')
_RE_SLOG_PREFIX = re.compile(r"time=\S+\s")
_RE_OPS_UINT = re.compile(r"[0-9]{1,18}\Z")

# Events whose body carries a fixed-vocabulary `cause` derived from err=.
_OPS_CAUSE_EVENTS = frozenset(["ws_ping_failed", "ws_read_error"])
_RE_OPS_EOF = re.compile(r"\beof\b")

_OPS_WS_CAUSES = ("net_change", "normal_closure", "going_away", "pong_timeout",
                  "canceled", "conn_reset", "broken_pipe", "closed_conn",
                  "eof", "timeout", "other")

_OPS_METHODS = frozenset(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD",
                          "OPTIONS"])
# URL path -> route CLASS (segment-aware prefix match). The path itself (ids,
# file names) never ships.
_OPS_ROUTES = (
    ("/api/v1/files/tus", "files_tus"),
    ("/api/v1/files", "files"),
    ("/api/v1/telemetry", "telemetry"),
    ("/api/v1/auth", "auth"),
    ("/api/v1/turn-ws", "turn_ws"),
    ("/api/v1/ready", "health"),
    ("/api/v1/health", "health"),
    ("/internal/vpn/health", "health"),
    ("/ws", "ws"),
    ("/api", "api_other"),
    ("/internal", "internal"),
)
OPS_ROUTE_CLASSES = frozenset([slug for _p, slug in _OPS_ROUTES] + ["other"])
_OPS_SLOW_HTTP_MS = 1000
# The server logs /ws and /api/v1/turn-ws with a fixed status=101 and
# ms = the whole SESSION duration (accessLogMiddleware), not a latency.
_OPS_HTTP_UPGRADE_STATUS = 101

# Non-slog journal lines (systemd unit lifecycle, Go runtime fatal output).
# (regex, event slug, level word). First match wins.
_OPS_RAW_RULES = (
    (re.compile(r"^panic:"), "process_fault", "ERROR"),
    (re.compile(r"^fatal error:"), "process_fault", "ERROR"),
    (re.compile(r"\bFailed with result\b"), "unit_failed", "ERROR"),
    (re.compile(r"\bMain process exited\b"), "unit_main_exited", "WARN"),
    (re.compile(r"\bScheduled restart job\b"), "unit_restart_scheduled", "WARN"),
    (re.compile(r"\bState '[a-z-]+' timed out\b"), "unit_stop_timeout", "WARN"),
    (re.compile(r"\bKilling process [0-9]+ .*with signal\b"), "unit_kill",
     "WARN"),
    (re.compile(r"\bkilled by the OOM killer\b"), "unit_oom_killed", "ERROR"),
    (re.compile(r"\bStart request repeated too quickly\b"), "unit_start_limit",
     "ERROR"),
    (re.compile(r"^Failed to start "), "unit_start_failed", "ERROR"),
    (re.compile(r"\bConsumed .*[0-9][BKMGT] memory peak\b"), "unit_consumed",
     "INFO"),
    (re.compile(r"^Started "), "unit_started", "INFO"),
    (re.compile(r"^Stopping "), "unit_stopping", "INFO"),
    (re.compile(r"^Stopped "), "unit_stopped", "INFO"),
)
# systemd `Failed with result '<x>'` -> fixed cause slug.
_UNIT_RESULTS = {
    "exit-code": "exit_code", "signal": "signal", "timeout": "timeout",
    "core-dump": "core_dump", "watchdog": "watchdog", "resources": "resources",
    "start-limit-hit": "start_limit_hit", "oom-kill": "oom_kill",
    "protocol": "protocol",
}
_UNIT_CODES = ("exited", "killed", "dumped")
_RE_RAW_STATUS = re.compile(r"\bstatus=([0-9]{1,3})\b")
_RE_RAW_CODE = re.compile(r"\bcode=(exited|killed|dumped)\b")
_RE_RAW_RESULT = re.compile(r"Failed with result '([a-z-]+)'")
_RE_RAW_RESTARTS = re.compile(r"restart counter is at ([0-9]{1,9})\b")
_RE_RAW_MEMPEAK = re.compile(r"([0-9]+(?:\.[0-9]+)?)([BKMGT]) memory peak\b")
_MEM_UNIT_MB = {"B": 1.0 / 1048576, "K": 1.0 / 1024, "M": 1.0, "G": 1024.0,
                "T": 1048576.0}

OPS_EVENTS = frozenset(
    [ev for _p, ev in OPS_MSG_EVENTS]
    + [ev for _rx, ev, _lv in _OPS_RAW_RULES]
    + ["http_5xx", "slow_http", "warn_other", "error_other"])
_OPS_CAUSES = (frozenset(_OPS_WS_CAUSES) | frozenset(_UNIT_RESULTS.values())
               | frozenset(_UNIT_CODES))


def _alt(items):
    """Regex alternation of literal items, longest first."""
    return "|".join(re.escape(i) for i in
                    sorted(items, key=lambda s: (-len(s), s)))


# Tripwire: EVERY assembled ops body must match this closed grammar (events,
# integer keys, causes, methods and route classes are all enumerated), else the
# record is dropped. \Z (not $) so a trailing newline cannot slip through.
OPS_SHAPE_RE = re.compile(
    r"^\[ops\] event=(?:%s) level=(?:DEBUG|INFO|WARN|ERROR|FATAL)"
    r"(?: (?:%s)=[0-9]{1,9}"
    r"| cause=(?:%s)"
    r"| method=(?:%s)"
    r"| route=(?:%s)"
    r"| msgid=[0-9a-f]{8})*\Z"
    % (_alt(OPS_EVENTS), _alt(OPS_INT_KEYS), _alt(_OPS_CAUSES),
       _alt(_OPS_METHODS), _alt(OPS_ROUTE_CLASSES)))


def _slog_pairs(line):
    """First occurrence of every key=value pair of a slog line -> {key: raw}."""
    pairs = {}
    for m in _RE_SLOG_KV.finditer(line or ""):
        pairs.setdefault(m.group(1), m.group(2))
    return pairs


def _unquote(v):
    v = v or ""
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return v[1:-1]
    return v


def _ops_ints(pairs, keys=OPS_INT_KEYS):
    """Bounded-integer fields (ORDER = OPS_INT_KEYS) from tokenised pairs."""
    fields = []
    for k in keys:
        v = pairs.get(k)
        if v is not None and _RE_OPS_UINT.match(v):
            fields.append((k, str(min(int(v), 999999999))))
    return fields


def _ops_cause(err):
    """Classify a lowercased ws err= text into a FIXED cause vocabulary (never
    the text itself)."""
    if "net-change" in err:
        return "net_change"
    if "statusnormalclosure" in err:
        return "normal_closure"
    if "statusgoingaway" in err:
        return "going_away"
    if "wait for pong" in err:
        return "canceled" if "context canceled" in err else "pong_timeout"
    if "reset by peer" in err:
        return "conn_reset"
    if "broken pipe" in err:
        return "broken_pipe"
    if "use of closed" in err:
        return "closed_conn"
    if "context canceled" in err:
        return "canceled"
    if _RE_OPS_EOF.search(err):
        return "eof"
    if "deadline exceeded" in err or "timeout" in err or "timed out" in err:
        return "timeout"
    return "other"


def _ops_route(path):
    p = (path or "").split("?", 1)[0].rstrip("/") or "/"
    for prefix, slug in _OPS_ROUTES:
        if p == prefix or p.startswith(prefix + "/"):
            return slug
    return "other"


def _ops_msg_norm(msg_value):
    """msg literal with every hex run / number replaced by '#', so a msg that
    embeds an id or a counter still fingerprints to ONE stable msgid and the
    hash never covers an id."""
    s = _nfkc(msg_value or "").lower()
    s = re.sub(r"[0-9a-f]{8,}", "#", s)
    s = re.sub(r"[0-9]+", "#", s)
    return " ".join(s.split())


def _ops_msgid(msg_value):
    """8-hex one-way fingerprint of a msg literal (identifies WHICH message
    without carrying any of its text)."""
    return hashlib.sha256(_ops_msg_norm(msg_value).encode("utf-8", "replace")
                          ).hexdigest()[:8]


def _classify_ops_raw(line):
    """Non-slog journal line -> (event, level, fields) or None. Fields come only
    from bounded ints / fixed enums parsed out of the systemd wording."""
    text = (line or "").strip()
    for rx, event, level in _OPS_RAW_RULES:
        if not rx.search(text):
            continue
        fields = []
        if event == "unit_main_exited":
            m = _RE_RAW_STATUS.search(text)
            if m:
                fields.append(("status", m.group(1)))
            m = _RE_RAW_CODE.search(text)
            if m:
                fields.append(("cause", m.group(1)))
        elif event == "unit_failed":
            m = _RE_RAW_RESULT.search(text)
            fields.append(("cause", _UNIT_RESULTS.get(m.group(1), "other")
                           if m else "other"))
        elif event == "unit_restart_scheduled":
            m = _RE_RAW_RESTARTS.search(text)
            if m:
                fields.append(("restarts", str(min(int(m.group(1)), 999999999))))
        elif event == "unit_consumed":
            m = _RE_RAW_MEMPEAK.search(text)
            if m:
                mb = int(float(m.group(1)) * _MEM_UNIT_MB[m.group(2)])
                fields.append(("mem_peak_mb", str(min(mb, 999999999))))
        return event, level, fields
    return None


def classify_ops(parsed):
    """parsed=(ms, level, msg_value, full_line) -> (event, level, fields) or
    None. `level` is a plain word; `fields` is an ORDERED list of (key, value)
    pairs whose values come only from bounded ints / fixed enums."""
    ms, level, msg_value, line = parsed
    if ms is None:
        return None
    line = line or ""
    if not msg_value and not _RE_SLOG_PREFIX.match(line):
        return _classify_ops_raw(line)     # systemd / Go runtime text

    lvl = (level or "INFO").strip().upper()
    low_msg = _nfkc(msg_value or "").strip().lower()
    pairs = _slog_pairs(line)

    for prefix, event in OPS_MSG_EVENTS:
        if low_msg.startswith(prefix):
            fields = _ops_ints(pairs)
            if event in _OPS_CAUSE_EVENTS:
                err = _nfkc(_unquote(pairs.get("err", ""))).lower()
                fields.append(("cause", _ops_cause(err)))
            return event, lvl, fields

    if low_msg == "http":
        ints = dict(_ops_ints(pairs))
        status = int(ints.get("status", "0"))
        took = int(ints.get("ms", "0"))
        if status >= 500:
            event, lvl = "http_5xx", "ERROR"
        elif status != _OPS_HTTP_UPGRADE_STATUS and took >= _OPS_SLOW_HTTP_MS:
            event, lvl = "slow_http", "WARN"
        else:
            return None
        fields = [(k, ints[k]) for k in ("ms", "status") if k in ints]
        method = _unquote(pairs.get("method", ""))
        if method in _OPS_METHODS:
            fields.append(("method", method))
        fields.append(("route", _ops_route(_unquote(pairs.get("path", "")))))
        return event, lvl, fields

    if lvl in ("WARN", "WARNING", "ERROR", "FATAL"):
        event = "warn_other" if lvl in ("WARN", "WARNING") else "error_other"
        return event, lvl, [("msgid", _ops_msgid(msg_value))]
    return None


def _ops_time_ns(ms):
    """epoch-ms (float) -> integer ns, computed in integers so the value is
    exact to the microsecond (ms * 1e6 in float can be off by ~128 ns)."""
    return int(round(ms * 1000.0)) * 1000


def build_ops_record(parsed, node_id):
    """Return (otlp_logRecord, OPS_SCOPE) for an operational-health line, else
    None. The body is assembled from vocabulary + integers ONLY and must pass
    OPS_SHAPE_RE (fail-closed tripwire)."""
    cls = classify_ops(parsed)
    if cls is None:
        return None
    event, level, fields = cls
    sev_num, sev_text = map_severity(level)
    if sev_text == "UNSPECIFIED":
        sev_num, sev_text = map_severity("INFO")
    body = " ".join(["[ops]", "event=" + event, "level=" + sev_text]
                    + ["%s=%s" % (k, v) for k, v in fields])
    if not OPS_SHAPE_RE.match(body):
        return None
    return {
        "timeUnixNano": str(_ops_time_ns(parsed[0])),
        "severityNumber": sev_num,
        "severityText": sev_text,
        "body": {"stringValue": body},
        "attributes": [_attr_str("qa.ops.event", event)],
    }, OPS_SCOPE


def ops_msgid_legend(records):
    """Operator-only (--dry-run) legend for the opaque msgid of unknown WARN /
    ERROR lines: [(msgid, count, event, normalised msg literal)]. Printed to the
    terminal, NEVER shipped."""
    seen = {}
    for parsed in records:
        cls = classify_ops(parsed)
        if cls is None or cls[0] not in ("warn_other", "error_other"):
            continue
        mid = dict(cls[2]).get("msgid")
        if mid is None:
            continue
        ent = seen.setdefault(mid, [0, cls[0], _ops_msg_norm(parsed[2])[:80]])
        ent[0] += 1
    return sorted(((mid, e[0], e[1], e[2]) for mid, e in seen.items()),
                  key=lambda t: -t[1])


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


_RE_SLOG_TIME_PREFIX = re.compile(r"^\s*time=\S+\s+")


def build_log_record(parsed, node_id):
    """parsed is (ms, level, msg_value, full_line). Returns an OTLP logRecord
    dict if the line is shippable, else None (dropped)."""
    ms, level, msg_value, full_line = parsed
    if ms is None:
        return None

    scope_name, scope_safe = resolve_scope(msg_value, full_line)
    attrs = extract_attributes(full_line, node_id)
    # The record already carries the journal timestamp (timeUnixNano); the
    # leading slog `time=<iso>` token is redundant AND was mangled by the blob
    # sweep into "[REDACTED:blob]:48:58.955+02:00" (2026-09-21), so it is cut
    # from the body. Nothing else about the line changes.
    kept, body = redact_body(_RE_SLOG_TIME_PREFIX.sub("", full_line, count=1),
                             scope_safe, attrs)
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


def build_export_request_ex(records, node_id, env_name,
                            lanes=("ops", "call")):
    """Assemble a full ExportLogsServiceRequest. Groups logRecords by scope.
    records is a list of parsed tuples. Returns (request_dict, stats) where
    stats = {call, ops, dropped_irrelevant, dropped_redact}.

    EXACTLY ONE record per journal line (2026-09-21; before, an 'audio relay
    rejected' line produced BOTH an ops-lane and a call-lane record, i.e. the
    same event twice in Loki). The CALL lane (redacted call telemetry, carries
    the qa.call.short8 join key) wins when it ships the line; the OPS lane
    (fixed-shape health signal) is the fallback for a line the call lane did
    not ship. When the call record wins for a line that is ALSO an ops event,
    it carries the closed-vocabulary attribute qa.ops.event so the query
        {service_name="qaudion-server"} | qa_ops_event="relay_rejected"
    still finds it exactly once.
    `lanes` restricts which lanes run (('ops',) = ops-only backfill). Counters:
    stats['call'] + stats['ops'] + dropped_irrelevant + dropped_redact ==
    len(records) always (each line is counted exactly once), and a line counts
    as dropped only if it fed NONE of the enabled lanes."""
    resource = build_resource(node_id, env_name)

    by_scope = {}
    seen = {}
    stats = {"call": 0, "ops": 0, "dropped_irrelevant": 0, "dropped_redact": 0}

    def _uniquify(lr):
        # Same (timestamp, body) inside one run -> +1ns, +2ns, ... so Loki's
        # identical-(ts, line) dedup cannot swallow a burst of genuinely
        # distinct journal lines (50 rejected relays in one millisecond). The
        # OPS lane always did this; now that the call record replaces the ops
        # record for shared lines, the call lane needs the same guard.
        # Deterministic (input order), so a re-run yields the same timestamps.
        sig = (lr["timeUnixNano"], lr["body"]["stringValue"])
        n = seen.get(sig, 0)
        seen[sig] = n + 1
        if n:
            lr["timeUnixNano"] = str(int(lr["timeUnixNano"]) + n)

    for parsed in records:
        built = build_log_record(parsed, node_id) if "call" in lanes else None
        if built is not None:
            lr, scope_name = built
            if "ops" in lanes:
                cls = classify_ops(parsed)
                if cls is not None and cls[0] in OPS_EVENTS:
                    lr["attributes"].append(_attr_str("qa.ops.event", cls[0]))
            _uniquify(lr)
            stats["call"] += 1
            by_scope.setdefault(scope_name, []).append(lr)
            continue
        built = build_ops_record(parsed, node_id) if "ops" in lanes else None
        if built is not None:
            lr, scope_name = built
            _uniquify(lr)
            stats["ops"] += 1
            by_scope.setdefault(scope_name, []).append(lr)
            continue
        ms, _lvl, msg_value, full_line = parsed
        _scope, relevant = resolve_scope(msg_value, full_line)
        if "call" in lanes and ms is not None and relevant:
            stats["dropped_redact"] += 1      # call line the redactor dropped
        else:
            stats["dropped_irrelevant"] += 1  # not a call/ops line at all

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
    return request, stats


def build_export_request(records, node_id, env_name):
    """Back-compat wrapper: returns (request_dict, kept, dropped)."""
    request, st = build_export_request_ex(records, node_id, env_name)
    return (request, st["call"] + st["ops"],
            st["dropped_irrelevant"] + st["dropped_redact"])


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
                           dropped_redact, cursor_advanced, now_ms=None,
                           ops_shipped=None, dropped_irrelevant=None):
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
    if ops_shipped is not None and dropped_irrelevant is not None:
        # W-OPSLANE: `shipped` = call + ops records; `dropped_redact` = call
        # lines the redactor dropped; `dropped_irrelevant` = lines that are
        # neither call nor ops signals (routine noise, by design not shipped).
        body += " ops=%d dropped_irrelevant=%d" % (int(ops_shipped),
                                                   int(dropped_irrelevant))

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
                            dropped_redact, cursor_advanced, now_ms=None,
                            ops_shipped=None, dropped_irrelevant=None):
    """Assemble a standalone ExportLogsServiceRequest carrying ONLY the
    heartbeat record. Shipped separately so it lands even when the call-relevant
    batch is empty (0 shippable lines) OR is being POSTed one-by-one under the
    poison-pill fallback."""
    lr, scope_name = build_heartbeat_record(
        node_id, records_read, shipped, dropped, dropped_redact,
        cursor_advanced, now_ms=now_ms, ops_shipped=ops_shipped,
        dropped_irrelevant=dropped_irrelevant)
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
        if parsed[0] is None:
            # Not a slog line (systemd unit lifecycle, Go runtime fatal
            # output). Only lines the OPS LANE recognises get a timestamp
            # (from journald); everything else stays ms=None and is dropped.
            raw = message.rstrip("\r\n")
            if _classify_ops_raw(raw) is not None:
                try:
                    rt_ms = int(obj.get("__REALTIME_TIMESTAMP")) / 1000.0
                except (TypeError, ValueError):
                    rt_ms = None
                if rt_ms is not None:
                    parsed = (rt_ms, "INFO", "", raw)
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

    # ------------------------------------------------------------------
    # OPS LANE (W-OPSLANE) cases 18-34. Every check bumps `ops_checks`; a
    # failure appends to `failures` (the run then ends NO-GO).
    # ------------------------------------------------------------------
    ops_checks = [0]
    T0 = "time=2026-09-20T18:00:01.123Z"
    U1 = "5b6f8c1e-2f3a-4c5d-8e9f-0a1b2c3d4e5f"          # a user uuid
    IP4 = "203.0.113.9"
    IP6 = "2a02:0e0a:0fce:5fa0:1de0:0c1b:02d7:00e5"
    SECRET = "sk_live_ABCDEF1234567890XYZ"

    def ops_check(label, ok, detail=""):
        ops_checks[0] += 1
        if not ok:
            failures.append("OPS[%s]: %s" % (label, detail))

    def ops_rec(line):
        return build_ops_record(parse_slog_line(line), NODE)

    def ops_body(line):
        b = ops_rec(line)
        return b[0]["body"]["stringValue"] if b else None

    def ops_expect(label, line, expected, forbidden=()):
        b = ops_body(line)
        ops_check(label, b == expected, "body %r != %r" % (b, expected))
        low = (b or "").lower()
        ops_check(label + "/noleak",
                  all(f.lower() not in low for f in forbidden),
                  "forbidden text survived in %r" % b)

    # 18. ws ping failed: user uuid + err text -> fixed cause only.
    l18 = (T0 + ' level=WARN msg="ws ping failed" user=' + U1 +
           ' err="failed to ping: failed to wait for pong: context deadline'
           ' exceeded"')
    ops_expect("ws_ping_failed", l18,
               "[ops] event=ws_ping_failed level=WARN cause=pong_timeout",
               [U1, "user", "err", "context", "deadline"])
    r18 = ops_rec(l18)
    ops_check("ws_ping_failed/record",
              r18 is not None and r18[1] == OPS_SCOPE
              and [a["key"] for a in r18[0]["attributes"]] == ["qa.ops.event"]
              and r18[0]["attributes"][0]["value"]["stringValue"]
              == "ws_ping_failed"
              and r18[0]["severityNumber"] == 13
              and r18[0]["severityText"] == "WARN",
              "record shape wrong: %r" % (r18,))

    # 19. slow tick: elapsed_ms + lines only (day= is not shipped).
    ops_expect("slow_tick",
               T0 + ' level=WARN msg="ingestFromOffset: slow tick held '
               'clusterMu+callIndexMu" day=2026-09-20 elapsed_ms=11550 lines=3',
               "[ops] event=slow_tick level=WARN elapsed_ms=11550 lines=3",
               ["day", "clusterMu", "2026-09-20"])

    # 20. MEMORY: ints only; the free-text step= never appears.
    ops_expect("memory",
               T0 + " level=INFO msg=MEMORY step=after-secret-step "
               "alloc_mb=107 sys_mb=198 goroutines=863",
               "[ops] event=memory level=INFO alloc_mb=107 sys_mb=198 "
               "goroutines=863", ["step", "secret", "cleanup"])

    # 21. UNKNOWN WARN/ERROR line carrying a uuid / IP / secret / free text ->
    #     event=warn_other|error_other + msgid ONLY.
    l21 = (T0 + ' level=WARN msg="tenant acme odd thing 4711 happened" user='
           + U1 + " ip=" + IP4 + " token=" + SECRET +
           ' err="boom Bearer eyJhbGciOiJIUzI1NiJ9.abc.def"')
    b21 = ops_body(l21)
    ops_check("unknown_warn/shape",
              b21 is not None and re.match(
                  r"^\[ops\] event=warn_other level=WARN msgid=[0-9a-f]{8}$",
                  b21) is not None, "body %r" % b21)
    ops_check("unknown_warn/noleak",
              b21 is not None and all(
                  f.lower() not in b21.lower() for f in
                  [U1, IP4, SECRET, "eyJ", "acme", "tenant", "boom", "bearer",
                   "odd", "4711", "token", "user"]),
              "secret/uuid/ip/text survived in %r" % b21)
    b21e = ops_body(l21.replace("level=WARN", "level=ERROR"))
    ops_check("unknown_error/shape",
              b21e is not None and re.match(
                  r"^\[ops\] event=error_other level=ERROR msgid=[0-9a-f]{8}$",
                  b21e) is not None, "body %r" % b21e)
    m_a = ops_body(T0 + ' level=WARN msg="worker 17 stalled"')
    m_b = ops_body(T0 + ' level=WARN msg="worker 942 stalled"')
    m_c = ops_body(T0 + ' level=WARN msg="worker 17 stopped"')
    ops_check("msgid/digit-normalised", m_a == m_b and m_a != m_c,
              "msgid not stable across digits: %r %r %r" % (m_a, m_b, m_c))

    # 22. raw non-slog panic / fatal lines -> event=process_fault, no content.
    #     Timestamped by journald only because the ops lane recognises them.
    fake_lines = [
        {"MESSAGE": "panic: runtime error: index out of range [5] with "
                    "length 3 user=" + U1 + " ip=" + IP4,
         "__CURSOR": "c1", "__REALTIME_TIMESTAMP": "1790000000123456"},
        {"MESSAGE": "fatal error: all goroutines are asleep - deadlock!",
         "__CURSOR": "c2", "__REALTIME_TIMESTAMP": "1790000001000000"},
        {"MESSAGE": "goroutine 1 [running]:",
         "__CURSOR": "c3", "__REALTIME_TIMESTAMP": "1790000001000001"},
        {"MESSAGE": "bcrypto-server.service: Main process exited, "
                    "code=killed, status=9/KILL",
         "__CURSOR": "c4", "__REALTIME_TIMESTAMP": "1790000002000000"},
        {"MESSAGE": T0 + ' level=INFO msg="Serving KMS pending keys"',
         "__CURSOR": "c5", "__REALTIME_TIMESTAMP": "1790000003000000"},
        {"MESSAGE": [104, 105],        # binary MESSAGE -> skipped
         "__CURSOR": "c6", "__REALTIME_TIMESTAMP": "1790000004000000"},
    ]

    class _FakeOut(object):
        def __init__(self, text):
            self._t = text

        def read(self):
            return self._t.encode("utf-8")

    class _FakeClient(object):
        def __init__(self, objs):
            self._objs = objs

        def exec_command(self, cmd):
            txt = "\n".join(json.dumps(o) for o in self._objs) + "\n"
            return None, _FakeOut(txt), _FakeOut("")

    jrecs, jcur = read_journal(_FakeClient(fake_lines), "", 60, 100)
    # (the trailing binary MESSAGE is skipped before the cursor is read, an
    #  existing read_journal behaviour: it is simply re-read next run.)
    ops_check("read_journal/count", len(jrecs) == 5 and jcur == "c5",
              "records=%d cursor=%r" % (len(jrecs), jcur))
    if len(jrecs) == 5:
        p_panic = build_ops_record(jrecs[0], NODE)
        ops_check("panic/body",
                  p_panic is not None and p_panic[0]["body"]["stringValue"]
                  == "[ops] event=process_fault level=ERROR",
                  "panic body %r" % (p_panic,))
        ops_check("panic/noleak",
                  p_panic is not None and all(
                      f not in p_panic[0]["body"]["stringValue"] for f in
                      (U1, IP4, "index", "runtime", "range")),
                  "panic content leaked")
        ops_check("panic/journald-ts",
                  p_panic is not None
                  and p_panic[0]["timeUnixNano"] == "1790000000123456000",
                  "ts %r" % (p_panic[0]["timeUnixNano"] if p_panic else None))
        f_rec = build_ops_record(jrecs[1], NODE)
        ops_check("fatal/body", f_rec is not None and
                  f_rec[0]["body"]["stringValue"]
                  == "[ops] event=process_fault level=ERROR", repr(f_rec))
        ops_check("raw-noise/untimestamped",
                  jrecs[2][0] is None
                  and build_ops_record(jrecs[2], NODE) is None,
                  "unrecognised raw line must stay ms=None and be dropped")
        m_rec = build_ops_record(jrecs[3], NODE)
        ops_check("unit_main_exited/body", m_rec is not None and
                  m_rec[0]["body"]["stringValue"] ==
                  "[ops] event=unit_main_exited level=WARN status=9 "
                  "cause=killed", repr(m_rec))
        ops_check("slog-line/unchanged",
                  jrecs[4][0] is not None and jrecs[4][2] ==
                  "Serving KMS pending keys", repr(jrecs[4]))

    # 23. HTTP: slow -> slow_http (route CLASS only), fast 200 -> nothing,
    #     5xx -> http_5xx, ws sessions (101, ms = session length) -> nothing,
    #     spoof attempts inside path -> nothing.
    ops_expect("slow_http",
               T0 + " level=INFO msg=http method=POST path=/api/v1/files/tus/"
               + U1 + " status=204 ms=1450 ip=" + IP4,
               "[ops] event=slow_http level=WARN ms=1450 status=204 "
               "method=POST route=files_tus", [U1, IP4, "ip=", "path"])
    ops_check("http_200_fast/not-shipped",
              ops_body(T0 + " level=INFO msg=http method=GET "
                       "path=/api/v1/flags status=200 ms=12 ip=" + IP4)
              is None, "fast 200 must not ship")
    ops_expect("http_502",
               T0 + " level=INFO msg=http method=GET path=/api/v1/users/"
               + U1 + "/identity-key status=502 ms=8 ip=" + IP6,
               "[ops] event=http_5xx level=ERROR ms=8 status=502 "
               "method=GET route=api_other", [U1, IP6, "2a02"])
    ops_check("http_ws_session/not-shipped",
              ops_body(T0 + " level=INFO msg=http method=GET path=/ws "
                       "status=101 ms=3600000 ip=" + IP4) is None,
              "a 101 ws session length is not a slow request")
    ops_check("http_spoof_path/not-shipped",
              ops_body(T0 + " level=INFO msg=http method=GET "
                       "path=/x?status=503&ms=99999 status=200 ms=5 ip="
                       + IP4) is None,
              "status=/ms= inside a path token must not spoof the fields")
    ops_check("http_spoof_quoted/not-shipped",
              ops_body(T0 + ' level=INFO msg=http method=GET path="/a b '
                       'status=503 ms=99999" status=200 ms=5 ip=' + IP4)
              is None, "status=/ms= inside a quoted value must not spoof")
    ops_check("http_ms_vs_elapsed_ms",
              ops_body(T0 + " level=INFO msg=http method=GET path=/x "
                       "status=200 elapsed_ms=5000 ms=3") is None
              and ops_body(T0 + " level=INFO msg=http method=GET path=/x "
                           "status=200 elapsed_ms=5000") is None,
              "elapsed_ms= must not be read as ms=")

    # 24. refresh token rejected: hash_prefix + ip must not ship.
    ops_expect("refresh_rejected",
               T0 + " level=WARN msg=\"refresh token rejected\" "
               "hash_prefix=deadbeefcafe0123 token_len=64 err=<nil> ip="
               + IP6,
               "[ops] event=refresh_rejected level=WARN",
               ["deadbeef", "hash", "2a02", "token_len", "ip"])

    # 25. OPS_SHAPE_RE rejects tampered bodies and accepts a good one.
    good = "[ops] event=ws_ping_failed level=WARN cause=pong_timeout"
    ops_check("shape/good", OPS_SHAPE_RE.match(good) is not None, "good body")
    for label, bad in (
            ("uuid-cause", good.replace("pong_timeout", U1)),
            ("user-kv", good + " user=" + U1),
            ("uuid-bare", good + " " + U1),
            ("ip-kv", good + " ip=" + IP4),
            ("hex-msgid", "[ops] event=warn_other level=WARN "
                          "msgid=deadbeefdeadbeef"),
            ("unknown-event", "[ops] event=made_up_event level=WARN"),
            ("unknown-cause", good.replace("pong_timeout", "some_free_text")),
            ("newline", good + "\nextra"),
            ("trailing-newline", good + "\n"),
            ("no-prefix", good.replace("[ops] ", "")),
            ("big-int", "[ops] event=memory level=INFO alloc_mb=1234567890")):
        ops_check("shape/reject-" + label, OPS_SHAPE_RE.match(bad) is None,
                  "tampered body accepted: %r" % bad)

    # 26. An ordinary INFO line is shipped by NEITHER lane.
    l26 = T0 + ' level=INFO msg="Serving KMS pending keys"'
    ops_check("plain_info/ops", ops_rec(l26) is None, "ops lane shipped INFO")
    ops_check("plain_info/call",
              build_log_record(parse_slog_line(l26), NODE) is None,
              "call lane shipped INFO")
    req26, st26 = build_export_request_ex([parse_slog_line(l26)], NODE,
                                          "production")
    ops_check("plain_info/stats",
              st26 == {"call": 0, "ops": 0, "dropped_irrelevant": 1,
                       "dropped_redact": 0}
              and req26["resourceLogs"][0]["scopeLogs"] == [], repr(st26))

    # 27. Heartbeat: new optional args -> exact extended shape; without them
    #     the exact OLD shape (case 15 above asserts the old one byte-exact).
    hb_new = build_heartbeat_request(
        NODE, "production", records_read=7, shipped=4, dropped=3,
        dropped_redact=3, cursor_advanced=True, now_ms=1_700_000_000_000.0,
        ops_shipped=2, dropped_irrelevant=1)
    hb_new_body = (hb_new["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
                   ["body"]["stringValue"])
    ops_check("heartbeat/new-shape", hb_new_body ==
              "[heartbeat] cursor_advanced=true records_read=7 shipped=4 "
              "dropped=3 dropped_redact=3 ops=2 dropped_irrelevant=1",
              hb_new_body)
    ops_check("heartbeat/new-int-only", re.match(
        r"^\[heartbeat\] cursor_advanced=(?:true|false) records_read=\d+ "
        r"shipped=\d+ dropped=\d+ dropped_redact=\d+ ops=\d+ "
        r"dropped_irrelevant=\d+$", hb_new_body) is not None, hb_new_body)
    hb_old = build_heartbeat_request(
        NODE, "production", records_read=7, shipped=4, dropped=3,
        dropped_redact=3, cursor_advanced=True, now_ms=1_700_000_000_000.0)
    hb_old_body = (hb_old["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
                   ["body"]["stringValue"])
    ops_check("heartbeat/old-shape", hb_old_body ==
              "[heartbeat] cursor_advanced=true records_read=7 shipped=4 "
              "dropped=3 dropped_redact=3", hb_old_body)

    # 28. build_export_request_ex stats: EXACTLY ONE record per journal line.
    #     A line both lanes could ship ships once, as the CALL record (it
    #     carries the join key); the ops record is the fallback. dropped_*
    #     only for lines feeding NEITHER lane.
    l_both = (T0 + ' level=WARN msg="audio relay rejected: not an established'
              ' call party (binary)" call_id=91fe5cf7 sender=aabbccdd')
    l_ops = l18
    l_call = (T0 + ' level=INFO msg="call_ready" call_id=91fe5cf7 '
              'receiver=aabbccdd device=11223344')
    l_none = l26
    l_redacted = (T0 + ' level=INFO msg="call started" call_id=91fe5cf7 '
                  'panic: runtime error: x')
    l_garbage = "goroutine 1 [running]:"
    recs28 = [parse_slog_line(x) for x in
              (l_both, l_ops, l_call, l_none, l_redacted, l_garbage)]
    req28, st28 = build_export_request_ex(recs28, NODE, "production")
    ops_check("stats/one-record-per-line", st28 == {
        "call": 2, "ops": 1, "dropped_irrelevant": 2, "dropped_redact": 1},
        repr(st28))
    ops_check("stats/adds-up", sum(st28.values()) == len(recs28), repr(st28))
    scopes28 = dict((sl["scope"]["name"], len(sl["logRecords"]))
                    for sl in req28["resourceLogs"][0]["scopeLogs"])
    # (the both-lane line is scoped qaudion.media by the call lane: "audio ...")
    ops_check("stats/scopes", scopes28 == {OPS_SCOPE: 1, "qaudion.media": 1,
                                           "qaudion.call": 1},
              repr(scopes28))
    _rq, kept28, dropped28 = build_export_request(recs28, NODE, "production")
    ops_check("stats/backcompat", (kept28, dropped28) == (3, 3),
              "kept=%r dropped=%r" % (kept28, dropped28))
    req28o, st28o = build_export_request_ex(recs28, NODE, "production",
                                            lanes=("ops",))
    ops_check("stats/ops-only", st28o == {
        "call": 0, "ops": 2, "dropped_irrelevant": 4, "dropped_redact": 0}
        and [sl["scope"]["name"]
             for sl in req28o["resourceLogs"][0]["scopeLogs"]] == [OPS_SCOPE],
        repr(st28o))

    # 29. Same-ms identical bodies get +1ns, +2ns (Loki dedup guard),
    #     deterministically; a different ms is untouched.
    burst = [parse_slog_line(l18.replace(U1, "%08x-0000-4000-8000-000000000000"
                                         % i)) for i in range(3)]
    burst.append(parse_slog_line(l18.replace("18:00:01.123Z",
                                             "18:00:01.124Z")))
    rq29a, _s = build_export_request_ex(burst, NODE, "production",
                                        lanes=("ops",))
    rq29b, _s = build_export_request_ex(burst, NODE, "production",
                                        lanes=("ops",))
    ts29 = [int(lr["timeUnixNano"]) for lr in
            rq29a["resourceLogs"][0]["scopeLogs"][0]["logRecords"]]
    ts29b = [int(lr["timeUnixNano"]) for lr in
             rq29b["resourceLogs"][0]["scopeLogs"][0]["logRecords"]]
    base29 = _ops_time_ns(iso_to_ms("2026-09-20T18:00:01.123Z"))
    ops_check("ns-uniquifier", ts29 == [base29, base29 + 1, base29 + 2,
                                        base29 + 1_000_000]
              and ts29 == ts29b, repr(ts29))

    # 30. Unit lifecycle (systemd) lines -> unit_* events, ints/enums only.
    ms30 = 1_790_000_000_000.0
    unit_cases = (
        ("Stopping bcrypto-server.service - BCrypto VoIP Server (lite, "
         "bbolt, HTTP behind Caddy)...",
         "[ops] event=unit_stopping level=INFO"),
        ("bcrypto-server.service: State 'stop-sigterm' timed out. Killing.",
         "[ops] event=unit_stop_timeout level=WARN"),
        ("bcrypto-server.service: Killing process 4242 (bcrypto-lite) with "
         "signal SIGKILL.", "[ops] event=unit_kill level=WARN"),
        ("bcrypto-server.service: Main process exited, code=killed, "
         "status=9/KILL",
         "[ops] event=unit_main_exited level=WARN status=9 cause=killed"),
        ("bcrypto-server.service: Failed with result 'timeout'.",
         "[ops] event=unit_failed level=ERROR cause=timeout"),
        ("bcrypto-server.service: Failed with result 'weird-new-result'.",
         "[ops] event=unit_failed level=ERROR cause=other"),
        ("Stopped bcrypto-server.service - BCrypto VoIP Server (lite, "
         "bbolt, HTTP behind Caddy).", "[ops] event=unit_stopped level=INFO"),
        ("bcrypto-server.service: Consumed 2min 31.480s CPU time, 401.5M "
         "memory peak, 0B memory swap peak.",
         "[ops] event=unit_consumed level=INFO mem_peak_mb=401"),
        ("Started bcrypto-server.service - BCrypto VoIP Server (lite, "
         "bbolt, HTTP behind Caddy).", "[ops] event=unit_started level=INFO"),
        ("bcrypto-server.service: Scheduled restart job, restart counter is "
         "at 3.",
         "[ops] event=unit_restart_scheduled level=WARN restarts=3"),
        ("bcrypto-server.service: Failed with result 'exit-code'.",
         "[ops] event=unit_failed level=ERROR cause=exit_code"),
        ("turn ERROR: 2026/09/20 19:48:17 Failed to close conn: tls: failed "
         "to send closeNotify alert", None),
        ("bcrypto-server.service: Deactivated successfully.", None),
    )
    for raw30, want30 in unit_cases:
        got30 = build_ops_record((ms30, "INFO", "", raw30), NODE)
        got30 = got30[0]["body"]["stringValue"] if got30 else None
        ops_check("unit/" + (want30 or "none")[:40], got30 == want30,
                  "%r -> %r != %r" % (raw30[:60], got30, want30))
    ops_check("unit/no-pid", "4242" not in (build_ops_record(
        (ms30, "INFO", "", unit_cases[2][0]), NODE)[0]["body"]["stringValue"]),
        "pid leaked")

    # 31. Cause vocabulary is closed: every ws err text maps into it.
    cause_cases = (
        ("failed to ping: failed to wait for pong: context deadline exceeded",
         "pong_timeout"),
        ("failed to ping: failed to wait for pong: context canceled",
         "canceled"),
        ("failed to ping: failed to write control frame opPing: use of "
         "closed network connection", "closed_conn"),
        ("failed to get reader: received close frame: status = "
         "StatusNormalClosure and reason = \\\"\\\"", "normal_closure"),
        ("failed to get reader: received close frame: status = "
         "StatusNormalClosure and reason = \\\"net-change:net:wifi\\\"",
         "net_change"),
        ("failed to get reader: received close frame: status = "
         "StatusGoingAway", "going_away"),
        ("failed to get reader: failed to read frame header: EOF", "eof"),
        ("failed to get reader: use of closed network connection",
         "closed_conn"),
        ("failed to get reader: context canceled", "canceled"),
        ("read tcp 10.0.0.1:1->10.0.0.2:2: read: connection reset by peer",
         "conn_reset"),
        ("write tcp 10.0.0.1:1: write: broken pipe", "broken_pipe"),
        ("read: i/o timeout", "timeout"),
        ("secret text " + U1 + " " + IP4, "other"),
    )
    for err31, want31 in cause_cases:
        b31 = ops_body(T0 + ' level=INFO msg="ws read error" user=' + U1 +
                       ' err="' + err31 + '"')
        ops_check("cause/" + want31,
                  b31 == "[ops] event=ws_read_error level=INFO cause=" + want31,
                  "%r -> %r" % (err31[:50], b31))
    # cause comes from err= ONLY: trigger words in other fields must not steer.
    b31x = ops_body(T0 + ' level=INFO msg="ws read error" user="" note="status'
                    ' = StatusGoingAway net-change wait for pong" err="failed '
                    'to get reader: use of closed network connection"')
    ops_check("cause/err-only", b31x ==
              "[ops] event=ws_read_error level=INFO cause=closed_conn",
              repr(b31x))
    ops_check("cause/closed-vocab",
              all(c in _OPS_CAUSES for c in _OPS_WS_CAUSES)
              and set(_OPS_WS_CAUSES) >= set(w for _e, w in cause_cases),
              "cause vocabulary out of sync")

    # 32. Named security/ops events shipped without their identifying fields.
    ops_expect("refresh_reuse",
               T0 + ' level=WARN msg="refresh token REUSE detected \u2014 '
               'family invalidated" user_id=' + U1 + " device_id=" + U1 +
               " invalidate_err=<nil> ip=" + IP6,
               "[ops] event=refresh_reuse level=WARN", [U1, "2a02", "user"])
    ops_expect("zombie_swept",
               T0 + ' level=WARN msg="ws zombie swept \u2014 no inbound frame '
               'past threshold" user=aabbccdd device=' + U1 +
               " age_sec=95 threshold_sec=90",
               "[ops] event=ws_zombie_swept level=WARN age_sec=95 "
               "threshold_sec=90", [U1, "aabbccdd", "device"])
    ops_expect("zombie_sweep_completed",
               T0 + ' level=INFO msg="ws zombie sweep completed" evicted=2',
               "[ops] event=ws_zombie_sweep_completed level=INFO evicted=2")
    ops_expect("ws_opened",
               T0 + ' level=INFO msg="ws: opened" remote=' + IP4 +
               ' ua="QAudionApp/1 CFNetwork/1.0 Darwin/1.0" cf_ray=abcdef0123'
               '456789-CDG cf_ip=' + IP4,
               "[ops] event=ws_opened level=INFO",
               [IP4, "QAudion", "cf_", "abcdef"])
    ops_expect("shutdown_signal",
               T0 + ' level=INFO msg="shutdown signal received"',
               "[ops] event=shutdown_signal level=INFO")
    ops_expect("relay_rejected",
               T0 + ' level=WARN msg="audio relay rejected: not an '
               'established call party (binary)" call_id=91fe5cf7 '
               'sender=aabbccdd',
               "[ops] event=relay_rejected level=WARN",
               ["91fe5cf7", "aabbccdd", "sender", "call_id"])

    # 33. Digits only from real integer tokens: a >9-digit value is clamped, a
    #     non-integer is ignored, an ASCII-only [0-9] match (no unicode digits).
    ops_expect("int-clamp",
               T0 + ' level=INFO msg="ws zombie sweep completed" '
               'evicted=99999999999999',
               "[ops] event=ws_zombie_sweep_completed level=INFO "
               "evicted=999999999")
    ops_expect("int-nonnumeric",
               T0 + ' level=INFO msg="ws zombie sweep completed" '
               'evicted=abc123',
               "[ops] event=ws_zombie_sweep_completed level=INFO")

    # 34. --dry-run msgid legend: opaque msgid -> normalised literal, no ids.
    leg = ops_msgid_legend([parse_slog_line(
        T0 + ' level=WARN msg="worker 17 stalled" user=' + U1)])
    ops_check("legend", len(leg) == 1 and leg[0][1] == 1
              and leg[0][3] == "worker # stalled" and U1 not in leg[0][3],
              repr(leg))

    # 35. ONE record per journal line (W-SINGLEREC 2026-09-21). An 'audio relay
    #     rejected' line used to ship as an ops record AND a call record.
    def _flat(req):
        return [(sl["scope"]["name"], lr) for sl in
                req["resourceLogs"][0]["scopeLogs"] for lr in sl["logRecords"]]

    def _attrs(lr):
        return dict((a["key"], a["value"]["stringValue"])
                    for a in lr["attributes"])

    rq35, st35 = build_export_request_ex([parse_slog_line(l_both)], NODE,
                                         "production")
    fl35 = _flat(rq35)
    ops_check("single/one-record", len(fl35) == 1 and st35 == {
        "call": 1, "ops": 0, "dropped_irrelevant": 0, "dropped_redact": 0},
        "%d records, %r" % (len(fl35), st35))
    if len(fl35) == 1:
        sc35, lr35 = fl35[0]
        at35 = _attrs(lr35)
        b35 = lr35["body"]["stringValue"]
        ops_check("single/call-record-wins", sc35 == "qaudion.media"
                  and at35.get("qa.call.short8") == "91fe5cf7"
                  and not b35.startswith("[ops]"), "%r %r %r" % (sc35, at35, b35))
        ops_check("single/ops-event-attr", at35.get("qa.ops.event")
                  == "relay_rejected", repr(at35))
        ops_check("single/no-time-prefix", "time=" not in b35
                  and "2026-09-20" not in b35 and not b35.startswith("[REDACTED"),
                  repr(b35))
        ops_check("single/no-callid-leak", "91fe5cf7-" not in b35
                  and "aabbccdd" not in b35, repr(b35))
    # fallback: when the call lane does NOT ship the line (the server drop-list
    # eats 'identity'), the ops record ships instead -- still exactly one.
    l_fb = (T0 + ' level=WARN msg="audio relay rejected: not an established'
            ' call party (binary)" identity=zz')
    rq35b, st35b = build_export_request_ex([parse_slog_line(l_fb)], NODE,
                                           "production")
    fl35b = _flat(rq35b)
    ops_check("single/ops-fallback", len(fl35b) == 1 and fl35b[0][0] == OPS_SCOPE
              and fl35b[0][1]["body"]["stringValue"]
              == "[ops] event=relay_rejected level=WARN"
              and st35b["ops"] == 1 and st35b["call"] == 0
              and "identity" not in fl35b[0][1]["body"]["stringValue"],
              "%r %r" % (fl35b, st35b))
    # ops-only backfill still ships the ops record (no call lane, no attr).
    rq35c, st35c = build_export_request_ex([parse_slog_line(l_both)], NODE,
                                           "production", lanes=("ops",))
    fl35c = _flat(rq35c)
    ops_check("single/ops-only", len(fl35c) == 1 and fl35c[0][0] == OPS_SCOPE
              and st35c["ops"] == 1 and st35c["call"] == 0, repr(st35c))
    # a mixed run: every line counted once, records == call + ops, and the
    # heartbeat built from these numbers adds up (records_read == shipped +
    # dropped).
    mix35 = [parse_slog_line(x) for x in
             (l_both, l_both, l_ops, l_call, l_none, l_redacted, l_garbage, l_fb)]
    rq35d, st35d = build_export_request_ex(mix35, NODE, "production")
    fl35d = _flat(rq35d)
    ops_check("single/counters", sum(st35d.values()) == len(mix35)
              and len(fl35d) == st35d["call"] + st35d["ops"], repr(st35d))
    hb35 = build_heartbeat_request(
        NODE, "production", len(mix35), st35d["call"] + st35d["ops"],
        st35d["dropped_irrelevant"] + st35d["dropped_redact"],
        st35d["dropped_redact"], True, now_ms=1_700_000_000_000.0,
        ops_shipped=st35d["ops"], dropped_irrelevant=st35d["dropped_irrelevant"])
    hbb35 = (hb35["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
             ["body"]["stringValue"])
    m35 = re.match(r"^\[heartbeat\] cursor_advanced=true records_read=(\d+) "
                   r"shipped=(\d+) dropped=(\d+) dropped_redact=(\d+) ops=(\d+) "
                   r"dropped_irrelevant=(\d+)$", hbb35)
    ops_check("single/heartbeat-consistent", bool(m35)
              and int(m35.group(1)) == int(m35.group(2)) + int(m35.group(3))
              and int(m35.group(3)) == int(m35.group(4)) + int(m35.group(6))
              and int(m35.group(2)) == len(fl35d), hbb35)
    # a burst of identical lines within one millisecond stays countable: the
    # call lane gets the same +1ns/+2ns guard the ops lane always had.
    burst35 = [parse_slog_line(l_both)] * 3
    rq35e, st35e = build_export_request_ex(burst35, NODE, "production")
    ts35 = [int(lr["timeUnixNano"]) for _s, lr in _flat(rq35e)]
    ops_check("single/burst-distinct-ns", len(ts35) == 3 and st35e["call"] == 3
              and ts35 == [ts35[0], ts35[0] + 1, ts35[0] + 2], repr(ts35))

    # 36. RED-TEAM HARDENING 2026-09-24 (ported from ship-ios-logs.py: W-KEYWORDS
    #     + W-FREEWORD). Every value is SYNTHETIC (the bytes 1..32 / letter runs).
    hd = 'level=INFO msg="call status: active" call_id=91fe5cf7 '
    for tail in ("derived_key ok", "raw_key [ABCD:EFGH]", "raw key computed",
                 "salt [ab:cd]", "slat (7)", "session_key [x]", "secret {a b}"):
        _k, _b = redact_body(hd + tail, True, {})
        if _k and _b:
            failures.append("LEAK[key-words]: line was not dropped: %r" % tail)
    _n = int.from_bytes(bytes(range(1, 33)), "big")
    _s = ""
    while _n:
        _n, _r = divmod(_n, 26)
        _s = "abcdefghijklmnopqrstuvwxyz"[_r] + _s
    for _k11 in (3, 5, 8, 11):
        _bl = [_s[i:i + _k11] for i in range(0, len(_s), _k11)]
        for _line in (hd + " active ".join(_bl) + " ok",
                      hd + " state=active ".join(_bl) + " ok"):
            _kk, _bb = redact_body(_line, True, {})
            _got = [b for b in _bl if b in _bb.split()] if _kk else []
            if len(_got) > MAX_UNKNOWN_WORDS or any(len(b) >= 10 for b in _got):
                failures.append("LEAK[freeword/%d]: %d letter block(s) survived"
                                % (_k11, len(_got)))
    for _blk in ("aBcDeFgHiJk", "1abcdefghij"):
        _kk, _bb = redact_body(hd + _blk + " ok", True, {})
        if _kk and _blk in _bb:
            failures.append("LEAK[freeword/shape]: %r survived" % _blk)
    _kk, _bb = redact_body(hd + "x=abcdefghi y=jklmnopqr z=stuvwxyza w=bcdefghij", True, {})
    if _kk and sum(1 for v in ("abcdefghi", "jklmnopqr", "stuvwxyza", "bcdefghij") if v in _bb) > MAX_UNKNOWN_WORDS:
        failures.append("LEAK[freeword/kv]: kv value carriers survived")
    _kk, _bb = redact_body(hd + "seq=12 rtt=35ms", True, {})
    if not _kk or "[summary]" in _bb or "seq=12" not in _bb:
        failures.append("REGRESS[freeword]: plain structured call line altered: %r" % _bb)

    out("=" * 72)
    out("SELF-TEST: server-leg privacy redaction + join-key reconcile")
    out("=" * 72)
    if failures:
        for f in failures:
            out("  FAIL: " + f)
        out("")
        out("  RESULT: NO-GO (%d leak/regression)" % len(failures))
        return 1
    out("  %d/%d ops-lane checks pass (W-OPSLANE): ws ping/read/zombie/opened"
        % (ops_checks[0], ops_checks[0]))
    out("  events ship as fixed vocabulary + bounded ints + enum causes only")
    out("  (no uuid/IP/err text/path/hash_prefix/UA), unknown WARN/ERROR ->")
    out("  msgid only, panic/unit lifecycle lines -> unit_*/process_fault,")
    out("  OPS_SHAPE_RE rejects tampered bodies, slow/5xx http shipped as")
    out("  route class only (fast 200 / ws sessions / spoofed paths not),")
    out("  plain INFO shipped by neither lane, heartbeat old+new shapes exact,")
    out("  per-lane stats add up, same-ms bursts get distinct ns, EXACTLY ONE")
    out("  record per journal line (call record wins, ops record is the")
    out("  fallback; counters + heartbeat add up).")
    out("  20/20 call-lane cases pass: full call_id/user-uuid/pubkey/panic/auth/SDP all")
    out("  blocked; bare mixed-alnum secret tokens hard-failed; non-call lines")
    out("  dropped; node id validated; structured call telemetry still ships;")
    out("  qa.call.short8 == iOS-leg short8 incl. the QUOTED form; 6/7-char ids")
    out("  floored to '' to match correlate-call.py; heartbeat emits pre-cleared")
    out("  int-only telemetry (idle + active) of exact safe shape; poison-pill")
    out("  fail_count round-trips through state; record-shape disclosure is")
    out("  shape-only (no body/value leak).")
    out("  key-material words (derived/raw key, secret/slat/salt/*key + a bracket")
    out("  group) drop the whole line; free-word letter blocks / mixed-case blocks /")
    out("  number+letter tokens / kv value carriers are capped (W-FREEWORD).")
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
    ap.add_argument("--ops-only", action="store_true",
                    help="ship ONLY the ops lane (no call lane, no heartbeat); "
                         "for a history backfill, run with a SEPARATE "
                         "--state-file so the cron cursor is untouched")
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
    ops_shipped = 0
    dropped_redact = 0
    dropped_irrelevant = 0
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

        request, stats = build_export_request_ex(
            records, node_id, args.env_name,
            lanes=("ops",) if args.ops_only else ("ops", "call"))
        kept = stats["call"] + stats["ops"]
        dropped = stats["dropped_irrelevant"] + stats["dropped_redact"]
        lines_shipped = kept
        lines_dropped = dropped
        ops_shipped = stats["ops"]
        dropped_redact = stats["dropped_redact"]
        dropped_irrelevant = stats["dropped_irrelevant"]

        if args.dry_run:
            # Show the heartbeat that WOULD ship alongside the call batch.
            hb_req = build_heartbeat_request(
                node_id, args.env_name, lines_total, kept, dropped,
                dropped_redact, cursor_advanced=False,
                ops_shipped=ops_shipped, dropped_irrelevant=dropped_irrelevant)
            print_dry_run(hb_req)
            print_dry_run(request)
            legend = ops_msgid_legend(records)
            if legend:
                out()
                out("OPS msgid legend (operator terminal only, never shipped):")
                for mid, cnt, ev, norm in legend:
                    out("  %s  x%-5d %-11s %s" % (mid, cnt, ev, norm))
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
            # --ops-only (history backfill) must NOT emit one: a heartbeat with
            # backfill counters would corrupt the shipper-liveness series.
            if not args.ops_only:
                hb_advanced = (new_cursor != cursor)
                hb_req = build_heartbeat_request(
                    node_id, args.env_name, lines_total, kept, dropped,
                    dropped_redact, cursor_advanced=hb_advanced,
                    ops_shipped=ops_shipped,
                    dropped_irrelevant=dropped_irrelevant)
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
    out("  lines shipped:           %d  (call %d + ops %d)"
        % (lines_shipped, lines_shipped - ops_shipped, ops_shipped))
    out("  lines dropped:           %d  (redact %d + not call/ops %d)"
        % (lines_dropped, dropped_redact, dropped_irrelevant))
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
        if args.ops_only:
            out("  heartbeat:               skipped (--ops-only backfill)")
        else:
            out("  heartbeat:               emitted (scope %s)"
                % HEARTBEAT_SCOPE)
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
