import Foundation

/// Per-(epoch, peer) symmetric ratchet session state for Q-Audion messaging
/// wire format v3.1. Direct port of Android's `RatchetState.kt`.
///
/// **Mutability**: `ckSend`, `ckRecv`, `nextSendIdx`, `lastSeenRecvIdx` are
/// all live cryptographic state — `MessageRatchet` mutates them after
/// every send/receive (derives `CK_{n+1}`, zeroizes the previous `CK_n`,
/// reassigns the field). Persisting a snapshot before the network
/// transmit is the write-ahead invariant that prevents catastrophic
/// nonce reuse on a crash between encrypt and send (spec §6/§8).
///
/// We keep this as a `class` (not a struct) so the engine can mutate
/// chain keys in place without value-type copies leaving stale buffers
/// in caller frames.
public final class RatchetSession {
    public let epochId: String
    public let selfId: String
    public let peerId: String
    public let sendDirFlag: UInt8
    public let recvDirFlag: UInt8

    public var ckSend: Data
    public var nextSendIdx: UInt64
    public var ckRecv: Data
    /// `nil` sentinel = "no message received yet"; otherwise the highest
    /// in-order chain_idx successfully decrypted.
    public var lastSeenRecvIdx: UInt64?

    /// Bounded `idx → SkippedKey` map populated when later messages arrive
    /// before earlier ones. LRU-evicted at `MessageRatchet.skippedKeysCacheMax`
    /// and TTL-expired at `MessageRatchet.skippedKeysTtlMs`. Insertion order
    /// is preserved (LRU eviction relies on it).
    public var skippedKeys: [(UInt64, SkippedKey)]

    public init(
        epochId: String,
        selfId: String,
        peerId: String,
        sendDirFlag: UInt8,
        recvDirFlag: UInt8,
        ckSend: Data,
        nextSendIdx: UInt64,
        ckRecv: Data,
        lastSeenRecvIdx: UInt64?,
        skippedKeys: [(UInt64, SkippedKey)] = []
    ) {
        self.epochId = epochId
        self.selfId = selfId
        self.peerId = peerId
        self.sendDirFlag = sendDirFlag
        self.recvDirFlag = recvDirFlag
        self.ckSend = ckSend
        self.nextSendIdx = nextSendIdx
        self.ckRecv = ckRecv
        self.lastSeenRecvIdx = lastSeenRecvIdx
        self.skippedKeys = skippedKeys
    }
}

/// A single message-key cached because the corresponding `chain_idx`
/// arrived later than expected (skip-ahead) or out of order.
public struct SkippedKey: Equatable {
    public let key: Data         // 32-byte AES-256-GCM message key
    public let nonce: Data       // 12-byte deterministic GCM nonce
    public let expiresAtMs: Int64

    public init(key: Data, nonce: Data, expiresAtMs: Int64) {
        self.key = key
        self.nonce = nonce
        self.expiresAtMs = expiresAtMs
    }
}

/// Wire-format-independent snapshot of a `RatchetSession`. Engine-owned;
/// vault implementations treat it as opaque. Persists every field needed
/// to recover a session across process death — including the
/// skipped-keys cache (dropping those would silently break decryption of
/// in-flight messages that arrived out of order before a crash).
public struct RatchetSnapshot: Equatable {
    public let epochId: String
    public let selfId: String
    public let peerId: String
    public let sendDirFlag: UInt8
    public let recvDirFlag: UInt8
    public let ckSend: Data
    public let nextSendIdx: UInt64
    public let ckRecv: Data
    public let lastSeenRecvIdx: UInt64?
    public let skipped: [SkippedEntry]

    public struct SkippedEntry: Equatable {
        public let idx: UInt64
        public let key: Data
        public let nonce: Data
        public let expiresAtMs: Int64

        public init(idx: UInt64, key: Data, nonce: Data, expiresAtMs: Int64) {
            self.idx = idx
            self.key = key
            self.nonce = nonce
            self.expiresAtMs = expiresAtMs
        }
    }

    public init(
        epochId: String,
        selfId: String,
        peerId: String,
        sendDirFlag: UInt8,
        recvDirFlag: UInt8,
        ckSend: Data,
        nextSendIdx: UInt64,
        ckRecv: Data,
        lastSeenRecvIdx: UInt64?,
        skipped: [SkippedEntry]
    ) {
        self.epochId = epochId
        self.selfId = selfId
        self.peerId = peerId
        self.sendDirFlag = sendDirFlag
        self.recvDirFlag = recvDirFlag
        self.ckSend = ckSend
        self.nextSendIdx = nextSendIdx
        self.ckRecv = ckRecv
        self.lastSeenRecvIdx = lastSeenRecvIdx
        self.skipped = skipped
    }
}
