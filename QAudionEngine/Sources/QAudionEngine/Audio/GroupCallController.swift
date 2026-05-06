import Foundation
import CryptoKit

/// Drives an N-way audio-only group call over the server-side SFU.
/// Direct port of Android's
/// `feature/feature-call/.../GroupCallController.kt`.
///
/// Responsibilities:
/// 1. Bridge to BCryptoGroupCallManager for the WebSocket protocol
///    (group_call_create / join / leave / forward).
/// 2. Derive a shared room key (deterministic for the MVP, identical
///    to Android's SHA-256(callId || "qaudion-group-v1") so iOS↔Android
///    group calls reuse the same key without coordination).
/// 3. On send: capture mic → Opus encode → AES-GCM seal → ship via
///    `forwardAudioFrame`.
/// 4. On receive: open sealed → Opus decode (per-sender state) → push
///    PCM into the shared playback jitter buffer.
///
/// **Cross-platform note:** the room key derivation is intentionally
/// simple — the server can decrypt frames in this MVP. To be production-
/// safe, replace with the GroupSenderKey ratchet (W340/W345) where
/// each member maintains a per-sender chain seeded by the creator's
/// PQC-wrapped opaque message. That work is tracked separately.
public final class GroupCallController: @unchecked Sendable {

    public enum State: Equatable {
        case idle
        case connecting(callId: String)
        case active(callId: String, participants: [String])
        case failed(reason: String)
    }

    public private(set) var state: State = .idle
    public var onStateChange: ((State) -> Void)?

    private let manager: BCryptoGroupCallManager
    private let aead = AeadCipher()
    private let lock = NSLock()
    private var roomKey: Data?
    private var muted = false
    /// Per-sender Opus decoders (one per peer; Opus state is stateful
    /// across frames — sharing one decoder across senders desyncs).
    private var perSenderDecoders: [String: OpusCodec] = [:]
    private let encoder: OpusCodec = OpusCodec()

    /// W358: optional audio I/O pipeline. When set via
    /// `attachAudioPipeline()`, the controller takes ownership of the
    /// capture source (mic → PCM → encrypt → forward) and the playback
    /// sink (incoming PCM → playback). Both are ManagedLifecycle: start
    /// fires when the call enters .active, stop fires on teardown.
    private var capture: AudioCapture?
    private var playback: AudioPlayback?

    public init(manager: BCryptoGroupCallManager) {
        self.manager = manager
        wireManagerCallbacks()
    }

    // MARK: - Public API

    /// Create a new group call and invite the listed peers.
    /// Returns the freshly-minted call id (also held internally).
    @discardableResult
    public func createCall(invitees: [String], title: String = "") -> String {
        let callId = UUID().uuidString
        deriveRoomKey(callId: callId)
        manager.createGroupCall(recipients: invitees, title: title)
        setState(.connecting(callId: callId))
        return callId
    }

    public func join(callId: String) {
        deriveRoomKey(callId: callId)
        manager.joinGroupCall(callId: callId)
        setState(.connecting(callId: callId))
    }

    public func leave() {
        manager.leaveGroupCall()
        stopAudioPipeline()
        teardown()
    }

    public func endCallForAll() {
        manager.endGroupCall()
        stopAudioPipeline()
        teardown()
    }

    public func setMuted(_ muted: Bool) {
        lock.lock(); self.muted = muted; lock.unlock()
    }

    public var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }; return muted
    }

    /// Hook for the audio-capture path: feed one captured Opus frame
    /// (already-encoded) to be sealed under the room key and shipped to
    /// every other participant via the SFU.
    public func sendOutgoingOpusFrame(_ opus: Data) {
        guard !isMuted else { return }
        lock.lock()
        guard let key = roomKey, case .active = state else {
            lock.unlock(); return
        }
        lock.unlock()
        let sealed: Data
        do {
            let out = try aead.encrypt(plaintext: opus, key: key)
            sealed = Self.packSealed(out)
        } catch {
            print("[GroupCallController] seal failed: \(error)")
            return
        }
        manager.forwardAudioFrame(sealed)
    }

    /// Convenience wrapper: encode raw PCM → seal → forward in one step.
    public func sendOutgoingPcmFrame(_ pcm: Data) {
        guard let opus = encoder.encode(pcm) else { return }
        sendOutgoingOpusFrame(opus)
    }

    /// PCM frames produced from the inbound stream are surfaced through
    /// this callback — the AppState wires this into the AudioPlayback
    /// jitter buffer (one shared buffer; multiple talkers interleave at
    /// frame granularity until a real N-source mixer lands).
    public var onIncomingPcmFrame: ((String, Data) -> Void)?

    /// W358: bind the in-process AudioCapture (mic) and AudioPlayback
    /// (speaker) lifecycles to this call. Once attached, the
    /// controller owns starting/stopping them in lockstep with the
    /// call state (active → start, idle → stop). The default
    /// `onIncomingPcmFrame` callback is replaced with one that pushes
    /// directly into the bound playback's jitter buffer.
    public func attachAudioPipeline(capture: AudioCapture, playback: AudioPlayback) {
        lock.lock()
        self.capture = capture
        self.playback = playback
        lock.unlock()
        capture.onFrame = { [weak self] pcm in
            self?.sendOutgoingPcmFrame(pcm)
        }
        // Default sink: dump incoming PCM into the jitter buffer.
        // Caller can replace by reassigning onIncomingPcmFrame after
        // attachAudioPipeline returns (e.g. for a per-sender mixer).
        onIncomingPcmFrame = { [weak self] _, pcm in
            self?.playback?.playFrame(pcm)
        }
    }

    /// Manually start the audio pipeline. Called from the state
    /// transition into .active; safe to invoke multiple times (each
    /// component idempotent).
    public func startAudioPipeline() throws {
        lock.lock()
        let capture = self.capture
        let playback = self.playback
        lock.unlock()
        if let playback = playback {
            try? playback.start()
        }
        if let capture = capture {
            try capture.start()
        }
    }

    /// Stop the audio pipeline. Idempotent.
    public func stopAudioPipeline() {
        lock.lock()
        let capture = self.capture
        let playback = self.playback
        lock.unlock()
        capture?.stop()
        playback?.stop()
    }

    // MARK: - Internal

    private func wireManagerCallbacks() {
        manager.onStateChanged = { [weak self] s in
            guard let self = self else { return }
            switch s {
            case .creating:
                if case .connecting = self.state { /* keep */ }
                else if let cid = self.manager.callId {
                    self.setState(.connecting(callId: cid))
                }
            case .active:
                if let cid = self.manager.callId {
                    let parts = self.manager.participants.map(\.id)
                    self.setState(.active(callId: cid, participants: parts))
                    // W358: kick off the bound audio pipeline once the
                    // server confirms the room is live. Best-effort —
                    // a missing mic permission throws here and we fall
                    // back to RX-only.
                    do { try self.startAudioPipeline() }
                    catch { print("[GroupCallController] startAudioPipeline failed: \(error)") }
                }
            case .ended:
                self.stopAudioPipeline()
                self.teardown()
            case .idle:
                self.setState(.idle)
            }
        }
        manager.onParticipantsChanged = { [weak self] parts in
            guard let self = self,
                  case let .active(cid, _) = self.state else { return }
            self.setState(.active(callId: cid, participants: parts.map(\.id)))
        }
        manager.onAudioFrame = { [weak self] senderId, frame in
            self?.handleIncomingFrame(senderId: senderId, sealed: frame)
        }
    }

    private func handleIncomingFrame(senderId: String, sealed: Data) {
        lock.lock()
        guard let key = roomKey else { lock.unlock(); return }
        var decoder = perSenderDecoders[senderId]
        if decoder == nil {
            decoder = OpusCodec()
            perSenderDecoders[senderId] = decoder
        }
        lock.unlock()
        guard let decoder = decoder else { return }

        let opus: Data
        do {
            let out = Self.unpackSealed(sealed)
            opus = try aead.decrypt(cipherOutput: out, key: key)
        } catch {
            print("[GroupCallController] open failed sender=\(senderId): \(error)")
            return
        }
        guard let pcm = decoder.decode(opus) else {
            print("[GroupCallController] opus decode failed sender=\(senderId)")
            return
        }
        onIncomingPcmFrame?(senderId, pcm)
    }

    private func deriveRoomKey(callId: String) {
        // SHA-256(callId || "qaudion-group-v1") — same as Android.
        var ikm = Data(callId.utf8)
        ikm.append(Data("qaudion-group-v1".utf8))
        let digest = SHA256.hash(data: ikm)
        lock.lock()
        roomKey = Data(digest)
        lock.unlock()
    }

    private func teardown() {
        lock.lock()
        roomKey = nil
        perSenderDecoders.removeAll()
        muted = false
        lock.unlock()
        setState(.idle)
    }

    private func setState(_ newState: State) {
        lock.lock(); state = newState; lock.unlock()
        onStateChange?(newState)
    }

    // MARK: - Wire format helpers

    /// Pack `nonce(12) || ciphertext || tag(16)` matching Android's
    /// `AeadCipher.seal` output shape.
    private static func packSealed(_ out: AeadCipher.CipherOutput) -> Data {
        var data = Data(capacity: out.nonce.count + out.ciphertext.count + out.tag.count)
        data.append(out.nonce)
        data.append(out.ciphertext)
        data.append(out.tag)
        return data
    }

    private static func unpackSealed(_ data: Data) -> AeadCipher.CipherOutput {
        let base = data.startIndex
        let nonce = data.subdata(in: base..<(base + 12))
        let tag = data.suffix(16)
        let ct = data.subdata(in: (base + 12)..<(data.endIndex - 16))
        return AeadCipher.CipherOutput(nonce: nonce, ciphertext: ct, tag: tag)
    }
}
