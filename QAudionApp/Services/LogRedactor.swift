import Foundation
import QAudionEngine

/// W-LIVELOGOFFMAIN (2026-09-21) -- the log redactors, moved here VERBATIM from
/// `RuntimeLogSink` (regexes, ordering, sentinels and placeholder unchanged).
///
/// Why moved: `RuntimeLogSink` is `@MainActor`, so its redactors were main-actor
/// isolated too, and the log shipper (`LiveLogStreamer`) had no choice but to run them --
/// up to 5000 ring entries, several regex passes each -- ON THE MAIN THREAD. That was the
/// source of the iPhone main-thread stalls of 0.7-4.5 s measured in call 4da935fd
/// (2026-09-20). This enum has no actor isolation and no mutable state: the regexes are
/// immutable `NSRegularExpression`s (thread-safe to match with), so the shipper's worker
/// can redact off the main thread. `RuntimeLogSink.redact` / `redactStructured` are now
/// one-line forwards to it, so every existing call site (text export, bug report, the
/// telemetry attribute scrub, the stdout tee) is untouched and still goes through the
/// SAME single implementation.
///
/// The doc comments below are the originals and still describe the rules.
///
/// W-KEYSCRUB (2026-09-21) -- BOTH redactors now start with `scrubKeyMaterial` (the pure
/// `KeyMaterialScrubber` of QAudionEngine): key bytes the native library prints to stdout
/// (`derived_key [..] len 32`, `secret [..] len 32 slat [..]`, byte lists, hex byte runs) are
/// replaced by `[REDACTED:keybytes]` before any of the regexes below run. `RuntimeLogSink.record`
/// applies the same function at ring entry, so this is the second layer (defence in depth) for
/// every path that reads text: the stdout tee (`redact`, off-main), the text export, the bug
/// report tail, the live-log worker and the telemetry attribute scrub (`redactStructured`).
enum LogRedactor {

    /// W-KEYSCRUB -- one-line forward so `RuntimeLogSink` needs no import of the engine module.
    /// Pure, thread-safe, linear in the length of `text`; a clean text comes back untouched.
    ///
    /// LINE ORIENTED on purpose (`scrubLines`, not `scrub`): `redactStructured` also runs on a
    /// composed multi-line text (`ReportCrypto.buildDiagSummary` gets the last lines of the
    /// bug-report log, whose lines were already scrubbed), and `scrub` reads
    /// "everything after `derived_key`" as the rest of the TEXT, so on such a blob one
    /// `derived_key <marker>` line would swallow every line after it (the newest ones, the ones
    /// the 200-character diag summary keeps). `scrubLines` scans each line on its own, so the
    /// lines around a key line survive and scrubbing twice gives the same text.
    static func scrubKeyMaterial(_ text: String) -> String {
        return KeyMaterialScrubber.scrubLines(text)
    }

    /// SECURITY H-2 — best-effort secret scrubber for the
    /// stdout/stderr tee. Masks bearer tokens, `token=`/`token:`
    /// values, Authorization headers, and any long hex/base64 run
    /// (>= 24 chars, which catches raw keys / JWTs / hashes). Not a
    /// substitute for not logging secrets, but stops the common
    /// leak paths from reaching the uploadable ring buffer.
    ///
    /// Compiled once; the regexes are static-let so the per-line
    /// hot path only does `stringByReplacingMatches`.
    private static let redactPlaceholder: String = "***REDACTED***"

    // Single source of truth for the keyword alternation, shared by the
    // stdout-tee redact() and the egress redactStructured(). P2 extends
    // the set with crypto-secret keywords (psk|seed|mnemonic|privkey|
    // private-key|mlkem|sframe|kyber). `keyfp` is deliberately NOT in
    // the alternation, so keyfp=<8-16hex> short fingerprints survive.
    //
    // Value-introducer is ['":=] (quote/colon/equals) optionally followed
    // by whitespace -- a BARE SPACE after the keyword does NOT arm the
    // rule, so prose like "PSK selected keyfp=..." keeps the keyfp the
    // unseal-debug diagnostics need (the old [\"'\s:=]+ armed on a space
    // and ate the following token). The value run is [^\s\x{0001}]+ which
    // EXCLUDES the U+0001 sentinel byte used by redactStructured() to
    // stash call_id UUIDs / fingerprints, so a keyworded value can never
    // swallow a stashed-and-restored diagnostic. (Harmless to the
    // stdout-tee redact() path, which never produces sentinels.)
    private static let secretPrefixedEgress: NSRegularExpression = try! NSRegularExpression(
        pattern: #"(?i)(bearer|authorization|token|secret|api[-_]?key|password|psk|seed|mnemonic|privkey|private[-_]?key|mlkem|sframe|kyber)([\"':=]\s*)[^\s\x{0001}]+"#)

    private static let redactRegexes: [NSRegularExpression] = {
        // Patterns are compile-time constants; force-try is safe.
        let secretPrefixed = secretPrefixedEgress
        let longBlob = try! NSRegularExpression(
            pattern: #"[A-Za-z0-9+/=_-]{24,}"#)
        return [secretPrefixed, longBlob]
    }()

    /// I2 (2026-09-28, TURN-stuck-on-P2P fix) — the raw libwebrtc debug
    /// lines this file's own doc comment names as flowing through the
    /// stdout/stderr tee (`port.cc`, `connection.cc`, `turn_port.cc` — ICE
    /// candidate/pair diagnostics, reachable whenever
    /// `raiseDebugLogLevelForNativeSrtpSession()` is active or the callback
    /// logger's own `.info` severity picks them up) print the candidate's
    /// connection address and port in the clear — the same field the
    /// Android-side privacy fix reduces to type/protocol/relay/cost only
    /// (`PeerConnectionHolder.kt`'s `redactCandidateSdp`). `<ip>` covers a
    /// dotted-quad optionally followed by `:port`; the second pattern covers
    /// a bracketed or bare IPv6 address, also with an optional port.
    /// Deliberately over-inclusive (any hex run that merely looks like an
    /// IPv6 address is masked too) — for a redactor, over-redaction is the
    /// safe failure mode.
    ///
    /// I8 FIX (2026-09-29, group video-publish investigation): the pinned
    /// WebRTC binary itself ALREADY partially redacts these same candidate/
    /// TURN-server addresses before a line ever reaches this file — release
    /// builds compile `rtc::IPAddress::ToSensitiveString()` in, which masks
    /// only the LAST IPv4 octet with a literal `x` (e.g. a real
    /// `connection.cc`/`turn_port.cc` line ships an address shaped like
    /// `a.b.c.x`, three real octets still in the clear) and the equivalent
    /// partial form for IPv6. Confirmed against a real collected phone log
    /// (`turn_port.cc` TURN-server lines): because that trailing `x` is not
    /// a digit, the ORIGINAL `\d{1,3}`-only last-octet/hextet requirement
    /// below never matched it, so those three real octets shipped
    /// untouched in the exported/uploaded log blob — only a fully-numeric
    /// address (already the exception, not the rule, for these specific
    /// trace lines in a release build) was ever fully masked. Both regexes
    /// now also accept that literal `x` as the last group so libwebrtc's
    /// OWN partial mask no longer defeats this one — the whole address,
    /// including the octets/hextets libwebrtc left in the clear, collapses
    /// to `<ip>` either way.
    private static let ipv4AddressRegex = try! NSRegularExpression(
        pattern: #"\b(?:\d{1,3}\.){3}(?:\d{1,3}|x)(?::\d{1,5})?\b"#)
    private static let ipv6AddressRegex = try! NSRegularExpression(
        pattern: #"(\[[0-9a-fA-Fx:]{2,45}\](?::\d{1,5})?)|(\b(?:[0-9a-fA-F]{1,4}:){2,7}(?:[0-9a-fA-F]{1,4}|x)\b(?:/\d{1,3})?)"#)

    /// I2 — mask IPv4/IPv6 addresses (and a trailing `:port`) to `<ip>`.
    /// Applied BEFORE the secret/blob rules in both `redact()` and
    /// `redactStructured()`: an address is short enough that the >=20/24-char
    /// blob rules would usually miss it entirely.
    private static func maskIpAddresses(_ text: String) -> String {
        var working = text
        let full1 = NSRange(working.startIndex..<working.endIndex, in: working)
        working = ipv4AddressRegex.stringByReplacingMatches(
            in: working, options: [], range: full1, withTemplate: "<ip>")
        let full2 = NSRange(working.startIndex..<working.endIndex, in: working)
        working = ipv6AddressRegex.stringByReplacingMatches(
            in: working, options: [], range: full2, withTemplate: "<ip>")
        return working
    }

    static func redact(_ line: String) -> String {
        var working: String = LogRedactor.scrubKeyMaterial(line)
        working = LogRedactor.maskIpAddresses(working)
        for rx in redactRegexes {
            let full = NSRange(working.startIndex..<working.endIndex, in: working)
            let template: String = redactPlaceholder
            working = rx.stringByReplacingMatches(in: working,
                                                  options: [],
                                                  range: full,
                                                  withTemplate: template)
        }
        return working
    }

    // P2 - EGRESS redactor for the upload boundary (the live-log shipper, `LiveLogWorker`).
    // Distinct from redact(_:) (stdout-tee): this MUST preserve
    // diagnostics that fetch-ios-live.py / correlate-call.py /
    // symbolicate.py / ship-ios-logs.py parse, while still removing
    // secrets at rest. Unconditional security control - never flag-gated.
    //
    // Strategy (ASCII-only U+0001 sentinels):
    //   1a. STASH call_id UUIDs (8-4-4-4-12) so neither the blob rule nor
    //       the residual sweep can eat them (correlate-call / shipper
    //       derive short8/h8 from full UUIDs).
    //   1b. STASH labelled short-hex fingerprints (keyfp/short8/h8/fp/
    //       selectedPskFingerprint = <8-16 hex>) -- these are the exact
    //       identifiers the W574n PSK-convergence / unseal diagnostics
    //       reference. Stashing them BEFORE any scrub is what makes the
    //       keyfp= form survive (the residual sweep would otherwise eat a
    //       run that includes the '=' separator).
    //   1c. STASH letters-only Swift/ObjC identifier-shaped runs (I8 FIX,
    //       2026-09-29 -- e.g. `BCryptoGroupCallManager`,
    //       `performAcceptIncomingGroupCall`) so the blob/residual sweeps
    //       below cannot destroy them -- see `codeIdentifierRegex`'s own
    //       doc comment for why this shape essentially never matches an
    //       encoded secret. Skipped when the candidate is directly glued
    //       (no separator) to a `+`/`/`/`=`/`-` -- see `blobAdjacentChars`'s
    //       doc comment: that shape means the "identifier" is actually a
    //       substring of a longer secret-charset run, and stashing it would
    //       fragment that run below the length rules' thresholds instead of
    //       protecting a real prose identifier.
    //   2.  Redact dot-delimited JWTs (3 base64url segments) explicitly --
    //       the '.' fragments each segment below the blob/residual bars,
    //       so a JWT is invisible to length-only rules.
    //   3.  Run secretPrefixed (keyworded VALUES) + blob scrub (continuous
    //       base64url/hex run >= 24). The blob/residual charset now
    //       INCLUDES '-' because UUIDs AND fingerprints are already stashed
    //       out of the way, so '-' can no longer span a call_id -- this
    //       closes the base64url/JWT-with-hyphen fail-OPEN hole.
    //   4.  FAIL-CLOSED residual sweep: any mixed-alnum run >= 20 left over
    //       (charset incl '-') gets redacted. Runs BEFORE restore so the
    //       sentinels (which the U+0001 bytes break into short tokens)
    //       survive.
    //   5.  RESTORE stashed UUIDs + fingerprints + code identifiers.
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)
    // Labelled short-hex fingerprint (8-16 hex) preceded by a known label.
    // Stash the WHOLE match so neither the secret-keyword rule nor the
    // residual sweep can touch the fingerprint regardless of separator.
    private static let fingerprintRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(keyfp|selectedpskfingerprint|short8|h8|fp)([\s:=]+)([0-9a-fA-F]{8,16})\b"#)
    // I8 FIX (2026-09-29) -- TWO-LAYER check, not a shape regex alone (a
    // shape-only version of this was measured, against 500k random base52
    // strings -- the exact encoding scripts/ship-ios-logs.py's own
    // red-team fixtures target -- at a 2.7% full-match false-positive
    // rate: too high for a fail-closed security sweep). Layer 1
    // (`codeIdentifierRegex`): letters-only CamelCase/lowerCamelCase
    // candidate shape -- an optional lowercase lead word (covers an
    // `iPhone`-style single-letter lead too), then 2+ "words" of 1-3
    // uppercase letters (covers this codebase's own short prefixes --
    // BCrypto, QAudion -- without opening the door to a long ALL-CAPS run)
    // followed by >= 2 lowercase letters, then an optional trailing
    // acronym. NO digits and NO base64/hex punctuation are in the
    // character class at all, so a hex/base64/UUID/JWT run can never match
    // this regex regardless of shape. Layer 2 (`isLikelyCodeIdentifier`,
    // below): every "word" the candidate splits into must ALSO look
    // English-derived -- the SAME vowel/consonant-run/tripled-letter
    // discipline scripts/ship-ios-logs.py's own already-fuzzed free-word
    // gate uses (see that script's "FREE-WORD PLAUSIBILITY" comment).
    // Measured together against the same 500k-case corpus: ~0.09%
    // full-match false positives, ~0.002% substring false positives inside
    // a realistic 24-60-char encoded-secret length -- confirmed against
    // both `BCryptoGroupCallManager` and `performAcceptIncomingGroupCall`.
    private static let codeIdentifierRegex = try! NSRegularExpression(
        pattern: #"\b[a-z]*(?:[A-Z]{1,3}[a-z]{2,}){2,}[A-Z]{0,3}\b"#)
    // Splits an already-matched candidate into its constituent "words" for
    // the per-word plausibility check below (e.g. "BCryptoGroupCallManager"
    // -> ["B","Crypto","Group","Call","Manager"]).
    private static let identifierWordSplitRegex = try! NSRegularExpression(
        pattern: #"[A-Z][a-z]*|^[a-z]+"#)

    /// I8 FIX -- does `word` look like an English-derived identifier
    /// fragment rather than a random letter run? 'y' counts as a vowel
    /// (covers ordinary words like "crypto"/"sync"). A 1-character word
    /// (a lone acronym initial, or an `iPhone`-style lead) is always
    /// neutral/plausible -- there is no vowel/consonant shape to judge.
    private static func isPlausibleIdentifierWord(_ word: Substring, maxLength: Int = 12) -> Bool {
        let lower = Array(word.lowercased())
        guard lower.count >= 2 else { return true }
        guard lower.count <= maxLength else { return false }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        guard lower.contains(where: { vowels.contains($0) }) else { return false }
        var consonantRun = 0
        var vowelRun = 0
        for ch in lower {
            if vowels.contains(ch) {
                vowelRun += 1; consonantRun = 0
            } else {
                consonantRun += 1; vowelRun = 0
            }
            if consonantRun >= 3 || vowelRun >= 3 { return false }
        }
        for i in 0..<(lower.count - 2) {
            if lower[i] == lower[i + 1] && lower[i + 1] == lower[i + 2] { return false }
        }
        return true
    }

    /// I8 FIX -- layer 2 of the check above: every word `candidate` splits
    /// into must be individually plausible.
    private static func isLikelyCodeIdentifier(_ candidate: Substring) -> Bool {
        let s = String(candidate)
        let ns = s as NSString
        let words = identifierWordSplitRegex.matches(
            in: s, options: [], range: NSRange(location: 0, length: ns.length))
        guard !words.isEmpty else { return false }
        return words.allSatisfy { m in
            guard let r = Range(m.range, in: s) else { return false }
            return isPlausibleIdentifierWord(s[r])
        }
    }
    // Post-v5 — the allow-listed call close reasons, exact whole tokens only. They are fixed ASCII words
    // (no digits, no base64/hex punctuation beyond '_'), and `identity_key_mismatch` is 21 characters,
    // above the 20-character residual bar, so without this allow-list the telemetry `end_reason` and the
    // log lines that name it would ship as `***REDACTED***`.
    // W-CALLERBUSY -- plus the two outgoing-call outcomes (`busy`, `peer_offline`): `peer_offline` was being
    // shipped as `***REDACTED***` as the call's `end_reason`.
    private static let closeReasonRegex = try! NSRegularExpression(
        pattern: #"\b(?:"#
            + (CallCloseReason.allTokens + CallerTerminalOutcome.allCases.map { $0.closeToken }).joined(separator: "|")
            + #")\b"#)

    // Dot-delimited JWT: three base64url segments. Caught explicitly because
    // '.' fragments each segment below the length bars of the blob/residual
    // rules (the classic base64url fail-open).
    private static let jwtRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#)
    // High-entropy run: base64/base64url/hex >= 24. INCLUDES '-' (safe now
    // that UUIDs + fingerprints are sentinel-stashed) so it catches
    // base64url tokens, raw keys, ML-KEM ciphertext, hyphen-chunked blobs.
    private static let blobWithHyphen = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9+/=_-]{24,}"#)
    // Fail-closed residual: mixed run >= 20 (lower bar than the blob rule),
    // charset incl '-'. Crash frames ("QAudionApp ... + 12345") are pure
    // digits after '+' and survive; hex offsets "0x..." are guarded by the
    // leading-[0-9a-fA-Fx] negative lookbehind.
    private static let residualRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9a-fA-Fx])[A-Za-z0-9+/=_-]{20,}"#)

    /// P2 EGRESS redactor, also reused by `TelemetryService.emit()` so the
    /// structured-event path gets the SAME fail-closed scrub as the text
    /// path before `sealBatch`. Exposed (public) for that second egress;
    /// the implementation and its UNCONDITIONAL nature are unchanged.
    static func redactStructured(_ line: String) -> String {
        let (work, stash) = redactStructuredStashed(line)
        // --- 5. restore stashed UUIDs + fingerprints + code identifiers ---
        return restoreStashed(work, stash: stash)
    }

    /// Steps 0-4 of `redactStructured`: everything up to, but not including, the restore.
    /// `text` still carries the U+0001 sentinels and `stash` holds what they stand for, in
    /// index order. Split out so the restore (step 5) can be tested on its own against the
    /// quadratic loop it replaced.
    static func redactStructuredStashed(_ line: String) -> (text: String, stash: [String]) {
        // --- 0. W-KEYSCRUB: key bytes first, before anything can be stashed or restored ---
        var work: String = LogRedactor.scrubKeyMaterial(line)
        // --- 0b. I2: mask IP addresses/ports before anything else touches the line ---
        work = LogRedactor.maskIpAddresses(work)
        var stash: [String] = []

        // --- 1a. stash call_id UUIDs ---
        work = LogRedactor.stashMatches(of: uuidRegex, in: work, stash: &stash)
        // --- 1b. stash labelled short-hex fingerprints ---
        work = LogRedactor.stashMatches(of: fingerprintRegex, in: work, stash: &stash)
        // --- 1b2. post-v5: stash the five allow-listed call close reasons (`CallCloseReason`) so
        //          the residual sweep cannot eat the 21-character `identity_key_mismatch` ---
        work = LogRedactor.stashCloseReasons(in: work, stash: &stash)
        // --- 1c. I8 FIX: stash letters-only code-identifier-shaped runs
        //         that ALSO pass the per-word plausibility check ---
        work = LogRedactor.stashCodeIdentifiers(in: work, stash: &stash)

        // --- 2. dot-delimited JWT scrub ---
        let fullJwt = NSRange(work.startIndex..<work.endIndex, in: work)
        work = jwtRegex.stringByReplacingMatches(
            in: work, options: [], range: fullJwt, withTemplate: redactPlaceholder)

        // --- 3. secret keyword + hyphen-inclusive blob scrub ---
        let full1 = NSRange(work.startIndex..<work.endIndex, in: work)
        work = secretPrefixedEgress.stringByReplacingMatches(
            in: work, options: [], range: full1, withTemplate: redactPlaceholder)
        let full2 = NSRange(work.startIndex..<work.endIndex, in: work)
        work = blobWithHyphen.stringByReplacingMatches(
            in: work, options: [], range: full2, withTemplate: redactPlaceholder)

        // --- 4. fail-closed residual (run BEFORE restore so the U+0001
        //         sentinel bytes break stashed runs into short tokens) ---
        let full3 = NSRange(work.startIndex..<work.endIndex, in: work)
        work = residualRegex.stringByReplacingMatches(
            in: work, options: [], range: full3, withTemplate: redactPlaceholder)

        return (work, stash)
    }

    /// Step 5 of `redactStructured`: put every stashed value back in place of its sentinel
    /// `U+0001 K <index> U+0001`, in ONE left-to-right pass over the bytes of `text`.
    ///
    /// W-REPORTFREEZE (2026-10-03): this used to be one `replacingOccurrences` per stash entry,
    /// each scanning the whole string. A bug report's 1.36 MB log tail stashes ~2,350 values
    /// (call ids, fingerprints, identifiers), i.e. 2,350 full scans: it froze the main thread
    /// for ~32 s in the call of 2026-10-03. This is linear in `text` plus the stashed values.
    ///
    /// Same result as the old loop for every text this redactor produces: the stashed values
    /// (UUIDs, labelled fingerprints, close reasons, identifiers) never contain a U+0001, so a
    /// restored value can never be mistaken for a sentinel. A sentinel-looking run that is not a
    /// canonical decimal index below `stash.count` (a forged one in the input, `K01`, an index
    /// out of range) is left exactly as it is, as before.
    static func restoreStashed(_ text: String, stash: [String]) -> String {
        if stash.isEmpty { return text }
        let bytes = Array(text.utf8)
        let count = bytes.count
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var i = 0
        while i < count {
            let b = bytes[i]
            if b == 0x01, i + 3 < count, bytes[i + 1] == 0x4B {   // U+0001 'K'
                var j = i + 2
                var index = 0
                // at most 9 digits: stash counts are far below that, and Int never overflows
                while j < count, j - (i + 2) < 9, bytes[j] >= 0x30, bytes[j] <= 0x39 {
                    index = index * 10 + Int(bytes[j] - 0x30)
                    j += 1
                }
                let digits = j - (i + 2)
                let canonical = digits > 0 && (digits == 1 || bytes[i + 2] != 0x30)
                if canonical, j < count, bytes[j] == 0x01, index < stash.count {
                    out.append(contentsOf: stash[index].utf8)
                    i = j + 1
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Replace every match of `rx` in `text` with a U+0001-delimited
    /// sentinel (`\u{0001}K<idx>\u{0001}`) and append the original matched
    /// substring to `stash` at that index. The sentinel bytes are control
    /// chars outside every scrub charset, so the stashed value is immune to
    /// the secret/blob/residual rules until restored by index. Left-to-
    /// right, non-overlapping; indices are assigned in match order.
    private static func stashMatches(of rx: NSRegularExpression,
                                     in text: String,
                                     stash: inout [String]) -> String {
        let ns = text as NSString
        let matches = rx.matches(
            in: text, options: [],
            range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var out: String = ""
        out.reserveCapacity(text.count)
        var lastEnd = text.startIndex
        for m in matches {
            guard let r = Range(m.range, in: text) else { continue }
            out.append(contentsOf: text[lastEnd..<r.lowerBound])
            let idx: Int = stash.count
            stash.append(String(text[r]))
            out.append("\u{0001}K")
            out.append(String(idx))
            out.append("\u{0001}")
            lastEnd = r.upperBound
        }
        out.append(contentsOf: text[lastEnd..<text.endIndex])
        return out
    }

    /// ADVERSARIAL REVIEW FIX (2026-09-29, follow-up to I8) -- a
    /// code-identifier candidate immediately touching one of the
    /// secret-blob charset's own separator characters (`+ / = -`, the
    /// non-alnum members of `blobWithHyphen`/`residualRegex`'s character
    /// class) on either side is NOT a standalone Swift/ObjC identifier --
    /// it is a substring of a LONGER base64/base64url/hex-with-hyphen run
    /// that merely happens to look CamelCase in the middle (`\b` fires at
    /// `+`/`/`/`=`/`-` because none of them are `\w`, so `codeIdentifierRegex`
    /// can match right up against one even though the surrounding run is
    /// one continuous token with no real word/prose boundary there --
    /// digits can't do this, a letter-digit transition is `\w`-`\w`, no
    /// `\b`, so this is specific to those four separator characters).
    /// Stashing that middle chunk BEFORE the JWT/secret-keyword/blob/
    /// residual scrubs below run splits what would have been one
    /// contiguous >=20/24-char secret run into shorter pieces that can
    /// each fall under those length thresholds -- restoring the "identifier"
    /// verbatim at the end and leaking every fragment around it too, not
    /// just the one word. Confirmed against the pinned pre-fix behavior:
    /// `relay candidate blob 7f3ac9012+XyzAbcDef+91beffcafe...==` fully
    /// redacted before this file's I8 change, leaked `7f3ac9012+XyzAbcDef`
    /// in the clear after it, with only the guard below closing that back
    /// up. A real prose identifier is never written glued to `+`/`/`/`=`/`-`
    /// this way, so the guard costs no genuine diagnostic value.
    private static let blobAdjacentChars: Set<Character> = ["+", "/", "=", "-"]

    /// Post-v5 -- stash the allow-listed close reason tokens (see `closeReasonRegex`). Same adjacency
    /// guard as `stashCodeIdentifiers`: a token glued to `+ / = -` is a substring of a longer
    /// secret-charset run, never a standalone reason, and is left for the blob/residual rules.
    private static func stashCloseReasons(in text: String, stash: inout [String]) -> String {
        let ns = text as NSString
        let matches = closeReasonRegex.matches(
            in: text, options: [],
            range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var out: String = ""
        out.reserveCapacity(text.count)
        var lastEnd = text.startIndex
        for m in matches {
            guard let r = Range(m.range, in: text) else { continue }
            // Left side: `=` is the key=value separator of a log line (end_reason=TOKEN), not a base64
            // member (padding only ever ends a run), so only `+ / -` glue a token to a longer run.
            if r.lowerBound > text.startIndex,
               ["+", "/", "-"].contains(text[text.index(before: r.lowerBound)]) {
                continue
            }
            if r.upperBound < text.endIndex,
               blobAdjacentChars.contains(text[r.upperBound]) {
                continue
            }
            out.append(contentsOf: text[lastEnd..<r.lowerBound])
            let idx: Int = stash.count
            stash.append(String(text[r]))
            out.append("\u{0001}K")
            out.append(String(idx))
            out.append("\u{0001}")
            lastEnd = r.upperBound
        }
        out.append(contentsOf: text[lastEnd..<text.endIndex])
        return out
    }

    /// I8 FIX -- same sentinel-stashing shape as `stashMatches` above, but
    /// for `codeIdentifierRegex` candidates specifically: each candidate is
    /// ALSO run through `isLikelyCodeIdentifier` (the per-word plausibility
    /// layer) AND the blob-adjacency guard above before being stashed. A
    /// candidate that fails either check is left exactly as-is in the
    /// output (not stashed, not otherwise modified) so it falls through to
    /// the JWT/secret/blob/residual rules below like any other text --
    /// this function only ever REMOVES work from those rules, never adds
    /// any.
    private static func stashCodeIdentifiers(in text: String, stash: inout [String]) -> String {
        let ns = text as NSString
        let matches = codeIdentifierRegex.matches(
            in: text, options: [],
            range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var out: String = ""
        out.reserveCapacity(text.count)
        var lastEnd = text.startIndex
        for m in matches {
            guard let r = Range(m.range, in: text) else { continue }
            guard isLikelyCodeIdentifier(text[r]) else { continue }
            if r.lowerBound > text.startIndex,
               blobAdjacentChars.contains(text[text.index(before: r.lowerBound)]) {
                continue
            }
            if r.upperBound < text.endIndex,
               blobAdjacentChars.contains(text[r.upperBound]) {
                continue
            }
            out.append(contentsOf: text[lastEnd..<r.lowerBound])
            let idx: Int = stash.count
            stash.append(String(text[r]))
            out.append("\u{0001}K")
            out.append(String(idx))
            out.append("\u{0001}")
            lastEnd = r.upperBound
        }
        out.append(contentsOf: text[lastEnd..<text.endIndex])
        return out
    }
}
