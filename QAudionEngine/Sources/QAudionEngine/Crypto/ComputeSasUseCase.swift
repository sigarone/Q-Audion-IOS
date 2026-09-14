import Foundation
import CryptoKit

/// Derive a deterministic 6-word Short-Authentication-String (SAS) from
/// an active call's session key. Direct port of Android's
/// `ComputeSasUseCase.kt`.
///
/// **Protocol** (must match Android byte-for-byte):
/// ```
///   hkdfOut = HKDF-SHA256(
///       ikm  = sessionKey,
///       salt = SasConstants.saltBytes,       // "qaudion-sas-v1"
///       info = SasConstants.infoWordsBytes,   // "sas-words-v1"
///       L    = 18                              // 6 × 3-byte indices
///   )
///   for i in 0..5:
///       idx[i] = uint24_be(hkdfOut[3i..3i+3]) % PgpSasWordList.words.count
///   sas = PgpSasWordList.words[idx[0..5]]
/// ```
///
/// The `initiator` flag is intentionally ignored for the derivation —
/// both peers must derive the same 6 words from the same session key,
/// otherwise the ceremony would be meaningless. It's accepted as a
/// parameter for future transcript-binding (asymmetric leg).
///
/// **Comparison**: always use `matches(_:_:)` rather than `==` to keep
/// equality checks constant-time.
public enum ComputeSasUseCase {

    public static let hkdfOutputBytes = 18
    public static let sasWordCount = SasConstants.wordCount

    public struct Sas: Equatable {
        public let words: [String]
        public init(words: [String]) {
            precondition(words.count == ComputeSasUseCase.sasWordCount,
                "Expected \(ComputeSasUseCase.sasWordCount) SAS words, got \(words.count)")
            self.words = words
        }

        /// Display string, e.g. `"TYPHOON · BALLAD · SLIPSTREAM · …"`.
        public var display: String {
            return words.map { $0.uppercased() }.joined(separator: " · ")
        }
    }

    public enum SasError: Error, Equatable {
        case emptyKey
    }

    /// Derive the 6-word SAS for `sessionKey`.
    ///
    /// - Parameters:
    ///   - sessionKey: shared symmetric session key (typically 32 bytes).
    ///                 Must not be empty — an empty key disables the ceremony.
    ///   - initiator: reserved for future protocol transcripts; unused in v1.
    ///   - transcriptHash: CALL-4/HSID-002 (2026-09-02 protocol audit) — the
    ///     32-byte SHA-256 of the call's v3 handshake transcript, supplied
    ///     ONLY when both peers negotiated the `hsTranscriptBindV1` capability
    ///     and its signature verified. When non-nil, `info` becomes
    ///     `HkdfLabels.sasTranscriptBindV1 || transcriptHash` INSTEAD of
    ///     `SasConstants.infoWordsBytes` — a relay that strips a signed
    ///     capability bit (or any other transcript field) from both bundles
    ///     changes `transcriptHash`, which changes these 6 words on both
    ///     ends, making the downgrade visible at SAS-verification time
    ///     instead of silent (the transcript-independent SAS this function
    ///     computed before this parameter existed). `nil` (default) is
    ///     BYTE-IDENTICAL to every call site that predates this fix — the
    ///     salt (`SasConstants.saltBytes`) is unchanged either way.
    public static func invoke(sessionKey: Data, initiator: Bool = false, transcriptHash: Data? = nil) throws -> Sas {
        guard !sessionKey.isEmpty else { throw SasError.emptyKey }
        let info: Data
        if let transcriptHash {
            precondition(transcriptHash.count == 32, "transcriptHash must be 32 bytes")
            var i = Data(capacity: HkdfLabels.sasTranscriptBindV1.count + 32)
            i.append(HkdfLabels.sasTranscriptBindV1)
            i.append(transcriptHash)
            info = i
        } else {
            info = SasConstants.infoWordsBytes
        }

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey),
            salt: SasConstants.saltBytes,
            info: info,
            outputByteCount: hkdfOutputBytes
        )
        let out = derived.withUnsafeBytes { Data($0) }

        let size = PgpSasWordList.words.count
        var words = [String]()
        words.reserveCapacity(sasWordCount)
        for i in 0..<sasWordCount {
            let a = Int(out[out.startIndex + 3 * i])
            let b = Int(out[out.startIndex + 3 * i + 1])
            let c = Int(out[out.startIndex + 3 * i + 2])
            let idx = ((a << 16) | (b << 8) | c) % size
            words.append(PgpSasWordList.words[idx])
        }
        return Sas(words: words)
    }

    /// Constant-time comparison of two SAS tokens.
    /// Uses byte-level comparison on UTF-8 of the joined word lists so the
    /// comparison time does not leak the position of the first mismatch.
    public static func matches(_ expected: Sas, _ candidate: Sas) -> Bool {
        let a = Data(expected.words.joined(separator: "|").utf8)
        let b = Data(candidate.words.joined(separator: "|").utf8)
        return constantTimeEquals(a, b)
    }

    /// Parse a user-entered SAS string into a `Sas` for `matches`. Accepts
    /// separators of whitespace, `-`, `·`, `,`. Returns `nil` if the
    /// result does not contain exactly `sasWordCount` words.
    public static func parse(_ input: String) -> Sas? {
        let separators: Set<Character> = ["·", "-", ",", " ", "\t", "\n"]
        let tokens = input
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        guard tokens.count == sasWordCount else { return nil }
        return Sas(words: tokens)
    }

    // MARK: - Internal

    /// Constant-time byte comparison. Returns true iff `a` and `b` have
    /// the same length and the same bytes; ALWAYS scans every byte of
    /// the shorter input regardless of early divergence.
    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }
}
