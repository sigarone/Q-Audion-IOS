import Foundation

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
enum LogRedactor {

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

    static func redact(_ line: String) -> String {
        var working: String = line
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
    //   5.  RESTORE stashed UUIDs + fingerprints.
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)
    // Labelled short-hex fingerprint (8-16 hex) preceded by a known label.
    // Stash the WHOLE match so neither the secret-keyword rule nor the
    // residual sweep can touch the fingerprint regardless of separator.
    private static let fingerprintRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(keyfp|selectedpskfingerprint|short8|h8|fp)([\s:=]+)([0-9a-fA-F]{8,16})\b"#)
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
        var work: String = line
        var stash: [String] = []

        // --- 1a. stash call_id UUIDs ---
        work = LogRedactor.stashMatches(of: uuidRegex, in: work, stash: &stash)
        // --- 1b. stash labelled short-hex fingerprints ---
        work = LogRedactor.stashMatches(of: fingerprintRegex, in: work, stash: &stash)

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

        // --- 5. restore stashed UUIDs + fingerprints ---
        if !stash.isEmpty {
            for (i, u) in stash.enumerated() {
                work = work.replacingOccurrences(
                    of: "\u{0001}K\(i)\u{0001}", with: u)
            }
        }
        return work
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
}
