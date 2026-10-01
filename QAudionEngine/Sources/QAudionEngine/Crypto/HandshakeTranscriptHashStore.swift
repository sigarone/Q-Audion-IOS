import Foundation

/// `SHA-256(ACCEPT_v5)` of each call's latest completed handshake round, keyed by the lowercased
/// call id (WIRE_SPEC §3.7 / §4).
///
/// The handshake derives the session key from this hash (the transcript-bound KDF is
/// unconditional) and the in-call SAS is derived from the session key AND this hash
/// (`ComputeSasUseCase.invoke(sessionKey:transcriptHash:)`), so a matching SAS also authenticates
/// both signers' identity keys and both DTLS fingerprints: a relay that rewrote any of them makes
/// the two legs derive different words. The integration writes the hash BEFORE it announces the
/// new session key; the app reads it when it renders the SAS words.
///
/// Only the last few calls are retained: the store has no notion of call end, so older entries are
/// evicted by insertion order.
public final class HandshakeTranscriptHashStore: @unchecked Sendable {
    public static let shared = HandshakeTranscriptHashStore()

    private let lock = NSLock()
    private var byCall: [String: Data] = [:]
    private var order: [String] = []
    private static let retained = 4

    public init() {}

    /// Record the hash of the round that just produced the call's session key (32 bytes).
    public func set(_ hash: Data, forCallId callId: String) {
        let key = callId.lowercased()
        guard hash.count == 32, !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if byCall[key] == nil { order.append(key) }
        byCall[key] = hash
        while order.count > Self.retained {
            let evicted = order.removeFirst()
            byCall.removeValue(forKey: evicted)
        }
    }

    /// The hash of the call's latest completed round, if a handshake completed for it.
    public func hash(forCallId callId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return byCall[callId.lowercased()]
    }

    /// Forget every entry (tests).
    func removeAll() {
        lock.lock()
        byCall.removeAll()
        order.removeAll()
        lock.unlock()
    }
}
