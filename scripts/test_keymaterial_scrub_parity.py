#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Parity port + test of KeyMaterialScrubber (W-KEYSCRUB, v1.0.1181):
  QAudionEngine/Sources/QAudionEngine/Diagnostics/KeyMaterialScrubber.swift

The Swift scrubber keeps KEY BYTES out of the app's log text (RuntimeLogSink ring, log export, bug
report, live-log shipper, telemetry attributes). This file is a line-by-line port of its scanner
(same function names in snake_case, same order of checks, the same byte-level rules) so that:
  - the corpus of real W417 blobs can be replayed against the exact rules on the server, and
  - the rules cannot drift silently: the Swift test (KeyMaterialScrubberTests) and this script
    check the SAME golden vectors,
      QAudionEngine/Tests/QAudionEngineTests/Diagnostics/Resources/key-material-scrub-vectors.json
    whose expected texts were composed by hand from the spec, not by running either implementation.

Run:  python scripts/test_keymaterial_scrub_parity.py
Exit: 0 = every vector and property passes, 1 = a mismatch.

Rules (all on the UTF-8 bytes of the text; every pattern is ASCII):
  (a) 'derived_key' (any case): everything after the word (after spaces and = : < >) to the end.
  (b) 'secret' | 'slat' | 'salt' (any case) + spaces/= : < > + a balanced [..] or (..) group
      (unclosed: to the end). An empty or blank group is left alone.
  (c) [..] or (..) list of >= 8 decimal integers 0-255 separated by , or ; (spaces / newlines
      allowed, one trailing separator allowed); a list cut by the end of the text counts with >= 1.
  (d) >= 8 two-digit hex bytes separated by one space or colon, each pair a whole token.
  (e) tail fragment: the text STARTS inside an integer list: [,;] int ([,;] int)* [,;] closer.
      A closing ']' accepts one integer, a closing ')' needs two or a leading separator.
  (f) overlong: only the first 256 KiB are scanned, the rest is replaced (fail closed).
Replacement: [REDACTED:keybytes]. Matches that touch are merged into one marker.
"""

import json
import os
import random
import sys
import time

MARKER = b"[REDACTED:keybytes]"
MAX_SCAN_BYTES = 256 * 1024
MIN_INT_LIST = 8
MIN_HEX_RUN = 8

KIND_DERIVED = "derived_key"
KIND_KEYWORD = "keyword_list"
KIND_INTLIST = "int_list"
KIND_TAIL = "tail_fragment"
KIND_HEX = "hex_run"
KIND_OVERLONG = "overlong"

# int_run outcomes
ENDED = 0    # ran into the end of the scan window
CLOSED = 1   # stopped after a closing bracket
BAD = 2      # met something that is not part of an integer list

_DERIVED = b"derived_key"
_SECRET = b"secret"
_SLAT = b"slat"
_SALT = b"salt"


# --- byte helpers ------------------------------------------------------------------------------

def is_space(c):
    return c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D


def is_digit(c):
    return 0x30 <= c <= 0x39


def is_hex(c):
    return (0x30 <= c <= 0x39) or (0x41 <= c <= 0x46) or (0x61 <= c <= 0x66)


def is_alnum(c):
    return (0x30 <= c <= 0x39) or (0x41 <= c <= 0x5A) or (0x61 <= c <= 0x7A)


def lower(c):
    return c + 32 if 0x41 <= c <= 0x5A else c


def is_open(c):
    return c == 0x5B or c == 0x28


def is_close(c):
    return c == 0x5D or c == 0x29


def is_keyword_separator(c):
    """Between a keyword and its value: white space, '=', ':', '<', '>'."""
    return is_space(c) or c == 0x3D or c == 0x3A or c == 0x3C or c == 0x3E


def is_hex_separator(c):
    return c == 0x20 or c == 0x3A


def match_word(b, i, limit, word):
    n = len(word)
    if i + n > limit:
        return False
    for k in range(n):
        if lower(b[i + k]) != word[k]:
            return False
    return True


def skip_spaces(b, p, limit):
    while p < limit and is_space(b[p]):
        p += 1
    return p


def skip_separators(b, p, limit):
    while p < limit and is_keyword_separator(b[p]):
        p += 1
    return p


def equals_marker(b, start, end):
    return end - start == len(MARKER) and b[start:end] == MARKER


# --- integer lists (c) and tail fragments (e) --------------------------------------------------

def int_run(b, p, limit):
    """Integers 0-255 (1-3 digits) separated by ',' or ';' (spaces allowed, one trailing separator
    allowed), starting at p. Returns (count, pos, state): CLOSED with pos after the closing
    bracket, ENDED with pos == limit, BAD with pos at the offending byte."""
    count = 0
    while True:
        p = skip_spaces(b, p, limit)
        if p >= limit:
            return count, limit, ENDED
        c = b[p]
        if is_close(c):
            return count, p + 1, CLOSED
        if not is_digit(c):
            return count, p, BAD
        q = p
        value = 0
        while q < limit and is_digit(b[q]):
            value = value * 10 + (b[q] - 0x30)
            q += 1
            if q - p > 3:
                return count, q, BAD
        if value > 255:
            return count, q, BAD
        count += 1
        p = skip_spaces(b, q, limit)
        if p >= limit:
            return count, limit, ENDED
        c = b[p]
        if c == 0x2C or c == 0x3B:
            p += 1
            continue
        if is_close(c):
            return count, p + 1, CLOSED
        return count, p, BAD


def match_int_list(b, i, limit):
    """b[i] is '[' or '('. End (exclusive) of a closed list of >= 8 integers, or of a list that is
    cut by the end of the window (a head fragment, see match_tail_fragment) with >= 1 integer;
    -1 when it is neither."""
    count, pos, state = int_run(b, i + 1, limit)
    if state == BAD:
        return -1
    if state == ENDED:
        return pos if count >= 1 else -1
    return pos if count >= MIN_INT_LIST else -1


def match_tail_fragment(b, limit):
    """A text that STARTS in the middle of an integer list (the stdout tee reads the pipe in 4096
    byte chunks, so a long key line can be cut in two): [sep] int (sep int)* [sep] closer.
    Returns the end (exclusive) of the fragment, -1 if the text does not start like that."""
    p = skip_spaces(b, 0, limit)
    lead = False
    if p < limit and (b[p] == 0x2C or b[p] == 0x3B):
        lead = True
        p = skip_spaces(b, p + 1, limit)
    count, pos, state = int_run(b, p, limit)
    if state != CLOSED or count < 1:
        return -1
    if b[pos - 1] == 0x5D or count >= 2 or lead:
        return pos
    return -1


# --- keyword groups (b) ------------------------------------------------------------------------

def group_end(b, p, limit):
    """b[p] is '[' or '('. Exclusive end of the balanced group, the end of the window if unclosed.
    Returns (end, closed)."""
    depth = 0
    q = p
    while q < limit:
        c = b[q]
        if is_open(c):
            depth += 1
        elif is_close(c):
            depth -= 1
            if depth == 0:
                return q + 1, True
        q += 1
    return limit, False


def group_is_blank(b, p, end, closed):
    stop = end - 1 if closed else end
    q = p + 1
    while q < stop:
        if not is_space(b[q]):
            return False
        q += 1
    return True


def keyword_length(b, i, limit):
    if match_word(b, i, limit, _SECRET):
        return len(_SECRET)
    if match_word(b, i, limit, _SLAT):
        return len(_SLAT)
    if match_word(b, i, limit, _SALT):
        return len(_SALT)
    return 0


# --- hex runs (d) ------------------------------------------------------------------------------

def is_hex_pair_token(b, p, limit):
    """b[p], b[p+1] are hex digits and that pair is a whole token (the next byte is not alnum)."""
    if p + 1 >= limit:
        return False
    if not is_hex(b[p]) or not is_hex(b[p + 1]):
        return False
    if p + 2 >= limit:
        return True
    return not is_alnum(b[p + 2])


def match_hex_run(b, i, limit):
    """>= 8 two-digit hex bytes separated by one space or colon, starting at i (the caller checked
    that i starts a token). Returns the end (exclusive), -1 if there are fewer."""
    count = 0
    p = i
    last_end = -1
    while is_hex_pair_token(b, p, limit):
        count += 1
        last_end = p + 2
        if p + 2 < limit and is_hex_separator(b[p + 2]):
            p += 3
        else:
            break
    return last_end if count >= MIN_HEX_RUN else -1


# --- the scanner -------------------------------------------------------------------------------

def scan(b, limit):
    """Every match of b[0:limit], in order, before touching matches are merged:
    a list of (start, end, kind)."""
    spans = []
    i = 0
    tail = match_tail_fragment(b, limit)
    if tail >= 0:
        spans.append((0, tail, KIND_TAIL))
        i = tail
    while i < limit:
        c = b[i]
        if is_open(c):                                            # (c)
            end = match_int_list(b, i, limit)
            if end >= 0:
                spans.append((i, end, KIND_INTLIST))
                i = end
            else:
                i += 1
            continue
        lc = lower(c)
        if lc == 0x64 and match_word(b, i, limit, _DERIVED):      # (a)
            s = skip_separators(b, i + len(_DERIVED), limit)
            if s < limit and not equals_marker(b, s, limit):
                spans.append((s, limit, KIND_DERIVED))
            i = limit
            continue
        if lc == 0x73:                                            # (b)
            k = keyword_length(b, i, limit)
            if k > 0:
                p = skip_separators(b, i + k, limit)
                if p < limit and is_open(b[p]):
                    end, closed = group_end(b, p, limit)
                    if not group_is_blank(b, p, end, closed) and not equals_marker(b, p, end):
                        spans.append((p, end, KIND_KEYWORD))
                    i = end
                    continue
        if is_hex(c) and (i == 0 or not is_alnum(b[i - 1])):      # (d)
            end = match_hex_run(b, i, limit)
            if end >= 0:
                spans.append((i, end, KIND_HEX))
                i = end
                continue
        i += 1
    return spans


def scan_data(data):
    """The matches of one text given as UTF-8 bytes: a list of (start, end, kind). (f) adds an
    'overlong' span for the part beyond the scan window. (Swift: `scan`, which does both.)"""
    n = len(data)
    limit = n
    if n > MAX_SCAN_BYTES:
        limit = MAX_SCAN_BYTES
        while limit > 0 and (data[limit] & 0xC0) == 0x80:     # never cut a multi-byte character
            limit -= 1
    spans = scan(data, limit)
    if n > limit:
        spans.append((limit, n, KIND_OVERLONG))
    return spans


def scan_line(line):
    """(spans, data, n) for a str: the matches, its UTF-8 bytes and their count."""
    data = line.encode("utf-8", "surrogatepass")
    return scan_data(data), data, len(data)


def append_replaced(data, spans, out):
    """Appends data to the bytearray out with every span replaced by the marker. Spans that touch or
    overlap are one replacement (one marker, not two). (Swift: `appendReplaced`.)"""
    merged = []
    cur_start = None
    cur_end = None
    for (s, e, _k) in spans:
        if cur_start is not None and s <= cur_end:
            if e > cur_end:
                cur_end = e
        else:
            if cur_start is not None:
                merged.append((cur_start, cur_end))
            cur_start, cur_end = s, e
    merged.append((cur_start, cur_end))
    pos = 0
    for (s, e) in merged:
        out += data[pos:s]
        out += MARKER
        pos = e
    out += data[pos:]


def scrub(line):
    """ONE log entry: 'the text' of the rules is the whole argument (derived_key takes the rest of
    it, even over several lines)."""
    spans, data, _n = scan_line(line)
    if not spans:
        return line
    out = bytearray()
    append_replaced(data, spans, out)
    return bytes(out).decode("utf-8", "surrogatepass")


def scrub_lines(text):
    """A text made of several lines (a blob of entries): cut at every line feed (byte 0x0A), each
    line scanned on its own with its own cap ('the text' of the rules is ONE LINE), the line feeds
    kept. A text without a line feed gives exactly scrub(). (Swift: `scrubLines`.)"""
    if not text:
        return text
    data = text.encode("utf-8", "surrogatepass")
    n = len(data)
    out = bytearray()
    changed = False
    copied = 0                       # once changed, data[:copied] is already in out
    start = 0
    while start <= n:
        end = data.find(b"\n", start)
        if end < 0:
            end = n
        if end > start:
            line = data[start:end]
            spans = scan_data(line)
            if spans:
                changed = True
                out += data[copied:start]
                append_replaced(line, spans, out)
                copied = end
        start = end + 1
    if not changed:
        return text
    out += data[copied:n]
    return bytes(out).decode("utf-8", "surrogatepass")


# --- the test ----------------------------------------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))
VECTORS = os.path.join(HERE, "..", "QAudionEngine", "Tests", "QAudionEngineTests", "Diagnostics",
                       "Resources", "key-material-scrub-vectors.json")
M = MARKER.decode("ascii")


def lst(a, b):
    return ",".join(str(i) for i in range(a, b + 1))


def check_vectors(failures):
    with open(VECTORS, encoding="utf-8") as fh:
        doc = json.load(fh)
    if doc.get("marker") != M:
        failures.append("vector file marker differs from the scrubber marker")
    vectors = doc["vectors"]
    for v in vectors:
        got = scrub(v["input"])
        if got != v["expected"]:
            failures.append("vector '%s': got %r expected %r" % (v["name"], got[:80], v["expected"][:80]))
        if scrub(v["expected"]) != v["expected"]:
            failures.append("vector '%s': expected text is not a fixed point" % v["name"])
        if "\n" not in v["input"]:
            # a text without a line feed: scrub_lines is exactly scrub
            got_lines = scrub_lines(v["input"])
            if got_lines != v["expected"]:
                failures.append("vector '%s': scrub_lines got %r expected %r"
                                % (v["name"], got_lines[:80], v["expected"][:80]))
    line_vectors = doc["lineVectors"]
    for v in line_vectors:
        got = scrub_lines(v["input"])
        if got != v["expected"]:
            failures.append("line vector '%s': got %r expected %r" % (v["name"], got[:120], v["expected"][:120]))
        if scrub_lines(v["expected"]) != v["expected"]:
            failures.append("line vector '%s': expected text is not a fixed point" % v["name"])
    print("  vectors: %d checked (scrub), %d line vectors (scrub_lines)" % (len(vectors), len(line_vectors)))


def check_split_lines(failures):
    """A key line cut at EVERY byte offset (the stdout tee splits its 4096-byte chunks into
    separate ring entries): no key number may survive in either part."""
    shapes = {
        "derived_key": "derived_key [" + lst(200, 231) + "] len 32",
        "secret+slat": "(x.cc:118): secret [" + lst(200, 231) + "] len 32 slat [" + lst(200, 215) + "] len 16",
        "secret+empty slat": "(x.cc:118): secret [" + lst(200, 231) + "] len 32 slat << [] len 0",
        "keyword-less list": "key bytes [" + lst(200, 231) + "] len 32",
    }
    for name, line in shapes.items():
        leaks = 0
        for k in range(len(line) + 1):
            out = scrub(line[:k]) + "\n" + scrub(line[k:])
            if any(str(n) in out for n in range(200, 232)):
                leaks += 1
        if leaks:
            failures.append("split shape '%s': key numbers survive at %d cut offsets" % (name, leaks))
    print("  split lines: %d shapes cut at every offset" % len(shapes))


def per_line_reference(text):
    """Independent formulation of scrub_lines: cut at every line feed, scrub each piece with scrub,
    join with a line feed. (In Swift the test builds the same reference from the UTF-8 bytes.)"""
    return "\n".join(scrub(piece) for piece in text.split("\n"))


def check_lines(failures):
    """scrub_lines on composed texts: the lines around a key line survive, a blob of already
    scrubbed lines is a fixed point (the bug that made ReportCrypto.buildDiagSummary keep an old
    slice of the log), and the result is the per-line reference."""
    key = lst(1, 32)
    prefix = "2026-09-21T10:00:00.000Z [INFO] [stdout] "
    entries = [
        "derived_key [" + key + "] len 32",
        "rekey round 2 done",
        "(x.cc:118): secret [" + key + "] len 32 slat << [] len 0",
        "secret [",
        "18,19,20,21] len 32",              # the tail of a key line the tee cut in two
        "media resumed",
    ]
    # the ring holds every entry scrubbed at entry (the tail fragment is a whole entry there)
    blob = "\n".join(prefix + scrub(e) for e in entries) + "\n"
    if scrub_lines(blob) != blob:
        failures.append("lines: a blob of scrubbed rows is not a fixed point of scrub_lines")
    if not blob.endswith("media resumed\n") or "media resumed" not in scrub_lines(blob):
        failures.append("lines: the newest row was lost")
    if "1,2,3" in blob or "18,19" in blob:
        failures.append("lines: the scrubbed blob still holds key digits")
    raw_blob = "\n".join(prefix + e for e in entries) + "\n"
    once = scrub_lines(raw_blob)
    if "1,2,3" in once or "media resumed" not in once:
        failures.append("lines: scrubbing a raw blob lost a row or left key digits")
    if scrub_lines(once) != once:
        failures.append("lines: scrub_lines is not idempotent on a blob")
    # the documented contract of scrub(): one entry, derived_key takes the rest of the TEXT, so a
    # blob is not a fixed point of it
    two_rows = "ts derived_key " + M + "\nnewest row"
    if scrub(two_rows) == two_rows:
        failures.append("lines: scrub() no longer reads derived_key as the rest of the text")
    for text in (raw_blob, blob, "a\nderived_key [1,2,3]\nb", "x [1,2,3,4,5,6,7,\n8] y", "\n\n", "",
                 "salt (\nfoo\n", "secret [1,2\nnext\nlast", "a\r\nsecret [1,2,3] len 3\r\nb\r\n"):
        if scrub_lines(text) != per_line_reference(text):
            failures.append("lines: scrub_lines differs from the per-line reference for %r" % text[:50])
    # the diag summary: the last 200 characters of the blob are the newest rows, not an old slice
    if not scrub_lines(blob)[-200:].endswith("media resumed\n"):
        failures.append("lines: the 200-character tail is not made of the newest rows")
    print("  lines: composed-text checks")


def check_cap(failures):
    cap = MAX_SCAN_BYTES
    long_clean = "abcdefghij klm " * 70000                       # about 1 MB, no match
    out = scrub(long_clean)
    if out != long_clean[:cap] + M:
        failures.append("cap: a 1 MB clean text is not cut to the cap plus the marker")
    key_after_cap = "x" * (cap + 10) + " derived_key [" + lst(1, 32) + "] len 32"
    out = scrub(key_after_cap)
    if "derived_key" in out or "1,2,3" in out or not out.endswith(M):
        failures.append("cap: a key list beyond the cap survived")
    key_before_cap = "y [" + lst(1, 32) + "] " + "x" * (cap + 10)
    out = scrub(key_before_cap)
    if not out.startswith("y " + M + " ") or "1,2,3" in out:
        failures.append("cap: a key list inside the scan window was not scrubbed")
    cut_in_char = "a" * (cap - 1) + "é" + "z" * 10           # the 2-byte char straddles the cap
    if scrub(cut_in_char) != "a" * (cap - 1) + M:
        failures.append("cap: cutting inside a multi-byte character")
    # scrub_lines: the cap is per LINE. A blob of many short rows longer than the cap is not cut ...
    row = "2026-09-21T10:00:00.000Z [INFO] [call] media heartbeat rx_frames_d=250 tx_frames_d=250"
    rows = [row] * (cap // (len(row) + 1) + 50)
    blob = "\n".join(rows + ["derived_key [" + lst(1, 32) + "] len 32", "last row"])
    expected = "\n".join(rows + ["derived_key " + M, "last row"])
    if len(blob.encode("utf-8")) <= cap:
        failures.append("cap: the test blob is not longer than the cap")
    if scrub_lines(blob) != expected:
        failures.append("cap: a blob of short rows longer than the cap was cut or changed by scrub_lines")
    # ... and one overlong row inside a blob loses only its own tail
    overlong = "abcdefghij klm " * 20000                          # 300000 bytes
    blob2 = "before\n" + overlong + "\nafter [" + lst(1, 8) + "]\nlast"
    expected2 = "before\n" + overlong[:cap] + M + "\nafter " + M + "\nlast"
    if scrub_lines(blob2) != expected2:
        failures.append("cap: an overlong row inside a blob is not cut on its own")
    print("  cap: 6 checks")


def check_linear_time(failures):
    n = 250000
    cases = {
        "open brackets": "[1,2,3,4,5,6,7," * (n // 15),
        "open parentheses": "(" * n,
        "broken hex runs": "aa bb cc dd ee ff 00 zz " * (n // 24),
        "secret [ repeated": "secret [" * (n // 8),
        "salt ] repeated": "salt ] " * (n // 7),
        "digits": "1234567890" * (n // 10),
        "clean": "call media heartbeat rx_frames_d=250 " * (n // 38),
    }
    for name, text in cases.items():
        t0 = time.time()
        scrub(text)
        took = time.time() - t0
        if took > 30.0:
            failures.append("linear time: '%s' took %.1f s for %d bytes" % (name, took, len(text)))
    line_cases = {
        "secret [ on every line": "secret [\n" * (n // 9),
        "derived_key on every line": "derived_key [1,2,3]\n" * (n // 20),
        "open brackets, one per line": "[1,2,3,4,5,6,7,\n" * (n // 16),
        "tail fragments, one per line": "1]\n" * (n // 3),
        "line feeds only": "\n" * n,
        "clean rows": "call media heartbeat rx_frames_d=250 tx_frames_d=250\n" * (n // 52),
    }
    for name, text in line_cases.items():
        t0 = time.time()
        scrub_lines(text)
        took = time.time() - t0
        if took > 30.0:
            failures.append("linear time: scrub_lines '%s' took %.1f s for %d bytes" % (name, took, len(text)))
    print("  linear time: %d pathological 250 KB texts, %d multi-line texts" % (len(cases), len(line_cases)))


def check_fuzz(failures):
    pieces = ["[", "]", "(", ")", ",", ";", " ", "\n", ":", "=", "<", ">", "-", ".", "_", "0", "1", "7",
              "12", "255", "256", "1234", "a", "f", "aa", "0f", "zz", "derived_key", "DERIVED_KEY",
              "secret", "slat", "salt", "len", "32", M, "é", "\U0001F680"]
    rng = random.Random(20260921)
    for _ in range(20000):
        line = "".join(rng.choice(pieces) for _ in range(rng.randint(0, 60)))
        out = scrub(line)
        if scrub(out) != out:
            failures.append("fuzz: not idempotent for %r" % line[:60])
            return
    # scrub_lines: idempotent on any text with line feeds, equal to scrub without one, equal to the
    # per-line reference, and a blob of rows that were each scrubbed is a fixed point
    for _ in range(20000):
        text = "".join(rng.choice(pieces) for _ in range(rng.randint(0, 80)))
        out = scrub_lines(text)
        if scrub_lines(out) != out:
            failures.append("fuzz: scrub_lines not idempotent for %r" % text[:60])
            return
        if out != per_line_reference(text):
            failures.append("fuzz: scrub_lines differs from the per-line reference for %r" % text[:60])
            return
        if "\n" not in text and out != scrub(text):
            failures.append("fuzz: scrub_lines differs from scrub on a single line %r" % text[:60])
            return
        rows = [rng.choice(pieces) + "".join(rng.choice(pieces) for _ in range(rng.randint(0, 12)))
                for _ in range(rng.randint(1, 8))]
        rows = [r.replace("\n", " ") for r in rows]
        blob = "\n".join(scrub(r) for r in rows)
        if scrub_lines(blob) != blob:
            failures.append("fuzz: a blob of scrubbed rows is not a fixed point: %r" % blob[:80])
            return
    print("  fuzz: 20000 random lines and 20000 random multi-line texts, idempotent")


def main():
    failures = []
    print("=== KeyMaterialScrubber parity (Python port) ===")
    check_vectors(failures)
    check_lines(failures)
    check_split_lines(failures)
    check_cap(failures)
    check_linear_time(failures)
    check_fuzz(failures)
    if failures:
        for f in failures:
            print("  [FAIL] " + f)
        print("\nRESULT: FAIL (%d)" % len(failures))
        return 1
    print("\nRESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
