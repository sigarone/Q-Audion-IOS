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
import AVFoundation

/// LiveKit SFU media transport for Q-Audion group calls. `video: true`
/// (or a later `setCameraEnabled(true)`) publishes camera alongside mic —
/// see `GroupCallController.wantsVideo`/`setVideoEnabled` (W-GRPVIDEO) for
/// how the call's `callType` and the mid-call toggle drive this.
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
    /// W-GRPVIDEO: fires with OUR OWN camera track (`LocalVideoTrack`,
    /// type-erased) whenever it starts/stops publishing — right after the
    /// initial `connect()` publish (when `video: true`) and on every
    /// `setCameraEnabled` toggle. `nil` means the camera is off (drop the
    /// self-preview tile). See the class doc comment for why this is
    /// type-erased to `AnyObject` rather than exposing `LocalVideoTrack`.
    public var onLocalVideoTrack: ((_ track: AnyObject?) -> Void)?
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

    /// W-GRPVIDEO-PERM (review fix): the SDK never requests camera
    /// authorization itself (verified against client-sdk-swift 2.13.0 —
    /// `CameraCapturer.startCapture()`/`LiveKit+DeviceHelpers.swift`'s
    /// `ensureDeviceAccess` is a public opt-in helper the SDK does not call
    /// internally). Without an explicit check here, a `.notDetermined`
    /// status (the user's very first camera-touching action in the app)
    /// would silently skip the OS permission prompt entirely — the camera
    /// session just never produces frames, no error, no crash, but also no
    /// prompt ever shown — and a `.denied` status would still "succeed"
    /// from `setCamera`'s point of view (SDK doesn't gate on authorization),
    /// publishing an empty/frozen video track instead of falling back to
    /// audio-only. Mirrors the existing explicit
    /// `AVCaptureDevice.authorizationStatus`/`requestAccess` gate already
    /// used for 1:1 video (`VideoCallPipeline.ensurePermission`) and QR
    /// scanning (`QrScannerView`).
    public enum CameraPermissionError: Error { case denied }

    private func ensureCameraAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    public init(video: Bool) {
        self.wantsVideo = video
        super.init()
    }

    /// Build the E2EE room, connect, and publish local mic (+camera if
    /// `video`). Throws on failure so the caller (`GroupCallController`)
    /// falls back to the existing WS-relay mesh path.
    ///
    /// W-GRPVIDEO-PERM: a camera-permission denial does NOT throw here —
    /// unlike a room-connect failure, losing the camera must degrade to an
    /// audio-only SFU call (mic still published), never abort the whole
    /// call. See `ensureCameraAuthorized`'s kdoc for why this check exists.
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
        // W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): local publish
        // confirmation — proves OUR OWN mic reached the SFU at all, cheap
        // to cross-reference against the SFU-side "track published" log.
        print("[GroupCallController][telemetry] local audio track published identity=\(room.localParticipant.identity?.stringValue ?? "self") callSid=\(room.sid?.stringValue ?? "?")")
        if wantsVideo {
            if await ensureCameraAuthorized() {
                _ = try await room.localParticipant.setCamera(enabled: true)
                print("[GroupCallController][telemetry] local video track published identity=\(room.localParticipant.identity?.stringValue ?? "self")")
                onLocalVideoTrack?(room.localParticipant.firstCameraVideoTrack)
            } else {
                // Graceful audio-only fallback: mic is already published
                // above, we simply never publish a camera track. No throw —
                // a camera-permission denial must not tear down the whole
                // SFU connection.
                onError?(CameraPermissionError.denied)
            }
        }
    }

    /// W-GRPVIDEO: mid-call camera on/off. Publishing a NEW video track
    /// through an already-connected room rides the SAME room-level
    /// `EncryptionOptions` configured above — `E2EEManager` hooks
    /// `Room`'s `didPublishTrack` delegate callback generically for
    /// whatever `Track.Kind` is published (verified against
    /// client-sdk-swift 2.13.0's `LocalParticipant._publish`, which sets
    /// `encryption: room.e2eeManager?.frameEncryptionType` on EVERY track
    /// add-request regardless of audio/video, and `E2EEManager.
    /// addRtpSender`, gated only on `publication.encryptionType != .none`)
    /// — so no separate key-application call is needed here, unlike
    /// `applyKey` above which feeds the actual SK_0 material.
    ///
    /// W-GRPVIDEO-PERM: turning video ON checks camera authorization first
    /// and THROWS `CameraPermissionError.denied` if not granted — unlike
    /// `connect()`, a toggle-on failure has a clean, existing revert path
    /// (`GroupCallController.setVideoEnabled` returns false ->
    /// `GroupCallViewModel.toggleVideo()` flips its optimistic UI back),
    /// so throwing here (rather than silently no-op'ing) is the correct,
    /// already-wired way to surface the denial.
    public func setCameraEnabled(_ enabled: Bool) async throws {
        guard let room = room else { return }
        if enabled {
            guard await ensureCameraAuthorized() else { throw CameraPermissionError.denied }
        }
        _ = try await room.localParticipant.setCamera(enabled: enabled)
        onLocalVideoTrack?(enabled ? room.localParticipant.firstCameraVideoTrack : nil)
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
        // W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): this is the
        // earliest point a REMOTE track exists locally at all — logging it
        // separates "never subscribed" (SFU/ICE/transport issue) from
        // "subscribed but never decrypts" (E2EE issue, see
        // `didUpdateE2EEState` below) and from "subscribed+decrypts but the
        // UI never binds it to a tile" (app-layer binding issue).
        if let audioTrack = publication.track as? RemoteAudioTrack {
            print("[GroupCallController][telemetry] remote audio track subscribed identity=\(identity)")
            onRemoteAudioTrack?(identity, audioTrack)
        } else if let videoTrack = publication.track as? RemoteVideoTrack {
            print("[GroupCallController][telemetry] remote video track subscribed identity=\(identity)")
            onRemoteVideoTrack?(identity, videoTrack)
        }
    }

    public func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        // W-GRPCALL-DIAG: the SDK-level counterpart to a successful
        // `didSubscribeTrack` above — if this fires for a peer whose track
        // publish the SFU logs confirm succeeded, the failure is on OUR
        // subscribe side (ICE/transport), not the sender's publish.
        print("[GroupCallController][telemetry] remote track subscribe FAILED identity=\(participant.identity?.stringValue ?? "") sid=\(trackSid) error=\(error)")
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

    /// W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): the single most
    /// direct signal for hypothesis A (silent E2EE key-install failure).
    /// `client-sdk-swift` 2.13.0's native `FrameCryptor` calls this per
    /// track whenever its crypto state changes; `.missing_key` means a
    /// track is arriving at the SFU and being handed to the cryptor, but no
    /// key has been installed for that participant/index yet (exactly what
    /// a never-delivered/never-decrypted `sender_key_init` produces);
    /// `.decryption_failed` means a key WAS installed but doesn't match the
    /// sender's actual key. Both explain "silence + black tile" with zero
    /// app-visible error, matching the reported symptoms exactly.
    public func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        let identity = Self.resolveIdentity(for: trackPublication, in: room)
        let kind = trackPublication.kind == .video ? "video" : "audio"
        print("[GroupCallController][telemetry] e2ee-state identity=\(identity ?? "?") kind=\(kind) state=\(state.toString())")
    }

    /// `TrackPublication` does not publicly expose its owning participant
    /// (the `participant` property is package-internal) — resolve it by
    /// matching `sid` against `room.localParticipant`/`room.remoteParticipants`
    /// instead, both of which DO publicly expose `trackPublications`.
    private static func resolveIdentity(for publication: TrackPublication, in room: Room) -> String? {
        if room.localParticipant.trackPublications[publication.sid] != nil {
            return room.localParticipant.identity?.stringValue ?? "self"
        }
        for (identity, participant) in room.remoteParticipants where participant.trackPublications[publication.sid] != nil {
            return identity.stringValue
        }
        return nil
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
    public var onLocalVideoTrack: ((_ track: AnyObject?) -> Void)?
    public var onParticipant: ((_ identity: String, _ present: Bool) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(video: Bool) { super.init() }

    public func connect(url: String, token: String) async throws {
        throw LiveKitUnavailableError.notAvailable
    }

    public func applyKey(_ key: GroupMediaKey) { /* no-op */ }

    public func setCameraEnabled(_ enabled: Bool) async throws {
        throw LiveKitUnavailableError.notAvailable
    }

    public func disconnect() async { /* no-op */ }
}

#endif
