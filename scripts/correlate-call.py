#!/usr/bin/env python3
"""
correlate-call.py -- correlate ONE call across the iOS device (W417 chunks)
and the bcrypto-server journal, into a single time-ordered timeline.

This is a SAFE, read-only dev-box tool. It:
  - SSHes to the prod VPS the SAME way fetch-ios-live.py does
    (env vars QAUDION_VPS_HOST/USER/PASS, else bcrypto-server/VPS_ACCESS.md)
  - reads recent W417 device chunks via SFTP (read only, <=256KB blobs)
  - runs ONE `journalctl -u bcrypto-server` read (no writes, no restart)
  - filters BOTH sides for the call id (case-insensitive, full-or-short8)
  - merges + stable-sorts ascending by ms, prints a [DEV]/[SRV] timeline

NO app build. NO prod write. NO external LLM. NO data leaves the box.

Why case-insensitive + short8: the server stores d.CallID verbatim (no
ToLower/ToUpper) but MANY server log sites emit only short8(d.CallID), while
the device may log the full UPPERCASE UUID or a lowercased short-8 form with a
trailing ellipsis. So a line matches if EITHER the normalized full id OR its
first 8 chars appears on EITHER side. Everything is lowercased and the trailing
ellipsis/dots are stripped before comparison.

Usage:
  python scripts/correlate-call.py --call-id 91FE5CF7-3572-42F1-9B84-29883F47BAB6
  python scripts/correlate-call.py --call-id 91fe5cf7
  python scripts/correlate-call.py --last-failed
  python scripts/correlate-call.py --last-failed --minutes 240 --limit 300

Options:
  --call-id        Full UUID, short-8, lowercase/uppercase, or numeric form.
  --last-failed    Auto-pick the most recent device call id whose msg carries a
                   failure marker AS A WHOLE TOKEN (failed, half_open,
                   no_peer_media, ice, error, unseal; endCall is a weak
                   fallback). Token-matched so 'device'/'service'/'voice' do NOT
                   count as ICE and 'no error' does NOT count as an error.
  --minutes        Lookback window in minutes (default 120).
  --limit          Max device chunks to download (default 200).
  --service-lines  journalctl -n value (default 4000).

Requires:
  - paramiko (`pip install paramiko`)
  - VPS credentials (env vars or bcrypto-server/VPS_ACCESS.md), same as
    fetch-ios-live.py.
"""

import os
import re
import sys
import json
import argparse
from datetime import datetime, timezone
from pathlib import Path

try:
    import paramiko
except ImportError:
    print("ERROR: paramiko not installed. `pip install paramiko`", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# VPS creds + SSH helpers -- duplicated from fetch-ios-live.py (NOT imported:
# that module is hyphenated and loads creds at import time; we keep these tools
# independent and importlib-free per the integration spec).
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


VPS_HOST = None
VPS_USER = None
VPS_PASS = None
DATA_DIR = "/opt/bcrypto/data/files"
SERVICE_UNIT = "bcrypto-server"  # systemd unit name (binary is bcrypto-lite)


def _ensure_creds():
    """Lazy-load VPS creds so --loki (pure HTTP, no SSH) never needs the VPS /
    VPS_ACCESS.md -- honors the tool's 'no SSH / no VPS creds needed' contract.
    Only the SSH-blob backend (ssh_connect) triggers the load."""
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
# Matching
# ---------------------------------------------------------------------------

# Failure markers used by --last-failed and by the outcome guess.
# STRONG markers are unambiguous failures; "endcall" is included per the spec
# but is WEAK (a clean endCall state=encrypted is a SUCCESS), so --last-failed
# only falls back to a weak marker when no strong one is present in the window.
#
# IMPORTANT: each marker is matched as a WORD-BOUNDARY token, never as a bare
# substring. A bare "ice" substring matches "device", "service", "voice",
# "invoice" -- words that saturate voice-call logs -- and a bare "error"
# matches "no error". Both bugs caused --last-failed to pick the WRONG call.
# We compile a single \b-anchored alternation. "no_peer_media"/"half_open" keep
# their underscores (\b sits at the alnum boundary, so 'no_peer_media' still
# matches as a whole token). "endcall" also matches camelCase "endCall" once the
# haystack is lowercased.
STRONG_FAIL_MARKERS = ["failed", "half_open", "no_peer_media", "ice", "error", "unseal"]
WEAK_FAIL_MARKERS = ["endcall"]
FAIL_MARKERS = STRONG_FAIL_MARKERS + WEAK_FAIL_MARKERS


def _compile_markers(markers):
    """Compile markers into one \b-anchored, case-insensitive alternation so a
    marker matches only as a delimited token, never inside a longer word."""
    alt = "|".join(re.escape(m) for m in markers)
    return re.compile(r"\b(?:%s)\b" % alt, re.IGNORECASE)


_STRONG_RE = _compile_markers(STRONG_FAIL_MARKERS)
_WEAK_RE = _compile_markers(WEAK_FAIL_MARKERS)


def _has_marker(text, marker_re):
    """True if any failure marker appears as a whole token in text."""
    return bool(marker_re.search(text or ""))

# Extract a callId token from a device msg or a server line. Accepts the
# key forms the codebase emits: callId=, call_id=, callID=. Captures a UUID,
# a numeric run, or a short alnum prefix, allowing a trailing ellipsis/dots.
_CALLID_RE = re.compile(
    r"call[_]?id\s*[=:]\s*([0-9a-fA-F][0-9a-fA-F\-]{3,}|\d{4,})",
    re.IGNORECASE,
)


_ELLIPSIS = "\u2026"  # HORIZONTAL ELLIPSIS escape (source pure-ASCII)


def normalize_id(raw):
    """Lowercase, strip trailing ellipsis (unicode U+2026 and ASCII dots) and
    whitespace. Returns the normalized id string."""
    if raw is None:
        return ""
    s = raw.strip()
    # Strip a trailing unicode ellipsis, ASCII dots, and surrounding whitespace.
    s = s.rstrip()
    s = s.rstrip(_ELLIPSIS)
    s = s.rstrip(".")
    s = s.rstrip(_ELLIPSIS)
    return s.strip().lower()


# A short id (short8 or a short full id) is only trusted when it sits next to a
# callId key, e.g. "call_id=91fe5cf7", "callid:91fe5cf7", "callID 91fe5cf7".
# This prevents a short hex prefix from colliding with an unrelated user/key/
# earbud hash slice that happens to share the same first 8 hex, and prevents a
# short numeric id from matching inside a longer number. {sid} is filled with
# the (regex-escaped) short id; the trailing (?![0-9a-z]) stops 'abc' from
# matching inside 'abcd' while still allowing a trailing ellipsis/space/quote.
_CALLID_KEY_CTX = r"call[ _]?id\s*[=:]?\s*[\"'`]?{sid}(?![0-9a-z])"

# A "long" id (>=12 chars, e.g. a full UUID or a long UUID prefix) is specific
# enough that a bare substring hit is safe -- no anchoring needed.
_LONG_ID_MIN = 12
# Below this length we refuse to match at all unless the key context is present.
_SHORT_ID_MIN = 6


def build_matcher(call_id):
    """Return (predicate, norm, short8). predicate(line_lower) -> bool.

    Matching tiers (lowercased haystack assumed):
      * norm is "long" (>= _LONG_ID_MIN chars): a bare substring hit is safe
        (full UUID / long prefix has negligible collision odds).
      * norm is "short" (>= _SHORT_ID_MIN, < _LONG_ID_MIN): a bare substring is
        NOT trusted (it collides with user/key/earbud short8 hashes and with
        substrings of longer numbers). It only matches adjacent to a callId key.
      * short8 (first 8 chars of a long norm) is ALSO key-anchored for the same
        reason; the long norm already covers the safe full-substring case.
      * norm shorter than _SHORT_ID_MIN: rejected (too ambiguous) -- callers are
        told to pass at least the 8-char prefix or the full UUID.
    """
    norm = normalize_id(call_id)
    short8 = norm[:8] if len(norm) >= 8 else ""

    long_substr = norm if len(norm) >= _LONG_ID_MIN else ""

    key_anchored = []
    if _SHORT_ID_MIN <= len(norm) < _LONG_ID_MIN:
        key_anchored.append(norm)
    if short8 and len(short8) >= _SHORT_ID_MIN:
        key_anchored.append(short8)

    key_res = [
        re.compile(_CALLID_KEY_CTX.format(sid=re.escape(s)), re.IGNORECASE)
        for s in dict.fromkeys(key_anchored)  # de-dup, order-stable
    ]

    def predicate(line_lower):
        if long_substr and long_substr in line_lower:
            return True
        for kr in key_res:
            if kr.search(line_lower):
                return True
        return False

    return predicate, norm, short8


def iso_to_ms(ts):
    """Parse an ISO8601 ms-Zulu timestamp ('2026-06-23T07:08:46.134Z') to epoch
    ms (UTC). Returns float ms, or None on failure."""
    if not ts:
        return None
    s = ts.strip()
    # Device ts is '...Z'; tolerate fractional seconds of varied precision and
    # an optional Z or +00:00.
    try:
        # Fast path: the exact device/server-text-handler shape.
        dt = datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ")
        return dt.replace(tzinfo=timezone.utc).timestamp() * 1000.0
    except ValueError:
        pass
    # Generic fallback via fromisoformat (Python 3.11+ handles 'Z').
    try:
        s2 = s.replace("Z", "+00:00") if s.endswith("Z") else s
        dt = datetime.fromisoformat(s2)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).timestamp() * 1000.0
    except ValueError:
        return None


def ms_to_hms(ms):
    """Render epoch ms (UTC) as HH:MM:SS.mmm."""
    dt = datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)
    return dt.strftime("%H:%M:%S.") + ("%03d" % int(ms % 1000))


def _ascii(s):
    """Force ASCII so output is safe on any console codepage (cp1252 etc).
    Device msgs carry unicode (em-dash, ellipsis); replace rather than crash."""
    return s.encode("ascii", "replace").decode("ascii")


def out(line=""):
    print(_ascii(line))


# ---------------------------------------------------------------------------
# Device side (W417 chunks)
# ---------------------------------------------------------------------------

def _is_w417_first_line(first_line):
    iso_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
    return (
        bool(iso_re.match(first_line))
        or first_line.startswith('{"type":"header"')
        or first_line.startswith('{"ts"')
    )


def list_device_chunks(client, minutes, limit):
    """find recent W417 blobs; returns list of (mtime, size, path) newest first."""
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


def read_device_lines(client, files):
    """SFTP-read each W417 chunk; return a flat list of parsed NDJSON objects.

    Each element: dict with keys ms, lvl, tag, msg, raw (the original line).
    Header lines (no ts) are skipped. Returns objects from ALL chunks, NOT yet
    filtered by call id (caller filters)."""
    records = []
    sftp = client.open_sftp()
    try:
        for mtime_s, size_s, path in files:
            if size_s == 0 or size_s > 256 * 1024:
                continue
            try:
                with sftp.open(path, "rb") as rf:
                    blob = rf.read()
            except Exception as e:
                print(f"  skip {path}: {e}", file=sys.stderr)
                continue
            try:
                txt = blob.decode("utf-8")
            except UnicodeDecodeError:
                continue
            first_line = txt.split("\n", 1)[0] if txt else ""
            if not _is_w417_first_line(first_line):
                continue
            for line in txt.split("\n"):
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:  # json.JSONDecodeError subclasses ValueError
                    continue
                ts = obj.get("ts")
                if not ts:
                    continue  # header line or non-event
                ms = iso_to_ms(ts)
                if ms is None:
                    continue
                records.append({
                    "ms": ms,
                    "lvl": obj.get("lvl", "I"),
                    "tag": obj.get("tag", ""),
                    "msg": obj.get("msg", ""),
                    "raw": line,
                })
    finally:
        sftp.close()
    return records


def pick_last_failed_call_id(device_records):
    """Scan device records for the most-recent line whose msg carries a failure
    marker AND a callId; return that callId string (verbatim, as logged) or None.

    A STRONG failure (half_open/no_peer_media/ICE/error/unseal/failed) always
    wins over a WEAK one (endCall, which can be a clean success). Only if no
    strong-failure line exists in the window do we fall back to the latest weak
    marker."""
    def scan(marker_re):
        best_ms = None
        best_id = None
        for rec in device_records:
            msg = rec.get("msg", "") or ""
            # \b-token match, NOT a bare substring: avoids 'ice' in 'device',
            # 'error' in 'no error', etc.
            if not _has_marker(msg, marker_re):
                continue
            m = _CALLID_RE.search(msg)
            if not m:
                continue
            if best_ms is None or rec["ms"] >= best_ms:
                best_ms = rec["ms"]
                best_id = m.group(1)
        return best_id

    return scan(_STRONG_RE) or scan(_WEAK_RE)


# ---------------------------------------------------------------------------
# Server side (journalctl)
# ---------------------------------------------------------------------------

# Leading journald short-iso-precise prefix, e.g. "2026-06-23T07:08:46.130000+0000".
_JOURNAL_TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}:?\d{2}|Z)?)"
)
# Go slog text-handler's own time= field (Zulu ms).
_GO_TIME_RE = re.compile(r"\btime=(\S+)")
_GO_LEVEL_RE = re.compile(r"\blevel=(\w+)")


def read_server_lines(client, predicate, service_lines):
    """ONE read-only journalctl call; return matching records as dicts with
    ms, lvl, text. Uses -o short-iso-precise so every line has a parseable
    leading timestamp even if its own time= differs."""
    cmd = (
        f"journalctl -u {SERVICE_UNIT} -n {service_lines} --no-pager "
        f"-o short-iso-precise"
    )
    stdout_text, err = run(client, cmd)
    if err.strip():
        print("STDERR (journalctl):", err.strip(), file=sys.stderr)
    records = []
    for line in stdout_text.split("\n"):
        line = line.rstrip("\r")
        if not line:
            continue
        if not predicate(line.lower()):
            continue
        # Prefer the Go time= field (matches the device clock convention); fall
        # back to the journald short-iso-precise prefix.
        ms = None
        gt = _GO_TIME_RE.search(line)
        if gt:
            ms = iso_to_ms(gt.group(1))
        if ms is None:
            jt = _JOURNAL_TS_RE.match(line)
            if jt:
                ms = iso_to_ms(jt.group(1))
        if ms is None:
            continue
        lvl_m = _GO_LEVEL_RE.search(line)
        lvl = lvl_m.group(1) if lvl_m else "INFO"
        records.append({"ms": ms, "lvl": lvl, "text": line})
    return records


# ---------------------------------------------------------------------------
# Loki query backend (ADDITIVE -- selected by --loki; the SSH path above stays
# the default). Pure stdlib: urllib for HTTP, base64 for HTTP Basic. No new dep.
#
# Topology (all anchors verified in-tree):
#   * Query route: GET https://dash.bcrypto.com/loki/api/v1/query_range
#     -> Caddy @lq path /loki/* -> basic_auth { admin ... } -> reverse_proxy
#     loki:3100 (caddy/Caddyfile:35-42). So HTTP Basic, user 'admin'.
#   * Loki 3.4.1, schema v13, allow_structured_metadata: true (loki/loki.yml:39,
#     compose :125). No *_as_index_labels promotion is configured, so the OTLP
#     record attribute qa.call.short8 lands in STRUCTURED METADATA keyed
#     qa_call_short8 (OTLP dots->underscores), NOT as a stream-label selector.
#     => the maintainer-intended query (ship-server-logs.py:12) is
#          {service_name=~"qaudion.*"} | qa_call_short8=`<short8>`
#     We run THIS pipeline-filter form as the single source of truth: in Loki
#     3.x the `| qa_call_short8=` filter matches qa_call_short8 whether it is a
#     stream label OR structured metadata, so no label-selector fast path is
#     needed (and one would risk returning a partial, stream-label-only result).
#   * service.name emitted: qaudion-ios (ship-ios-logs.py:754),
#     qaudion-server (ship-server-logs.py:763). Android/Desktop are mapped for
#     forward-compat even though no shipper exists yet.
# ---------------------------------------------------------------------------

import urllib.request   # noqa: E402  (kept local to the Loki backend block)
import urllib.error     # noqa: E402
import urllib.parse     # noqa: E402
import base64           # noqa: E402
import time             # noqa: E402


# service_name (OTLP service.name -> Loki stream label service_name) -> the
# short side-tag used in the rendered timeline. Forward-compat: the android /
# desktop names have no shipper yet but are mapped so the renderer is ready.
_SERVICE_TAG = {
    "qaudion-ios": "IOS",
    "qaudion-server": "SRV",
    "qaudion-android": "AND",
    "qaudion-desktop": "DESK",
}


def _service_tag(service_name):
    """Map a Loki service_name label to a [IOS]/[AND]/[DESK]/[SRV] side tag.
    Anything unrecognized renders as [unknown] so a new shipper is never hidden."""
    return _SERVICE_TAG.get((service_name or "").strip(), "unknown")


_SHORT8_HEX_RE = re.compile(r"^[0-9a-f]{8}$")


def _loki_logql(short8, line_grep=False):
    """Build the LogQL query string for one short8.

    CALLER CONTRACT: short8 MUST be a validated 8-char lowercase hex string
    (^[0-9a-f]{8}$). On the EMIT side this is guaranteed by ship-ios-logs.py's
    _RE_CALLID_VALUE ([0-9a-fA-F][0-9a-fA-F-]{3,}) gating call_short8. On the
    QUERY side normalize_id()/build_matcher() do NOT enforce hex (they only
    lowercase + strip), so run_loki_backend() validates short8 against
    _SHORT8_HEX_RE BEFORE any query is built. This function re-asserts the
    invariant as a defense-in-depth guard: a stray double-quote or backtick in
    short8 would otherwise break the LogQL literal. With the hex guarantee the
    value is injection-safe; it is still backtick-wrapped (raw string literal)
    and the whole query= param is urlencoded by the caller.

      line_grep=True : {service_name=~"qaudion.*"} |~ `(?i)X`
          opt-in (--loki-linegrep) CASE-INSENSITIVE regex grep for legs that put
          short8 in the body but never as an attribute (e.g. raw journald lines
          that did not pass through the shipper). short8 is lowercased by
          normalize_id() but 1:1 call sites log the call_id in its original
          UPPERCASE form, so a case-SENSITIVE |= would miss exactly those raw
          lines; (?i) makes the filter match both cases. short8 is [0-9a-f]{8}
          so it is already regex-safe (no metacharacters).
      default        : {service_name=~"qaudion.*"} | qa_call_short8=`X`
          the pipeline / structured-metadata filter -- the SOURCE OF TRUTH here.
          Matches both stream-label and structured-metadata placements of
          qa_call_short8 in Loki 3.x. Byte-for-byte the maintainer-intended
          query (ship-server-logs.py:12).
    """
    if not _SHORT8_HEX_RE.match(short8 or ""):
        raise ValueError(
            "refusing to build LogQL for non-hex short8 %r (expected ^[0-9a-f]{8}$)"
            % (short8,))
    if line_grep:
        return '{service_name=~"qaudion.*"} |~ `(?i)%s`' % short8
    return '{service_name=~"qaudion.*"} | qa_call_short8=`%s`' % short8


def _loki_query_once(url, user, pw, logql, start_ns, end_ns, limit=5000):
    """One GET to Loki query_range. Returns (status_int, json_obj_or_None,
    raw_body_text). Never raises on HTTP error status -- HTTPError bodies are
    captured so the caller can inspect a 400 'unknown label' parse error and
    decide to fall back. Network/decode failures raise so main() can report."""
    params = urllib.parse.urlencode({
        "query": logql,
        "start": str(start_ns),
        "end": str(end_ns),
        "limit": str(limit),
        "direction": "forward",
    })
    full = url + ("&" if "?" in url else "?") + params
    req = urllib.request.Request(full, method="GET")
    basic = base64.b64encode(("%s:%s" % (user, pw)).encode("utf-8")).decode("ascii")
    req.add_header("Authorization", "Basic " + basic)
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = resp.getcode()
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        status = e.code
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
    obj = None
    try:
        obj = json.loads(body)
    except ValueError:
        obj = None
    return status, obj, body


def _loki_streams(obj):
    """Extract the stream list from a query_range JSON response, or [] if the
    shape is not the expected success/streams result. Tolerates missing keys."""
    if not isinstance(obj, dict):
        return []
    if obj.get("status") != "success":
        return []
    data = obj.get("data") or {}
    if data.get("resultType") != "streams":
        # query_range on a log selector always yields 'streams'; anything else
        # (e.g. 'matrix' from a metric query) carries no log lines for us.
        return []
    result = data.get("result")
    return result if isinstance(result, list) else []


def query_loki(url, user, pw, short8, minutes, line_grep=False):
    """Run the ONE source-of-truth LogQL query and return a flat list of
    timeline records: dicts with ms, side, lvl, text. Window = max(minutes, 120)
    ending now. Raises RuntimeError with a clear message on a hard HTTP/transport
    error so main() prints it and exits non-zero (never crashes a traceback).

    Single query by design. The default pipeline-filter form
        {service_name=~"qaudion.*"} | qa_call_short8=`X`
    already matches qa_call_short8 whether Loki stores it as a stream label OR
    as structured metadata (Loki 3.x), so there is NO label-selector fast path:
    a fast path could short-circuit on a PARTIAL stream-label-only result and
    silently drop the structured-metadata legs. --loki-linegrep swaps in the
    case-insensitive body-regex form instead (opt-in)."""
    window_min = max(minutes, 120)
    end_ns = int(time.time() * 1_000_000_000)
    start_ns = end_ns - window_min * 60 * 1_000_000_000

    logql = _loki_logql(short8, line_grep=line_grep)
    label = "line-grep" if line_grep else "pipeline-filter"

    status, obj, body = _loki_query_once(url, user, pw, logql, start_ns, end_ns)

    if status == 401 or status == 403:
        raise RuntimeError(
            "Loki auth failed (HTTP %d). Check --loki-user/--loki-pw "
            "(QA_LOKI_QUERY_PW). Caddy basic_auth gates /loki/*." % status)
    if status >= 500:
        raise RuntimeError(
            "Loki server error (HTTP %d): %s"
            % (status, (body or "").strip()[:300]))
    if status >= 400:
        raise RuntimeError(
            "Loki query rejected (HTTP %d) for %s form: %s"
            % (status, label, (body or "").strip()[:300]))

    streams = _loki_streams(obj)
    if not streams:
        return []  # 200 with no match in the window
    return _loki_records_from_streams(streams)


def _loki_records_from_streams(streams):
    """Flatten Loki streams [{stream:{labels}, values:[[ts_ns, line], ...]}] into
    timeline records. ts_ns is a nanosecond string; we store ms (float) so the
    merge sort matches the device/server ms convention. Sorting on ts_ns is
    preserved exactly because ms is monotonic in ns."""
    records = []
    for s in streams:
        if not isinstance(s, dict):
            continue
        labels = s.get("stream") or {}
        service_name = labels.get("service_name", "")
        side = _service_tag(service_name)
        # severity/level may arrive as a label (detected_level) or structured
        # metadata; fall back to a neutral tag.
        lvl = (labels.get("detected_level")
               or labels.get("level")
               or labels.get("severity")
               or "")
        values = s.get("values") or []
        for pair in values:
            if not (isinstance(pair, list) and len(pair) >= 2):
                continue
            ts_ns_raw, line = pair[0], pair[1]
            try:
                ts_ns = int(ts_ns_raw)
            except (TypeError, ValueError):
                continue
            records.append({
                "ms": ts_ns / 1_000_000.0,
                "ts_ns": ts_ns,
                "side": side,
                "service_name": service_name,
                "lvl": lvl or "",
                "text": line if isinstance(line, str) else str(line),
            })
    return records


def render_loki(timeline, short8, norm, window_min, line_grep):
    """Render the unified cross-platform Loki timeline. Tags each leg
    [IOS]/[AND]/[DESK]/[SRV]/[unknown] by its service_name."""
    out()
    out("=" * 72)
    out("CALL CORRELATION TIMELINE  (backend: Loki / dash.bcrypto.com)")
    out("times are UTC; legs are tagged by OTLP service.name")
    out("matcher: full='%s'  short8='%s'  window=%d min  query=%s"
        % (norm or "(none)", short8 or "(none)", window_min,
           "line-grep" if line_grep else "pipeline-filter"))
    out("=" * 72)

    if not timeline:
        out()
        out("0 correlated lines from Loki for short8='%s'." % short8)
        out("  Nothing matched in the last %d min on any qaudion.* service."
            % window_min)
        out()
        out("Checks: (1) widen --minutes; (2) confirm a shipper "
            "(ship-ios-logs.py / ship-server-logs.py) is running and POSTing")
        out("        to the OTLP ingest; (3) try --loki-linegrep for legs that "
            "carry short8 only in the body, not as an attribute.")
        return

    # Per-service counts for the summary.
    counts = {}
    for rec in timeline:
        counts[rec["side"]] = counts.get(rec["side"], 0) + 1

    for rec in timeline:
        hms = ms_to_hms(rec["ms"])
        lvl = rec.get("lvl", "") or "-"
        label = ("%s/%s" % (lvl, rec["side"]))[:14]
        out("%s [%-7s] %-14s %s" % (hms, rec["side"], label, rec["text"]))

    first = ms_to_hms(timeline[0]["ms"])
    last = ms_to_hms(timeline[-1]["ms"])
    span_ms = timeline[-1]["ms"] - timeline[0]["ms"]
    out()
    out("-" * 72)
    out("SUMMARY")
    parts = ", ".join("%d %s" % (counts[k], k) for k in sorted(counts))
    out("  %d lines (%s)" % (len(timeline), parts))
    out("  window [%s .. %s]  span %.3fs" % (first, last, span_ms / 1000.0))
    out("  outcome guess: %s" % guess_outcome(timeline))
    out("-" * 72)


def run_loki_backend(args, call_id):
    """Pure-HTTP Loki path. Derives short8 the SAME way as the SSH path (reuse
    build_matcher -> normalize_id), validates it is 8-char hex, queries Loki
    with the single pipeline-filter source-of-truth form, and renders the
    cross-platform timeline. Returns an exit code."""
    predicate, norm, short8 = build_matcher(call_id)
    if not short8:
        # build_matcher only yields short8 when len(norm) >= 8 (line 213) -- the
        # SAME >= 8 floor the shippers honor (ship-ios-logs.py:617-635). Without
        # it there is no join key the emit side ever produced.
        print("ERROR: need >= 8 chars (full UUID or 8-char prefix) for a Loki "
              "join. Got normalized id '%s'." % (norm or ""), file=sys.stderr)
        return 1

    # HEX GUARD (must-fix): normalize_id()/build_matcher() only lowercase + strip
    # -- they do NOT enforce hex. The emit-side join key, by contrast, is gated
    # by ship-ios-logs.py:_RE_CALLID_VALUE to [0-9a-fA-F-]{4,}, so the only short8
    # that can EVER appear in Loki is 8-char lowercase hex. Reject anything else
    # here: (1) a non-hex prefix can never match a value the shipper produced, so
    # it is a guaranteed-empty query; (2) a stray double-quote/backtick would
    # break the LogQL literal. Fail fast on the same >= 8-char error path.
    if not _SHORT8_HEX_RE.match(short8):
        print("ERROR: call-id prefix '%s' is not 8-char hex. The Loki join key "
              "(qa.call.short8) is always [0-9a-f]{8} (ship-ios-logs.py emit "
              "regex); pass the real UUID or its 8-char hex prefix."
              % short8, file=sys.stderr)
        return 1

    loki_pw = args.loki_pw or os.environ.get("QA_LOKI_QUERY_PW", "")
    if not loki_pw:
        print("ERROR: no Loki password. Set env QA_LOKI_QUERY_PW or pass "
              "--loki-pw.", file=sys.stderr)
        return 1

    window_min = max(args.minutes, 120)
    print("=== Loki query @ %s (basic_auth user=%s) ==="
          % (args.loki_url, args.loki_user))
    print("short8=%s  window=%d min  query=%s"
          % (short8, window_min,
             "line-grep" if args.loki_linegrep else "pipeline-filter"))
    try:
        timeline = query_loki(args.loki_url, args.loki_user, loki_pw, short8,
                              args.minutes, line_grep=args.loki_linegrep)
    except urllib.error.URLError as e:
        print("ERROR: cannot reach Loki at %s: %s"
              % (args.loki_url, getattr(e, "reason", e)), file=sys.stderr)
        return 1
    except RuntimeError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 1

    # Stable ascending sort by nanosecond timestamp (ts_ns is the authoritative
    # key; ms is derived and monotonic in ns).
    timeline.sort(key=lambda r: r.get("ts_ns", int(r["ms"] * 1_000_000)))
    render_loki(timeline, short8, norm, window_min, args.loki_linegrep)
    return 0


# ---------------------------------------------------------------------------
# Merge + render
# ---------------------------------------------------------------------------

def guess_outcome(timeline):
    """Heuristic single-word outcome from the merged timeline.

    Uses the SAME \b-token marker matching as --last-failed so 'device'/'voice'
    never count as ICE and 'no error' never counts as an error."""
    joined = " ".join(t["text"].lower() for t in timeline)
    has = lambda tok: bool(re.search(r"\b%s\b" % re.escape(tok), joined))
    if has("no_peer_media") or has("half_open"):
        return "FAILED (no peer media / half-open)"
    if has("unseal") and (has("fail") or has("failed") or has("error")):
        return "FAILED (unseal error)"
    if has("failed") or has("error"):
        return "FAILED (error markers present)"
    if has("endcall") and has("encrypted"):
        return "OK (endCall, state=encrypted)"
    if has("endcall"):
        return "ended (endCall, state unknown)"
    return "unknown (no terminal marker found)"


def render(timeline, dev_count, srv_count, norm, short8):
    out()
    out("=" * 72)
    out("CALL CORRELATION TIMELINE")
    out("times are UTC (server text handler and device ts are both Zulu;")
    out("the two clocks may drift -- W574-class bugs show as ORDERING,")
    out("not absolute skew)")
    out("matcher: full='%s'  short8='%s'" % (norm or "(none)", short8 or "(none)"))
    out("=" * 72)

    if not timeline:
        out()
        out("0 correlated lines. Nothing matched on either side.")
        out("  device matched lines: %d" % dev_count)
        out("  server matched lines: %d" % srv_count)
        out()
        out("Try a wider --minutes / --service-lines, or verify the call id.")
        return

    for rec in timeline:
        side = rec["side"]
        hms = ms_to_hms(rec["ms"])
        if side == "DEV":
            tag = rec.get("tag", "") or ""
            lvl = rec.get("lvl", "I") or "I"
            label = ("%s/%s" % (lvl, tag))[:12]
            out("%s [DEV] %-12s %s" % (hms, label, rec["text"]))
        else:
            lvl = rec.get("lvl", "INFO") or "INFO"
            label = ("%s/srv" % lvl)[:12]
            out("%s [SRV] %-12s %s" % (hms, label, rec["text"]))

    first = ms_to_hms(timeline[0]["ms"])
    last = ms_to_hms(timeline[-1]["ms"])
    span_ms = timeline[-1]["ms"] - timeline[0]["ms"]
    out()
    out("-" * 72)
    out("SUMMARY")
    out("  %d device lines, %d server lines (%d total)"
        % (dev_count, srv_count, len(timeline)))
    out("  window [%s .. %s]  span %.3fs" % (first, last, span_ms / 1000.0))
    out("  outcome guess: %s" % guess_outcome(timeline))
    out("-" * 72)


def main():
    ap = argparse.ArgumentParser(
        description="Correlate one call across iOS W417 chunks and the bcrypto-server journal."
    )
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--call-id", type=str, help="full UUID, short-8, lower/upper, or numeric")
    g.add_argument("--last-failed", action="store_true",
                   help="auto-pick the most recent failed call id from device chunks")
    ap.add_argument("--minutes", type=int, default=120, help="lookback window in minutes")
    ap.add_argument("--limit", type=int, default=200, help="max device chunks to download")
    ap.add_argument("--service-lines", type=int, default=4000, help="journalctl -n value")
    # --- Loki backend (additive; the SSH path above stays the default) ------
    ap.add_argument("--loki", action="store_true",
                    help="query the Loki backend (dash.bcrypto.com) instead of "
                         "the SSH journal/blob path; unified cross-platform timeline")
    ap.add_argument("--loki-url", type=str,
                    default="https://dash.bcrypto.com/loki/api/v1/query_range",
                    help="Loki query_range endpoint")
    ap.add_argument("--loki-user", type=str, default="admin",
                    help="Loki basic_auth user (default admin)")
    ap.add_argument("--loki-pw", type=str, default="",
                    help="Loki basic_auth password; overrides env QA_LOKI_QUERY_PW")
    ap.add_argument("--loki-linegrep", action="store_true",
                    help="opt-in: use a |= line-grep on short8 instead of the "
                         "qa_call_short8 attribute filter (matches legs that put "
                         "short8 only in the body; may yield substring false hits)")
    args = ap.parse_args()

    # === Loki backend branch ===============================================
    # With an explicit --call-id this is a pure-HTTP path: no SSH, no VPS creds.
    # With --last-failed we still need the device chunks to resolve the failed
    # id, so we fall through to the SSH device-pull first, then branch.
    if args.loki and not args.last_failed:
        sys.exit(run_loki_backend(args, args.call_id))

    print("=== bcrypto-server SSH @ %s (read-only) ===" % VPS_HOST)
    client = ssh_connect()
    print("Connected.")
    try:
        # 1) Always pull device chunks first (needed for --last-failed and for
        #    the device side of the timeline).
        print("\n=== Listing device W417 chunks (last %d min, <=%d) ==="
              % (args.minutes, args.limit))
        files = list_device_chunks(client, args.minutes, args.limit)
        print("Found %d candidate blobs." % len(files))
        device_records = read_device_lines(client, files)
        print("Parsed %d device NDJSON event lines." % len(device_records))

        # 2) Resolve the target call id.
        if args.last_failed:
            picked = pick_last_failed_call_id(device_records)
            if not picked:
                print("\nNo failed call id found in the last %d minutes."
                      % args.minutes)
                print("Failure markers scanned: %s" % ", ".join(FAIL_MARKERS))
                print("Widen --minutes or pass --call-id explicitly.")
                return
            call_id = picked
            print("\n--last-failed picked call id: %s" % call_id)
        else:
            call_id = args.call_id

        # --loki --last-failed: the SSH device-pull above only resolved the
        # failed call id; the actual cross-platform timeline comes from Loki.
        # Close the SSH client (the finally below also closes it; close() is
        # idempotent) and hand off to the pure-HTTP backend.
        if args.loki:
            client.close()
            sys.exit(run_loki_backend(args, call_id))

        predicate, norm, short8 = build_matcher(call_id)
        if not norm:
            print("ERROR: empty/invalid call id after normalization.", file=sys.stderr)
            return
        if len(norm) < _SHORT_ID_MIN:
            print("ERROR: call id '%s' is too short (need >= %d chars after"
                  " normalization). Pass the 8-char prefix or the full UUID."
                  % (norm, _SHORT_ID_MIN), file=sys.stderr)
            return

        # 3) Filter device records by the matcher.
        dev_hits = []
        for rec in device_records:
            hay = (rec.get("msg", "") + " " + rec.get("raw", "")).lower()
            if predicate(hay):
                dev_hits.append({
                    "ms": rec["ms"], "side": "DEV",
                    "lvl": rec.get("lvl", "I"), "tag": rec.get("tag", ""),
                    "text": rec.get("msg", "") or rec.get("raw", ""),
                })

        # 4) Server side: ONE journalctl read, filtered.
        print("\n=== Reading bcrypto-server journal (-n %d, read-only) ==="
              % args.service_lines)
        srv_records = read_server_lines(client, predicate, args.service_lines)
        srv_hits = [{
            "ms": r["ms"], "side": "SRV", "lvl": r["lvl"], "text": r["text"],
        } for r in srv_records]
        print("Device matched: %d   Server matched: %d"
              % (len(dev_hits), len(srv_hits)))

        # 5) Merge + STABLE sort ascending by ms (DEV before SRV preserved on
        #    ties because we extend dev first).
        timeline = dev_hits + srv_hits
        timeline.sort(key=lambda r: r["ms"])  # Python sort is stable

        render(timeline, len(dev_hits), len(srv_hits), norm, short8)
    finally:
        client.close()


if __name__ == "__main__":
    main()
