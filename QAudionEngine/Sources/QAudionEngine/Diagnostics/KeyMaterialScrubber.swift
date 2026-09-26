import Foundation

/// W-KEYSCRUB (2026-09-21) -- last line of defence that keeps KEY BYTES out of log text.
///
/// WHY: the native crypto library on the iPhone prints key material to stdout during call
/// handshakes and re-keys, for example `derived_key [1,2,...,32] len 32` and
/// `secret [...] len 32 slat << [] len 0` (the second word is the library's own typo of
/// "salt"). The app captures stdout into `RuntimeLogSink` (tag `stdout`) and the opt-in live
/// log shipper uploaded those lines in clear (299 lines in 90 blobs in 7 days). The proper fix
/// is to stop printing them in the native library; until every installed build has it this
/// scrub makes sure the text never reaches the ring, the on-screen viewer, the log export, a
/// bug report, the shipper or the telemetry attributes.
///
/// TWO ENTRY POINTS. `scrub(_:)` treats its argument as ONE log entry: "the text" below is the
/// whole argument, so `derived_key` takes everything after it, even over several lines.
/// `scrubLines(_:)` is for a text that is COMPOSED of several entries (the bug-report tail
/// `recentLogsAsString`, a multi-line message): it cuts the text at every line feed and scans each
/// line on its own, so "the text" below is ONE LINE and the lines after a key line survive. The app
/// calls only `scrubLines` (`LogRedactor.scrubKeyMaterial`), because the same text is scrubbed
/// more than once on its way out: `scrub` on a blob of lines that were already scrubbed is NOT a
/// fixed point (the marker after `derived_key` is not "nothing after the word", so it would eat
/// every later line), `scrubLines` is.
///
/// WHAT IT MATCHES (all on the UTF-8 bytes; every pattern is ASCII, so a multi-byte character
/// can never be cut). Each match is replaced by `marker` and the rest of the text is kept:
///
///   (a) `derived_key` (any case): everything AFTER the word, up to the end of the text,
///       once the separators `= : < >` and spaces after the word are skipped.
///   (b) `secret`, `slat` or `salt` (any case) followed, after spaces and `= : < >`, by a
///       bracketed group `[...]` or `(...)`: the whole group (balanced, nested groups
///       included; an unclosed group runs to the end of the text). An empty group `[]` is
///       not key material and is left alone, so `slat << [] len 0` stays readable.
///   (c) any `[...]` or `(...)` list of 8 OR MORE decimal integers 0-255 separated by `,` or
///       `;` (spaces and newlines allowed, one trailing separator allowed). A list that is CUT
///       by the end of the text (no closing bracket: the head of a split line, see (e)) counts
///       with as few as ONE integer.
///   (d) 8 OR MORE consecutive two-digit hex bytes separated by a single space or colon
///       (`aa bb cc ...`, `aa:bb:cc:...`); every pair must be a whole token, so 4-digit
///       groups (IPv6, 0x prefixes, longer hex) and a 6-byte MAC address do not match.
///   (e) a TAIL FRAGMENT: a text that STARTS in the middle of an integer list, that is
///       `[,;] int ([,;] int)* [,;] ]` at the very beginning (after spaces), for example
///       `18,19,...,32] len 32`. `RuntimeLogSink.attachStdoutTee` reads the pipe in 4096-byte
///       chunks and splits every chunk into lines on its own, so a long key line that straddles
///       a chunk boundary becomes two ring entries and the second one has no opening bracket
///       and no keyword (4 such lines in the 14-day corpus). A closing `]` OR `)` accepts a
///       single integer (Copilot follow-up to #109: `)` used to need two integers or a leading
///       separator, so the last value of a parenthesised key list split right before it, e.g.
///       `32) len 32`, was not caught). The price of treating `)` the same as `]`: a bare
///       `1) item` enumeration marker or the tail of a `(file.cc:118): ...` prefix now also
///       counts as a tail fragment -- accepted per this file's over-scrubbing policy.
///   (f) OVERLONG: only the first `maxScanBytes` (256 KiB) of a text are scanned, the rest is
///       replaced by the marker (fail closed): the work per text is bounded. The stdout tee
///       never produces a line longer than 4096 bytes, so this only ever applies to a very
///       long `RTLog` message. With `scrubLines` the bound is per LINE, so a blob made of many
///       short lines is never cut, however long it is.
///
/// POLICY: over-scrubbing is deliberate. A list of 8 or more small integers in brackets is
/// scrubbed in ANY log line, whatever it means (`hist [1,2,3,4,5,6,7,8]` becomes
/// `hist [REDACTED:keybytes]`), and so is every word `derived_key`. A list of 7, a MAC
/// address, timestamps, versions (`1.0.1180`), IPv4 (`1.2.3.4`), UUIDs and base64 are not
/// matched. A key printed in a shape none of the patterns knows (say raw base64 without a
/// keyword) is NOT caught here; `LogRedactor` still catches the long runs.
///
/// COST: `scrub` runs on the MAIN thread for every line (`RuntimeLogSink.record`). A clean
/// line is one linear pass over its bytes with no allocation and is returned as is; only a
/// line with a match allocates. There is no regular expression and nothing backtracks: every
/// attempt either matches (and the scan continues after it) or fails within the same run of
/// characters, so the worst case is linear in the length of the text.
///
/// Idempotent PER LINE: `scrub(scrub(x)) == scrub(x)` for a text WITHOUT a line feed (the marker
/// itself is never matched again) whose scrubbed form is not longer than `maxScanBytes`, that is
/// every real log line. Past that size a second pass may cut the text again: it only ever makes
/// it shorter. For a text with line feeds the fixed point is `scrubLines`:
/// `scrubLines(scrubLines(x)) == scrubLines(x)`, and a blob whose lines were each scrubbed on
/// their own (`scrub` of one line) comes back from `scrubLines` unchanged. `scrub` alone is not
/// idempotent on such a blob (see above).
public enum KeyMaterialScrubber {

    /// What replaces a match. `grep REDACTED:keybytes` finds every place the scrub acted.
    public static let marker: String = "[REDACTED:keybytes]"

    /// Only this many bytes of a text are scanned; the rest is replaced by the marker.
    public static let maxScanBytes: Int = 256 * 1024

    /// Smallest integer list (c) and hex run (d) that count as key material.
    static let minListInts: Int = 8
    static let minHexBytes: Int = 8

    // MARK: - Public API

    /// Returns `line` with every key-material match replaced by `marker`. A line with no match
    /// is returned unchanged (the same string, nothing copied).
    public static func scrub(_ line: String) -> String {
        if line.isEmpty { return line }
        var work: String = line
        let replaced: String? = work.withUTF8 { (buf: UnsafeBufferPointer<UInt8>) -> String? in
            return KeyMaterialScrubber.scrubBytes(buf)
        }
        if let result = replaced { return result }
        return line
    }

    /// Like `scrub`, for a text that is made of several lines (a bug-report tail, a message with
    /// line feeds): the text is cut at every line feed (byte 0x0A), each line is scanned on its own,
    /// with its own `maxScanBytes` cap, and the line feeds are kept. So a `derived_key` (or an
    /// unclosed group after `secret`) takes the rest of ITS line only, and the lines after it
    /// survive. A text without a line feed gives exactly `scrub`. Nothing is copied when no line
    /// matches (the same string comes back). A list of integers cut by ONE line feed is still
    /// caught (its first line is a head fragment, its second a tail fragment, the way the stdout
    /// tee cuts a key line); a list spread over three or more lines is not (the middle lines are
    /// plain numbers and are left alone: the native library never prints one like that).
    public static func scrubLines(_ text: String) -> String {
        if text.isEmpty { return text }
        var work: String = text
        let replaced: String? = work.withUTF8 { (buf: UnsafeBufferPointer<UInt8>) -> String? in
            return KeyMaterialScrubber.scrubLinesBytes(buf)
        }
        if let result = replaced { return result }
        return text
    }

    // MARK: - Matches (internal, for tests)

    enum Kind: Equatable {
        case derivedKey
        case keywordList
        case intList
        case tailFragment
        case hexRun
        case overlong
    }

    struct Match: Equatable {
        /// Byte offset of the first matched byte.
        let start: Int
        /// Byte offset just after the last matched byte.
        let end: Int
        let kind: Kind
    }

    /// Every match of `line`, in order, before touching matches are merged.
    static func matches(in line: String) -> [Match] {
        var work: String = line
        let found: [Match] = work.withUTF8 { (buf: UnsafeBufferPointer<UInt8>) -> [Match] in
            return KeyMaterialScrubber.scan(buf)
        }
        return found
    }

    // MARK: - Output

    private static let markerBytes: [UInt8] = Array(KeyMaterialScrubber.marker.utf8)
    private static let derivedKeyWord: [UInt8] = Array("derived_key".utf8)
    private static let secretWord: [UInt8] = Array("secret".utf8)
    private static let slatWord: [UInt8] = Array("slat".utf8)
    private static let saltWord: [UInt8] = Array("salt".utf8)

    /// nil when nothing matched (the caller then returns the original string).
    private static func scrubBytes(_ buf: UnsafeBufferPointer<UInt8>) -> String? {
        let found: [Match] = scan(buf)
        if found.isEmpty { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(buf.count + 32)
        appendReplaced(buf, found, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Appends `buf` to `out` with every match of `found` (in order, from `scan(buf)`) replaced by
    /// the marker. Matches that touch or overlap are one replacement (one marker, not two).
    private static func appendReplaced(_ buf: UnsafeBufferPointer<UInt8>, _ found: [Match], into out: inout [UInt8]) {
        var pos: Int = 0
        var index: Int = 0
        while index < found.count {
            let start: Int = found[index].start
            var end: Int = found[index].end
            index += 1
            while index < found.count && found[index].start <= end {
                if found[index].end > end { end = found[index].end }
                index += 1
            }
            if start > pos {
                out.append(contentsOf: buf[pos..<start])
            }
            out.append(contentsOf: markerBytes)
            pos = end
        }
        if pos < buf.count {
            out.append(contentsOf: buf[pos..<buf.count])
        }
    }

    /// nil when no line matched (the caller then returns the original string). Each line (the bytes
    /// between two 0x0A) is scanned on its own; the line feeds are copied as they are.
    private static func scrubLinesBytes(_ buf: UnsafeBufferPointer<UInt8>) -> String? {
        let n: Int = buf.count
        var out: [UInt8] = []
        var changed: Bool = false
        // Once `changed`, the bytes of `buf` before `copied` are already in `out`.
        var copied: Int = 0
        var start: Int = 0
        while start <= n {
            var end: Int = start
            while end < n && buf[end] != 0x0A {
                end += 1
            }
            if end > start {
                let line: UnsafeBufferPointer<UInt8> = UnsafeBufferPointer<UInt8>(rebasing: buf[start..<end])
                let found: [Match] = scan(line)
                if !found.isEmpty {
                    if !changed {
                        changed = true
                        out.reserveCapacity(n + 32)
                    }
                    out.append(contentsOf: buf[copied..<start])
                    appendReplaced(line, found, into: &out)
                    copied = end
                }
            }
            start = end + 1
        }
        if !changed { return nil }
        if copied < n {
            out.append(contentsOf: buf[copied..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - The scanner

    static func scan(_ b: UnsafeBufferPointer<UInt8>) -> [Match] {
        let n: Int = b.count
        var found: [Match] = []
        if n == 0 { return found }

        var limit: Int = n
        if n > maxScanBytes {
            limit = maxScanBytes
            // Never cut inside a multi-byte character: back up to the start of one.
            while limit > 0 && (b[limit] & 0xC0) == 0x80 {
                limit -= 1
            }
        }

        var i: Int = 0
        let tail: Int = matchTailFragment(b, limit)
        if tail >= 0 {
            found.append(Match(start: 0, end: tail, kind: .tailFragment))
            i = tail
        }

        while i < limit {
            let c: UInt8 = b[i]

            // (c) a bracketed or parenthesised list of 8+ integers
            if isOpen(c) {
                let end: Int = matchIntList(b, i, limit)
                if end >= 0 {
                    found.append(Match(start: i, end: end, kind: .intList))
                    i = end
                } else {
                    i += 1
                }
                continue
            }

            let lc: UInt8 = lower(c)

            // (a) derived_key: the rest of the text
            if lc == 0x64 && matchWord(b, i, limit, derivedKeyWord) {
                let s: Int = skipSeparators(b, i + derivedKeyWord.count, limit)
                if s < limit && !equalsMarker(b, s, limit) {
                    found.append(Match(start: s, end: limit, kind: .derivedKey))
                }
                i = limit
                continue
            }

            // (b) secret / slat / salt followed by a bracketed group
            if lc == 0x73 {
                let k: Int = keywordLength(b, i, limit)
                if k > 0 {
                    let p: Int = skipSeparators(b, i + k, limit)
                    if p < limit && isOpen(b[p]) {
                        let group: GroupResult = groupEnd(b, p, limit)
                        if !groupIsBlank(b, p, group) && !equalsMarker(b, p, group.end) {
                            found.append(Match(start: p, end: group.end, kind: .keywordList))
                        }
                        i = group.end
                        continue
                    }
                }
            }

            // (d) 8+ hex bytes separated by a space or a colon
            if isHex(c) && (i == 0 || !isAlnum(b[i - 1])) {
                let end: Int = matchHexRun(b, i, limit)
                if end >= 0 {
                    found.append(Match(start: i, end: end, kind: .hexRun))
                    i = end
                    continue
                }
            }

            i += 1
        }

        // (f) the part that was not scanned
        if n > limit {
            found.append(Match(start: limit, end: n, kind: .overlong))
        }
        return found
    }

    // MARK: - Integer lists (c) and tail fragments (e)

    enum RunState {
        /// Ran into the end of the scan window.
        case ended
        /// Stopped just after a closing bracket.
        case closed
        /// Met something that is not part of an integer list.
        case bad
    }

    struct RunResult {
        let count: Int
        let pos: Int
        let state: RunState
    }

    /// Integers 0-255 (1 to 3 digits) separated by `,` or `;` (spaces allowed, one trailing
    /// separator allowed), starting at `start`. `.closed`: `pos` is just after the closing
    /// bracket. `.ended`: `pos == limit`. `.bad`: `pos` is the offending byte.
    private static func intRun(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ limit: Int) -> RunResult {
        var p: Int = start
        var count: Int = 0
        while true {
            p = skipSpaces(b, p, limit)
            if p >= limit {
                return RunResult(count: count, pos: limit, state: .ended)
            }
            let c: UInt8 = b[p]
            if isClose(c) {
                return RunResult(count: count, pos: p + 1, state: .closed)
            }
            if !isDigit(c) {
                return RunResult(count: count, pos: p, state: .bad)
            }
            var q: Int = p
            var value: Int = 0
            while q < limit && isDigit(b[q]) {
                value = value * 10 + Int(b[q] - 0x30)
                q += 1
                if q - p > 3 {
                    return RunResult(count: count, pos: q, state: .bad)
                }
            }
            if value > 255 {
                return RunResult(count: count, pos: q, state: .bad)
            }
            count += 1
            p = skipSpaces(b, q, limit)
            if p >= limit {
                return RunResult(count: count, pos: limit, state: .ended)
            }
            let d: UInt8 = b[p]
            if d == 0x2C || d == 0x3B {
                p += 1
                continue
            }
            if isClose(d) {
                return RunResult(count: count, pos: p + 1, state: .closed)
            }
            return RunResult(count: count, pos: p, state: .bad)
        }
    }

    /// `b[i]` is `[` or `(`. The end (exclusive) of a closed list of 8 or more integers, or of a
    /// list that is cut by the end of the window (a head fragment, see `matchTailFragment`)
    /// with at least one integer; -1 when it is neither.
    private static func matchIntList(_ b: UnsafeBufferPointer<UInt8>, _ i: Int, _ limit: Int) -> Int {
        let run: RunResult = intRun(b, i + 1, limit)
        if run.state == .bad { return -1 }
        if run.state == .ended {
            if run.count >= 1 { return run.pos }
            return -1
        }
        if run.count >= minListInts { return run.pos }
        return -1
    }

    /// A text that starts in the middle of an integer list: see (e). Returns the end
    /// (exclusive) of the fragment, -1 if the text does not start like that.
    private static func matchTailFragment(_ b: UnsafeBufferPointer<UInt8>, _ limit: Int) -> Int {
        var p: Int = skipSpaces(b, 0, limit)
        var lead: Bool = false
        if p < limit && (b[p] == 0x2C || b[p] == 0x3B) {
            lead = true
            p = skipSpaces(b, p + 1, limit)
        }
        let run: RunResult = intRun(b, p, limit)
        if run.state != .closed || run.count < 1 { return -1 }
        // Copilot follow-up to #109: `)` is accepted symmetrically with `]` here. A
        // parenthesised key list ("secret (1,2,...,32) len 32") split by the stdout tee right
        // before its last value leaves a tail fragment like "32) len 32" -- only one integer
        // before the closing delimiter, same shape as the `]` case this already caught.
        if b[run.pos - 1] == 0x5D || b[run.pos - 1] == 0x29 || run.count >= 2 || lead {
            return run.pos
        }
        return -1
    }

    // MARK: - Keyword groups (b)

    struct GroupResult {
        /// Exclusive end of the group; the end of the window when it is not closed.
        let end: Int
        let closed: Bool
    }

    /// `b[p]` is `[` or `(`: the balanced group that starts there (nesting counted).
    private static func groupEnd(_ b: UnsafeBufferPointer<UInt8>, _ p: Int, _ limit: Int) -> GroupResult {
        var depth: Int = 0
        var q: Int = p
        while q < limit {
            let c: UInt8 = b[q]
            if isOpen(c) {
                depth += 1
            } else if isClose(c) {
                depth -= 1
                if depth == 0 {
                    return GroupResult(end: q + 1, closed: true)
                }
            }
            q += 1
        }
        return GroupResult(end: limit, closed: false)
    }

    /// True when nothing but white space sits between the brackets (`[]`, `[ ]`).
    private static func groupIsBlank(_ b: UnsafeBufferPointer<UInt8>, _ p: Int, _ group: GroupResult) -> Bool {
        let stop: Int = group.closed ? group.end - 1 : group.end
        var q: Int = p + 1
        while q < stop {
            if !isSpace(b[q]) { return false }
            q += 1
        }
        return true
    }

    private static func keywordLength(_ b: UnsafeBufferPointer<UInt8>, _ i: Int, _ limit: Int) -> Int {
        if matchWord(b, i, limit, secretWord) { return secretWord.count }
        if matchWord(b, i, limit, slatWord) { return slatWord.count }
        if matchWord(b, i, limit, saltWord) { return saltWord.count }
        return 0
    }

    // MARK: - Hex runs (d)

    /// True when `b[p]` and `b[p + 1]` are hex digits and that pair is a whole token (the byte
    /// after it, if any, is not a letter or digit).
    private static func isHexPairToken(_ b: UnsafeBufferPointer<UInt8>, _ p: Int, _ limit: Int) -> Bool {
        if p + 1 >= limit { return false }
        if !isHex(b[p]) || !isHex(b[p + 1]) { return false }
        if p + 2 >= limit { return true }
        return !isAlnum(b[p + 2])
    }

    /// 8 or more two-digit hex bytes separated by one space or colon, starting at `i` (the caller
    /// has checked that `i` starts a token). Returns the end (exclusive) of a full match. Also
    /// returns the scan boundary `limit` (Copilot follow-up to #109) when the run was cut by the
    /// cap with fewer than `minHexBytes` pairs visible: the caller can never rule out more hex
    /// bytes past `limit`, so the visible prefix is treated as sensitive too, instead of being
    /// left unredacted while only the separate `.overlong` span (`limit..<n`) gets scrubbed. That
    /// match ends exactly at `limit`, touching the `.overlong` match that starts there, so
    /// `appendReplaced` merges the two into one marker. -1 when neither (a genuine, well-inside-
    /// the-window end of a run shorter than `minHexBytes`, OR the window's `limit` is simply the
    /// real end of the text/line -- `b.count == limit` -- so there is nothing to fail closed about).
    private static func matchHexRun(_ b: UnsafeBufferPointer<UInt8>, _ i: Int, _ limit: Int) -> Int {
        // Only a REAL cap cut (more bytes exist past `limit`) can leave more key bytes unseen.
        // When `limit` is just the end of the whole buffer (b.count == limit, the common case for
        // any text/line shorter than the 256 KiB cap), reaching it is a genuine, unambiguous end.
        let truncated: Bool = b.count > limit
        var count: Int = 0
        var p: Int = i
        var lastEnd: Int = -1
        var cutByCap: Bool = false
        while isHexPairToken(b, p, limit) {
            count += 1
            lastEnd = p + 2
            if lastEnd < limit && isHexSeparator(b[lastEnd]) {
                p += 3
            } else {
                // The pair itself reached the boundary: there is no room left to see whether a
                // separator and more pairs follow, so this is a cap cut, not a genuine end --
                // but only when the buffer truly continues past `limit`.
                if truncated && lastEnd >= limit { cutByCap = true }
                break
            }
        }
        if !cutByCap && truncated && p + 1 >= limit {
            // The top-of-loop check failed for lack of room (not content): the cap cut before
            // the next candidate pair could even be looked at.
            cutByCap = true
        }
        if count >= minHexBytes { return lastEnd }
        if cutByCap && count >= 1 { return limit }
        return -1
    }

    // MARK: - Byte helpers

    private static func matchWord(_ b: UnsafeBufferPointer<UInt8>, _ i: Int, _ limit: Int, _ word: [UInt8]) -> Bool {
        let n: Int = word.count
        if i + n > limit { return false }
        var k: Int = 0
        while k < n {
            if lower(b[i + k]) != word[k] { return false }
            k += 1
        }
        return true
    }

    private static func equalsMarker(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        if end - start != markerBytes.count { return false }
        var k: Int = 0
        while k < markerBytes.count {
            if b[start + k] != markerBytes[k] { return false }
            k += 1
        }
        return true
    }

    private static func skipSpaces(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ limit: Int) -> Int {
        var p: Int = start
        while p < limit && isSpace(b[p]) {
            p += 1
        }
        return p
    }

    private static func skipSeparators(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ limit: Int) -> Int {
        var p: Int = start
        while p < limit && isKeywordSeparator(b[p]) {
            p += 1
        }
        return p
    }

    private static func lower(_ c: UInt8) -> UInt8 {
        if c >= 0x41 && c <= 0x5A { return c + 32 }
        return c
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        switch c {
        case 0x20, 0x09, 0x0A, 0x0D: return true
        default: return false
        }
    }

    private static func isDigit(_ c: UInt8) -> Bool {
        return c >= 0x30 && c <= 0x39
    }

    private static func isHex(_ c: UInt8) -> Bool {
        switch c {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
        default: return false
        }
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        switch c {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    /// `[` or `(`
    private static func isOpen(_ c: UInt8) -> Bool {
        return c == 0x5B || c == 0x28
    }

    /// `]` or `)`
    private static func isClose(_ c: UInt8) -> Bool {
        return c == 0x5D || c == 0x29
    }

    /// Between a keyword and its value: white space, `=`, `:`, `<`, `>`.
    private static func isKeywordSeparator(_ c: UInt8) -> Bool {
        switch c {
        case 0x20, 0x09, 0x0A, 0x0D, 0x3D, 0x3A, 0x3C, 0x3E: return true
        default: return false
        }
    }

    /// Between two hex bytes: one space or one colon.
    private static func isHexSeparator(_ c: UInt8) -> Bool {
        return c == 0x20 || c == 0x3A
    }
}
