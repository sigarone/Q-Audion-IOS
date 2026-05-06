import Foundation
import CryptoKit

public struct RecoverySeedViewModel: ViewModelProtocol {

    public enum Step: Equatable, Sendable {
        case setupShowMnemonic           // setup phase 1: display 12/24-word mnemonic
        case setupConfirmEntry           // setup phase 2: user types it back to confirm
        case verifyEnterMnemonic         // recovery phase: user enters mnemonic to recover account
        case complete                    // success state
        case error(message: String)

        fileprivate var rank: Int {
            switch self {
            case .setupShowMnemonic: return 0
            case .setupConfirmEntry, .verifyEnterMnemonic: return 1
            case .complete: return 2
            case .error: return 3
            }
        }
    }

    /// 12 or 24 BIP-39 words, lowercase. Generated client-side at setup,
    /// or empty during verify (user types it).
    public let mnemonicWords: [String]

    public let userTypedWords: [String]
    public private(set) var step: Step

    public init(mnemonicWords: [String], userTypedWords: [String] = [],
                step: Step = .setupShowMnemonic) {
        self.mnemonicWords = mnemonicWords
        self.userTypedWords = userTypedWords
        self.step = step
    }

    public mutating func transition(to next: Step) {
        // Allow forward transitions and recovery from error.
        switch (step, next) {
        case (.error, _), (.complete, .setupShowMnemonic), (.complete, .verifyEnterMnemonic):
            step = next
        case (let cur, let nxt) where nxt.rank >= cur.rank:
            step = next
        default:
            break  // reject backward
        }
    }

    /// Compute the SHA-256 hex hash of the canonical mnemonic representation.
    /// Server-side recovery setup stores this hash; verification re-hashes
    /// the user-entered mnemonic and compares.
    ///
    /// Canonical form: words joined by single spaces, lowercase, then UTF-8 bytes.
    public static func computeRecoveryHash(mnemonic: [String]) -> String {
        let canonical = mnemonic.map { $0.lowercased() }.joined(separator: " ")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static let mock = RecoverySeedViewModel(
        mnemonicWords: [
            "abandon", "ability", "able", "about",
            "above", "absent", "absorb", "abstract",
            "absurd", "abuse", "access", "accident"
        ],
        userTypedWords: [],
        step: .setupShowMnemonic
    )
}
