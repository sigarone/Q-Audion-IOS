import Foundation
import CryptoKit

/// BIP-39-style mnemonic generator + canonical-hash helper for account recovery.
///
/// Aligns with `RecoverySeedViewModel` (W9.B). Produces a 12-word mnemonic
/// from a small fixed wordlist (NOT the full BIP-39 2048-word list — for
/// development convenience). Cross-platform parity: Android uses BIP-39
/// wordlist (recommend full BIP-39 for production; this is a placeholder
/// pending WordList agreement — see Open Discrepancy §6 in INVARIANTS_VERIFIED.md).
///
/// Recovery hash format: `hex(SHA-256("word1 word2 ..."))` lowercase
/// per `RecoverySeedViewModel.computeRecoveryHash`.
public enum RecoveryMnemonic {

    /// 64-word reduced wordlist for development use. Production should adopt
    /// full BIP-39. Words are lowercase, alphabetically ordered, no diacritics.
    public static let wordList: [String] = [
        "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract",
        "absurd", "abuse", "access", "accident", "account", "accuse", "achieve", "acid",
        "acoustic", "acquire", "across", "act", "action", "actor", "actress", "actual",
        "adapt", "add", "addict", "address", "adjust", "admit", "adult", "advance",
        "advice", "aerobic", "affair", "afford", "afraid", "again", "age", "agent",
        "agree", "ahead", "aim", "air", "airport", "aisle", "alarm", "album",
        "alcohol", "alert", "alien", "all", "alley", "allow", "almost", "alone",
        "alpha", "already", "also", "alter", "always", "amateur", "amazing", "among"
    ]

    public enum Error: Swift.Error, LocalizedError {
        case invalidWordCount(Int)
        case unknownWord(String)

        public var errorDescription: String? {
            switch self {
            case .invalidWordCount(let n): return "Mnemonic must be 12 words, got \(n)"
            case .unknownWord(let w): return "Word '\(w)' is not in the wordlist"
            }
        }
    }

    /// Generate a fresh 12-word mnemonic using SecRandomCopyBytes for entropy.
    public static func generate() -> [String] {
        var words: [String] = []
        let count = wordList.count
        var randomBuffer = [UInt8](repeating: 0, count: 12 * 2)
        _ = randomBuffer.withUnsafeMutableBufferPointer { buf in
            SecRandomCopyBytes(kSecRandomDefault, buf.count, buf.baseAddress!)
        }
        for i in 0..<12 {
            let high = UInt16(randomBuffer[i * 2])
            let low = UInt16(randomBuffer[i * 2 + 1])
            let combined = (high << 8) | low
            let idx = Int(combined) % count
            words.append(wordList[idx])
        }
        return words
    }

    /// Canonical-form hash: `hex(SHA-256("word1 word2 ..."))` lowercase.
    /// Matches `RecoverySeedViewModel.computeRecoveryHash`.
    public static func canonicalHash(words: [String]) throws -> String {
        guard words.count == 12 else { throw Error.invalidWordCount(words.count) }
        let canonical = words.map { $0.lowercased() }.joined(separator: " ")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verify all words are in the wordlist (helps catch typos before submit).
    public static func validate(words: [String]) throws {
        guard words.count == 12 else { throw Error.invalidWordCount(words.count) }
        let lower = words.map { $0.lowercased() }
        let set = Set(wordList)
        for word in lower {
            if !set.contains(word) {
                throw Error.unknownWord(word)
            }
        }
    }
}
