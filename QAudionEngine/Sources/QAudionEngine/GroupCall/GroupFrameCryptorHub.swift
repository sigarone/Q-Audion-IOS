import Foundation
#if canImport(WebRTC)
import WebRTC

/// Group calls v2 (spec §5.3) — the native FrameCryptor wiring of ONE call:
/// one `RTCFrameCryptorKeyProvider` (per-participant keys, `sharedKey` false,
/// HKDF, key ring 16, no ratchet, no magic-bytes bypass, frames are discarded
/// while no key is ready) and the cryptors attached to our sender(s) and to
/// every remote receiver. Same AES-256-GCM frame format as 1:1; the strict
/// M150 build refuses anything but a 32-byte key.
///
///  * our own sender cryptors use OUR pseudonym as participantId and encrypt
///    with the ring slot of `setSendKeyIndex`;
///  * every receiver cryptor uses the PUBLISHER's pseudonym, and is driven by
///    the key index each frame carries;
///  * the key provider outlives a media restart (`media_moved` / rejoin keep
///    the keys, spec §2.5): `detachAll()` drops only the cryptors.
public final class GroupFrameCryptorHub: NSObject, @unchecked Sendable {

    /// participantId of the cryptor bound to a receiver whose stream is not a
    /// known, enabled publisher stream (spec §4.3: nothing is rendered without a
    /// cryptor). Nobody ever installs a key under it, so every frame that
    /// arrives on such a receiver is discarded instead of being played in the
    /// clear. Pseudonyms are 32 hex characters, so it can never collide.
    public static let unboundParticipantId = "unbound"

    /// A receiver cryptor reported a missing key for this participant.
    public var onMissingKey: ((String) -> Void)?
    /// ... or a decrypt failure.
    public var onDecryptFailure: ((String) -> Void)?

    public let keyProvider: RTCFrameCryptorKeyProvider
    /// Bound by `bind(factory:)` before the first PeerConnection exists: the key
    /// store must be usable earlier than that (the epoch-1 key of a call can
    /// arrive before its media session is built).
    private var factory: RTCPeerConnectionFactory?
    private let lock = NSLock()
    private var senders: [String: RTCFrameCryptor] = [:]
    private var receivers: [String: (participantId: String, cryptor: RTCFrameCryptor)] = [:]
    private var constructing: Set<String> = []
    private var sendKeyIndex: Int32 = 0
    private var disposed = false

    public override init() {
        self.keyProvider = RTCFrameCryptorKeyProvider(
            ratchetSalt: Data(),
            ratchetWindowSize: 0,
            sharedKeyMode: false,
            uncryptedMagicBytes: nil,
            failureTolerance: -1,
            keyRingSize: Int32(GroupE2ee.keyRingSize),
            discardFrameWhenCryptorNotReady: true,
            // swiftlint:disable:next force_unwrapping
            keyDerivationAlgorithm: RTCKeyDerivationAlgorithm(rawValue: 1)!)
        super.init()
    }

    public func bind(factory: RTCPeerConnectionFactory) {
        lock.lock()
        self.factory = factory
        lock.unlock()
    }

    // MARK: Keys

    /// `K[M,E]` of `participantId` into ring slot `index`.
    public func installKey(_ key: Data, index: Int32, participantId: String) {
        guard key.count == GroupE2ee.keyLength else { return }
        keyProvider.setKey(key, with: index, forParticipant: participantId)
    }

    /// Points every sender cryptor (and every one attached later) at `index`.
    public func setSendKeyIndex(_ index: Int32) {
        lock.lock()
        sendKeyIndex = index
        let current = Array(senders.values)
        lock.unlock()
        for cryptor in current { cryptor.keyIndex = index }
    }

    // MARK: Attach

    /// Creates + enables the cryptor of one of OUR senders. Must run before the
    /// offer exists. The native init marshals to the signalling thread, so it
    /// runs with `lock` released (the same discipline as the 1:1 cryptors).
    @discardableResult
    public func attachSender(_ sender: RTCRtpSender, participantId: String) -> Bool {
        let id = sender.senderId
        lock.lock()
        if disposed || senders[id] != nil {
            let already = senders[id] != nil
            lock.unlock()
            return already
        }
        guard !constructing.contains(id) else {
            lock.unlock()
            return false
        }
        guard let factory = factory else {
            lock.unlock()
            return false
        }
        constructing.insert(id)
        let index = sendKeyIndex
        lock.unlock()

        let built = RTCFrameCryptor(factory: factory, rtpSender: sender, participantId: participantId,
                                    algorithm: .aesGcm, keyProvider: keyProvider)

        lock.lock()
        constructing.remove(id)
        guard let cryptor = built, !disposed else {
            built?.enabled = false
            lock.unlock()
            return false
        }
        cryptor.keyIndex = index
        cryptor.enabled = true
        cryptor.delegate = self
        senders[id] = cryptor
        lock.unlock()
        return true
    }

    /// Creates + enables the cryptor of one remote receiver for `participantId`
    /// (the publisher's pseudonym). A receiver that a later offer re-assigns to
    /// ANOTHER publisher gets a fresh cryptor.
    @discardableResult
    public func attachReceiver(_ receiver: RTCRtpReceiver, participantId: String) -> Bool {
        let id = receiver.receiverId
        lock.lock()
        if disposed {
            lock.unlock()
            return false
        }
        if let existing = receivers[id] {
            if existing.participantId == participantId {
                lock.unlock()
                return true
            }
            existing.cryptor.enabled = false
            receivers[id] = nil
        }
        guard !constructing.contains(id), let factory = factory else {
            lock.unlock()
            return false
        }
        constructing.insert(id)
        lock.unlock()

        let built = RTCFrameCryptor(factory: factory, rtpReceiver: receiver, participantId: participantId,
                                    algorithm: .aesGcm, keyProvider: keyProvider)

        lock.lock()
        constructing.remove(id)
        guard let cryptor = built, !disposed else {
            built?.enabled = false
            lock.unlock()
            return false
        }
        cryptor.keyIndex = 0
        cryptor.enabled = true
        cryptor.delegate = self
        receivers[id] = (participantId: participantId, cryptor: cryptor)
        lock.unlock()
        return true
    }

    public func detachReceiver(receiverId: String) {
        lock.lock()
        let entry = receivers.removeValue(forKey: receiverId)
        lock.unlock()
        entry?.cryptor.enabled = false
    }

    /// Drops the cryptors of OUR senders (the publisher PeerConnection is
    /// closing) but KEEPS the keys and the receiver cryptors. A disabled sender
    /// cryptor discards every frame (`discardFrameWhenCryptorNotReady`), so this
    /// must never run while the publisher PC is meant to keep sending.
    public func detachSenders() {
        lock.lock()
        let all = Array(senders.values)
        senders.removeAll()
        lock.unlock()
        for cryptor in all { cryptor.enabled = false }
    }

    /// Drops every receiver cryptor (the subscriber PeerConnection is closing)
    /// but KEEPS the keys and the sender cryptors: a subscriber that is dropped
    /// on its own (a refused join) must not silence our own published media.
    public func detachReceivers() {
        lock.lock()
        let all = receivers.values.map { $0.cryptor }
        receivers.removeAll()
        lock.unlock()
        for cryptor in all { cryptor.enabled = false }
    }

    /// Drops every cryptor (both PeerConnections are closing) but KEEPS the keys.
    public func detachAll() {
        detachSenders()
        detachReceivers()
    }

    /// Test seams: what is attached right now.
    var attachedSenderCount: Int {
        lock.lock(); defer { lock.unlock() }
        return senders.count
    }

    var attachedReceiverParticipants: [String] {
        lock.lock(); defer { lock.unlock() }
        return receivers.values.map { $0.participantId }.sorted()
    }

    /// Final teardown.
    public func dispose() {
        lock.lock()
        disposed = true
        lock.unlock()
        detachAll()
    }
}

extension GroupFrameCryptorHub: RTCFrameCryptorDelegate {
    public func frameCryptor(_ frameCryptor: RTCFrameCryptor,
                             didStateChangeWithParticipantId participantId: String,
                             with state: RTCFrameCryptorState) {
        switch state {
        case .missingKey:
            onMissingKey?(participantId)
        case .decryptionFailed, .internalError:
            onDecryptFailure?(participantId)
        default:
            break
        }
    }
}
#endif
