#!/usr/bin/env python3
"""
synth-traces.py -- synthesize an OTLP distributed-trace WATERFALL for ONE call
from the structured logs already in Loki, WITHOUT touching any of the apps.

We do NOT add tracing to iOS/Android/Desktop/server. Instead we read the
timestamped lifecycle logs every leg already ships to Loki (joined by
qa_call_short8), map the lifecycle markers in each leg to phase spans, and POST
synthetic OTLP spans to Grafana Tempo. Grafana then renders a per-call waterfall
(one row per platform-leg x phase) with trace->logs correlation back to Loki.

Why this exists: the iOS build is Mac-less / fragile (see qaudion-ios/CLAUDE.md
sec 16) so we will NOT instrument the app. The logs are already in Loki; this
turns them into spans server-side / dev-box-side only.

Pipeline (all pure Python stdlib -- urllib, hashlib, base64, json):
  1. Resolve short8 the SAME way correlate-call.py does (normalize_id ->
     build_matcher) and validate it is 8-char lowercase hex.
  2. Query Loki query_range for {service_name=~"qaudion-.+"} | qa_call_short8=`X`
     (the maintainer source-of-truth filter; matches stream-label OR structured
     metadata in Loki 3.x). Reuses the Caddy @lq basic_auth route + the same
     QA_LOKI_QUERY_PW env contract.
  3. Group the returned lines by service_name (= platform leg). For each leg,
     classify each line into a canonical lifecycle PHASE by matching the REAL
     body markers ('call started', 'call_offer', 'ICE state -> connected',
     'state .active -> .encrypted', 'no_peer_media', 'endCall', 'call ended', ...).
  4. Build OTLP spans: traceId = sha256("qaudion-call:" + short8)[:16].
     - one root span `call` (kind SERVER) owned by the relay/server leg if
       present else the initiator; start = min ts across legs, end = max ts.
     - per (leg, phase) a child phase span (kind INTERNAL), start = ts of the
       phase's first marker, end = ts of the next phase's first marker on the
       SAME leg (or the leg's last line for the terminal phase). 1ms min clamp.
       Extra marker lines in a phase become span EVENTS (not extra spans), so a
       storm of identical lines is an event count, not 100 spans.
     - phase span status=ERROR if its window holds an error marker; root
       status=ERROR if the call ended via a failure marker.
  5. POST the OTLP/HTTP JSON payload to Tempo via the Caddy @traces route
     (Authorization: Bearer <TEMPO_INGEST_TOKEN>, Content-Type application/json).

Usage:
  export QA_LOKI_QUERY_PW=...        # Loki basic_auth pw (Caddy @lq)
  export TEMPO_INGEST_TOKEN=...      # Tempo write token (Caddy @traces)
  python scripts/synth-traces.py --call-id 136e4e0d
  python scripts/synth-traces.py --call-id 91FE5CF7-3572-42F1-9B84-29883F47BAB6
  python scripts/synth-traces.py --call-id 136e4e0d --minutes 240
  python scripts/synth-traces.py --call-id 136e4e0d --dry-run   # print spans, no POST

Exit codes: 0 ok (spans pushed or dry-run printed), 1 usage/auth/transport error,
2 no log lines matched in the window (nothing to synthesize).

No app build. No prod write. No SSH (pure HTTP to Loki + Tempo via Caddy).
No external LLM. No data leaves the dash.bcrypto.com perimeter.
"""

import os
import re
import sys
import json
import time
import base64
import hashlib
import argparse
import urllib.request
import urllib.error
import urllib.parse
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# short8 derivation -- identical contract to correlate-call.py so the SAME call
# id forms (full UUID, 8-char hex prefix, upper/lowercase) resolve to the SAME
# join key. Kept inline (not imported): correlate-call.py is hyphenated and the
# two tools are intentionally importlib-free per the iOS scripts integration spec.
# ---------------------------------------------------------------------------

_ELLIPSIS = "…"
_SHORT8_HEX_RE = re.compile(r"^[0-9a-f]{8}$")


def normalize_id(raw):
    """Lowercase, strip a trailing unicode/ASCII ellipsis + whitespace."""
    if raw is None:
        return ""
    s = raw.strip().rstrip()
    s = s.rstrip(_ELLIPSIS).rstrip(".").rstrip(_ELLIPSIS)
    return s.strip().lower()


def derive_short8(call_id):
    """Return the validated 8-char lowercase-hex short8 join key, or None.

    Mirrors correlate-call.py: normalize, take the first 8 chars of an id that is
    at least 8 long, and REQUIRE it to be hex -- the only short8 the shippers can
    ever have emitted (ship-ios-logs.py _RE_CALLID_VALUE gates the join key to
    [0-9a-fA-F-]{4,}). A non-hex prefix is a guaranteed-empty query."""
    norm = normalize_id(call_id)
    if len(norm) < 8:
        return None, norm
    short8 = norm[:8]
    if not _SHORT8_HEX_RE.match(short8):
        return None, norm
    return short8, norm


# ---------------------------------------------------------------------------
# Loki query backend -- reuse correlate-call.py's exact route + auth contract:
#   GET https://dash.bcrypto.com/loki/api/v1/query_range
#   -> Caddy @lq path /loki/* -> basic_auth { admin ... } -> reverse_proxy loki:3100
#   LogQL source of truth: {service_name=~"qaudion-.+"} | qa_call_short8=`X`
# ---------------------------------------------------------------------------

# OTLP service.name (-> Loki stream label service_name) -> the OTLP service.name
# we re-stamp on the span resource, plus the [tag] used in dry-run output and the
# leg role default. Forward-compat: android/desktop are mapped even where a
# shipper may not exist yet, so a new leg is never silently dropped.
_LEG = {
    "qaudion-ios":     ("qaudion-ios",     "IOS"),
    "qaudion-server":  ("qaudion-server",  "SRV"),
    "qaudion-android": ("qaudion-android", "AND"),
    "qaudion-desktop": ("qaudion-desktop", "DESK"),
}


def _loki_logql(short8):
    """Source-of-truth pipeline filter. short8 is hex-validated by the caller so
    the backtick literal is injection-safe; the query param is urlencoded."""
    if not _SHORT8_HEX_RE.match(short8 or ""):
        raise ValueError("non-hex short8 %r" % (short8,))
    return '{service_name=~"qaudion-.+"} | qa_call_short8=`%s`' % short8


def _loki_query_once(url, user, pw, logql, start_ns, end_ns, limit=5000):
    """One GET to Loki query_range. Returns (status, json_or_None, raw_body).
    Never raises on HTTP status; transport/decode errors propagate."""
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
            return resp.getcode(), _safe_json(resp.read()), ""
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        return e.code, _safe_json(body.encode("utf-8")), body


def _safe_json(raw_bytes):
    try:
        return json.loads(raw_bytes.decode("utf-8", errors="replace"))
    except ValueError:
        return None


def query_loki(url, user, pw, short8, minutes):
    """Run the source-of-truth query; return flat records {ts_ns, service_name,
    lvl, text}. Window = max(minutes, 120) ending now. Raises RuntimeError on a
    hard HTTP error with a clear message (never a raw traceback)."""
    window_min = max(minutes, 120)
    end_ns = int(time.time() * 1_000_000_000)
    start_ns = end_ns - window_min * 60 * 1_000_000_000

    status, obj, body = _loki_query_once(url, user, pw, _loki_logql(short8),
                                         start_ns, end_ns)
    if status in (401, 403):
        raise RuntimeError(
            "Loki auth failed (HTTP %d). Set QA_LOKI_QUERY_PW / --loki-pw. "
            "Caddy basic_auth gates /loki/*." % status)
    if status >= 500:
        raise RuntimeError("Loki server error (HTTP %d): %s"
                           % (status, (body or "").strip()[:300]))
    if status >= 400:
        raise RuntimeError("Loki query rejected (HTTP %d): %s"
                           % (status, (body or "").strip()[:300]))

    records = []
    if not isinstance(obj, dict) or obj.get("status") != "success":
        return records
    data = obj.get("data") or {}
    if data.get("resultType") != "streams":
        return records
    for s in (data.get("result") or []):
        if not isinstance(s, dict):
            continue
        labels = s.get("stream") or {}
        service_name = labels.get("service_name", "")
        lvl = (labels.get("detected_level") or labels.get("level")
               or labels.get("severity") or "")
        for pair in (s.get("values") or []):
            if not (isinstance(pair, list) and len(pair) >= 2):
                continue
            try:
                ts_ns = int(pair[0])
            except (TypeError, ValueError):
                continue
            line = pair[1] if isinstance(pair[1], str) else str(pair[1])
            records.append({
                "ts_ns": ts_ns,
                "service_name": service_name,
                "lvl": lvl or "",
                "text": line,
            })
    return records


# ---------------------------------------------------------------------------
# Marker -> phase map. Phases are ordered (index = waterfall order). Each marker
# is matched as a CASE-INSENSITIVE substring against the log body -- the exact
# bodies were observed in Loki (call 136e4e0d / 2c2872b0 / f0d8d8ab) and in the
# server/iOS log vocabulary. Order matters: the FIRST phase whose marker hits
# wins for a given line, but each line is also tested against every phase so a
# later-phase marker on an earlier-printed line is still classified correctly.
# ---------------------------------------------------------------------------

# Canonical phases in waterfall order.
PHASES = [
    "setup",       # call created / offer announced / incoming
    "ringing",     # ringing / answer
    "signaling",   # SDP offer/answer + ICE candidate exchange
    "ice",         # ICE connectivity establishment
    "crypto",      # PQC / ratchet / key handshake, seal/unseal
    "media",       # audio/video flowing, encrypted, active
    "teardown",    # endCall / call ended / hangup / offline
]
_PHASE_IDX = {p: i for i, p in enumerate(PHASES)}

# (phase, lowercase-marker-substring). Bodies are the literal markers seen in the
# logs / known leg vocabulary across iOS, Android, Desktop, server.
_MARKERS = [
    ("setup",     "call started"),
    ("setup",     "call_offer"),
    ("setup",     "asinitiator"),
    ("setup",     "call-incoming"),
    ("setup",     "call incoming"),
    ("setup",     "incoming call"),
    ("setup",     "offer announced"),
    ("ringing",   "ringing"),
    ("ringing",   "call_answer"),
    ("ringing",   "answered"),
    ("ringing",   ".ringing"),
    ("signaling", "setremotedescription"),
    ("signaling", "setlocaldescription"),
    ("signaling", "sdp"),
    ("signaling", "call_ice"),
    ("signaling", "ice candidate"),
    ("signaling", "candidate"),
    ("ice",       "ice state"),
    ("ice",       "ice ->"),
    ("ice",       "iceconnectionstate"),
    ("ice",       "ice connected"),
    ("ice",       "ice state -> connected"),
    ("ice",       "direct_p2p"),
    ("ice",       "host-host"),
    ("crypto",    "pqc"),
    ("crypto",    "ratchet"),
    ("crypto",    "ml-kem"),
    ("crypto",    "mlkem"),
    ("crypto",    "handshake"),
    ("crypto",    "unseal"),
    ("crypto",    "seal"),
    ("crypto",    "psk"),
    ("crypto",    "encrypted"),                 # also a media gate; see ordering
    ("media",     "state .active -> .encrypted"),
    ("media",     ".active -> .encrypted"),
    ("media",     "-> .active"),
    ("media",     "active"),
    ("media",     "rx heartbeat"),
    ("media",     "audio_frame"),
    ("media",     "frames decrypted"),
    ("media",     "mediamode"),
    ("media",     "video"),
    ("teardown",  "endcall"),
    ("teardown",  "call ended"),
    ("teardown",  "hangup"),
    ("teardown",  "call_end"),
    ("teardown",  "bye"),
]

# Error markers -> the phase span (and root) get status=ERROR. Literal bodies /
# tokens observed for the 3 failing/edge calls.
_ERROR_MARKERS = [
    "half_open",
    "no_peer_media",
    "call_peer_offline",
    "peer offline",
    "recipient offline",
    "pqc handshake failed",
    "handshake failed",
    "unseal failed",
    "unseal-fail",
    "decode failed",
    "ice state -> closed",
    "ice -> closed",
    "ice never converged",
    "identity_key_mismatch",
    "verify fail",
]


def classify_phase(text):
    """Return the canonical phase for a log line, or None if no marker hits.
    Tests ALL markers and keeps the LOWEST phase index that matches, so a line
    carrying both 'encrypted' (crypto) and '.active -> .encrypted' (media) lands
    in the earliest applicable phase deterministically -- except media-specific
    phrases override the bare 'encrypted' crypto marker via explicit ordering
    below."""
    low = text.lower()
    # Media-specific override: a line that announces the active/encrypted media
    # transition is a MEDIA phase even though it contains 'encrypted' (crypto).
    if (".active -> .encrypted" in low or "state .active -> .encrypted" in low
            or "rx heartbeat" in low or "frames decrypted" in low
            or "audio_frame" in low):
        return "media"
    best = None
    for phase, marker in _MARKERS:
        if marker in low:
            idx = _PHASE_IDX[phase]
            if best is None or idx < best[0]:
                best = (idx, phase)
    return best[1] if best else None


def is_error_line(text):
    low = text.lower()
    return any(m in low for m in _ERROR_MARKERS)


# ---------------------------------------------------------------------------
# OTLP span synthesis.
# ---------------------------------------------------------------------------

def _trace_id_hex(short8):
    """Deterministic 16-byte (32 hex) traceId so the SAME call always maps to the
    SAME trace and logs<->traces join without a lookup table."""
    return hashlib.sha256(("qaudion-call:" + short8).encode("utf-8")).hexdigest()[:32]


def _span_id_hex(trace_id_hex, service_name, phase, seq):
    """Deterministic 8-byte (16 hex) spanId per (trace, leg, phase, seq)."""
    h = hashlib.sha256(
        ("%s|%s|%s|%d" % (trace_id_hex, service_name, phase, seq)).encode("utf-8")
    ).hexdigest()
    return h[:16]


def _leg_role(service_name, lines):
    """Derive initiator|responder|relay for a leg from its line bodies.
    server is always the relay; otherwise look for initiator vs responder cues."""
    if service_name == "qaudion-server":
        return "relay"
    joined = " ".join(l["text"].lower() for l in lines)
    if ("asinitiator=true" in joined or "asinitiator" in joined
            or "offer announced" in joined or "call_offer announced" in joined):
        return "initiator"
    if ("call-incoming" in joined or "call incoming" in joined
            or "incoming call" in joined or "responder" in joined):
        return "responder"
    return "initiator"  # neutral default


def _str_attr(key, value):
    return {"key": key, "value": {"stringValue": str(value)}}


def _int_attr(key, value):
    return {"key": key, "value": {"intValue": int(value)}}


def build_otlp_payload(short8, records):
    """Turn the flat Loki records for one call into an OTLP/HTTP ResourceSpans
    payload. Returns (payload_dict, summary_dict). Empty records -> (None, summary
    with 0 legs)."""
    trace_id = _trace_id_hex(short8)

    # Group by leg (service_name), drop legs we cannot map.
    legs = {}
    for r in records:
        sn = (r.get("service_name") or "").strip()
        if sn not in _LEG:
            sn = sn or "unknown"
        legs.setdefault(sn, []).append(r)
    for sn in legs:
        legs[sn].sort(key=lambda r: r["ts_ns"])

    if not legs:
        return None, {"legs": 0, "spans": 0, "trace_id": trace_id}

    # Global call window (root span).
    all_ts = [r["ts_ns"] for r in records]
    call_start = min(all_ts)
    call_end = max(all_ts)
    if call_end <= call_start:
        call_end = call_start + 1_000_000  # 1ms clamp

    # Root span owner: relay (server) leg if present, else first initiator, else
    # any leg. The root carries the call lifecycle; phase spans are its children.
    root_owner = ("qaudion-server" if "qaudion-server" in legs
                  else next(iter(legs)))
    root_span_id = _span_id_hex(trace_id, root_owner, "__root__", 0)

    call_failed = any(is_error_line(r["text"]) for r in records)
    # A clean teardown ('call ended' without a failure on the same/last line)
    # keeps the root OK; any failure marker anywhere flips it ERROR.
    root_status = 2 if call_failed else 1  # 2=ERROR, 1=OK (unset=0)

    resource_spans = []
    total_spans = 0

    for sn, lines in legs.items():
        svc_name, _tag = _LEG.get(sn, (sn, "unknown"))
        role = _leg_role(sn, lines)

        # Resource = the platform leg. Drives trace->logs (qa.call.short8).
        resource_attrs = [
            _str_attr("service.name", svc_name),
            _str_attr("qa.call.short8", short8),
            _str_attr("qa.role", role),
        ]
        # Carry a level/severity hint if present on the leg's lines.
        lvl = next((l["lvl"] for l in lines if l.get("lvl")), "")
        if lvl:
            resource_attrs.append(_str_attr("qa.level", lvl))

        spans = []

        # Root span is attached to EVERY leg's resourceSpans? No -- OTLP requires
        # the root to live under exactly one resource. We attach it to the
        # root_owner leg only; other legs carry just their phase spans (children
        # reference root_span_id by parentSpanId, which is valid cross-resource
        # within one trace).
        if sn == root_owner:
            spans.append({
                "traceId": trace_id,
                "spanId": root_span_id,
                "name": "call",
                "kind": 2,  # SERVER
                "startTimeUnixNano": str(call_start),
                "endTimeUnixNano": str(call_end),
                "attributes": [
                    _str_attr("qa.call.short8", short8),
                    _str_attr("qa.span.kind", "call-root"),
                ],
                "status": {"code": root_status},
            })
            total_spans += 1

        # --- Per-leg phase spans -------------------------------------------
        # Assign each line to a phase; phases that have >=1 line become a span.
        # A phase span's window: start = its first line ts; end = the first line
        # ts of the NEXT non-empty phase on this leg (in canonical order), or the
        # leg's last line ts for the terminal phase. Extra lines in a phase are
        # span events.
        phase_lines = {}  # phase -> list[record], in ts order (lines already sorted)
        for r in lines:
            ph = classify_phase(r["text"])
            if ph is None:
                continue
            phase_lines.setdefault(ph, []).append(r)

        # Ordered list of (phase, first_ts, lines) by canonical phase index.
        present = sorted(phase_lines.items(), key=lambda kv: _PHASE_IDX[kv[0]])
        leg_last_ts = lines[-1]["ts_ns"]

        for i, (phase, plines) in enumerate(present):
            start_ns = plines[0]["ts_ns"]
            if i + 1 < len(present):
                end_ns = present[i + 1][1][0]["ts_ns"]
            else:
                end_ns = max(leg_last_ts, start_ns)
            if end_ns <= start_ns:
                end_ns = start_ns + 1_000_000  # 1ms min clamp so it renders

            phase_failed = any(is_error_line(r["text"]) for r in plines)

            events = []
            for r in plines:
                ev_attrs = [_str_attr("body", r["text"][:512])]
                if r.get("lvl"):
                    ev_attrs.append(_str_attr("level", r["lvl"]))
                if is_error_line(r["text"]):
                    ev_attrs.append(_str_attr("qa.error", "true"))
                events.append({
                    "timeUnixNano": str(r["ts_ns"]),
                    "name": "log",
                    "attributes": ev_attrs,
                })

            span_id = _span_id_hex(trace_id, sn, phase, i)
            spans.append({
                "traceId": trace_id,
                "spanId": span_id,
                "parentSpanId": root_span_id,
                "name": "%s/%s" % (role, phase),
                "kind": 1,  # INTERNAL
                "startTimeUnixNano": str(start_ns),
                "endTimeUnixNano": str(end_ns),
                "attributes": [
                    _str_attr("qa.call.short8", short8),
                    _str_attr("qa.phase", phase),
                    _str_attr("qa.leg.role", role),
                    _int_attr("qa.event.count", len(plines)),
                ],
                "events": events,
                "status": {"code": 2 if phase_failed else 1},
            })
            total_spans += 1

        if not spans:
            continue
        resource_spans.append({
            "resource": {"attributes": resource_attrs},
            "scopeSpans": [{
                "scope": {"name": "synth-traces", "version": "1"},
                "spans": spans,
            }],
        })

    payload = {"resourceSpans": resource_spans}
    summary = {
        "legs": len(resource_spans),
        "spans": total_spans,
        "trace_id": trace_id,
        "call_start_ns": call_start,
        "call_end_ns": call_end,
        "failed": call_failed,
    }
    return payload, summary


# ---------------------------------------------------------------------------
# Tempo push -- OTLP/HTTP via the Caddy @traces route. Bearer-token gated, bare
# application/json (no gzip), mirroring the @otlp Loki ingest pattern.
# ---------------------------------------------------------------------------

def push_tempo(url, token, payload):
    """POST the OTLP/HTTP JSON to Tempo. Returns (status, body). Raises
    URLError on transport failure. Tempo replies 200 with an empty/partial body
    on success (partialSuccess.rejectedSpans=0)."""
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.getcode(), resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        return e.code, body


# ---------------------------------------------------------------------------
# Rendering (dry-run) helpers.
# ---------------------------------------------------------------------------

def _ms_to_hms(ts_ns):
    ms = ts_ns / 1_000_000.0
    dt = datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)
    return dt.strftime("%H:%M:%S.") + ("%03d" % int(ms % 1000))


def print_dry_run(short8, summary, payload):
    print("=" * 72)
    print("SYNTH-TRACES dry-run  short8=%s  traceId=%s" % (short8, summary["trace_id"]))
    print("legs=%d  spans=%d  failed=%s" % (summary["legs"], summary["spans"],
                                            summary.get("failed")))
    if summary.get("call_start_ns"):
        print("call window [%s .. %s]"
              % (_ms_to_hms(summary["call_start_ns"]),
                 _ms_to_hms(summary["call_end_ns"])))
    print("=" * 72)
    for rs in payload["resourceSpans"]:
        svc = next((a["value"]["stringValue"] for a in rs["resource"]["attributes"]
                    if a["key"] == "service.name"), "?")
        role = next((a["value"]["stringValue"] for a in rs["resource"]["attributes"]
                     if a["key"] == "qa.role"), "?")
        print("\n[%s] role=%s" % (svc, role))
        for sp in rs["scopeSpans"][0]["spans"]:
            st = _ms_to_hms(int(sp["startTimeUnixNano"]))
            en = _ms_to_hms(int(sp["endTimeUnixNano"]))
            dur_ms = (int(sp["endTimeUnixNano"]) - int(sp["startTimeUnixNano"])) / 1e6
            err = " ERROR" if sp.get("status", {}).get("code") == 2 else ""
            nev = len(sp.get("events", []))
            print("  %-22s %s -> %s  %8.1fms  ev=%-3d%s"
                  % (sp["name"], st, en, dur_ms, nev, err))


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Synthesize an OTLP per-call trace waterfall from Loki logs "
                    "and push it to Grafana Tempo. No app changes.")
    ap.add_argument("--call-id", required=True,
                    help="full UUID, 8-char hex prefix, or lower/upper form")
    ap.add_argument("--minutes", type=int, default=120,
                    help="Loki lookback window in minutes (floored at 120)")
    # Loki query route -- identical defaults to correlate-call.py.
    ap.add_argument("--loki-url", default="https://dash.bcrypto.com/loki/api/v1/query_range",
                    help="Loki query_range endpoint (Caddy @lq)")
    ap.add_argument("--loki-user", default="admin", help="Loki basic_auth user")
    ap.add_argument("--loki-pw", default="",
                    help="Loki basic_auth pw; overrides env QA_LOKI_QUERY_PW")
    # Tempo ingest route.
    ap.add_argument("--tempo-url", default="https://dash.bcrypto.com/tempo/v1/traces",
                    help="Tempo OTLP/HTTP ingest endpoint (Caddy @traces)")
    ap.add_argument("--tempo-token", default="",
                    help="Tempo bearer token; overrides env TEMPO_INGEST_TOKEN")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the synthesized spans; do NOT POST to Tempo")
    args = ap.parse_args()

    short8, norm = derive_short8(args.call_id)
    if not short8:
        print("ERROR: need a >=8-char hex call id (full UUID or 8-char hex "
              "prefix). The Loki join key qa.call.short8 is always [0-9a-f]{8}. "
              "Got normalized id '%s'." % (norm or ""), file=sys.stderr)
        return 1

    loki_pw = args.loki_pw or os.environ.get("QA_LOKI_QUERY_PW", "")
    if not loki_pw:
        print("ERROR: no Loki password. Set env QA_LOKI_QUERY_PW or --loki-pw.",
              file=sys.stderr)
        return 1

    window_min = max(args.minutes, 120)
    print("=== Loki query @ %s (user=%s, window=%dm) ==="
          % (args.loki_url, args.loki_user, window_min))
    print("short8=%s  query={service_name=~\"qaudion-.+\"} | qa_call_short8=`%s`"
          % (short8, short8))
    try:
        records = query_loki(args.loki_url, args.loki_user, loki_pw, short8,
                             args.minutes)
    except urllib.error.URLError as e:
        print("ERROR: cannot reach Loki at %s: %s"
              % (args.loki_url, getattr(e, "reason", e)), file=sys.stderr)
        return 1
    except RuntimeError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 1

    if not records:
        print("No log lines matched short8=%s in the last %d min on any "
              "qaudion-* service. Widen --minutes or confirm a shipper is "
              "POSTing to the OTLP ingest." % (short8, window_min))
        return 2

    print("Got %d Loki lines across %d service(s)."
          % (len(records), len({r["service_name"] for r in records})))

    payload, summary = build_otlp_payload(short8, records)
    if not payload or not payload["resourceSpans"]:
        print("No mappable lifecycle markers found for short8=%s -- nothing to "
              "synthesize. (Lines were present but none matched a phase marker.)"
              % short8)
        return 2

    if args.dry_run:
        print_dry_run(short8, summary, payload)
        print("\nDRY-RUN: %d spans across %d legs NOT pushed."
              % (summary["spans"], summary["legs"]))
        return 0

    tempo_token = args.tempo_token or os.environ.get("TEMPO_INGEST_TOKEN", "")
    if not tempo_token:
        print("ERROR: no Tempo token. Set env TEMPO_INGEST_TOKEN or --tempo-token.",
              file=sys.stderr)
        return 1

    print("=== Pushing %d spans (%d legs) to Tempo @ %s ==="
          % (summary["spans"], summary["legs"], args.tempo_url))
    try:
        status, body = push_tempo(args.tempo_url, tempo_token, payload)
    except urllib.error.URLError as e:
        print("ERROR: cannot reach Tempo at %s: %s"
              % (args.tempo_url, getattr(e, "reason", e)), file=sys.stderr)
        return 1

    if status == 401:
        print("ERROR: Tempo ingest rejected (HTTP 401). Check TEMPO_INGEST_TOKEN "
              "against the Caddy @traces bearer token.", file=sys.stderr)
        return 1
    if status >= 400:
        print("ERROR: Tempo ingest failed (HTTP %d): %s"
              % (status, (body or "").strip()[:300]), file=sys.stderr)
        return 1

    print("OK: pushed traceId=%s (HTTP %d). View the waterfall in Grafana -> "
          "Explore -> Tempo -> search qa.call.short8=%s, or open the trace and "
          "click a span -> 'Logs for this span'." % (summary["trace_id"], status, short8))
    if body.strip():
        print("Tempo response: %s" % body.strip()[:300])
    return 0


if __name__ == "__main__":
    sys.exit(main())
