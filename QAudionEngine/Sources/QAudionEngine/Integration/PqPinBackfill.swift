import Foundation

/// Pins made before the second public key was kept with the record have only the key id. This fills the key in, in the background,
/// from the peer's published bundle, and only when the key id DERIVED from the fetched public key (SHA-256 of its bytes,
/// `Pqsig.MlDsaPublicKey.keyId()`) equals the id the record names. A kept key is never overwritten or erased here.
public enum PqPinBackfill {

    public enum Result: String, Sendable, Equatable {
        case stored
        case mismatch
        case failed
    }

    /// The most records one run looks at.
    public static let maxPerRun = 20

    /// One record: look at every candidate key the contact's devices publish for the pinned signer key, and store the one whose derived
    /// id is the record's (exact match only). `nil`: nothing to do (the record has a key or is gone).
    static func backfillOne(
        book: CapsPinBook, peerUserId: String, signerKey: Data,
        fetch: (_ peerUserId: String, _ signerKey: Data) async -> [MldsaIdentityPublication.VerifiedPeer]
    ) async -> Result? {
        guard book.pinnedKey(peerUserId: peerUserId, signerKey: signerKey) == nil,
              book.record(peerUserId: peerUserId, signerKey: signerKey)?.mldsaKeyId != nil else { return nil }
        let candidates = await fetch(peerUserId, signerKey).filter { Pqsig.parsePublicKey($0.pub) != nil }
        guard !candidates.isEmpty else { return .failed }
        var sawMismatch = false
        for candidate in candidates {
            switch book.backfillPinnedKey(peerUserId: peerUserId, signerKey: signerKey, key: candidate.pub) {
            case .stored: return .stored
            case .mismatch: sawMismatch = true
            case .alreadyKept, .noRecord: return nil
            }
        }
        return sawMismatch ? .mismatch : .failed
    }

    /// Looks at every pinned record without a kept key (at most `maxPerRun`), one after the other with `spacing` seconds between,
    /// and stops at once when a call is in progress. One line per record: `PQ-BACKFILL result=stored|mismatch|failed` (no ids).
    public static func run(
        book: CapsPinBook, maxPerRun: Int = PqPinBackfill.maxPerRun, spacing: Double = 0.5,
        callActive: () async -> Bool,
        fetch: (_ peerUserId: String, _ signerKey: Data) async -> [MldsaIdentityPublication.VerifiedPeer]
    ) async {
        for target in book.pinsWithoutKeptKey().prefix(maxPerRun) {
            if Task.isCancelled { return }
            if await callActive() { return }
            // asked again before each fetch (a device is fetched one after the other): a call that starts meanwhile stops the run
            let guardedFetch: (String, Data) async -> [MldsaIdentityPublication.VerifiedPeer] = { user, signer in
                if await callActive() { return [] }
                return await fetch(user, signer)
            }
            if let result = await backfillOne(book: book, peerUserId: target.peerUserId, signerKey: target.signerKey, fetch: guardedFetch) {
                CapsBindLog.line("PQ-BACKFILL result=\(result.rawValue)")
            }
            if spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
        }
    }
}
