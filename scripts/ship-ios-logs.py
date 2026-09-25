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
every body. [Note, v1.0.1180: the redactors moved to LogRedactor.swift and the shipper is now
LiveLogWorker.swift; the RuntimeLogSink line numbers below are those of the older layout.]
The on-device redaction is INCOMPLETE: RuntimeLogSink.redact()
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
TURN creds, audio / base64 media, SSID / network names, raw key bytes printed
as decimal/hex byte lists (derived_key [1,2,3,...,32] len 32).

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
  --local-dir DIR  Read blobs from a LOCAL directory (the nightly mirror
                   /opt/bcrypto/fullbackup/staging/files) instead of SSH/SFTP.
                   No VPS credentials; read-only; the mirror is up to ~24h
                   stale, so pair it with a large --minutes/--limit for a
                   catch-up (per-blob state dedups; blob paths are mapped to
                   the canonical /opt/bcrypto/data/files/<id> so state is
                   shared with the SSH mode).

  QAUDION_VPS_IOS_KEY=/path/key   (env) RESTRICTED-EXEC mode: connect with that
                   dedicated key (host/user from QAUDION_VPS_HOST/USER) whose
                   forced command on the VPS is qaudion-shipper-ios-ro.sh. The
                   VPS then answers ONLY `ios-list <minutes> <limit>` and
                   `ios-cat <uuid>`: no SFTP, no shell, no password. Used by the
                   Helsinki */5 cron; --local-dir and the password path are
                   untouched.

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

    Same precedence + same regexes as fetch-ios-live.py: env first, then the
    sibling bcrypto-server/VPS_ACCESS.md (values may be wrapped in markdown
    backticks).
    """
    host = os.environ.get("QAUDION_VPS_HOST")
    user = os.environ.get("QAUDION_VPS_USER")
    password = os.environ.get("QAUDION_VPS_PASS")
    # W-VPSKEYAUTH (2026-09-02): the prod VPS accepts publickey only since
    # the post-migration hardening (password auth disabled) — host+user are
    # enough when a key is available (see _vps_key_path); password stays an
    # optional fallback for any box that still allows it.
    if host and user and (password or _vps_key_path() or _ios_ro_key_path()):
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
            if h and u and pw:
                return h.group(1), u.group(1), pw.group(1)

    print("ERROR: VPS credentials not found.", file=sys.stderr)
    print("Set env vars QAUDION_VPS_HOST / QAUDION_VPS_USER / QAUDION_VPS_PASS", file=sys.stderr)
    print("or place VPS_ACCESS.md in the bcrypto-server sibling repo.", file=sys.stderr)
    sys.exit(1)


VPS_HOST = None
VPS_USER = None
VPS_PASS = None
DATA_DIR = "/opt/bcrypto/data/files"


def _ensure_creds():
    """Lazy-load VPS creds so --selftest / --dry-run-less paths never need the
    VPS / VPS_ACCESS.md. Only ssh_connect (the prod blob pull) triggers it."""
    global VPS_HOST, VPS_USER, VPS_PASS
    if VPS_HOST is None:
        VPS_HOST, VPS_USER, VPS_PASS = _load_vps_creds()


def _vps_key_path():
    """Private key for the prod VPS: env QAUDION_VPS_KEY / VPS_SSH_KEY, else
    the dev-box default the other prod tools (phone-debug, deploy.py) use.
    Returns None when no readable key exists so callers can fall back."""
    for cand in (os.environ.get("QAUDION_VPS_KEY"), os.environ.get("VPS_SSH_KEY"),
                 str(Path.home() / ".claude" / "bin" / "bcrypto_vps_ed25519")):
        if cand:
            p = Path(os.path.expanduser(cand))
            if p.is_file():
                return str(p)
    return None


def _ios_ro_key_path():
    """RESTRICTED-EXEC mode switch: env QAUDION_VPS_IOS_KEY names the dedicated
    key whose forced command on the VPS is qaudion-shipper-ios-ro.sh. Unset ->
    None (normal modes). Set but unreadable -> exit 1: never silently fall back
    to the password / general key."""
    p = os.environ.get("QAUDION_VPS_IOS_KEY", "").strip()
    if not p:
        return None
    q = Path(os.path.expanduser(p))
    if not q.is_file():
        print("ERROR: QAUDION_VPS_IOS_KEY names a missing file: %s" % p,
              file=sys.stderr)
        sys.exit(1)
    return str(q)


def ssh_connect():
    _ensure_creds()
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ro_key = _ios_ro_key_path()
    if ro_key:
        client.connect(VPS_HOST, username=VPS_USER, key_filename=ro_key,
                       look_for_keys=False, allow_agent=False, timeout=15)
        return client
    # W-VPSKEYAUTH (2026-09-02): key first (the prod VPS is publickey-only
    # after the migration hardening — password auth returned
    # "Bad authentication type; allowed types: ['publickey']"), password only
    # as a fallback when no key is present.
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
    r"ice[-_]?ufrag|passwd|ssid|key|nonce|iv|tag|"
    # W-KVPRECISION 2026-09-21: short secret-named keys (a 6-digit pin= / otp=
    # is only 10 chars, below every blob threshold, so it used to ship).
    r"pin|otp|passcode|passphrase|pwd|ufrag)\b\s*[=:]\s*\S+")
RE_MAC = re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b")
RE_IPV6 = re.compile(r"\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b")
# compressed IPv6 (contains '::'): 2001:db8::1, fe80::1, ::1, 2001:db8:: -- the
# full-form rule above cannot match these (W-KVPRECISION hardening 2026-09-21).
RE_IPV6_COMPRESSED = re.compile(
    r"(?<![\w:])(?:"
    r"(?:[0-9a-fA-F]{1,4}:){1,7}:(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){0,6})?"
    r"|::[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){0,6})(?![\w:])")
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
    ("ipv6", RE_IPV6_COMPRESSED),
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

# 1c-bis. KEY-BYTES FAIL-CLOSED DROP (W-KEYBYTES 2026-09-21). Native crypto code
# linked into the app prints RAW key material to stdout as a decimal byte list,
# e.g. "derived_key [1,2,3,4,...,32,] len 32" or "(x.cc:1): secret [..,]
# len 32". The shape gate below is NOT a guarantee for such a line: a comma-joined
# number list is just ONE unknown token, so a line with enough key=value
# neighbours ("... state=active ice=connected") ships with the raw bytes intact,
# and "derived_key" escapes RE_SECRET_KV (\bkey\b does not fire after '_').
# Therefore the WHOLE line is DROPPED (any tag), matched on the NFKC-folded
# lowercased ORIGINAL body BEFORE any scrub, on any of:
#   - the words derived key (derived_key / derived-key / "derived key")
#   - a list of >= 8 small decimal numbers joined by ',' or ';' (an optional
#     trailing separator is allowed: the real lines end "...,]"), bare or inside
#     [..] (..) {..} <..>; inside brackets whitespace also separates
#   - a run of >= 8 two-hex-digit bytes ("11 22 33 44 ..", "0x11,0x22,..")
# Fail-closed on purpose: a legit telemetry line with a very long number list
# is dropped too; that costs a log line, never a key.
#
# W-KEYWORDS 2026-09-24 (red-team finding 3): the numeric-list rules alone were
# not enough. The same native trace also prints "secret [WORD:WORD] len 32 slat
# << [] len 0" (8 real lines / 14 days, tag stdout): the bracket held words, not
# numbers, so _has_key_bytes() said False and the line shipped (`slat [..]` /
# `salt [..]` / `raw_key [..]` with any content shipped VERBATIM when the line
# had a few key=value neighbours). The redactor must not depend on WHAT is
# printed after a key-material word, so the WHOLE line is now also dropped on
#   - the words derived key / raw key (derived_key, raw-key, "raw key", rawkey),
#   - the words secret / slat / salt (and any word ending in key / keys:
#     session_key, root_key ...) followed, within a few non-word characters, by
#     an opening bracket [ ( { <  (whatever the group contains, even empty),
#   - a run of >= 6 indexed key=value tokens sharing one stem (k0=17 k1=203 ...:
#     a key printed one byte per kv pair is not a "list" for the rules above).
KEYBYTES_MIN_RUN = 8
_KB_N = KEYBYTES_MIN_RUN - 1
RE_KEY_WORDS = re.compile(r"(?:derived|raw)[\s_\-]*key")
RE_SECRET_GROUP = re.compile(r"(?:secret|slat|salt|\w*keys?)\W{0,8}[\[({<]")
RE_INDEXED_KV = re.compile(r"(?<![a-z0-9_.\-])([a-z][a-z_.\-]{0,23}?)\d{1,3}[=:]")
INDEXED_KV_MAX = 5      # 6+ same-stem indexed kv tokens in one body -> DROP
RE_DEC_BYTE_LIST_BARE = re.compile(
    r"(?<![\w.])\d{1,3}(?:\s*[,;]\s*\d{1,3}){%d,}(?:\s*[,;])?(?![\w.])" % _KB_N)
RE_DEC_BYTE_LIST_BRACKETED = re.compile(
    r"[\[({<]\s*\d{1,3}(?:[\s,;]+\d{1,3}){%d,}[\s,;]*[\])}>]" % _KB_N)
RE_HEX_BYTE_RUN = re.compile(
    r"(?<![0-9a-f])(?:0x)?[0-9a-f]{2}(?:[\s,;:\-]+(?:0x)?[0-9a-f]{2}){%d,}"
    r"(?![0-9a-f])" % _KB_N)


def _has_indexed_kv_run(low):
    """True if 6+ key=value tokens of one body share the same alphabetic stem
    and end in an index (k0=.. k1=.. k2=..): raw bytes printed one per pair."""
    counts = {}
    for m in RE_INDEXED_KV.finditer(low):
        stem = m.group(1)
        counts[stem] = counts.get(stem, 0) + 1
        if counts[stem] > INDEXED_KV_MAX:
            return True
    return False


def _has_key_bytes(low):
    """True if the (NFKC-folded, lowercased) body looks like printed key bytes
    or names key material (derived/raw key, secret/slat/salt + a bracket
    group). See the 1c-bis block above."""
    return bool(RE_KEY_WORDS.search(low)
                or RE_SECRET_GROUP.search(low)
                or RE_DEC_BYTE_LIST_BARE.search(low)
                or RE_DEC_BYTE_LIST_BRACKETED.search(low)
                or RE_HEX_BYTE_RUN.search(low)
                or _has_indexed_kv_run(low))

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

# ---------------------------------------------------------------------------
# 1e-bis. FREE-WORD PLAUSIBILITY (W-FREEWORD 2026-09-24, red-team finding 1).
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
# taken from the app sources and confirmed on the 14-day corpus, so the lines
# that ship readable today keep shipping unchanged.
# ---------------------------------------------------------------------------
MAX_UNKNOWN_WORDS = 2     # per body: words that are neither TELEMETRY_VOCAB nor APP_VOCAB
UNKNOWN_MAX_LEN = 9       # an unknown word longer than this is not a plausible word
MAX_IDLIKE_TOKENS = 2     # per body: hex id prefixes (4-8 hex) + numbers of 6+ digits
MAX_NUM_RUN = 3           # consecutive bare number tokens

APP_VOCAB = frozenset("""
    answerguard arm cancelpush cfg drained drops endguard er ev ff ghost ignore missed nocall over refuse rxago since stale wedge wedgesw wsec
    abs accept accepted activated activation active add aead aec aes agc age
    allocation already android annullato answer answered apns appeared
    appstate aprof apt armed arrival as atomic audio audiobeacon audioio
    audionack audiosrtp audiovp aunit available average background base
    bcrypto bcryptorest bcryptows beta binding bitrates ble block boot bound
    bps bridge buf bw bw-cap bwe bypassed callconnect callctrl callee caller
    callkit callservice calltiming camera cancelled capture cbor cc cd
    cellular changed changing channel check client closed code com complete
    component compression conf config conn connecting connection connessione
    control controller cores corrected cos cpu crc create created cum dash
    db dc dchangup dcmux decode decoded deferred delta destroyed di diag
    dialandcall dispatch dp drain dtls dtx dup duplicate dupoffer during
    echo ef empty enabled encoded encrypted endcall ended eng entry epoch
    exchange extension fail failure false features fec feed fetch fetched
    fir fire flags flush forced fps frameheight framewidth gain gate gcm gen
    giveup grp handshake handshakeready hangup hangupecho hasv4session hb hd
    headroom hf high hkdf hmac host http https icegate id idle idr idrfrc
    idx if in inactive inbound index ing initiator inp install integration
    intr ipv6 isincall islocked iterations jitter json kbps kcmac kdf kem
    key keys kfr kind kms knew la learning len level lookup loss lost low lv
    max maxbps mediadead mesh message metrickit mic mid min mis missedevt
    mobile moderate msg mtu nack nalu nat negative negotiated negotiatedv4
    net netchange network nil no nocontrol noctl noinput noise noop not ns
    null nullptr number off offer offline offset ok old on online opaquehang
    options opus origin out outbox outp outstanding ov overlay ownercont p2p
    packet pad parameters patch paused payload pcm pcma pcmu persa piggy-
    back ping pinned pipeline placeholder playout plc pli plp plpfeedback
    ply poll pong port post pqc pre prebootstrap predictor pref present
    prflx priorsent processing profile prx psk pt ptr ptt ptx pu qp queued
    rb re reality reason rec receipt receipts receive receiveonly receiving
    recv redacted reduction relay render renderer report requested reset
    resolution resolved responder result retained richiesta ringing rollback
    route routing rows rsn rst rtcp rtp rtt run rw rxdc rxpre sample
    satisfied scaduto scorex sctp sdp selfver send sender sequence server
    session set setactive settings sfu sha signaling sigsend skip skipped
    source spk spkchg sr srflx srtcp srtp srtpkeyfwd ssrc st stable stata
    stats stun suppressed swap target tcp terminate tf tg thresholds time
    timestamp tls tofupin took total totalfail track transport trig true
    turn txdc txfall type udp un unc uncertain undec unknown unseal
    untracked updating upgrade upload upok us user usev4 uvk va vad vbind
    vbwcap vbwcaprx vcap verified version vidcap video voice voiced voip vol
    vpio vpn vpostneg vspostneg w-callawake wait watchdog wdstart wdstop
    webrtc why wifi wire writable ws wss wsunavailable x xw yet
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


# 1f. hard length cap.
BODY_CAP = 512

# ---------------------------------------------------------------------------
# 1g. BENIGN key=value PRECISION (W-KVPRECISION 2026-09-21).
#
# The blob sweeps below (RE_LONG_BLOB >= 16, RE_BASE64_BLOB >= 12, and the
# residual tripwire) use a character class that contains '=', so an innocent
# structured token such as isInCall=false, state=active, ice=connected,
# scorex100=54, outp=BluetoothHFP was masked as [REDACTED:blob] purely because
# "key=value" is >= 12 characters. On the 14-day corpus that was the single
# largest class of masked tokens and made call debugging much harder.
#
# A key=value token is now PROTECTED from the blob / JWT / hex / phone sweeps
# only if BOTH halves pass a CLOSED allow-list grammar (fail-closed: anything
# that does not match takes the unchanged old path and is masked):
#   * key   : letters/digits/_/./- , every part word-like (no random-looking or
#             hex-looking part), no identity / secret word (name, user, peer,
#             pin, otp, key, token, psk, sas, fp, ufrag, id, ...; waived only
#             for a boolean value, or a number under a measurement key such as
#             peerReadyAgeMs), and the token must not be matched by the keyed
#             deny rules (call id, device, psk/key/tag/iv/... key=value) --
#             those still win.
#   * value : a boolean; a small number (<= 7 digits, signed, or a short
#             decimal); a number with a fixed unit (35ms 1.5s 64kbps); a 2-3
#             part version or a "v5"/"v5-ctrl" tag; an epoch-seconds value under
#             a version/time named key; one of a FIXED vocabulary of mixed-case
#             constants (audio route types...); or -- only under an enum-like
#             key (state, reason, mode, kind, role, ...) -- a lower-case word
#             (one '_' at most, <= 12 chars a part, word-like) or a lowerCamel
#             enum (endCall). A value followed by an ellipsis (a truncated id)
#             is never benign; hex-looking / random-looking values never are.
# Side effect (intended): a protected token counts as ONE structural token in
# the shape gate even when wrapped in brackets, so "(age=1.4s)" no longer makes
# an otherwise structured line fail the gate.
# Protected tokens are swapped for private-use sentinels for the duration of the
# sweeps and restored at the very end; the private-use characters are stripped
# from the input first, so a device line can never forge one.
# ---------------------------------------------------------------------------
KV_OPEN = chr(0xE000)     # private-use sentinel delimiters (source stays ASCII)
KV_CLOSE = chr(0xE001)
KV_IDX_BASE = 0xE100
KV_MAX_PROTECTED = 0x0E00   # per body; any further kv token is simply swept

# key=value token candidate: starts at a token boundary, value fully delimited
# (whitespace, , ; ) ] } > " ' ! ? end, or a sentence '.'/':' before a space).
RE_KV_SCAN = re.compile(
    r"(?<![A-Za-z0-9_.\-+/=:@%$#&*~^\\" + KV_OPEN + "-" + chr(0xF8FF) + "])"
    r"([A-Za-z][A-Za-z0-9_.\-]{0,39})="
    r"([A-Za-z0-9_\-%]+(?:\.[A-Za-z0-9_\-%]+)*)"
    r"(?=$|[\s,;)\]}>\"'!?]|[.:](?:\s|$))")
RE_KVSENT = re.compile(KV_OPEN + "([" + chr(0xE100) + "-" + chr(0xEFFF) + "])" + KV_CLOSE)
RE_KVSENT_TOKEN = re.compile("^" + KV_OPEN + "[" + chr(0xE100) + "-" + chr(0xEFFF) + "]" + KV_CLOSE + "$")
RE_PRIVATE_USE = re.compile("[" + KV_OPEN + "-" + chr(0xF8FF) + "]")   # never legitimate in telemetry

_KV_WORD_SPLIT = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+")
_RE_HEX_ONLY = re.compile(r"^[0-9a-fA-F]+$")
_RE_CONSONANT_RUN = re.compile(r"[bcdfghjklmnpqrstvwxz]{6,}", re.IGNORECASE)

# Words that name an identity, a secret or free content: a key containing one of
# them is never protected (unless the value is a bare boolean, which carries one
# bit and cannot hide anything).
_KV_DENY_WORDS = frozenset("""
name username user nick nickname display contact caller callee peer from to
sender recipient owner account acct email mail phone tel telephone mobile
number addr address ip host hostname url uri path file filename text msg
message body title note comment label alias handle word words phrase pass
passwd password passphrase pwd pin otp secret token key keys psk sas seed salt
nonce iv tag sig signature hash digest fp fingerprint cid id uid uuid guid
serial imei imsi udid ssid bssid mac device model cred creds credential auth
cookie ticket cert pubkey privkey ufrag pwd verify verification confirm
confirmation activation sms unlock passcode challenge invite
""".split())
# A numeric value under a key whose LAST word is a measurement (peerReadyAgeMs,
# userCount, retryAttempts) is a measurement, not an identity: the ROLE words of
# _KV_MEASURE_WAIVE are waived for it. The identity words (id, name, email,
# phone, ip, number, ...) and the deny SUBSTRINGS below are never waived.
_KV_MEASURE_SUFFIX = frozenset("""
ms sec secs seconds age count counts len length size bytes bps kbps fps hz rate
ratio attempts retries total idx index seq score rtt ttl pct percent
""".split())
_KV_MEASURE_WAIVE = frozenset("""
peer user caller callee from to sender recipient owner account acct contact
host activation
""".split())
# ... and concatenated spellings the word splitter cannot see.
_KV_DENY_SUBSTR = ("passw", "secret", "token", "cred", "fingerprint",
                   "username", "nickname", "devicename", "hostname", "phone",
                   "email", "psk", "privkey", "pubkey", "keyfp", "ufrag",
                   "mnemonic", "otp", "callid", "userid", "peerid", "deviceid")
# `code` is fine for error/status codes, not for verification-style codes.
_KV_CODE_CONTEXT = frozenset("""
verify verification sms otp pair pairing invite confirm activation login reset
security access auth pass promo referral recovery
""".split())

_KV_BOOLS = frozenset(["true", "false", "yes", "no", "on", "off", "null",
                       "nil", "none", "nan"])
RE_KV_INT = re.compile(r"^-?\d{1,7}$", re.ASCII)
RE_KV_DEC = re.compile(r"^-?\d{1,6}\.\d{1,4}$", re.ASCII)
RE_KV_UNITNUM = re.compile(
    r"^-?\d{1,7}(?:\.\d{1,3})?(?:ms|us|ns|s|sec|min|h|hz|khz|kbps|mbps|bps|"
    r"fps|kb|mb|gb|b|db|dbfs|px|x|%)$", re.ASCII)
# W-KVPRECISION-2: closed shapes. A version is major.minor[.patch] (a 3-digit
# first group, i.e. an IPv4 fragment, is not a version); a routing-epoch tag is
# v<1-2 digits> with one of the suffixes the app defines (MessageRatchet:
# v4, v5-chat, v5-ctrl, v1-fallback).
RE_KV_VERSION = re.compile(r"^\d{1,2}\.\d{1,3}(?:\.\d{1,4})?$", re.ASCII)
RE_KV_VTAG = re.compile(r"^v\d{1,2}(?:-(?:ctrl|chat|fallback))?$", re.ASCII)
# enum: one '_' at most (snake_case constants); a hyphen-joined value could be a
# pair of passphrase / SAS words, so hyphenated constants live in KV_FIXED_VOCAB.
RE_KV_ENUM = re.compile(r"^[a-z][a-z0-9]{1,11}(?:_[a-z][a-z0-9]{1,11})?$")
RE_KV_LCAMEL = re.compile(r"^[a-z]{2,10}(?:[A-Z][a-z]{2,10}){1,3}$")
RE_KV_EPOCH10 = re.compile(r"^1[5-9]\d{8}$", re.ASCII)        # 2017..2033 in seconds
# keys (whole key, lower-cased) allowed to carry each of the closed value shapes:
# the ones the app / the 14-day corpus actually use, plus their obvious siblings.
_KV_VTAG_KEYS = frozenset(["epoch", "wire"])
_KV_VERSION_KEYS = frozenset(["version", "ver", "appversion", "osversion",
                              "sdkversion"])
_KV_EPOCH_KEYS = frozenset(["version", "ver", "selfver", "peerver", "cached"])
# per-body budgets for the protected key=value tokens (corpus maxima: 3 open
# tokens; see _protect_benign_kv).
KV_MAX_OPEN = 6

# Fixed (constant) mixed-case strings the app prints. CLOSED set: a value that
# is not lower-case / lowerCamel / number-shaped and not listed here is masked.
KV_FIXED_VOCAB = frozenset([
    # AVAudioSession port types
    "Receiver", "Speaker", "CarAudio", "BluetoothHFP", "BluetoothA2DP",
    "BluetoothLE", "Headphones", "HeadsetMic", "BuiltInMic", "BuiltInSpeaker",
    "BuiltInReceiver", "LineIn", "LineOut", "USBAudio", "AirPlay", "HDMI",
    # transports / reasons / error kinds seen in the field
    "P2pSrtp", "P2pDtls", "WsRelay", "Session", "Tempo", "TUS",
    "WIFI", "CELLULAR", "ETHERNET", "LOOPBACK", "OTHER", "NONE",
    "ws-relay", "media-lost", "half-open",
])


def _kv_plausible_word(w, max_len=24, max_digits=3, consonants=True):
    """True if `w` (alphanumeric) reads like a word / identifier and not like a
    random or hex-looking string."""
    n = len(w)
    if n == 0 or n > max_len:
        return False
    digits = 0
    trans = 0
    prev_digit = None
    for ch in w:
        is_d = "0" <= ch <= "9"
        if is_d:
            digits += 1
        if prev_digit is not None and is_d != prev_digit:
            trans += 1
        prev_digit = is_d
    if digits > max_digits or trans > 2:
        return False
    if n >= 6 and _RE_HEX_ONLY.match(w):
        return False
    if consonants and _RE_CONSONANT_RUN.search(w):
        return False
    return True


def _kv_key_words(key):
    words = []
    for part in re.split(r"[._\-]+", key):
        words.extend(w.lower() for w in _KV_WORD_SPLIT.findall(part))
    return words


# Keys whose value is an enum / state word (last word of the key decides).
_KV_ENUM_KEY_WORDS = frozenset("""
state status mode reason rsn kind role level lv result why ev event phase stage
type rail dir direction site branch step cause err error fail media first
transport route net quality health outcome action trigger source origin ice
dtls srtp conn connection signaling
""".split())


def _kv_enum_key(key):
    words = _kv_key_words(key)
    return bool(words) and words[-1] in _KV_ENUM_KEY_WORDS


def _kv_key_ok(key, numeric=False):
    """Key half of the grammar: word-like parts, no identity/secret word.
    Returns the number of key words that are not app vocabulary (>= 0) when the
    key is acceptable, else -1."""
    if not key or len(key) > 40 or key[-1] in "._-":
        return -1
    for part in re.split(r"[._\-]+", key):
        # whole part: length / digit / hex shape; consonant runs are judged per
        # camelCase word below (lastKfrAgeMs is fine, 'qzxvbnmk' is not).
        if not part or not _kv_plausible_word(part, consonants=False):
            return -1
        for cw in _KV_WORD_SPLIT.findall(part):
            if cw.isdigit():
                continue
            if _RE_CONSONANT_RUN.search(cw):
                return -1
    words = _kv_key_words(key)
    low = key.lower()
    # W-KVPRECISION-2 (red-team finding 4): the identity words (id, name, email,
    # phone, ip, number, ...) are NEVER waived. Only the ROLE words in
    # _KV_MEASURE_WAIVE (peer, user, caller, ...) are, and only for a numeric
    # value under a measurement key (peerReadyAgeMs, userCount): the old code
    # waived EVERY deny word there, so peerSessionIdMs=1234567 shipped.
    measurement = numeric and bool(words) and words[-1] in _KV_MEASURE_SUFFIX
    for w in words:
        if w in _KV_DENY_WORDS and not (measurement and w in _KV_MEASURE_WAIVE):
            return -1
    if any(s in low for s in _KV_DENY_SUBSTR):
        return -1
    if "code" in words and _KV_CODE_CONTEXT.intersection(words):
        return -1
    # W-FREEWORD: the key is free text too (`qzkmxvplwtrnh=1`): it must read like
    # an identifier -- known words, or word-like ones.
    ok, n_unknown = _ident_ok(key)
    return n_unknown if ok else -1


@functools.lru_cache(maxsize=16384)
def _kv_classify(key, val):
    """Value class of a provably-benign key=val token, else None. Returns
    (kind, n_unknown_words): n_unknown counts the words of the key and of the
    value that are not app vocabulary (budgeted per body by the caller)."""
    tok = key + "=" + val
    # the keyed deny rules always win (call id / device / psk|key|tag|iv|...).
    if (RE_CALLID_KEY.search(tok) or RE_DEVICE_KEY.search(tok)
            or RE_SECRET_KV.search(tok) or RE_SECRET_PREFIXED.search(tok)):
        return None, 0
    if not val or len(val) > 24:
        return None, 0
    klow = key.lower()
    low = val.lower()
    kind = None
    n_val = 0
    if low in _KV_BOOLS and val in (low, val.capitalize(), val.upper()):
        kind = "bool"
    elif RE_KV_INT.match(val) or RE_KV_DEC.match(val) or RE_KV_UNITNUM.match(val):
        kind = "num"
    # W-KVPRECISION-2 (red-team finding 2): the version / tag / epoch channels
    # used to survive under ANY key. Now they need a key from a short list and
    # a value from a closed shape (v<1-2 digits>[-ctrl|-chat|-fallback];
    # major.minor[.patch]; epoch seconds), so they cannot smuggle data.
    elif RE_KV_VERSION.match(val):
        if klow in _KV_VERSION_KEYS:
            kind = "version"
    elif RE_KV_VTAG.match(val):
        if klow in _KV_VTAG_KEYS:
            kind = "vtag"
    elif RE_KV_EPOCH10.match(val):
        if klow in _KV_EPOCH_KEYS:
            kind = "epoch"
    elif val in KV_FIXED_VOCAB:
        kind = "fixed"
    # an open-vocabulary WORD is only trusted under an enum-like key (state,
    # reason, mode, kind, ...): a lower-case string under key `x` or `sessionkey`
    # could be anything, so it takes the unchanged masking path. It must also
    # read like a word / be app vocabulary (W-FREEWORD), and unknown ones are
    # budgeted per body.
    elif RE_KV_ENUM.match(val):
        if _kv_enum_key(key) and all(
                _kv_plausible_word(p, 12, 3) for p in val.split("_")):
            ok, n_val = _ident_ok(val)
            if ok:
                kind = "enum"
    elif RE_KV_LCAMEL.match(val):
        if _kv_enum_key(key) and all(
                _kv_plausible_word(p, 12, 0) for p in _KV_WORD_SPLIT.findall(val)):
            ok, n_val = _word_ok(val)
            if ok:
                kind = "lcamel"
    if kind is None:
        return None, 0
    if kind == "bool":
        # a bare boolean carries one bit: any word-like key (identity words are
        # fine here -- there is nothing to hide in true/false).
        if len(key) > 40 or key[-1] in "._-" or not all(
                _kv_plausible_word(p, consonants=False)
                for p in re.split(r"[._\-]+", key) if p):
            return None, 0
        ok, n_key = _ident_ok(key)
        return ("bool", n_key) if ok else (None, 0)
    n_key = _kv_key_ok(key, numeric=(kind == "num"))
    if n_key < 0:
        return None, 0
    return kind, n_key + n_val


def _kv_is_benign(key, val):
    """True only if key=val is provably-benign structured telemetry."""
    return _kv_classify(key, val)[0] is not None


# kinds whose value is not a plain number / boolean: budgeted per body.
_KV_OPEN_KINDS = frozenset(["version", "vtag", "epoch", "enum", "lcamel", "fixed"])


class _ProtList(list):
    """The protected key=value tokens of one body; `.unknown` = how many of their
    key / value words are not app vocabulary, `.idlike` = how many carry a number
    of 6+ digits (both shared with the gate's budgets)."""
    unknown = 0
    idlike = 0


def _protect_benign_kv(s):
    """Swap every benign key=value token for a sentinel. Returns (text, list of
    the protected tokens); restore with _restore_kv(). Per-body budgets (W-
    KVPRECISION-2): at most KV_MAX_OPEN tokens with a non-numeric, non-boolean
    value, MAX_UNKNOWN_WORDS key/value words that are not app vocabulary and
    MAX_IDLIKE_TOKENS numbers of 6+ digits (the gate spends the same budgets on
    the rest of the body); any further token is simply swept (masked) like before
    the precision work."""
    prot = _ProtList()
    budget = {"open": 0, "unknown": 0, "idlike": 0}

    def _sub(m):
        if len(prot) >= KV_MAX_PROTECTED:
            return m.group(0)
        kind, n_unk = _kv_classify(m.group(1), m.group(2))
        if kind is None:
            return m.group(0)
        is_open = 1 if kind in _KV_OPEN_KINDS else 0
        is_big = 1 if kind == "num" and _is_bignum(m.group(2)) else 0
        if (budget["open"] + is_open > KV_MAX_OPEN
                or budget["unknown"] + n_unk > MAX_UNKNOWN_WORDS
                or budget["idlike"] + is_big > MAX_IDLIKE_TOKENS):
            return m.group(0)
        budget["open"] += is_open
        budget["unknown"] += n_unk
        budget["idlike"] += is_big
        prot.unknown = budget["unknown"]
        prot.idlike = budget["idlike"]
        prot.append(m.group(0))
        return KV_OPEN + chr(KV_IDX_BASE + len(prot) - 1) + KV_CLOSE

    return RE_KV_SCAN.sub(_sub, s), prot


def _restore_kv(s, prot):
    if not prot:
        return s

    def _r(m):
        i = ord(m.group(1)) - KV_IDX_BASE
        return prot[i] if 0 <= i < len(prot) else ""

    return RE_KVSENT.sub(_r, s)


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


def _scrub_body_ex(body):
    """Scrub a (normalized) body. Returns (scrubbed, protected): `scrubbed`
    still carries sentinels for the benign key=value tokens (see the 1g block),
    `protected` is the list _restore_kv() puts back. The residual tripwire and
    the shape gate run on this sentinel form: a protected token is structural
    by construction and invisible to the blob/hex/JWT/phone sweeps."""
    # private-use sentinels can never come from the device: strip them first.
    s = RE_PRIVATE_USE.sub("", body)
    # Mirror of redact(): secretPrefixed first, then longBlob (Swift order).
    s = RE_SECRET_PREFIXED.sub(PLACEHOLDER, s)
    # W-KVPRECISION: provably-benign key=value tokens step out of the sweeps.
    s, prot = _protect_benign_kv(s)
    s = RE_LONG_BLOB.sub("[REDACTED:blob]", s)
    # Strengthening: keyed/structured first, then broad sweeps.
    for kind, rx in STRENGTHEN_RULES:
        s = rx.sub("[REDACTED:%s]" % kind, s)
    return s, prot


def _scrub_body(body):
    """Run the mirror patterns + strengthening rules over a (normalized) body.
    Returns the scrubbed string. Does NOT decide keep/drop (that is the gate)."""
    s, prot = _scrub_body_ex(body)
    return _restore_kv(s, prot)


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


def _passes_structured_gate(scrubbed, unknown_used=0, idlike_used=0):
    """POSITIVE allow-list. A body ships ONLY if it is recognizably structured
    telemetry. THREE conditions, ALL required (fail-closed):

      (A) NO run of more than MAX_FREEWORD_RUN consecutive free
          natural-language words; AND
      (B) free natural-language words must not DOMINATE -- if the body carries
          unrecognized free words, it must also carry positive structure
          (key=value / [REDACTED:*] / number / known state-enum vocab) and the
          free words must be the minority. A plaintext sentence ("he said meet
          at noon tomorrow") has ZERO structural anchors and many free words,
          so it fails (B) and is replaced by the attribute summary; AND
      (C) (W-FREEWORD) every token must be PLAUSIBLE (see 1e-bis): words must
          be known or read like words, at most MAX_UNKNOWN_WORDS words that are
          not known, key=value values / units / hex prefixes / separator-joined
          tokens / runs of numbers are checked too. A token that fails is a
          HARD FAIL (a random letter block is not "just a free word").

    Bracketed placeholders, key=value tokens, numbers, known-vocab words and
    punctuation are "structural"; unknown alphabetic words >=3 chars are
    "free". Connectors (<=2 chars) are neutral for (A)/(B) but count as unknown
    words for (C) unless they are app vocabulary."""
    run = 0
    free = 0
    structural = 0
    unknown = unknown_used   # (C) words that are neither TELEMETRY_VOCAB nor APP_VOCAB
                             # (already spent by the protected key=value tokens)
    idlike = idlike_used   # (C) hex id prefixes / 6+ digit numbers (kv values too)
    numrun = 0      # (C) consecutive bare number tokens
    # each protected benign key=value sentinel (1g) becomes its own token, so a
    # neighbouring word or punctuation is judged on its own merits.
    for tok in RE_KVSENT.sub(lambda m: " %s " % m.group(0), scrubbed).split():
        if RE_PLACEHOLDER_TOKEN.match(tok):
            run = 0
            numrun = 0
            structural += 1
            continue
        if RE_KVSENT_TOKEN.match(tok):
            # a protected benign key=value token: structural by construction.
            run = 0
            numrun = 0
            structural += 1
            continue
        if RE_KV_TOKEN.match(tok):
            # W-FREEWORD: an unprotected key=value token used to be structural
            # whatever followed the separator; key and value are judged now.
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
            run = 0
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
            run = 0
            structural += 1
            continue
        numrun = 0
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
        # (C) what is left of the token once redactor placeholders and wrapper
        # punctuation are removed: judged for plausibility below. A placeholder
        # glued to punctuation ("[REDACTED:blob]:") is the redactor's own
        # output: it keeps its legacy free-word count but nothing to judge.
        eff = _RE_PH_INSIDE.sub("", tok).strip(_GATE_WRAP + "*")
        if core in TELEMETRY_VOCAB:
            if eff.isalpha() and not _case_shape_ok(eff):
                return False
            run = 0
            structural += 1
            continue
        if len(core) <= 2:
            # Short connector: neutral, but it does NOT break a free-word run
            # (so "meet at noon" is two free words in one run, not reset by
            # "at"). This is what catches plaintext prose.
            if eff.isalpha() and not _word_known(eff.lower()):
                unknown += 1
                if unknown > MAX_UNKNOWN_WORDS:
                    return False
            continue
        # a free word (RE_FREEWORD) or an unknown token shape: conservative ->
        # free, and it must also be plausible (C).
        run += 1
        free += 1
        if run > MAX_FREEWORD_RUN:
            return False
        if eff:
            ok, n_unk = _ident_ok(eff)
            if not ok:
                return False
            unknown += n_unk
            if unknown > MAX_UNKNOWN_WORDS:
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
      1b. KEY-BYTES (derived_key, >=8-number decimal/hex byte lists) -> DROP.
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

    # 1b -- KEY-BYTES (derived_key / decimal or hex byte lists) -> DROP, any tag.
    if _has_key_bytes(low):
        return False, ""

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

    # 5 -- scrub (benign key=value tokens are held out as sentinels).
    scrubbed, protected = _scrub_body_ex(norm)

    # 6 -- residual high-entropy tripwire -> attribute summary fallback.
    if _has_residual_secret(scrubbed):
        scrubbed = _attribute_summary(attrs)

    # 7 -- positive structured-shape gate.
    elif not _passes_structured_gate(scrubbed, getattr(protected, "unknown", 0),
                                     getattr(protected, "idlike", 0)):
        scrubbed = _attribute_summary(attrs)

    # 7b -- put the protected benign key=value tokens back (only reached when
    # the scrubbed body itself passed the tripwire and the gate).
    else:
        scrubbed = _restore_kv(scrubbed, protected)

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
    # W-AVATARSHIP (2026-08-01): AppState.swift's avatar_announce dispatch
    # (broadcastAvatarToKnownPeers / maybeAnnounceAvatarTo /
    # handleInboundAvatarAnnounce) tags its RTLog calls "avatar" — this
    # prefix was missing here, so every one of those lines (e.g. the
    # malformed-envelope RTLog.error at AppState.swift:6778) was silently
    # dropped before ever reaching Loki. Found while investigating Pavel's
    # "avatar exchange still not working on iOS" report: zero avatar-tagged
    # evidence in 180 min of real iOS activity including a live call, with
    # no way to tell whether that meant "never fired" or "fired but
    # invisible". Message bodies are still gated by redact_body's own
    # structured-shape check below — this only fixes the tag-level drop.
    ("avatar", "avatar"),
    # W-TAGDROP (2026-08-02): the "avatar" fix above was one instance of a
    # class, not the whole class. Every RTLog tag actually used in the app was
    # enumerated and diffed against this list; ten more were being dropped at
    # the tag gate, including the ONE line that records a chat message failing
    # to decrypt (AppState.swift `RTLog.error("chat", "msg_receive decrypt
    # failed from=...")`) — the exact evidence for Pavel's "ogni tanto vedo
    # ancora messaggi non decifrati", invisible in every log pull to date, and
    # `NameResolve`, which owns the rubrica auto-save from calls. Tag matching
    # is `startswith` on the lowercased tag, so these cover their own
    # variants. Bodies still go through redact_body's structured-shape gate
    # below; this only fixes the tag-level drop.
    ("chat", "chat"),
    ("group", "group"),
    ("nameresolve", "nameresolve"),
    ("dial", "dial"),
    ("security", "security"),
    ("privacy", "privacy"),
    ("keymgmt", "keymgmt"),
    ("settings", "settings"),
    ("featureflags", "featureflags"),
    ("bugreport", "bugreport"),
    ("videodiag", "videodiag"),
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


def is_permanent_age_reject(status, resp_body):
    """True for a Loki 400 that is a verdict on the sample's AGE and can never
    be fixed by retrying: 'entry too far behind' (out-of-order window) and 'has
    timestamp too old' (reject_old_samples_max_age, 7 days on this Loki). Both
    only move forward in time, so a blob that hit one must be recorded as
    handled instead of being re-read and re-POSTed on every future run."""
    if status != 400:
        return False
    low = (resp_body or "").lower()
    return "too far behind" in low or "timestamp too old" in low


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

RE_BLOB_UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
IOS_RO_MAX_MINUTES = 20160   # limits enforced by the wrapper on the VPS
IOS_RO_MAX_LIMIT = 5000


def parse_ios_list(text):
    """Parse the qaudion-shipper-ios-ro.sh `ios-list` output ('<mtime> <size>
    <path>' per line) into [(mtime, size, path)] newest first. Anything that is
    not exactly DATA_DIR/<uuid36> with a sane size is IGNORED (the wrapper's
    error text, path tricks, extra fields): the path later feeds `ios-cat`."""
    files = []
    for line in (text or "").split("\n"):
        parts = line.strip().split(" ")
        if len(parts) != 3:
            continue
        mtime_s, size_s, path = parts
        if not path.startswith(DATA_DIR + "/"):
            continue
        if not RE_BLOB_UUID.match(path[len(DATA_DIR) + 1:]):
            continue
        try:
            mtime, size = float(mtime_s), int(size_s)
        except ValueError:
            continue
        if mtime <= 0 or size <= 0 or size > 256 * 1024:
            continue
        files.append((mtime, size, path))
    files.sort(key=lambda f: f[0], reverse=True)
    return files


def list_chunks_exec(client, minutes, limit):
    """Restricted-exec twin of list_device_chunks(): `ios-list <m> <n>`."""
    m = min(max(int(minutes), 1), IOS_RO_MAX_MINUTES)
    n = min(max(int(limit), 1), IOS_RO_MAX_LIMIT)
    out_text, err = run(client, "ios-list %d %d" % (m, n))
    if err.strip():
        print("STDERR (ios-list):", err.strip()[:200], file=sys.stderr)
    return parse_ios_list(out_text)


def read_blob_exec(client, path):
    """Restricted-exec blob read: `ios-cat <uuid>` -> stdout bytes. Returns the
    bytes, or None on a refusal / non-zero exit / oversize. No SFTP."""
    uid = path.rsplit("/", 1)[-1]
    if not RE_BLOB_UUID.match(uid):
        return None
    _stdin, stdout, stderr = client.exec_command("ios-cat " + uid)
    blob = stdout.read()
    if stdout.channel.recv_exit_status() != 0 or len(blob) > 256 * 1024:
        print("  skip %s: ios-cat refused (%s)"
              % (path, stderr.read().decode("utf-8", "replace").strip()[:80]),
              file=sys.stderr)
        return None
    return blob


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


def list_local_chunks(local_dir, minutes, limit, local_map):
    """LOCAL-mirror twin of list_device_chunks(): (mtime, size, path) newest
    first for regular files under local_dir modified in the last `minutes`.

    `path` is the CANONICAL prod path (DATA_DIR + the file's relative name),
    NOT the mirror path, so the per-blob state key and the orphan-blob
    instance id (hmac8(blob_path)) are byte-identical to what the SSH mode
    produces for the same blob -- switching modes never re-ships or re-keys.
    local_map[canonical] = real local path (used by read_chunk_blob). Symlinks
    are ignored; nothing is ever written."""
    cutoff = time.time() - minutes * 60.0
    files = []
    base = os.path.realpath(local_dir)
    for root, _dirs, names in os.walk(base):
        for name in names:
            real = os.path.join(root, name)
            try:
                if os.path.islink(real):
                    continue
                st = os.stat(real)
            except OSError:
                continue
            if st.st_mtime < cutoff:
                continue
            rel = os.path.relpath(real, base).replace(os.sep, "/")
            canon = DATA_DIR + "/" + rel
            local_map[canon] = real
            files.append((float(st.st_mtime), int(st.st_size), canon))
    files.sort(key=lambda f: f[0], reverse=True)
    return files[:limit]


def order_blobs_oldest_first(files):
    """Reorder list_device_chunks()'s newest-first selection to oldest-first.

    Loki's out-of-order ingester tracks, per stream, the highest timestamp it
    has accepted; any later POST older than (that high-water mark - window)
    is bounced with "entry too far behind" and the verdict is permanent for
    that stream. Shipping blobs newest-first means the very FIRST accepted
    POST in a run jumps the watermark to the newest chunk's timestamp, which
    then permanently dooms every older blob selected in the SAME run -- a
    within-run version of the trap documented in
    reference_ios_log_pipeline_limits.md. Shipping oldest-first instead lets
    the watermark advance in the same direction the data does, so a blob is
    only bounced if it is genuinely older than Loki's window, not merely
    because a newer sibling from the same run went out first."""
    return sorted(files, key=lambda f: f[0])


def read_chunk_blob(sftp, path, size_s, local_map=None, exec_client=None):
    """SFTP-read one blob (or, in --local-dir mode, read it from the local
    mirror via local_map[path]; in restricted-exec mode, `ios-cat` through
    exec_client). Returns the UTF-8 text, or None if it is not a parseable W417
    chunk (too big, empty, binary, or wrong first line)."""
    if size_s == 0 or size_s > 256 * 1024:
        return None
    try:
        if exec_client is not None:
            blob = read_blob_exec(exec_client, path)
            if blob is None:
                return None
        elif local_map is not None:
            with open(local_map[path], "rb") as rf:
                blob = rf.read()
        else:
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
    # Stable-sort ascending by ts. The on-device ring buffer normally appends
    # in order, but this is the same "ship oldest-first" invariant as
    # order_blobs_oldest_first() applied one level down: a single POST's
    # logRecords should never regress in time within a stream, or Loki can
    # bounce the tail of an otherwise-acceptable blob.
    records.sort(key=lambda r: r["ms"])
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


def record_shipped(state, blob_path, sig, line_count, mt=None, sz=None):
    ent = {
        "sig": sig,
        "lines": line_count,
        "ts": int(time.time()),
    }
    if mt is not None and sz is not None:
        # listing mtime/size: restricted-exec mode skips an UNCHANGED blob with
        # no ios-cat (one process spawn per blob on the production box).
        ent["mt"] = round(float(mt), 3)
        ent["sz"] = int(sz)
    state.setdefault("blobs", {})[blob_path] = ent


def unchanged_since_shipped(state, blob_path, mtime, size):
    """True if this blob was shipped with the SAME listing mtime+size."""
    prev = state.get("blobs", {}).get(blob_path)
    return (bool(prev) and prev.get("mt") == round(float(mtime), 3)
            and prev.get("sz") == int(size))


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

    # 18. Blobs must ship oldest-first (ascending mtime): shipping newest-first
    #     lets the first accepted POST jump Loki's per-stream watermark ahead,
    #     permanently dooming every older blob picked in the SAME run.
    fake_files = [(300.0, 10, "/c"), (100.0, 10, "/a"), (200.0, 10, "/b")]
    ordered = order_blobs_oldest_first(fake_files)
    if [p for _, _, p in ordered] != ["/a", "/b", "/c"]:
        failures.append("ORDER[blobs]: not oldest-first: %r" % (ordered,))

    # 19. Records within one blob must ship in ascending ts order even if the
    #     on-device W417 chunk itself was appended out of order.
    _hdr, _recs = parse_chunk(
        '{"ts":"2026-01-01T00:00:03.000Z","lvl":"I","tag":"call","msg":"c"}\n'
        '{"ts":"2026-01-01T00:00:01.000Z","lvl":"I","tag":"call","msg":"a"}\n'
        '{"ts":"2026-01-01T00:00:02.000Z","lvl":"I","tag":"call","msg":"b"}\n'
    )
    if [r["msg"] for r in _recs] != ["a", "b", "c"]:
        failures.append("ORDER[records]: not ascending ts: %r" % (_recs,))

    # 20. --local-dir mirror mode: mtime window, newest-first, --limit,
    #     CANONICAL prod paths (state key / orphan instance id identical to the
    #     SSH mode), symlinks ignored, W417-only reads, size cap. Read-only.
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        w417 = ('{"type":"header","x":1}\n'
                '{"ts":"2026-01-01T00:00:01.000Z","lvl":"I","tag":"call",'
                '"msg":"a"}\n')
        u_old = "22222222-2222-4222-8222-222222222222"
        u_mid = "44444444-4444-4444-8444-444444444444"
        u_new = "11111111-1111-4111-8111-111111111111"
        u_bin = "33333333-3333-4333-8333-333333333333"

        def _mk(name, data, age_s):
            p = os.path.join(td, name)
            with open(p, "wb") as f:
                f.write(data)
            t = time.time() - age_s
            os.utime(p, (t, t))
            return p

        _mk(u_old, w417.encode("utf-8"), 3 * 86400)
        _mk(u_mid, w417.encode("utf-8"), 3600)
        _mk(u_new, w417.encode("utf-8"), 60)
        _mk(u_bin, b"\x89PNG\r\n\x1a\n" + b"\x00" * 50, 30)
        made_link = False
        try:
            os.symlink(os.path.join(td, u_new), os.path.join(td, "a-link"))
            made_link = True
        except (OSError, NotImplementedError, AttributeError):
            pass
        lmap = {}
        got = list_local_chunks(td, 24 * 60, 10, lmap)
        names = [p.rsplit("/", 1)[1] for _, _, p in got]
        if names != [u_bin, u_new, u_mid]:
            failures.append("LOCAL[list]: window/order wrong: %r" % (names,))
        if not all(p.startswith(DATA_DIR + "/") for _, _, p in got):
            failures.append("LOCAL[canon]: path not canonical prod path: %r"
                            % (got,))
        if made_link and "a-link" in names:
            failures.append("LOCAL[symlink]: symlink was not ignored")
        if len(list_local_chunks(td, 24 * 60, 2, {})) != 2:
            failures.append("LOCAL[limit]: --limit not applied")
        by_name = dict((p.rsplit("/", 1)[1], (s, p)) for _, s, p in got)
        s_new, p_new = by_name[u_new]
        txt_new = read_chunk_blob(None, p_new, s_new, lmap)
        if not txt_new or not txt_new.startswith('{"type":"header"'):
            failures.append("LOCAL[read]: W417 blob not read from mirror")
        s_bin, p_bin = by_name[u_bin]
        if read_chunk_blob(None, p_bin, s_bin, lmap) is not None:
            failures.append("LOCAL[read]: non-W417 binary blob was returned")
        if read_chunk_blob(None, p_new, 300 * 1024, lmap) is not None:
            failures.append("LOCAL[read]: oversize blob was not skipped")

    # 21. KEY-BYTES fail-closed DROP (W-KEYBYTES). Native libs print raw key
    #     bytes as a decimal byte list: "derived_key [1,2,...,32] len 32". EVERY
    #     one of these shapes must be DROPPED (kept == False), on any tag, also
    #     when the line carries enough key=value structure to pass the shape gate.
    n32 = [(i * 37 + 11) % 256 for i in range(32)]
    l32 = ",".join(str(n) for n in n32)
    l32sp = ", ".join(str(n) for n in n32)
    l8 = "1,2,3,4,5,6,7,8"
    struct = " state=active ice=connected role=caller"
    fw_dk = "".join(chr(0xFF00 + (ord(c) - 0x20)) for c in "derived_key")
    key_cases = [
        ("crypto", "derived_key [%s] len 32" % l32, "dk_plain"),
        ("stdout", "derived_key [%s,] len 32" % l32, "dk_trailing_comma"),
        ("stdout", "derived_key [%s] len 32" % l32sp, "dk_spaced"),
        ("call", "derived_key [%s]%s" % (l32, struct), "dk_with_structure"),
        ("crypto", "derived_key: [%s]" % l32, "dk_colon"),
        ("crypto", "DERIVED_KEY [%s] len 32" % l32, "dk_upper"),
        ("crypto", "%s [%s] len 32" % (fw_dk, l32), "dk_fullwidth"),
        ("crypto", "derived_key ok len=32" + struct, "dk_word_only"),
        ("crypto", "derived key computed" + struct, "dk_two_words"),
        ("crypto", "[%s]" % l32, "list_no_word"),
        ("crypto", "hkdf out [%s]%s" % (l32, struct), "list_with_structure"),
        ("crypto", "hkdf out [%s]%s" % (l32sp, struct), "list_spaced_structure"),
        ("stdout", "session bytes (%s) done%s" % (l32, struct), "list_parens"),
        ("stdout", "session bytes {%s} done%s" % (l32, struct), "list_braces"),
        ("stdout", "x [%s]%s" % (l8, struct), "list_exactly_8"),
        ("stdout", "x %s%s" % (l8, struct), "list_bare_8"),
        ("stdout", "x [%s]%s" % (l8.replace(",", " "), struct), "list_space_sep_8"),
        ("stdout", "x [%s]%s" % (l8.replace(",", ";"), struct), "list_semicolon_8"),
        ("stdout", "(a.cc:1): secret [%s,] len 32 slat << [] len 0" % l32,
         "native_secret_trace"),
        ("crypto", "k 0x11,0x22,0x33,0x44,0x01,0x02,0x03,0x04" + struct, "hex_0x_list"),
        ("crypto", "k 11 22 33 44 01 02 03 04" + struct, "hex_bytes_spaced"),
        ("crypto", "k 11:22:33:44:01:02:03:04:05" + struct, "hex_bytes_colon"),
    ]
    for tag, msg, label in key_cases:
        scope, safe = resolve_scope(tag)
        kept, body = redact_body(msg, safe, extract_attributes(msg))
        if kept:
            failures.append("LEAK[keybytes/%s]: line was not dropped: %r"
                            % (label, body[:80]))
    # boundary: ordinary structured telemetry with short numbers must STILL ship.
    for msg in ("ice=connected role=caller retry=2 rtt=35 loss=2 jitter=4",
                "state=active ice=connected seq=12 frames=480 bytes=9600"):
        kept, body = redact_body(msg, True, extract_attributes(msg))
        if not kept or not body:
            failures.append("REGRESS[keybytes]: telemetry dropped: %r" % msg)

    # 22. Loki AGE verdicts are permanent (state advanced, never retried);
    #     everything else (5xx, timeouts, 429, other 400s) stays retryable.
    for st, body, want in (
        (400, "entry too far behind, entry timestamp is: 2026-09-14", True),
        (400, "entry for stream '{a=\"b\"}' has timestamp too old: 2026-09-13T"
              "00:00:00Z, oldest acceptable timestamp is: 2026-09-14T", True),
        (400, "ENTRY TOO FAR BEHIND", True),
        (400, "some other validation error", False),
        (429, "too far behind", False),
        (500, "timestamp too old", False),
        (0, "timed out", False),
        (204, "", False),
        (400, None, False),
    ):
        if is_permanent_age_reject(st, body) != want:
            failures.append("AGE[reject]: is_permanent_age_reject(%r, %r) != %r"
                            % (st, body, want))

    # 23. Restricted-exec mode (QAUDION_VPS_IOS_KEY): the `ios-list` parser and
    #     the `ios-cat` reader. The path returned by the VPS feeds the next
    #     command, so ANYTHING that is not DATA_DIR/<uuid36> must be ignored.
    _u1 = "0d044687-ce5d-4412-bea8-c89de446ffcc"
    _u2 = "1e155798-df6e-4523-8fb9-d9ae5573ffdd"
    _lst = ("1758433211.123456 921 %s/%s\n" % (DATA_DIR, _u1)
            + "1758433999.500000 4096 %s/%s\n" % (DATA_DIR, _u2)
            + "rejected: command not allow-listed for this restricted key\n"
            + "1758433999.5 10 %s/../../etc/passwd\n" % DATA_DIR
            + "1758433999.5 10 /etc/%s\n" % _u1
            + "1758433999.5 10 %s/%s; id\n" % (DATA_DIR, _u1)
            + "1758433999.5 10 %s/UPPER0D0-ce5d-4412-bea8-c89de446ffcc\n" % DATA_DIR
            + "1758433999.5 -5 %s/%s\n" % (DATA_DIR, _u1)
            + "1758433999.5 0 %s/%s\n" % (DATA_DIR, _u1)
            + "1758433999.5 999999 %s/%s\n" % (DATA_DIR, _u1)
            + "abc 10 %s/%s\n" % (DATA_DIR, _u1)
            + "1758433999.5 10 %s/%s extra\n" % (DATA_DIR, _u1)
            + "\n")
    _got = parse_ios_list(_lst)
    if [p.rsplit("/", 1)[1] for _, _, p in _got] != [_u2, _u1]:
        failures.append("RO[parse]: wrong survivors/order: %r" % (_got,))
    if parse_ios_list("") != [] or parse_ios_list(None) != []:
        failures.append("RO[parse]: empty input not handled")

    class _FakeChan(object):
        def __init__(self, rc):
            self._rc = rc

        def recv_exit_status(self):
            return self._rc

    class _FakeOut(object):
        def __init__(self, data, rc=0):
            self._d = data
            self.channel = _FakeChan(rc)

        def read(self):
            return self._d

    class _FakeClient(object):
        def __init__(self, data, rc=0):
            self.cmds = []
            self._data, self._rc = data, rc

        def exec_command(self, cmd):
            self.cmds.append(cmd)
            return None, _FakeOut(self._data, self._rc), _FakeOut(b"denied")

    _fc = _FakeClient(b'{"type":"header"}\n')
    _b = read_blob_exec(_fc, "%s/%s" % (DATA_DIR, _u1))
    if _b != b'{"type":"header"}\n' or _fc.cmds != ["ios-cat " + _u1]:
        failures.append("RO[cat]: wrong command/bytes: %r %r" % (_fc.cmds, _b))
    _fc = _FakeClient(b"x", rc=1)
    if read_blob_exec(_fc, "%s/%s" % (DATA_DIR, _u1)) is not None:
        failures.append("RO[cat]: non-zero exit was not refused")
    _fc = _FakeClient(b"x" * (256 * 1024 + 1))
    if read_blob_exec(_fc, "%s/%s" % (DATA_DIR, _u1)) is not None:
        failures.append("RO[cat]: oversize blob was not refused")
    _fc = _FakeClient(b"x")
    for _bad in ("%s/../../etc/passwd" % DATA_DIR, "%s/%s;id" % (DATA_DIR, _u1),
                 "%s/" % DATA_DIR, ""):
        if read_blob_exec(_fc, _bad) is not None or _fc.cmds:
            failures.append("RO[cat]: bad path reached exec: %r %r" % (_bad, _fc.cmds))
    _fc = _FakeClient(b'{"ts":"2026-01-01T00:00:01.000Z","tag":"call"}\n')
    _txt = read_chunk_blob(None, "%s/%s" % (DATA_DIR, _u1), 50, None,
                           exec_client=_fc)
    if not _txt or _fc.cmds != ["ios-cat " + _u1]:
        failures.append("RO[read]: read_chunk_blob(exec_client=) failed: %r" % (_txt,))
    _fc = _FakeClient(b"hello world not telemetry\n")
    if read_chunk_blob(None, "%s/%s" % (DATA_DIR, _u1), 26, None,
                       exec_client=_fc) is not None:
        failures.append("RO[read]: non-W417 blob was returned")
    if read_chunk_blob(None, "%s/%s" % (DATA_DIR, _u1), 300 * 1024, None,
                       exec_client=_FakeClient(b"x")) is not None:
        failures.append("RO[read]: oversize (per list) was not skipped")

    _st = {"blobs": {}}
    record_shipped(_st, "/x/" + _u1, "sig", 3, 1758433211.1234567, 921)
    if not unchanged_since_shipped(_st, "/x/" + _u1, 1758433211.1234567, 921):
        failures.append("RO[skip]: unchanged blob not recognised")
    if (unchanged_since_shipped(_st, "/x/" + _u1, 1758433212.5, 921)
            or unchanged_since_shipped(_st, "/x/" + _u1, 1758433211.1234567, 922)
            or unchanged_since_shipped(_st, "/x/" + _u2, 1758433211.1234567, 921)):
        failures.append("RO[skip]: changed/unknown blob was treated as unchanged")

    # 24. BENIGN key=value PRECISION (W-KVPRECISION). Every value below is
    #     SYNTHETIC. (a) benign structured tokens MUST survive verbatim (no
    #     [REDACTED:] anywhere); (b) adversarial secrets in key=value form MUST
    #     NOT survive; (c) the private-use sentinels cannot be forged.
    pos_lines = [
        "state=active ice=connected role=caller transport=P2pSrtp scorex100=54",
        "isInCall=false isLocked=false callState=idle enrolled=true bridgeSet=true",
        "integration.state=connecting outp=BluetoothHFP rtt=35ms elapsed=1.5s "
        "jitter=-1000",
        "reason=endCall err=wsUnavailable selfver=1758433211 media_mode=p2p "
        "epoch=v5-ctrl",
        "peerReadyAgeMs=-1 lastKfrAgeMs=2034 maxbps=4500000 sdp_len=3177 "
        "version=1.0.1177",
        "reason=local_hangup dirKeys=true peer=true selfId=false",
        "[BCryptoWS] ping sent (age=1.4s)",
        "W-CALLAWAKE (isInCall=true, groupLive=false)",
    ]
    for line in pos_lines:
        kept, body = redact_body(line, True, extract_attributes(line))
        if not kept or "[REDACTED" in body or "[summary]" in body:
            failures.append("KV-POS: benign structured line was masked/summarised:"
                            " %r -> %r" % (line, body))
            continue
        for tokn in line.split():
            tokn = tokn.strip("[](),")
            if "=" in tokn and tokn not in body:
                failures.append("KV-POS: token %r missing from %r" % (tokn, body))

    b64s = "c3ludGhldGljLXNlY3JldC1ieXRlcy0wMTIzNDU2Nzg5"     # synthetic
    hexk = "0123456789abcdef0123456789abcdef"                 # synthetic
    jwts = ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzeW50aGV0aWMifQ."
            "c2lnbmF0dXJlLXN5bnRoZXRpYw")                     # synthetic
    uuid = "11112222-3333-4444-5555-666677778888"             # synthetic
    neg_cases = [
        ("token=" + b64s + " state=active", [b64s]),
        ("key=" + hexk + " state=active", [hexk]),
        ("secretval=" + b64s + " state=active", [b64s]),
        ("data=" + b64s + " state=active", [b64s]),
        ("blob=" + b64s[:20] + " state=active", [b64s[:20]]),
        ("jwt=" + jwts + " state=active", ["eyJhbGci", "c2lnbmF0"]),
        ("psk=alpha-bravo-charlie-delta state=active", ["alpha", "bravo"]),
        ("psk=alpha_bravo_charlie state=active", ["alpha", "bravo"]),
        ("words=apple-river state=active", ["apple", "river"]),
        ("x=apple-river state=active", ["apple", "river"]),
        ("foo=apple-river-tiger state=active", ["apple", "tiger"]),
        ("id=" + uuid + " role=caller", [uuid, "11112222"]),
        ("ip=203.0.113.7 role=caller", ["203.0.113.7"]),
        ("ver=1.2.3.4 role=caller", ["1.2.3.4"]),
        ("ip6=2001:db8:0:0:0:0:0:1 role=caller", ["2001:db8"]),
        ("ip=2001:db8::1 role=caller", ["2001:db8"]),
        ("addr=fe80::1a2b:3c4d role=caller", ["fe80", "1a2b"]),
        ("gw=::1 role=caller state=active", ["::1"]),
        ("mail=bob.smith@example.com role=caller", ["bob.smith", "example.com"]),
        ("phone=+393331234567 role=caller", ["393331234567"]),
        ("tel=3331234567 role=caller", ["3331234567"]),
        ("number=5551234 role=caller", ["5551234"]),
        ("verification=123456 state=active", ["123456"]),
        ("pin=123456 state=active", ["123456"]),
        ("otpValue=123456 state=active", ["123456"]),
        ("verificationCode=123456 state=active", ["123456"]),
        ("sender=alice-smith state=active", ["alice"]),
        ("userId=alicebob state=active", ["alicebob"]),
        ("displayName=alicebob state=active", ["alicebob"]),
        ("x=k7Gq9Lp2Zx1 state=active", ["k7Gq9Lp2Zx1"]),
        ("code=aB3dE5gH state=active", ["aB3dE5gH"]),
        ("k7Gq9Lp2Zx1=active state=active", ["k7Gq9Lp2Zx1"]),
        ("peer=abcdefab... role=caller state=active", ["abcdefab"]),
        ("x=correcthorse role=caller state=active", ["correcthorse"]),
        ("sessionkey=abcdefghijklmn role=caller state=active", ["abcdefghijklmn"]),
        ("data=endCallNow role=caller state=active", ["endCallNow"]),
        ("state=correcthorsebattery role=caller", ["correcthorse"]),
        ("state=decade role=caller", ["decade"]),
        ("state=qzxvbnmkwr role=caller", ["qzxvbnmkwr"]),
        ("state=activeactiveactiveactive role=caller", ["activeactiveactive"]),
        ("callId=" + uuid + " state=active", [uuid, "11112222"]),
        ("device_name=Pavels-iPhone state=active", ["Pavels", "iPhone"]),
        ("ufrag=abcd1234efgh state=active", ["abcd1234efgh"]),
    ]
    for line, secrets in neg_cases:
        kept, body = redact_body(line, True, extract_attributes(line))
        shipped = body if kept else ""
        for sec in secrets:
            if sec.lower() in shipped.lower():
                failures.append("KV-NEG[%s]: %r survived in %r"
                                % (line.split("=")[0], sec, shipped))
    # the deny rules still win over the value grammar, booleans aside.
    for key, val, want in (("state", "active", True), ("callId", "none", False),
                           ("key", "true", False), ("psk", "false", False),
                           ("peer", "true", True), ("peer", "connected", False),
                           ("peerReadyAgeMs", "-1", True),
                           ("userCount", "3", True), ("userId", "3", False),
                           ("x", "1f3a9c", False), ("x", "deadbeefcafe", False),
                           ("uuid", "abc", False), ("mail", "bobby", False),
                           ("ufrag", "abcd", False), ("id", "abcd", False),
                           ("version", "1758433211", True),
                           ("phone", "1758433211", False),
                           ("x", "1758433211", False)):
        if _kv_is_benign(key, val) != want:
            failures.append("KV-GRAMMAR: _kv_is_benign(%r, %r) != %r"
                            % (key, val, want))
    # the private-use sentinels cannot be forged by a device line.
    forged = ("state=active " + KV_OPEN + chr(KV_IDX_BASE) + KV_CLOSE
              + " role=caller x" + KV_OPEN + chr(KV_IDX_BASE + 5) + KV_CLOSE)
    kept, body = redact_body(forged, True, extract_attributes(forged))
    if not kept or body.count("state=active") != 1 or any(
            0xE000 <= ord(c) <= 0xF8FF for c in body):
        failures.append("KV-SENTINEL: forged sentinel not neutralised: %r" % (body,))
    # more benign tokens than the per-body cap: the surplus is swept, not lost
    # to an IndexError and never restored wrongly.
    # keys = pairs of app-vocabulary words (audioVideo, ...): word-like, no deny
    # word, no unknown word -> every one is protectable until the cap.
    _kvw = sorted(w for w in APP_VOCAB
                  if w.isalpha() and 4 <= len(w) <= 7 and w not in _KV_DENY_WORDS)
    _kvkeys = []
    for _a in _kvw:
        for _b in _kvw:
            if _a != _b and _kv_is_benign(_a + _b.capitalize(), "1"):
                _kvkeys.append(_a + _b.capitalize())
        if len(_kvkeys) >= KV_MAX_PROTECTED + 50:
            break
    many = " ".join("%s=%d" % (_kvkeys[i], i % 7)
                    for i in range(KV_MAX_PROTECTED + 50))
    _t, _p = _protect_benign_kv(many)
    if len(_p) != KV_MAX_PROTECTED or _restore_kv(_t, _p) != many:
        failures.append("KV-CAP: protect/restore round trip failed at the cap")
    # keyed deny rules run even when the token would be benign by shape.
    if "[REDACTED" not in _scrub_body("callId=none role=caller"):
        failures.append("KV-DENY: callId=none was not masked")

    # 26. RED-TEAM HARDENING 2026-09-24 (W-FREEWORD / W-KEYWORDS / W-KVPRECISION-2).
    #     Compact version of scripts/test_ship_ios_redactor_hardening.py; every
    #     value is SYNTHETIC (the bytes 1..32 / letter runs / fixed words).
    def _enc(data, alphabet):
        n = int.from_bytes(data, "big")
        s = ""
        while n:
            n, r = divmod(n, len(alphabet))
            s = alphabet[r] + s
        return s

    def _body(line, tag="stdout"):
        _sc, _safe = resolve_scope(tag)
        _k, _b = redact_body(line, _safe, extract_attributes(line))
        return _b if _k else ""

    _syn = bytes(range(1, 33))
    # 26a. free words: letter blocks (base26 / base52) between structural tokens.
    for _alpha, _lab in (("abcdefghijklmnopqrstuvwxyz", "b26"),
                         ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", "b52")):
        _s = _enc(_syn, _alpha)
        for _k in (3, 5, 8, 11):
            _bl = [_s[i:i + _k] for i in range(0, len(_s), _k)]
            for _line in ("state=active " + " active ".join(_bl) + " ice=connected",
                          "ice=connected " + " retry=1 ".join(_bl) + " node=helsinki"):
                _got = [b for b in _bl if b in _body(_line).split()]
                if len(_got) > MAX_UNKNOWN_WORDS or any(len(b) >= 10 for b in _got):
                    failures.append("LEAK[freeword/%s/%d]: %d block(s) survived"
                                    % (_lab, _k, len(_got)))
    for _blk in ("aBcDeFgHiJk", "kXqJmZvBnRt", "1abcdefghij", "abcd\u0435fghijk"):
        if _blk in _body("state=active ice=connected %s role=caller" % _blk):
            failures.append("LEAK[freeword/shape]: %r survived" % _blk)
    _c = ["".join(chr(97 + (i * 7 + j * 3) % 26) for j in range(9)) for i in range(4)]
    for _mk, _lab in (("%s=true", "key"), ("x=%s", "value"), ("%s:", "emptyvalue")):
        _b = _body("state=active " + " ".join(_mk % c for c in _c))
        if sum(1 for c in _c if c in _b) > MAX_UNKNOWN_WORDS:
            failures.append("LEAK[freeword/kv-%s]: carrier tokens survived" % _lab)
    # 26b. kv-precision side channels (any key) + the legit forms that stay.
    for _line, _sec in (("chunk0=v1-abcdefgh state=active", "v1-abcdefgh"),
                        ("netSeq=192.168.1 state=active", "192.168.1"),
                        ("ver=203.0.113 state=active", "203.0.113"),
                        ("somethingCached=1758433211 state=active", "1758433211"),
                        ("epoch=v5-abcdefgh state=active", "v5-abcdefgh"),
                        ("state=abcdefghijk role=caller", "abcdefghijk")):
        if _sec in _body(_line):
            failures.append("LEAK[kv-channel]: %r survived in %r" % (_sec, _line))
    for _line in ("epoch=v5-ctrl wire=v4 state=active", "version=1.0.1177 state=active",
                  "selfver=1758433211 cached=1758433211 state=active"):
        if _body(_line) != _line:
            failures.append("REGRESS[kv-channel]: legit line altered: %r" % _line)
    # 26c. key-material words followed by a group are dropped whole, any content.
    for _line in ("(x.cc:1): secret [ABCDEF:GHIJKL] len 32",
                  "(x.cc:1): secret (ABCDEF:GHIJKL) slat << [] len 0",
                  "state=active raw_key [ABCD:EFGH] ice=connected",
                  "state=active salt [ab:cd] ice=connected",
                  "state=active slat (7) ice=connected",
                  "state=active derived_key ok ice=connected",
                  "state=active raw key computed ice=connected",
                  "state=active " + " ".join("k%d=%d" % (i, b) for i, b in enumerate(_syn))):
        if _body(_line):
            failures.append("LEAK[key-words]: line was not dropped: %r" % _line[:60])
    if not _body("state=active k0=1 k1=2 k2=3 k3=4 k4=5"):
        failures.append("REGRESS[key-words]: 5 indexed kv tokens must still ship")
    # 26d. identity word before the measure suffix.
    for _k, _v, _want in (("peerSessionIdMs", "1234567", False), ("userIdCount", "5", False),
                          ("peerReadyAgeMs", "-1", True), ("userCount", "3", True),
                          ("activationCount", "1", True), ("userId", "3", False)):
        if _kv_is_benign(_k, _v) != _want:
            failures.append("KV-IDENTITY: _kv_is_benign(%r, %r) != %r" % (_k, _v, _want))

    out("=" * 72)
    out("SELF-TEST: privacy redaction regression")
    out("=" * 72)
    if failures:
        for f in failures:
            out("  FAIL: " + f)
        out("")
        out("  RESULT: NO-GO (%d leak/regression)" % len(failures))
        return 1
    out("  26/26 cases pass: no forbidden value survived; structured telemetry")
    out("  still ships (benign key=value tokens kept, adversarial key=value")
    out("  secrets masked, sentinels unforgeable); call_id hashed;")
    out("  SSID/serial/SDP/SAS/plaintext blocked;")
    out("  join key matches the server leg incl. QUOTED form; 6/7-char floored;")
    out("  bare mixed-alnum secret tokens (8-11 char) hard-failed; blob + record")
    out("  ship order is oldest-first; --local-dir mirror mode lists/reads")
    out("  W417 blobs with canonical prod paths, ignores symlinks/non-W417;")
    out("  key-byte lists (derived_key / >=8 decimal or hex bytes) DROPPED whole;")
    out("  secret/slat/salt + bracket group, raw_key, indexed k0=..k5= bytes DROPPED;")
    out("  free-word blocks (base26/base52), kv side channels, identity+measure keys")
    out("  (peerSessionIdMs) masked; unknown words capped per body;")
    out("  restricted-exec ios-list parser / ios-cat reader accept only uuid paths.")
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
    ap.add_argument("--local-dir", type=str, default="",
                    help="read blobs from a LOCAL directory (e.g. the nightly "
                         "mirror /opt/bcrypto/fullbackup/staging/files) instead "
                         "of SSH/SFTP: no VPS credentials needed, read-only. "
                         "The mirror is up to ~24h stale; for a catch-up use a "
                         "large --minutes and --limit (state dedups)")
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

    # The host is resolved lazily by _ensure_creds() inside ssh_connect(), so
    # printing VPS_HOST before connecting always said "None" — which is the one
    # line that would have shown, instantly, that a run was talking to the
    # decommissioned IONOS box instead of prod. Resolve first, then announce.
    local_map = None
    client = None
    ro_mode = False
    if args.local_dir:
        # LOCAL-MIRROR mode: no SSH, no SFTP, no VPS credentials.
        if not os.path.isdir(args.local_dir):
            print("ERROR: --local-dir %s is not a directory." % args.local_dir,
                  file=sys.stderr)
            sys.exit(1)
        local_map = {}
        print("=== LOCAL mirror %s (read-only, no SSH) ===" % args.local_dir)
    else:
        _ensure_creds()
        ro_mode = bool(_ios_ro_key_path())
        print("=== bcrypto-server SSH @ %s as %s (%s) ==="
              % (VPS_HOST, VPS_USER,
                 "restricted-exec: ios-list/ios-cat only, no SFTP" if ro_mode
                 else "read-only"))
        client = ssh_connect()
        print("Connected.")

    blobs_read = 0
    blobs_skipped_state = 0
    blobs_too_old = 0
    blobs_not_w417 = 0
    lines_shipped = 0
    lines_dropped = 0
    http_results = []  # (blob_path, status)

    try:
        print("\n=== Listing device W417 chunks (last %d min, <=%d) ==="
              % (args.minutes, args.limit))
        if local_map is not None:
            files = list_local_chunks(args.local_dir, args.minutes, args.limit,
                                      local_map)
        elif ro_mode:
            files = list_chunks_exec(client, args.minutes, args.limit)
        else:
            files = list_device_chunks(client, args.minutes, args.limit)
        print("Found %d candidate blobs." % len(files))
        # Ship oldest-first: see order_blobs_oldest_first() docstring. This
        # only reorders the already-limited (newest-N) selection above.
        files = order_blobs_oldest_first(files)

        sftp = client.open_sftp() if (client is not None and not ro_mode) else None
        try:
            for mtime_s, size_s, path in files:
                if ro_mode and unchanged_since_shipped(state, path, mtime_s,
                                                       size_s):
                    blobs_skipped_state += 1
                    continue
                txt = read_chunk_blob(sftp, path, size_s, local_map,
                                      exec_client=client if ro_mode else None)
                if txt is None:
                    blobs_not_w417 += 1
                    continue

                sig = chunk_line_signature(txt)
                if already_shipped(state, path, sig):
                    blobs_skipped_state += 1
                    if ro_mode:  # backfill mt/sz so the next run skips it unread
                        record_shipped(state, path, sig,
                                       state["blobs"][path].get("lines", 0),
                                       mtime_s, size_s)
                    continue

                header, records = parse_chunk(txt)
                if not records:
                    record_shipped(state, path, sig, 0, mtime_s, size_s)
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
                    record_shipped(state, path, sig, 0, mtime_s, size_s)
                    http_results.append((path, "no-records"))
                    continue

                blob_ok = True
                blob_too_old = False
                blob_retryable_fail = False
                for sub in _split_request_into_batches(request, args.batch):
                    status, resp_body = post_otlp(args.endpoint, token, sub)
                    http_results.append((path, status))
                    if status != 204:
                        blob_ok = False
                        snippet = (resp_body or "").strip().replace("\n", " ")
                        # Loki refuses any entry more than ~1h behind the newest
                        # already in the stream ("entry too far behind"). That
                        # verdict is PERMANENT: the window only moves forward,
                        # so this blob can never be accepted, and leaving its
                        # state unadvanced means re-reading and re-POSTing it on
                        # every single future run. qa-logs.ps1 now ships on every
                        # log read, which turned a one-off annoyance into 39
                        # doomed POSTs per invocation, forever.
                        if is_permanent_age_reject(status, resp_body):
                            blob_too_old = True
                        else:
                            # A timeout, a 5xx or a dropped connection is
                            # retryable, and the blob must NOT be marked handled
                            # or that batch is lost for good. Caught in review:
                            # deciding "too old" from ANY too-old batch would
                            # drop the retryable ones alongside it whenever a
                            # multi-batch blob failed both ways at once.
                            blob_retryable_fail = True
                        print("  POST %s -> HTTP %s %s"
                              % (path, status, _ascii(snippet[:200])),
                              file=sys.stderr)
                if blob_ok:
                    record_shipped(state, path, sig, kept, mtime_s, size_s)
                elif blob_too_old and not blob_retryable_fail:
                    # Recorded as handled so it is not retried. `--reset-state`
                    # brings it back if Loki's out-of-order window is ever
                    # widened and the backlog becomes shippable again.
                    record_shipped(state, path, sig, 0, mtime_s, size_s)
                    blobs_too_old += 1
        finally:
            if sftp is not None:
                sftp.close()
    finally:
        if client is not None:
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
    out("  blobs skipped (not W417/too big/unreadable): %d" % blobs_not_w417)
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
        if blobs_too_old:
            out("  blobs too old/behind (Loki age verdict): %d  (state advanced, never retried)"
                % blobs_too_old)
        if bad:
            out()
            retryable = bad - blobs_too_old
            if retryable > 0:
                out("  NOTE: %d POST(s) failed for a retryable reason. State was"
                    % retryable)
                out("        NOT advanced; a re-run will retry them.")
            if blobs_too_old:
                out("  NOTE: %d blob(s) rejected as 'too far behind / too old'. Loki's"
                    % blobs_too_old)
                out("        window only moves forward, so that verdict is permanent:")
                out("        recorded as handled, NOT retried. Use --reset-state if")
                out("        the out-of-order window is ever widened.")
    else:
        out()
        out("  (dry-run: nothing shipped, state untouched. Eyeball the OTLP")
        out("   bodies above to confirm redaction before a real run.)")
    out("=" * 72)


if __name__ == "__main__":
    main()
