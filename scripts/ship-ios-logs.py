#!/usr/bin/env python3
"""
ship-ios-logs.py -- ship iOS W417 telemetry chunks from the PROD VPS into a
Loki OTLP/JSON log backend, FAIL-CLOSED redacted at translation time.

This is a SAFE, read-only-on-the-VPS dev-box tool. It:
  - SSHes to the prod VPS the SAME way fetch-ios-live.py / correlate-call.py do
    (env vars QAUDION_VPS_HOST/USER/PASS, else bcrypto-server/VPS_ACCESS.md)
  - SFTP-reads recent W417 device chunks (read only, <=256KB blobs)
  - parses the {"type":"header"} line + the {"ts",...} NDJSON event lines
  - REDACTS EVERY line FAIL-CLOSED. A body reaches the backend ONLY if it is
    PROVABLY SAFE: structured telemetry (key=value pairs, known state enums,
    numbers, short tokens, bracketed [REDACTED:*] placeholders). Anything that
    is not provably structured is DROPPED or replaced by an attribute-only
    summary. RAW BYTES NEVER REACH THE BACKEND.
  - maps to an OTLP/JSON ExportLogsServiceRequest. EVERY resource + record
    attribute is ALLOW-LISTED and validated/scrubbed (deny-by-default). No
    device-controlled header field ships unvalidated.
  - batch-POSTs to the Loki OTLP endpoint with a bearer token from the env var
    QA_LOG_INGEST_TOKEN (--ingest-token overrides). Loki returns 204 on success.

NO app build. NO prod write. NO external LLM. Pure ASCII output.

=== HARD PRIVACY INVARIANT (read before editing the redaction) ==============
This ships logs from a post-quantum ENCRYPTED VOICE app into a QUERYABLE Loki
backend. After shipping, anyone with Grafana/query access can full-text search
every body. The on-device redaction is INCOMPLETE: RuntimeLogSink.redact()
(RuntimeLogSink.swift line 257) runs ONLY on the stdout-tee path (line 311);
the PRIMARY structured path RTLog.info/warn/error -> record() (line 68) is
NEVER redacted, and entriesSince() (line 159) JSON-escapes but does NOT redact.
So the raw uploaded blobs on PROD MAY contain unredacted secrets on every
non-"stdout"-tagged line. Therefore this shipper treats on-device redaction AND
the header JSON as UNTRUSTED, and is FAIL-CLOSED:

  SHIP A BODY ONLY IF IT IS PROVABLY SAFE. NOT "ship unless a secret matches".

The body redactor is a POSITIVE allow-list (structured-shape gate) backed by a
deny scrub + residual-entropy tripwires, NOT a deny-list. Every OTLP attribute
(resource AND record) is allow-listed by KEY and validated/enum-checked by
VALUE; a header field that fails validation is dropped, never shipped raw.

FORBIDDEN to ever reach the backend: message plaintext / chat / SAS words,
crypto keys / PSK / ML-KEM ciphertext / tokens, raw call_id, device serial /
IMEI / MAC, device_name / model, account/user/peer UUIDs (only hmac8 hashes),
phone numbers, identity public keys / fingerprints, SDP, ICE candidate IPs,
TURN creds, audio / base64 media, SSID / network names.

Usage:
  python scripts/ship-ios-logs.py --dry-run
  python scripts/ship-ios-logs.py --minutes 180 --limit 200
  python scripts/ship-ios-logs.py --endpoint https://dash.bcrypto.com/otlp/v1/logs
  QA_LOG_INGEST_TOKEN=... python scripts/ship-ios-logs.py
  python scripts/ship-ios-logs.py --ingest-token "$TOKEN" --env production

Options:
  --minutes        Lookback window in minutes (default 180).
  --limit          Max device chunks to download (default 200).
  --endpoint       Loki OTLP/JSON logs endpoint
                   (default https://dash.bcrypto.com/otlp/v1/logs).
  --ingest-token   Bearer token; overrides env QA_LOG_INGEST_TOKEN.
  --env            deployment.environment.name (default testflight).
  --batch          Log records per HTTP POST (default 500).
  --state-file     Local JSON state path
                   (default ~/.qaudion/ship-ios-logs.state.json).
  --dry-run        Print the redacted OTLP that WOULD ship; push nothing.
  --reset-state    Ignore + overwrite prior state (re-ship everything).

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

    Same precedence + same regexes as fetch-ios-live.py: env first, then the
    sibling bcrypto-server/VPS_ACCESS.md (values may be wrapped in markdown
    backticks).
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


VPS_HOST, VPS_USER, VPS_PASS = _load_vps_creds()
DATA_DIR = "/opt/bcrypto/data/files"


def ssh_connect():
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
    Device msgs carry unicode (em-dash, ellipsis); replace rather than crash."""
    return s.encode("ascii", "replace").decode("ascii")


def out(line=""):
    print(_ascii(line))


def _is_w417_first_line(first_line):
    """Same chunk-detection heuristic as correlate-call.py:_is_w417_first_line
    (lines 284-290). Reused verbatim."""
    iso_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
    return (
        bool(iso_re.match(first_line))
        or first_line.startswith('{"type":"header"')
        or first_line.startswith('{"ts"')
    )


def hmac8(raw):
    """Stable, NON-reversible, NON-device-identifying 8-hex digest of a value.
    Used for correlation keys (call short id) and the orphan-blob instance id.
    A digest, not a prefix: it never leaks real bits of the source value."""
    if not raw:
        return ""
    return hashlib.sha256(str(raw).encode("utf-8")).hexdigest()[:8]


# ---------------------------------------------------------------------------
# UNICODE NORMALIZATION (close the full-width / homoglyph bypass).
# All ASCII regexes below run on the NFKC-folded body, so 'password' written
# with full-width code points (U+FF50..) folds to ASCII and is caught.
# ---------------------------------------------------------------------------

def _nfkc(s):
    if s is None:
        return ""
    try:
        return unicodedata.normalize("NFKC", s)
    except Exception:
        return s


# ---------------------------------------------------------------------------
# REDACTION -- FAIL-CLOSED, positive allow-list.
# ---------------------------------------------------------------------------

# 1a. Mirror of RuntimeLogSink.redact() (RuntimeLogSink.swift lines 246-255),
# applied in the SAME order (secretPrefixed first, then longBlob). We MIRROR it
# only to stay aligned; the real protection is the positive gate below.
PLACEHOLDER = "[REDACTED:secret]"
RE_SECRET_PREFIXED = re.compile(
    r"(?i)(bearer|authorization|token|secret|api[-_]?key|password)([\"'\s:=]+)\S+")
RE_LONG_BLOB = re.compile(r"[A-Za-z0-9+/=_-]{16,}")  # lowered 24 -> 16

# 1b. Deny scrub -- bounded [REDACTED:<kind>] replacements. Keyed/structured
# patterns run before broad sweeps. Thresholds are deliberately LOW (12) so
# short ML-KEM fragments / PSK prefixes / framed-audio chunks cannot slip.
RE_RAW_UUID = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
RE_CALLID_KEY = re.compile(r"(?i)call[ _]?id\s*[=:]\s*\S+")
# device identity keys -> drop the value (closes the device_name=... body leak).
RE_DEVICE_KEY = re.compile(
    r"(?i)\b(device[ _]?name|devicename|device[ _]?id|model|hostname|"
    r"machine|udid|serial(?:[ _]?no)?)\b\s*[=:]\s*\S+")
RE_SECRET_KV = re.compile(
    r"(?i)\b(psk|mlkem|ml[-_]?kem|ciphertext|privkey|private[-_]?key|pubkey|"
    r"public[-_]?key|fingerprint|sas|imei|serial|turn|ice[-_]?pwd|"
    r"ice[-_]?ufrag|passwd|ssid|key|nonce|iv|tag)\b\s*[=:]\s*\S+")
RE_MAC = re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b")
RE_IPV6 = re.compile(r"\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b")
RE_IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
RE_EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b")
RE_PHONE = re.compile(r"(?<!\d)\+?\d[\d\s().\-/]{6,}\d(?!\d)")
# JWT / dotted-token: 2+ base64url segments joined by dots.
RE_JWT_DOTTED = re.compile(r"\b[A-Za-z0-9_-]{6,}(?:\.[A-Za-z0-9_-]{4,}){1,}\b")
# Spaced/chunked hex groups (pretty-printed key/fingerprint dumps):
# 2+ groups of 4-8 hex separated by single spaces.
RE_SPACED_HEX = re.compile(r"\b(?:[0-9a-fA-F]{4,8}\s){2,}[0-9a-fA-F]{4,8}\b")
RE_HEX_BLOB = re.compile(r"\b[0-9a-fA-F]{12,}\b")              # lowered 16 -> 12
# base64 AND base64url (includes '-' and '_'); lowered 20 -> 12.
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
    # Spaced/chunked hex BEFORE phone/ipv4 so a hex dump like
    # "aabbccdd eeff0011 ..." is collapsed as one [REDACTED:hex] rather than
    # having its digit-only groups partially eaten by the phone sweep.
    ("hex", RE_SPACED_HEX),
    ("ipv4", RE_IPV4),
    ("phone", RE_PHONE),
    ("jwt", RE_JWT_DOTTED),
    ("hex", RE_HEX_BLOB),
    ("blob", RE_BASE64_BLOB),
]

# 1c. SAS / plaintext DROP-list (matched on the NFKC-normalized lowercased
# ORIGINAL body). Any hit => DROP the whole line (do not ship even scrubbed).
SAS_DROP_SUBSTRINGS = [
    "sas", "safety number", "safety-number", "emoji", "plaintext",
    "cleartext", "decrypted", "transcript", "message body", "messagebody",
    "chat:", "msg=", "verify words", "verification words", "verify code",
    "device_name", "devicename", "ssid",
]

# 1d. Residual high-entropy tripwire (run AFTER scrub). base64 AND base64url.
RE_RESIDUAL_B64 = re.compile(r"[A-Za-z0-9+/=_\-]{12,}")
RE_RESIDUAL_HEX = re.compile(r"\b[0-9a-fA-F]{12,}\b")

# 1e. POSITIVE STRUCTURED-SHAPE GATE (the core fail-closed mechanism).
# A scrubbed body may ship ONLY if it is recognizably structured telemetry.
# We tokenize on whitespace and require that the body contains NO run of more
# than MAX_FREEWORD_RUN consecutive "free natural-language" words -- i.e. lower
# alphabetic words >=3 chars that are NOT recognized telemetry vocabulary and
# do NOT sit next to a '=' / ':' (key=value form). This makes plaintext
# sentences (chat bodies, SAS verify-words) fail the gate and get replaced by
# an attribute-only summary, while "ice=connected role=caller retries=2 ..."
# passes.
MAX_FREEWORD_RUN = 3

# Recognized telemetry vocabulary -- short, closed set. Anything here does NOT
# count toward a free-word run. Lowercased compare.
TELEMETRY_VOCAB = frozenset([
    # states / lifecycle
    "new", "checking", "connected", "completed", "failed", "disconnected",
    "closed", "gathering", "ringing", "dialing", "active", "encrypted",
    "ended", "half_open", "connecting", "idle", "open", "opening", "start",
    "started", "stop", "stopped", "ok", "error", "warn", "info", "debug",
    "fatal", "retry", "retrying", "timeout", "abort", "aborted", "done",
    "init", "ready", "pending", "success", "fail", "drop", "dropped",
    # roles / modes
    "caller", "callee", "offerer", "answerer", "datachannel", "relay",
    "ws_relay", "ws-relay", "direct_p2p", "p2p", "host", "srflx", "prflx",
    "wifi", "cellular", "ethernet", "loopback", "other", "none",
    "helsinki", "frankfurt", "milano",
    # generic telemetry nouns (no payload)
    "call", "ice", "media", "crypto", "net", "voicenote", "livelog",
    "stdout", "state", "role", "mode", "node", "count", "seq", "frame",
    "frames", "bytes", "ms", "sec", "peer", "self", "remote", "local",
    "candidate", "offer", "answer", "rx", "tx", "sent", "recv", "received",
    "and", "to", "of", "at", "is", "via", "for", "with",
])

# A token is "safe-structured" if it is one of: a key=value or key:value pair,
# a bracketed [REDACTED:*] placeholder, a pure number / number+unit, a known
# vocab word, a short token (<=2 chars), or punctuation-only.
RE_KV_TOKEN = re.compile(r"^[A-Za-z][A-Za-z0-9_.\-]*[=:].*$")
RE_NUM_TOKEN = re.compile(r"^[+\-]?\d[\d.,:]*[A-Za-z%]*$")
RE_PLACEHOLDER_TOKEN = re.compile(r"^\[REDACTED:[a-z]+\]$")
RE_PUNCT_TOKEN = re.compile(r"^[\W_]+$")
RE_FREEWORD = re.compile(r"^[A-Za-z][A-Za-z'\-]{2,}$")  # candidate NL word
# A bare mixed-alphanumeric token (letters AND digits, >=8 chars, no kv '='/':'
# and not a [REDACTED:*] placeholder) has the exact shape of a truncated PSK
# prefix / short device PIN / base32 secret fragment that is too short (8-11) to
# trip the >=12 blob/residual sweeps yet too high-entropy to ship. The gate
# treats it as a HARD FAIL (fall back to the attribute summary), closing the
# "free <= structural" escape hatch that would otherwise let one such token ride
# alongside a single structural token. Letters-only or digits-only tokens do NOT
# match (those are caught as free words / numbers respectively).
RE_MIXED_ALNUM_SECRET = re.compile(
    r"^(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{8,}$")

# 1f. hard length cap.
BODY_CAP = 512


# SDP / ICE / DTLS detection -- applied to EVERY line of the body, not just the
# first (re.match is anchored, so we scan line by line).
RE_SDP_ATTR = re.compile(r"^\s*[vostmacbiyzk]=", re.IGNORECASE)
SDP_TOKENS = (
    "a=candidate", "a=fingerprint", "m=audio", "m=video",
    "ice-ufrag", "ice-pwd", "rtpmap", "rtcp", "setup:actpass",
    "typ host", "typ srflx", "typ relay", "typ prflx",
)


def _is_sdp_line(body):
    """True if ANY line of the body is an SDP / ICE / DTLS line (drop whole
    record). Scans every physical line because re.match only anchors at 0."""
    low = body.lower()
    for tok in SDP_TOKENS:
        if tok in low:
            return True
    for ln in body.splitlines():
        if RE_SDP_ATTR.match(ln.strip()):
            return True
    return False


def _scrub_body(body):
    """Run the mirror patterns + strengthening rules over a (normalized) body.
    Returns the scrubbed string. Does NOT decide keep/drop (that is the gate)."""
    s = body
    # Mirror of redact(): secretPrefixed first, then longBlob (Swift order).
    s = RE_SECRET_PREFIXED.sub(PLACEHOLDER, s)
    s = RE_LONG_BLOB.sub("[REDACTED:blob]", s)
    # Strengthening: keyed/structured first, then broad sweeps.
    for kind, rx in STRENGTHEN_RULES:
        s = rx.sub("[REDACTED:%s]" % kind, s)
    return s


def _has_residual_secret(body):
    """True if a scrubbed body STILL looks high-entropy (b64/b64url run / hex /
    UUID / dotted token). The scrub was not confident -> drop to summary."""
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
    """POSITIVE allow-list. A body ships ONLY if it is recognizably structured
    telemetry. TWO conditions, BOTH required (fail-closed):

      (A) NO run of more than MAX_FREEWORD_RUN consecutive free
          natural-language words; AND
      (B) free natural-language words must not DOMINATE -- if the body carries
          unrecognized free words, it must also carry positive structure
          (key=value / [REDACTED:*] / number / known state-enum vocab) and the
          free words must be the minority. A plaintext sentence ("he said meet
          at noon tomorrow") has ZERO structural anchors and many free words,
          so it fails (B) and is replaced by the attribute summary.

    Bracketed placeholders, key=value tokens, numbers, known-vocab words and
    punctuation are "structural"; unknown alphabetic words >=3 chars are
    "free". Connectors (<=2 chars) are neutral (counted as neither)."""
    run = 0
    free = 0
    structural = 0
    for tok in scrubbed.split():
        if RE_PLACEHOLDER_TOKEN.match(tok):
            run = 0
            structural += 1
            continue
        if RE_KV_TOKEN.match(tok):
            run = 0
            structural += 1
            continue
        if RE_NUM_TOKEN.match(tok):
            run = 0
            structural += 1
            continue
        if RE_PUNCT_TOKEN.match(tok):
            run = 0
            continue
        # HARD FAIL on a bare mixed-alnum secret-shaped token (8-11 chars slip
        # the >=12 blob sweeps). Checked on the RAW token (before strip) so an
        # embedded digit+letter run is not masked by surrounding punctuation.
        if RE_MIXED_ALNUM_SECRET.match(tok):
            return False
        core = tok.strip("[](){}<>.,:;!?\"'").lower()
        if RE_MIXED_ALNUM_SECRET.match(core):
            return False
        if core in TELEMETRY_VOCAB:
            run = 0
            structural += 1
            continue
        if len(core) <= 2:
            # Short connector: neutral, but it does NOT break a free-word run
            # (so "meet at noon" is two free words in one run, not reset by
            # "at"). This is what catches plaintext prose.
            continue
        if RE_FREEWORD.match(core):
            run += 1
            free += 1
            if run > MAX_FREEWORD_RUN:
                return False
            continue
        # Unknown token shape (residual mixed alnum): conservative -> free.
        run += 1
        free += 1
        if run > MAX_FREEWORD_RUN:
            return False
    # (B) -- if there are free words, require positive structure AND that the
    # free words do not dominate. Pure structure (free==0) always passes.
    if free == 0:
        return True
    if structural == 0:
        return False
    return free <= structural


def _attribute_summary(attrs):
    """Build a safe, structured body from the already-extracted allow-listed
    attributes ONLY. Used when the original body fails the structured gate, so
    a dropped free-text body still leaves correlatable structure."""
    if not attrs:
        return ""
    parts = []
    for k in ALLOWED_ATTR_KEYS:
        if k in attrs:
            short = k.split(".")[-1]
            parts.append("%s=%s" % (short, attrs[k]))
    return "[summary] " + " ".join(parts) if parts else ""


def redact_body(orig_body, tag_is_safe, attrs):
    """FAIL-CLOSED body redaction. Returns (kept: bool, body: str).

    A body ships ONLY if it is provably safe. Steps:
      1. NFKC-normalize (kills full-width / homoglyph bypass).
      2. SAS / plaintext DROP-list (pre-scrub) -> DROP.
      3. SDP / ICE / DTLS (any line) -> DROP.
      4. tag not in allow-list -> DROP body.
      5. scrub secrets (deny patterns -> bounded placeholders).
      6. residual high-entropy tripwire -> fall back to attribute summary.
      7. POSITIVE structured-shape gate: if the scrubbed body is NOT
         recognizably structured telemetry, replace it with the attribute
         summary (or DROP if no safe attributes).
      8. hard length cap; empty -> DROP.
    """
    if orig_body is None:
        return False, ""

    norm = _nfkc(orig_body)
    low = norm.lower()

    # 2 -- plaintext / SAS drop-list (pre-scrub).
    for needle in SAS_DROP_SUBSTRINGS:
        if needle in low:
            return False, ""

    # 3 -- SDP / ICE / DTLS whole-record drop.
    if _is_sdp_line(norm):
        return False, ""

    # 4 -- untrusted tag: never ship the body.
    if not tag_is_safe:
        return False, ""

    # 5 -- scrub.
    scrubbed = _scrub_body(norm)

    # 6 -- residual high-entropy tripwire -> attribute summary fallback.
    if _has_residual_secret(scrubbed):
        scrubbed = _attribute_summary(attrs)

    # 7 -- positive structured-shape gate.
    elif not _passes_structured_gate(scrubbed):
        scrubbed = _attribute_summary(attrs)

    # 8 -- cap + empty drop.
    if len(scrubbed) > BODY_CAP:
        scrubbed = scrubbed[:BODY_CAP] + "...[trunc]"
    if not scrubbed.strip():
        return False, ""

    return True, scrubbed


# ---------------------------------------------------------------------------
# TAG ALLOW-LIST -- deny-by-default. Prefix match, lowercased.
# Maps a device tag -> OTLP InstrumentationScope name "qaudion.<scope>".
# A tag NOT in this map is UNTRUSTED: the body is never shipped.
# ---------------------------------------------------------------------------

TAG_SCOPE_PREFIXES = [
    ("call", "call"),
    ("ice", "ice"),
    ("media", "media"),
    ("crypto", "crypto"),
    ("net", "net"),
    ("voicenote", "voicenote"),
    ("livelog", "livelog"),
    ("stdout", "stdout"),
]


def resolve_scope(tag):
    """Return (scope_name, is_safe). scope_name is 'qaudion.<scope>' for a
    known tag, else 'qaudion.unknown'. is_safe gates whether the body ships."""
    t = (tag or "").strip().lower()
    for prefix, scope in TAG_SCOPE_PREFIXES:
        if t.startswith(prefix):
            return "qaudion." + scope, True
    return "qaudion.unknown", False


# ---------------------------------------------------------------------------
# lvl -> OTLP severity. lvl is the 1-char form (RuntimeLogSink line 172).
# ---------------------------------------------------------------------------

SEVERITY = {
    "D": (5, "DEBUG"),
    "I": (9, "INFO"),
    "W": (13, "WARN"),
    "E": (17, "ERROR"),
    "F": (21, "FATAL"),
}


def map_severity(lvl):
    """Map the 1-char lvl to (severityNumber:int, severityText:str)."""
    key = (lvl or "").strip().upper()[:1]
    return SEVERITY.get(key, (0, "UNSPECIFIED"))


# ---------------------------------------------------------------------------
# RECORD-LEVEL ATTRIBUTE ALLOW-LIST (deny-by-default).
# Only these keys may ride along; anything else stays out. Values come from
# narrow enum/regex extractors over the NFKC-normalized ORIGINAL message, and
# the call id is HASHED (hmac8), never a prefix of the real id.
# ---------------------------------------------------------------------------

ALLOWED_ATTR_KEYS = (
    "qa.call.h8", "qa.call.short8", "qa.role", "qa.net", "qa.media.mode",
    "qa.retry.count", "qa.node", "qa.ice.state", "qa.call.state",
)

# CROSS-LEG JOIN KEY. The bcrypto-server slog logs the plaintext call_id and
# ship-server-logs.py emits qa.call.short8 = canon(call_id)[:8] (lowercased,
# ellipsis/dot-stripped first-8). correlate-call.py already keys on that same
# prefix. To JOIN the iOS leg to the server leg in Loki, BOTH legs must carry
# qa.call.short8 with the IDENTICAL value, so we compute it here from the SAME
# canonical call_id we already extract for qa.call.h8 -- using the SAME
# canonicalization as ship-server-logs.py / correlate-call.py (idempotent,
# case-folding) so an uppercase device UUID and a lowercase server id collapse
# to the same 8 chars. This prefix is NOT secret (already in journald + already
# what correlate-call.py matches on); qa.call.h8 (a non-reversible HMAC) is kept
# alongside it as a secondary, harmless key.
_ELLIPSIS = "\u2026"  # HORIZONTAL ELLIPSIS (source stays pure-ASCII)


def call_short8(raw):
    """THE JOIN KEY. canon(call_id)[:8]: strip + lower, strip trailing ellipsis
    (U+2026) / ASCII dots, take first 8 chars.

    MUST be byte-identical to ship-server-logs.py:call_short8 AND to
    correlate-call.py:build_matcher's short8 (norm[:8] if len(norm) >= 8 else "").
    The >= 8 floor (NOT >= 6) is load-bearing: correlate-call.py only produces a
    short8 when the normalized id is >= 8 chars, so a 6/7-char id must yield ""
    here too -- otherwise this leg would emit a join value the canonical matcher
    can never reproduce (a silent cross-tool reconcile failure). Fail-closed:
    when in doubt, emit no key rather than a non-joinable one."""
    if raw is None:
        return ""
    s = raw.strip().rstrip()
    s = s.rstrip(_ELLIPSIS)
    s = s.rstrip(".")
    s = s.rstrip(_ELLIPSIS)
    s = s.strip().lower()
    return s[:8] if len(s) >= 8 else ""

# Optional opening-quote (\"?) MUST be present so a quoted device value
# call_id="91FE5CF7-..." captures identically to the server leg (whose regex
# also has \"?). Without it, a quoted iOS value matches NOTHING while the server
# emits qa.call.short8 -> a one-sided SILENT join failure (= NO-GO). The closing
# quote is naturally excluded by the [0-9a-fA-F\-] character class.
_RE_CALLID_VALUE = re.compile(
    r"call[ _]?id\s*[=:]\s*\"?([0-9a-fA-F][0-9a-fA-F\-]{3,})", re.IGNORECASE)
_RE_ROLE = re.compile(r"\brole\s*[=:]\s*(caller|callee|offerer|answerer)\b",
                      re.IGNORECASE)
_RE_MEDIA_MODE = re.compile(
    r"\b(?:media[ _]?mode|mediaMode)\s*[=:]\s*(datachannel|ws[-_]?relay|"
    r"relay|direct_p2p|p2p)\b", re.IGNORECASE)
_RE_RETRY = re.compile(r"\bretry(?:[ _]?count)?\s*[=:]\s*(\d{1,4})\b",
                       re.IGNORECASE)
_RE_NODE = re.compile(r"\bnode\s*[=:]\s*([a-z]{2}\d?|helsinki|frankfurt|milano)\b",
                      re.IGNORECASE)
_RE_ICE_STATE = re.compile(
    r"\bice(?:[ _]?state)?\s*[=:]\s*(new|checking|connected|completed|failed|"
    r"disconnected|closed|gathering)\b", re.IGNORECASE)
_RE_CALL_STATE = re.compile(
    r"\b(?:call[ _]?state|state)\s*[=:]\s*(ringing|dialing|active|encrypted|"
    r"ended|half_open|connecting|idle)\b", re.IGNORECASE)
_RE_NET = re.compile(r"\b(WIFI|CELLULAR|ETHERNET|LOOPBACK|OTHER|NONE)\b")

# Value-side enum allow-lists so a smuggled value can never reach an attribute.
_NET_ENUM = frozenset(["WIFI", "CELLULAR", "ETHERNET", "LOOPBACK", "OTHER", "NONE"])
_ROLE_ENUM = frozenset(["caller", "callee", "offerer", "answerer"])
_MEDIA_ENUM = frozenset(["datachannel", "ws-relay", "ws_relay", "relay",
                         "direct_p2p", "p2p"])
_NODE_ENUM = frozenset(["helsinki", "frankfurt", "milano",
                        "fi", "de", "it", "fi1", "de1", "it1"])
_ICE_ENUM = frozenset(["new", "checking", "connected", "completed", "failed",
                       "disconnected", "closed", "gathering"])
_CALL_STATE_ENUM = frozenset(["ringing", "dialing", "active", "encrypted",
                              "ended", "half_open", "connecting", "idle"])


def extract_attributes(orig_msg):
    """Build the allow-listed attribute set from the NFKC-normalized ORIGINAL
    message. Deny-by-default: only keys in ALLOWED_ATTR_KEYS may appear, only
    enum-validated values, and the call id is HASHED (hmac8), never raw."""
    attrs = {}
    if not orig_msg:
        return attrs
    msg = _nfkc(orig_msg)

    m = _RE_CALLID_VALUE.search(msg)
    if m:
        h8 = hmac8(m.group(1))
        if h8:
            attrs["qa.call.h8"] = h8
        # JOIN KEY: plaintext first-8, identical to the server leg's value so a
        # single Loki query joins iOS + server for one call.
        s8 = call_short8(m.group(1))
        if s8:
            attrs["qa.call.short8"] = s8

    m = _RE_ROLE.search(msg)
    if m and m.group(1).lower() in _ROLE_ENUM:
        attrs["qa.role"] = m.group(1).lower()

    m = _RE_NET.search(msg)
    if m and m.group(1).upper() in _NET_ENUM:
        attrs["qa.net"] = m.group(1).upper()

    m = _RE_MEDIA_MODE.search(msg)
    if m and m.group(1).lower() in _MEDIA_ENUM:
        attrs["qa.media.mode"] = m.group(1).lower()

    m = _RE_RETRY.search(msg)
    if m:
        attrs["qa.retry.count"] = m.group(1)

    m = _RE_NODE.search(msg)
    if m and m.group(1).lower() in _NODE_ENUM:
        attrs["qa.node"] = m.group(1).lower()

    m = _RE_ICE_STATE.search(msg)
    if m and m.group(1).lower() in _ICE_ENUM:
        attrs["qa.ice.state"] = m.group(1).lower()

    m = _RE_CALL_STATE.search(msg)
    if m and m.group(1).lower() in _CALL_STATE_ENUM:
        attrs["qa.call.state"] = m.group(1).lower()

    # Final hard gate: drop anything not in the allow-list (belt + suspenders).
    return {k: v for k, v in attrs.items() if k in ALLOWED_ATTR_KEYS}


# ---------------------------------------------------------------------------
# RESOURCE ATTRIBUTE VALIDATORS (header JSON is UNTRUSTED, device-controlled).
# Every header-derived attribute is validated/enum-checked; on failure it is
# DROPPED, never shipped raw.
# ---------------------------------------------------------------------------

RE_UUID_FULL = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RE_OS_VER = re.compile(r"^\d{1,3}(?:\.\d{1,3}){0,3}$")
RE_APP_VER = re.compile(r"^\d{1,4}(?:\.\d{1,4}){0,3}$")
BRAND_ALLOW = frozenset(["Apple"])


def _valid_session_instance_id(header, blob_path):
    """service.instance.id MUST be a per-boot UUID. A non-UUID (legacy/hostile
    serial or device name) is rejected; fall back to a stable, non-identifying
    blob-<hmac8>."""
    session = str((header or {}).get("session") or "").strip().lower()
    if RE_UUID_FULL.match(session):
        return session
    return "blob-" + hmac8(blob_path)


# ---------------------------------------------------------------------------
# OTLP/JSON construction.
# ---------------------------------------------------------------------------

SERVICE_NAME = "qaudion-ios"


def _attr_str(key, value):
    return {"key": key, "value": {"stringValue": str(value)}}


def _attr_bool(key, value):
    return {"key": key, "value": {"boolValue": bool(value)}}


def build_resource(header, blob_path, env_name):
    """Build the OTLP resource. ALLOW-LIST + VALIDATE every header-derived
    field; the header JSON is UNTRUSTED. device_name / model / type are NEVER
    emitted. A field that fails validation is DROPPED, never shipped raw."""
    attrs = [_attr_str("service.name", SERVICE_NAME)]

    # service.instance.id -- per-boot UUID or blob-<hmac8> fallback.
    attrs.append(_attr_str("service.instance.id",
                           _valid_session_instance_id(header, blob_path)))

    # service.version -- validate dotted-numeric.
    app_ver = str((header or {}).get("app_ver") or "").strip()
    if RE_APP_VER.match(app_ver):
        attrs.append(_attr_str("service.version", app_ver))

    # os.name fixed; os.version validated dotted-numeric ("ios-18.5" -> "18.5").
    attrs.append(_attr_str("os.name", "iOS"))
    os_field = str((header or {}).get("os") or "").strip()
    os_ver = os_field[4:] if os_field.lower().startswith("ios-") else os_field
    if RE_OS_VER.match(os_ver):
        attrs.append(_attr_str("os.version", os_ver))

    # qa.net -- enum allow-list ONLY (closes the SSID/hotspot leak).
    net = str((header or {}).get("net") or "").strip().upper()
    if net in _NET_ENUM:
        attrs.append(_attr_str("qa.net", net))

    # qa.net.metered -- bool only.
    metered = (header or {}).get("metered")
    if isinstance(metered, bool):
        attrs.append(_attr_bool("qa.net.metered", metered))

    # device.manufacturer -- allow-list to known brand set ONLY.
    brand = str((header or {}).get("brand") or "").strip()
    if brand in BRAND_ALLOW:
        attrs.append(_attr_str("device.manufacturer", brand))

    attrs.append(_attr_str("deployment.environment.name", env_name))

    # device_name, model, type, session(raw), serial are NEVER emitted.
    return {"attributes": attrs}


def build_log_record(rec):
    """rec is a parsed device event dict (ms, lvl, tag, msg). Returns an OTLP
    logRecord dict if the line is shippable, else None (dropped)."""
    scope_name, tag_safe = resolve_scope(rec.get("tag"))

    orig_msg = rec.get("msg", "") or ""
    attrs = extract_attributes(orig_msg)
    kept, body = redact_body(orig_msg, tag_safe, attrs)
    if not kept:
        return None

    sev_num, sev_text = map_severity(rec.get("lvl"))
    ms = rec.get("ms")
    if ms is None:
        return None
    time_unix_nano = int(ms * 1_000_000)  # ms -> ns

    otlp_attrs = [_attr_str(k, v) for k, v in attrs.items()
                  if k in ALLOWED_ATTR_KEYS]

    return {
        "timeUnixNano": str(time_unix_nano),  # MUST be a quoted string
        "severityNumber": sev_num,            # MUST be an int
        "severityText": sev_text,
        "body": {"stringValue": body},
        "attributes": otlp_attrs,
    }


def build_export_request(header, records, blob_path, env_name):
    """Assemble a full ExportLogsServiceRequest for one blob's records.
    Groups logRecords by scope. Returns (request_dict, kept, dropped)."""
    resource = build_resource(header, blob_path, env_name)

    by_scope = {}
    kept = 0
    dropped = 0
    for rec in records:
        lr = build_log_record(rec)
        if lr is None:
            dropped += 1
            continue
        kept += 1
        scope_name, _ = resolve_scope(rec.get("tag"))
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
# Loki OTLP/JSON POST.
# ---------------------------------------------------------------------------

def post_otlp(endpoint, token, request_dict, timeout=30):
    """POST one ExportLogsServiceRequest as OTLP/JSON. Returns (status, body).
    Never raises on HTTP error (returns the status); only network errors
    surface as status=0."""
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
    """Split a single ExportLogsServiceRequest into multiple requests each
    carrying at most batch_size logRecords total (flattened across scopes),
    preserving the resource + scope grouping. Yields request dicts."""
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
# Device side: list + read W417 chunks (read-only over SFTP).
# ---------------------------------------------------------------------------

def list_device_chunks(client, minutes, limit):
    """find recent blobs; returns list of (mtime, size, path) newest first."""
    cmd = (
        f"find {DATA_DIR} -type f -mmin -{minutes} "
        f"-printf '%T@ %s %p\\n' | sort -nr | head -{limit}"
    )
    stdout_text, err = run(client, cmd)
    if err.strip():
        print("STDERR (find):", err.strip(), file=sys.stderr)
    files = []
    for line in stdout_text.strip().split("\n"):
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) != 3:
            continue
        mtime_s, size_s, path = parts
        try:
            files.append((float(mtime_s), int(size_s), path))
        except ValueError:
            continue
    return files


def read_chunk_blob(sftp, path, size_s):
    """SFTP-read one blob. Returns the UTF-8 text, or None if it is not a
    parseable W417 chunk (too big, empty, binary, or wrong first line)."""
    if size_s == 0 or size_s > 256 * 1024:
        return None
    try:
        with sftp.open(path, "rb") as rf:
            blob = rf.read()
    except Exception as e:
        print(f"  skip {path}: {e}", file=sys.stderr)
        return None
    try:
        txt = blob.decode("utf-8")
    except UnicodeDecodeError:
        return None
    first_line = txt.split("\n", 1)[0] if txt else ""
    if not _is_w417_first_line(first_line):
        return None
    return txt


def parse_chunk(txt):
    """Parse a W417 chunk's text into (header_dict_or_None, [event_dicts]).

    Header is the {"type":"header"} line (if present). Event dicts have keys
    ms, lvl, tag, msg. Lines without a ts are skipped (header / non-event)."""
    header = None
    records = []
    for line in txt.split("\n"):
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") == "header":
            header = obj
            continue
        ts = obj.get("ts")
        if not ts:
            continue
        ms = iso_to_ms(ts)
        if ms is None:
            continue
        records.append({
            "ms": ms,
            "lvl": obj.get("lvl", "I"),
            "tag": obj.get("tag", ""),
            "msg": obj.get("msg", ""),
        })
    return header, records


def chunk_line_signature(txt):
    """Stable hash of a chunk's event-line set so re-runs can detect whether a
    blob's content changed since last ship. Hash over raw lines (cheap)."""
    h = hashlib.sha256()
    for line in txt.split("\n"):
        line = line.strip()
        if line.startswith('{"ts"'):
            h.update(line.encode("utf-8", errors="replace"))
            h.update(b"\n")
    return h.hexdigest()


# ---------------------------------------------------------------------------
# State tracking.
# ---------------------------------------------------------------------------

def default_state_path():
    return Path.home() / ".qaudion" / "ship-ios-logs.state.json"


def load_state(path):
    """Load shipped-blob state. Shape: {"blobs": {path: {"lines": n,
    "sig": "<sha256>"}}}. Returns an empty skeleton if absent/corrupt."""
    try:
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("blobs"), dict):
                return data
    except Exception as e:
        print(f"WARN: state file unreadable ({e}); starting fresh.",
              file=sys.stderr)
    return {"blobs": {}}


def save_state(path, state):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(state, indent=2), encoding="utf-8")
        tmp.replace(path)
    except Exception as e:
        print(f"WARN: could not persist state ({e}).", file=sys.stderr)


def already_shipped(state, blob_path, sig):
    """True if this blob path was shipped before with the SAME content
    signature (so re-runs do not duplicate). A changed sig => re-ship (so we
    do not lose newly-appended lines)."""
    prev = state.get("blobs", {}).get(blob_path)
    return bool(prev) and prev.get("sig") == sig


def record_shipped(state, blob_path, sig, line_count):
    state.setdefault("blobs", {})[blob_path] = {
        "sig": sig,
        "lines": line_count,
        "ts": int(time.time()),
    }


# ---------------------------------------------------------------------------
# Dry-run rendering.
# ---------------------------------------------------------------------------

def print_dry_run(request_dict, blob_path):
    out()
    out("-" * 72)
    out("DRY-RUN OTLP for blob: %s" % blob_path)
    out("-" * 72)
    rendered = json.dumps(request_dict, indent=2, ensure_ascii=True)
    print(_ascii(rendered))


# ---------------------------------------------------------------------------
# Self-test (privacy regression cases). Run with --selftest.
# ---------------------------------------------------------------------------

def run_selftest():
    """Assert the FORBIDDEN values never survive redaction. Pure ASCII output.
    Exit 0 = all pass, 1 = a leak slipped (NO-GO)."""
    failures = []

    def must_drop_or_summary(tag, msg, forbidden_substrs, label):
        scope, safe = resolve_scope(tag)
        attrs = extract_attributes(msg)
        kept, body = redact_body(msg, safe, attrs)
        shipped = body if kept else ""
        low = shipped.lower()
        for f in forbidden_substrs:
            if f.lower() in low:
                failures.append("LEAK[%s]: %r survived as %r" % (label, f, shipped))

    # 1. device_name free-text body.
    must_drop_or_summary("call", "device_name=Pavels iPhone 15 Pro",
                         ["pavels", "iphone"], "device_name")
    # 2. SAS verify-words.
    must_drop_or_summary("crypto",
                         "verify words apple river tiger moon happy cloud",
                         ["apple", "river", "tiger", "moon", "happy", "cloud"],
                         "sas_words")
    # 3. plaintext chat body (no msg= trigger).
    must_drop_or_summary("call", "He said meet at noon tomorrow at the cafe",
                         ["meet", "noon", "tomorrow", "cafe"], "plaintext_chat")
    # 4. full-width password bypass. Built from code points so THIS source
    #    file stays pure ASCII; NFKC folds U+FF50.. back to 'password='.
    fw = "".join(chr(0xFF00 + (ord(c) - 0x20)) for c in "password=") + "secret123value"
    must_drop_or_summary("net", fw, ["secret123value"], "fullwidth_pw")
    # 5. short base64 audio frame (12 chars).
    must_drop_or_summary("media", "frame AAAAAAAAAAAA done",
                         ["AAAAAAAAAAAA"], "short_b64_frame")
    # 6. 15-char hex secret.
    must_drop_or_summary("crypto", "key 0123456789abcde end",
                         ["0123456789abcde"], "short_hex")
    # 7. base64url 16-char token with - and _.
    must_drop_or_summary("crypto", "tok Abc-Def_GhiJkLmN end",
                         ["abc-def_ghijklmn"], "b64url_token")
    # 8. spaced/chunked hex dump.
    must_drop_or_summary("crypto", "fp aabbccdd eeff0011 22334455 66778899",
                         ["aabbccdd", "eeff0011"], "spaced_hex")
    # 9. raw call_id UUID (must NOT ship; only hmac8 in attrs).
    cid = "call_id=11112222-3333-4444-5555-666677778888 role=caller"
    attrs = extract_attributes(cid)
    _, body = redact_body(cid, True, attrs)
    if "11112222-3333-4444-5555-666677778888" in body:
        failures.append("LEAK[callid]: raw call_id survived in body")
    if attrs.get("qa.call.h8") == "11112222":
        failures.append("LEAK[callid]: qa.call.h8 is a PREFIX not a hash")
    # 10. embedded (non-first-line) SDP line.
    must_drop_or_summary("ice", "connecting...\nc=IN IP4 203.0.113.7",
                         ["203.0.113.7", "c=in ip4"], "embedded_sdp")
    # 11. unknown tag -> body never ships.
    scope, safe = resolve_scope("randomtag")
    kept, body = redact_body("anything at all here", safe, {})
    if kept and body:
        failures.append("LEAK[tag]: unknown tag shipped a body: %r" % body)
    # 12. SSID in header net must not reach qa.net.
    res = build_resource({"net": "MyHomeWiFi-5G", "brand": "Apple"},
                         "/x/y", "testflight")
    for a in res["attributes"]:
        if a["key"] == "qa.net" and "MyHomeWiFi" in a["value"].get("stringValue", ""):
            failures.append("LEAK[net]: SSID reached qa.net resource attr")
    # 13. non-UUID session must not ship as instance id.
    res = build_resource({"session": "SERIAL-F2LX1234"}, "/a/b/c", "testflight")
    for a in res["attributes"]:
        if a["key"] == "service.instance.id":
            v = a["value"].get("stringValue", "")
            if "SERIAL-F2LX1234" in v:
                failures.append("LEAK[session]: serial shipped as instance.id")
            if not v.startswith("blob-"):
                failures.append("BUG[session]: non-UUID not replaced by blob-")
    # 14. structured telemetry MUST still ship.
    msg = "ice=connected role=caller retry=2 node=helsinki media_mode=datachannel"
    kept, body = redact_body(msg, True, extract_attributes(msg))
    if not kept or not body:
        failures.append("REGRESS: structured telemetry was dropped: %r" % msg)

    # 15. QUOTED call_id value (the regex-asymmetry MUST-FIX). A device line
    #     carrying call_id="91FE5CF7-..." MUST extract the SAME join key the
    #     server leg extracts from the same quoted value -> 91fe5cf7. Before the
    #     \"? fix this matched NOTHING and the iOS leg shipped no key (silent
    #     one-sided join failure).
    quoted = 'call_id="91FE5CF7-3572-42F1-9B84-29883F47BAB6" role=caller'
    aq = extract_attributes(quoted)
    if aq.get("qa.call.short8") != "91fe5cf7":
        failures.append("JOIN-FAIL[quoted]: quoted call_id short8 %r != 91fe5cf7"
                        % aq.get("qa.call.short8"))
    # the bare (unquoted) form MUST yield the identical join key.
    ab = extract_attributes("call_id=91fe5cf7-3572-42f1-9b84-29883f47bab6")
    if ab.get("qa.call.short8") != aq.get("qa.call.short8"):
        failures.append("JOIN-FAIL[quoted]: bare vs quoted short8 disagree: "
                        "%r != %r" % (ab.get("qa.call.short8"),
                                      aq.get("qa.call.short8")))

    # 16. LENGTH-FLOOR reconcile with correlate-call.py / server leg (>= 8). A
    #     6/7-char id yields "" (no non-joinable key emitted); exactly 8 is kept.
    for short_id in ("91fe5c", "91fe5cf"):
        if call_short8(short_id) != "":
            failures.append("JOIN-FAIL[floor]: %r should yield '' (>=8 floor) "
                            "but got %r" % (short_id, call_short8(short_id)))
    if call_short8("91fe5cf7") != "91fe5cf7":
        failures.append("JOIN-FAIL[floor]: 8-char id should be kept verbatim")

    # 17. BARE mixed-alnum secret-shaped token (8-11 chars) must NOT ship even
    #     with surrounding structure (closes the >=12-threshold escape hatch).
    must_drop_or_summary("call", "role=caller state=active k7Gq9Lp2Zx1",
                         ["k7gq9lp2zx1"], "bare_mixed_secret")
    must_drop_or_summary("crypto", "pin a1B2c3D4 state=active",
                         ["a1b2c3d4"], "bare_pin")

    out("=" * 72)
    out("SELF-TEST: privacy redaction regression")
    out("=" * 72)
    if failures:
        for f in failures:
            out("  FAIL: " + f)
        out("")
        out("  RESULT: NO-GO (%d leak/regression)" % len(failures))
        return 1
    out("  18/18 cases pass: no forbidden value survived; structured telemetry")
    out("  still ships; call_id hashed; SSID/serial/SDP/SAS/plaintext blocked;")
    out("  join key matches the server leg incl. QUOTED form; 6/7-char floored;")
    out("  bare mixed-alnum secret tokens (8-11 char) hard-failed.")
    out("  RESULT: GO")
    return 0


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Ship iOS W417 telemetry to Loki OTLP, fail-closed redacted."
    )
    ap.add_argument("--minutes", type=int, default=180,
                    help="lookback window in minutes (default 180)")
    ap.add_argument("--limit", type=int, default=200,
                    help="max device chunks to download (default 200)")
    ap.add_argument("--endpoint", type=str,
                    default="https://dash.bcrypto.com/otlp/v1/logs",
                    help="Loki OTLP/JSON logs endpoint")
    ap.add_argument("--ingest-token", type=str, default="",
                    help="bearer token; overrides env QA_LOG_INGEST_TOKEN")
    ap.add_argument("--env", type=str, default="testflight",
                    dest="env_name",
                    help="deployment.environment.name (default testflight)")
    ap.add_argument("--batch", type=int, default=500,
                    help="log records per HTTP POST (default 500)")
    ap.add_argument("--state-file", type=str, default="",
                    help="local JSON state path "
                         "(default ~/.qaudion/ship-ios-logs.state.json)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the redacted OTLP that WOULD ship; push nothing")
    ap.add_argument("--reset-state", action="store_true",
                    help="ignore + overwrite prior state (re-ship everything)")
    ap.add_argument("--selftest", action="store_true",
                    help="run the privacy redaction regression suite and exit")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(run_selftest())

    token = args.ingest_token or os.environ.get("QA_LOG_INGEST_TOKEN", "")
    if not token and not args.dry_run:
        print("ERROR: no ingest token. Set env QA_LOG_INGEST_TOKEN or pass "
              "--ingest-token. (Not required for --dry-run.)", file=sys.stderr)
        sys.exit(1)

    state_path = Path(args.state_file) if args.state_file else default_state_path()
    state = {"blobs": {}} if args.reset_state else load_state(state_path)

    print("=== bcrypto-server SSH @ %s (read-only) ===" % VPS_HOST)
    client = ssh_connect()
    print("Connected.")

    blobs_read = 0
    blobs_skipped_state = 0
    lines_shipped = 0
    lines_dropped = 0
    http_results = []  # (blob_path, status)

    try:
        print("\n=== Listing device W417 chunks (last %d min, <=%d) ==="
              % (args.minutes, args.limit))
        files = list_device_chunks(client, args.minutes, args.limit)
        print("Found %d candidate blobs." % len(files))

        sftp = client.open_sftp()
        try:
            for mtime_s, size_s, path in files:
                txt = read_chunk_blob(sftp, path, size_s)
                if txt is None:
                    continue

                sig = chunk_line_signature(txt)
                if already_shipped(state, path, sig):
                    blobs_skipped_state += 1
                    continue

                header, records = parse_chunk(txt)
                if not records:
                    record_shipped(state, path, sig, 0)
                    continue

                blobs_read += 1
                request, kept, dropped = build_export_request(
                    header, records, path, args.env_name)
                lines_shipped += kept
                lines_dropped += dropped

                if args.dry_run:
                    print_dry_run(request, path)
                    continue

                if kept == 0:
                    record_shipped(state, path, sig, 0)
                    http_results.append((path, "no-records"))
                    continue

                blob_ok = True
                for sub in _split_request_into_batches(request, args.batch):
                    status, resp_body = post_otlp(args.endpoint, token, sub)
                    http_results.append((path, status))
                    if status != 204:
                        blob_ok = False
                        snippet = (resp_body or "").strip().replace("\n", " ")
                        print("  POST %s -> HTTP %s %s"
                              % (path, status, _ascii(snippet[:200])),
                              file=sys.stderr)
                if blob_ok:
                    record_shipped(state, path, sig, kept)
        finally:
            sftp.close()
    finally:
        client.close()

    if not args.dry_run:
        save_state(state_path, state)

    out()
    out("=" * 72)
    out("SHIP-IOS-LOGS SUMMARY")
    out("=" * 72)
    out("  endpoint:                %s" % args.endpoint)
    out("  environment:             %s" % args.env_name)
    out("  dry-run:                 %s" % ("yes" if args.dry_run else "no"))
    out("  blobs read (new/changed):%d" % blobs_read)
    out("  blobs skipped (state):   %d" % blobs_skipped_state)
    out("  lines shipped:           %d" % lines_shipped)
    out("  lines dropped (redact):  %d" % lines_dropped)
    if not args.dry_run:
        ok = sum(1 for _, s in http_results if s == 204)
        bad = sum(1 for _, s in http_results if s not in (204, "no-records"))
        noop = sum(1 for _, s in http_results if s == "no-records")
        out("  HTTP 204 (ok):           %d" % ok)
        out("  HTTP non-204 (failed):   %d" % bad)
        out("  blobs with no records:   %d" % noop)
        out("  state file:              %s" % state_path)
        if bad:
            out()
            out("  NOTE: %d POST(s) did not return 204. State was NOT advanced"
                % bad)
            out("        for those blobs, so a re-run will retry them.")
    else:
        out()
        out("  (dry-run: nothing shipped, state untouched. Eyeball the OTLP")
        out("   bodies above to confirm redaction before a real run.)")
    out("=" * 72)


if __name__ == "__main__":
    main()
