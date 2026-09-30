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
///    the keys, spec §2.5): `releaseAll()` drops only the cryptors.
///
/// **A live cryptor is never disabled (spec §12.1).** On the strict M150 build a
/// `RTCFrameCryptor` with `enabled == false` PASSES EVERY FRAME THROUGH IN THE
/// CLEAR, in both directions, cryptors are created disabled, and releasing one
/// leaves its transformer attached to the sender / receiver. So this class has
/// no "detach" that flips `enabled`: a cryptor leaves the books only by being
/// REPLACED (the new binding is attached first) or RELEASED after the
/// PeerConnection it belongs to has been closed.
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

    /// `K[M,E]` of `participantId` into ring slot `index`. The sentinel id of the
    /// unbound receivers never gets a key, whatever asks for one.
    public func installKey(_ key: Data, index: Int32, participantId: String) {
        guard key.count == GroupE2ee.keyLength, participantId != Self.unboundParticipantId else { return }
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
    /// offer exists, on a sender that already carries its track: a cryptor
    /// cannot be created without one, and a sender without a cryptor would
    /// publish in the clear, so `false` (the caller aborts publishing, spec
    /// §12.9) is the answer for every way this can fail. The native init
    /// marshals to the signalling thread, so it runs with `lock` released (the
    /// same discipline as the 1:1 cryptors).
    @discardableResult
    public func attachSender(_ sender: RTCRtpSender, participantId: String) -> Bool {
        guard sender.track != nil else { return false }
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
    /// ANOTHER publisher (or to the unbound sentinel) gets a fresh cryptor that is
    /// attached BEFORE the old one is forgotten: the receiver is never without an
    /// enabled cryptor, and the old one is never disabled (spec §12.1). If the new
    /// cryptor cannot be created the old binding stays in place (it can only
    /// decrypt the OLD publisher's key, so the new stream's frames are dropped)
    /// and `false` is returned.
    @discardableResult
    public func attachReceiver(_ receiver: RTCRtpReceiver, participantId: String) -> Bool {
        let id = receiver.receiverId
        lock.lock()
        if disposed {
            lock.unlock()
            return false
        }
        if let existing = receivers[id], existing.participantId == participantId {
            lock.unlock()
            return true
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
            lock.unlock()
            return false
        }
        cryptor.keyIndex = 0
        cryptor.enabled = true
        cryptor.delegate = self
        // The replaced cryptor is only released (outside the lock), never disabled.
        let replaced = receivers[id]
        receivers[id] = (participantId: participantId, cryptor: cryptor)
        lock.unlock()
        _ = replaced
        return true
    }

    // MARK: Release

    /// Forgets the cryptors of OUR senders (the publisher PeerConnection has been
    /// closed) but KEEPS the keys and the receiver cryptors. Nothing is disabled:
    /// on this build a disabled sender cryptor would let frames through in the
    /// clear, so a caller closes the PeerConnection FIRST and only then calls
    /// this. Also clears the stale entries of a previous publisher PeerConnection
    /// (sender ids repeat) before a new one attaches its own.
    public func releaseSenders() {
        lock.lock()
        let all = Array(senders.values)
        senders.removeAll()
        lock.unlock()
        _ = all
    }

    /// Forgets every receiver cryptor (the subscriber PeerConnection has been
    /// closed) but KEEPS the keys and the sender cryptors: a subscriber that is
    /// dropped on its own (a refused join) must not touch our own published media.
    /// Nothing is disabled; close the PeerConnection first.
    public func releaseReceivers() {
        lock.lock()
        let all = receivers.values.map { $0.cryptor }
        receivers.removeAll()
        lock.unlock()
        _ = all
    }

    /// Forgets every cryptor (both PeerConnections are closed) but KEEPS the keys.
    public func releaseAll() {
        releaseSenders()
        releaseReceivers()
    }

    /// Test seams: what is attached right now.
    var attachedSenderCount: Int {
        lock.lock(); defer { lock.unlock() }
        return senders.count
    }

    var attachedSenderCryptors: [RTCFrameCryptor] {
        lock.lock(); defer { lock.unlock() }
        return Array(senders.values)
    }

    var attachedReceiverParticipants: [String] {
        lock.lock(); defer { lock.unlock() }
        return receivers.values.map { $0.participantId }.sorted()
    }

    var attachedReceiverCryptors: [RTCFrameCryptor] {
        lock.lock(); defer { lock.unlock() }
        return receivers.values.map { $0.cryptor }
    }

    /// Final teardown (the call's PeerConnections are closed, or are being
    /// closed by the same teardown): later attaches are refused and every cryptor
    /// is released, none is disabled.
    public func dispose() {
        lock.lock()
        disposed = true
        lock.unlock()
        releaseAll()
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
