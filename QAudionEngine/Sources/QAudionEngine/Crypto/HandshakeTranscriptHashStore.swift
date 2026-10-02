import Foundation

/// `SHA-256(ACCEPT_v6)` of each call's latest completed handshake round, keyed by the lowercased
/// call id (WIRE_SPEC §3.7 / §4).
///
/// The handshake derives the session key from this hash (the transcript-bound KDF is unconditional), so
/// a stored hash is the marker that a call's session key is bound to the signed transcript
/// (`QAudionCallIntegration.isSessionKeyTranscriptBound`: both signers' identity keys, both DTLS
/// fingerprints and the SAS commitment). The in-call SAS no longer reads it: the words are derived from
/// the ROUND-1 session key, the round-1 accept hash AND the caller's committed nonce, kept by
/// `SasCommitBook`. The integration writes the hash BEFORE it announces the new session key.
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
