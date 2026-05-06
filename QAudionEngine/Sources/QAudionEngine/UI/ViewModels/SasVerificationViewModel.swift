import Foundation

public struct SasVerificationViewModel: ViewModelProtocol {

    public enum Verdict: Equatable, Sendable {
        case pending           // user hasn't pressed match / mismatch yet
        case match             // user confirmed words match peer's
        case mismatch          // user reports words DON'T match — call MUST be torn down
    }

    public let peerDisplayName: String
    public let peerFingerprint: String  // §5.1 format
    /// 4 lowercase PGP words derived from first 32 bits of the call-session
    /// PQC handshake transcript, lookup-mapped to PGP word list.
    public let sasWords: [String]
    public private(set) var userVerdict: Verdict

    public init(peerDisplayName: String, peerFingerprint: String, sasWords: [String], userVerdict: Verdict = .pending) {
        self.peerDisplayName = peerDisplayName
        self.peerFingerprint = peerFingerprint
        self.sasWords = sasWords
        self.userVerdict = userVerdict
    }

    public mutating func recordUserVerdict(_ verdict: Verdict) {
        guard userVerdict == .pending else { return }
        userVerdict = verdict
    }

    public static let mock = SasVerificationViewModel(
        peerDisplayName: "Alice (Pixel 7)",
        peerFingerprint: (try? Fingerprint.format(pubkey: Data(repeating: 0x45, count: 32))) ?? "????.????.????.????",
        sasWords: ["abandon", "ability", "able", "about"],  // PGP word-list samples
        userVerdict: .pending
    )
}
