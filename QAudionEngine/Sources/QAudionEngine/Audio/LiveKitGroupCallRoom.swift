import Foundation

/// One media-key update applied to the LiveKit room (self or a remote
/// participant). `graceMs`, when set, delays applying the key — used ONLY
/// for our own key right after a member-leave rekey, so in-flight frames
/// keyed under the OLD slot still decrypt for the ~3s Signal-style grace
/// window (mirrors Desktop `GroupMediaKey.graceMs` /
/// `GroupCallController.rekeyOnLeave`).
public struct GroupMediaKey {
    public let identity: String
    public let keyIndex: Int32
    /// `base64(SK_0)` — fed VERBATIM as the key material string. The native
    /// FrameCryptor UTF-8-encodes this string and PBKDF2-derives the
    /// AES-128-GCM frame key from it (see `LiveKitGroupE2eeKatTests` for the
    /// frozen vector). Never decode this to raw bytes before handing it to
    /// the key provider — the STRING is the cross-platform contract input.
    public let keyB64: String
    public let graceMs: Double?

    public init(identity: String, keyIndex: Int32, keyB64: String, graceMs: Double? = nil) {
        self.identity = identity
        self.keyIndex = keyIndex
        self.keyB64 = keyB64
        self.graceMs = graceMs
    }
}

#if canImport(LiveKit)
import LiveKit

/// LiveKit SFU media transport for Q-Audion group calls (audio today;
/// `video: true` publishes camera too, for a future video-group-call PR).
/// Direct Swift port of Desktop's `renderer/lib/GroupCallRoom.ts` — see that
/// file's header for the full cross-platform E2EE contract this MUST stay
/// byte-identical to:
///
///   KeyProvider options: sharedKey=false, ratchetSalt="LKFrameEncryptionKey",
///                        ratchetWindowSize=0, keyRingSize=16 (AES-128-GCM is
///                        the SDK's fixed/only cipher for this path — the
///                        Swift `KeyProviderOptions` type has no separate
///                        `keySize` knob the way the JS SDK's does).
///   Key input string:   S = base64(SK_0) (RFC4648, '=' padding, no newlines)
///   keyIndex:            epoch % 16 ; participant identity == userId UUID.
///
/// Owned directly by `GroupCallController` (no main/renderer process split
/// on iOS, unlike Desktop/Electron) — connect/disconnect and key application
/// are driven from there; remote track callbacks are surfaced up through
/// `GroupCallController` for the app layer (SwiftUI `VideoView` / audio
/// rendering) to attach to, type-erased to `AnyObject` so the public surface
/// of `GroupCallController` does not itself need to import LiveKit (see the
/// `#else` stub below — the two branches must expose an identical API).
public final class LiveKitGroupCallRoom: NSObject, @unchecked Sendable {

    /// A remote participant's audio/video track was subscribed. `track` is
    /// a `RemoteAudioTrack` or `RemoteVideoTrack` (type-erased — see the
    /// class doc comment for why).
    public var onRemoteAudioTrack: ((_ identity: String, _ track: AnyObject) -> Void)?
    public var onRemoteVideoTrack: ((_ identity: String, _ track: AnyObject) -> Void)?
    public var onParticipant: ((_ identity: String, _ present: Bool) -> Void)?
    public var onError: ((Error) -> Void)?

    private let wantsVideo: Bool
    private var room: Room?
    private var keyProvider: BaseKeyProvider?
    private let lock = NSLock()
    // NOTE: deliberately `DispatchWorkItem` + `asyncAfter`, NOT `Timer`.
    // `applyKey` is invoked from `GroupCallController`, itself driven off
    // the WS client's own background delegate queue (not the main run
    // loop) — a `Timer` scheduled there would silently never fire (Timer
    // needs an actively-pumped RunLoop; a plain GCD queue doesn't run one).
    private var graceWorkItems: [DispatchWorkItem] = []

    public init(video: Bool) {
        self.wantsVideo = video
        super.init()
    }

    /// Build the E2EE room, connect, and publish local mic (+camera if
    /// `video`). Throws on failure so the caller (`GroupCallController`)
    /// falls back to the existing WS-relay mesh path.
    public func connect(url: String, token: String) async throws {
        // Options set EXPLICITLY — SDK defaults diverge across platforms
        // (the JS SDK defaults `sharedKey: true`; we need per-participant
        // keys, so this must never rely on a default).
        let keyProviderOptions = KeyProviderOptions(
            sharedKey: false,
            ratchetSalt: Data("LKFrameEncryptionKey".utf8),
            ratchetWindowSize: 0,
            keyRingSize: 16
            // NOTE: LiveKit 2.13.0 (the Xcode-15.4-compatible pin — see
            // Package.swift) has NO `keyDerivationAlgorithm` option: it derives
            // the frame key with **PBKDF2 unconditionally** (the `.pbkdf2`/`.hkdf`
            // toggle arrived in 2.14+). PBKDF2 is exactly the cross-platform
            // contract (matches the JS SDK's string-key path + Desktop/Android),
            // so this stays interoperable without the toggle. If this dep is ever
            // bumped to >= 2.14, re-add `keyDerivationAlgorithm: .pbkdf2`
            // EXPLICITLY to guard against a future default flip to `.hkdf`.
            // 2.13.0's KeyProviderOptions defaults happen to already match this
            // contract (defaultRatchetSalt="LKFrameEncryptionKey",
            // defaultRatchetWindowSize=0, defaultKeyRingSize=16) — set anyway.
        )
        let keyProvider = BaseKeyProvider(options: keyProviderOptions)
        // `EncryptionOptions` (not the deprecated `E2EEOptions`) — same
        // KeyProvider-driven media E2EE, without also turning on data-channel
        // encryption (group TEXT CHAT is untouched by this feature).
        let encryptionOptions = EncryptionOptions(keyProvider: keyProvider, encryptionType: .gcm)
        let roomOptions = RoomOptions(encryptionOptions: encryptionOptions)
        let room = Room(delegate: self, roomOptions: roomOptions)

        self.keyProvider = keyProvider
        self.room = room

        try await room.connect(url: url, token: token)
        _ = try await room.localParticipant.setMicrophone(enabled: true)
        if wantsVideo {
            _ = try await room.localParticipant.setCamera(enabled: true)
        }
    }

    /// Apply a media-key update. `graceMs` (only ever set for our own key
    /// after a member leave) delays application so in-flight frames still
    /// decrypt under the previous slot until we flip.
    public func applyKey(_ key: GroupMediaKey) {
        guard let kp = keyProvider else { return }
        let apply = {
            kp.setKey(key: key.keyB64, participantId: key.identity, index: key.keyIndex)
        }
        if let grace = key.graceMs, grace > 0 {
            let work = DispatchWorkItem(block: apply)
            lock.lock(); graceWorkItems.append(work); lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace / 1000.0, execute: work)
        } else {
            apply()
        }
    }

    public func disconnect() async {
        lock.lock()
        for w in graceWorkItems { w.cancel() }
        graceWorkItems.removeAll()
        lock.unlock()
        await room?.disconnect()
        room = nil
        keyProvider = nil
    }
}

extension LiveKitGroupCallRoom: RoomDelegate {
    public func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let identity = participant.identity?.stringValue ?? ""
        if let audioTrack = publication.track as? RemoteAudioTrack {
            onRemoteAudioTrack?(identity, audioTrack)
        } else if let videoTrack = publication.track as? RemoteVideoTrack {
            onRemoteVideoTrack?(identity, videoTrack)
        }
    }

    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        onParticipant?(participant.identity?.stringValue ?? "", true)
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        onParticipant?(participant.identity?.stringValue ?? "", false)
    }

    public func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        if let error = error { onError?(error) }
    }

    public func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        // NOTE: a mid-call SFU disconnect does NOT currently auto-fall-back
        // to the WS-relay mesh (that fallback today only covers the INITIAL
        // connect attempt — see `GroupCallController.handleSfuToken`). This
        // just surfaces the error; resuming the mesh mid-call is a known
        // follow-up, not silently claimed as handled here.
        if let error = error { onError?(error) }
    }
}

#else

/// LiveKit SPM dependency did not resolve/compile in this build environment
/// (see `Package.swift`'s `.package(url: ".../client-sdk-swift", ...)` pin
/// for the version-compatibility rationale). Mirrors the `#if
/// canImport(Reality)` stub pattern already used in this package: the real
/// implementation above compiles wherever the dependency resolves; every
/// other build configuration gets this inert stub so the rest of
/// QAudionEngine is never blocked on it. `GroupCallController` treats a
/// throw from `connect` exactly like a `group_call_sfu_unavailable` server
/// reply and falls back to the existing WS-relay mesh path.
public final class LiveKitGroupCallRoom: NSObject, @unchecked Sendable {
    public enum LiveKitUnavailableError: Error { case notAvailable }

    public var onRemoteAudioTrack: ((_ identity: String, _ track: AnyObject) -> Void)?
    public var onRemoteVideoTrack: ((_ identity: String, _ track: AnyObject) -> Void)?
    public var onParticipant: ((_ identity: String, _ present: Bool) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(video: Bool) { super.init() }

    public func connect(url: String, token: String) async throws {
        throw LiveKitUnavailableError.notAvailable
    }

    public func applyKey(_ key: GroupMediaKey) { /* no-op */ }

    public func disconnect() async { /* no-op */ }
}

#endif
