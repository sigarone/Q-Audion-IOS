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
    /// W-GRPSCREENSHARE: a remote participant's SCREEN-SHARE track was
    /// subscribed (non-nil) or unsubscribed (nil). Deliberately SEPARATE
    /// from `onRemoteVideoTrack` — mirrors Android's `GroupCallRoom.
    /// Callbacks.onRemoteScreenShareTrack` (same rationale there: a
    /// participant can publish a camera track AND a screen-share track at
    /// the same time — two independent `Track.Source` values — so routing
    /// both through one `identity -> track` slot would silently drop
    /// whichever published second). See the `RoomDelegate` conformance
    /// below for how this is split off `onRemoteVideoTrack`.
    public var onRemoteScreenShareTrack: ((_ identity: String, _ track: AnyObject?) -> Void)?
    /// W-GRPSCREENSHARE: fires as OUR OWN screen-share track publishes
    /// (`true`) / unpublishes (`false`) — driven by the SDK's own
    /// ReplayKit-broadcast-lifecycle plumbing (see `setScreenShareEnabled`'s
    /// kdoc), NOT by this class synchronously deciding it. No self-preview
    /// tile is rendered off this signal — showing your own shared screen
    /// back to yourself inside itself is not useful UX — the app layer
    /// uses it purely to reconcile the toggle button state.
    public var onLocalScreenShareChanged: ((Bool) -> Void)?
    public var onParticipant: ((_ identity: String, _ present: Bool) -> Void)?
    public var onError: ((Error) -> Void)?
    /// Tier-1 layout toggle (item 5, 2026-07-16 wire contract) — fires with
    /// the current set of speaking participant identities whenever LiveKit's
    /// native active-speaker detection updates (`RoomDelegate.room(_:
    /// didUpdateSpeakingParticipants:)`, confirmed present on the pinned
    /// `sigarone/client-sdk-swift@2.13.0-aes256-livekit` fork). Data-layer
    /// plumbing only in this pass — the speaker/gallery layout toggle itself
    /// (pin/enlarge whichever identity this names) is a UI-layer follow-up.
    public var onSpeakingParticipantsChanged: ((_ identities: [String]) -> Void)?
    /// W-GRPTELEM: app-layer telemetry sink — QAudionEngine cannot import
    /// QAudionApp (`TelemetryService`/`CallMediaTelemetry` live there),
    /// same rationale as `QAudionWebRtcCallController.videoTelemetry` for
    /// the 1:1 path. `GroupCallController.handleSfuToken` wires this
    /// right after constructing this room (alongside the other `onXxx`
    /// callbacks below). `callId` is split out as its own parameter
    /// (rather than folded into `attrs`) so the wiring can pass it
    /// straight through to `TelemetryService.emit(kind:callId:attrs:)`
    /// without duplicating it inside the dict — see `emitTelemetry`.
    public var onTelemetry: ((_ kind: String, _ callId: String?, _ attrs: [String: Any]) -> Void)?
    /// W-GRPSENDERKEY-NACK — operational (not just diagnostic) forwarding of
    /// `didUpdateE2EEState`, fired alongside the `call.media.e2ee_state`
    /// telemetry emit in that delegate method below. `state` is the raw
    /// `.toString()` value ("missing_key" / "decryption_failed" / ...).
    public var onE2eeStateChanged: ((_ identity: String, _ kind: String, _ state: String) -> Void)?

    private let wantsVideo: Bool
    private var room: Room?
    private var keyProvider: BaseKeyProvider?
    /// W-GRPTELEM: set once at `connect(url:token:callId:)` time so every
    /// RoomDelegate/TrackDelegate callback fired afterwards (they don't
    /// otherwise carry the call id) can attach it to its telemetry event.
    private var callId: String?
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

    /// W-GRPTELEM: emit one telemetry event, folding in the `callId`
    /// captured at `connect(url:token:callId:)` time. Mirrors
    /// `QAudionWebRtcCallController.videoTelemetry`'s (kind, attrs) shape.
    private func emitTelemetry(_ kind: String, _ attrs: [String: Any] = [:]) {
        onTelemetry?(kind, callId, attrs)
    }

    /// W-GRPTELEM: the `video.stats`/`call.audio.stats` equivalent of
    /// `QAudionWebRtcCallController.pollVideoStatsOnce` — event-driven off
    /// the SDK's OWN native per-track statistics timer
    /// (`Track.set(reportStatistics:)`, verified against the real SDK
    /// source at the pinned tag: `Track._statisticsTimer`, a 1s
    /// `AsyncTimer` that drives `TrackDelegate.track(_:didUpdateStatistics:
    /// simulcastStatistics:)`) rather than a hand-rolled `Timer`.
    /// Deliberately NOT a `Timer` here: `graceWorkItems`'s kdoc above
    /// already documents why a `Timer` silently never fires when driven
    /// off a non-RunLoop-pumped queue, and `RoomDelegate`'s own doc
    /// comment says its callbacks "are not guaranteed to be the main
    /// thread" — the SDK's internal timer sidesteps that entirely.
    /// Gated on `onTelemetry` being wired (mirrors `videoTelemetry`'s own
    /// `guard videoTelemetry != nil` gate on the 1:1 path) so a room used
    /// without app-layer telemetry wiring never pays for the SDK's
    /// internal per-track polling.
    private func attachStatsReporting(to track: Track?) {
        guard let track, onTelemetry != nil else { return }
        track.add(delegate: self)
        Task { try? await track.set(reportStatistics: true) }
    }

    private func detachStatsReporting(from track: Track?) {
        guard let track else { return }
        track.remove(delegate: self)
    }

    /// Build the E2EE room, connect, and publish local mic (+camera if
    /// `video`). Throws on failure so the caller (`GroupCallController`)
    /// falls back to the existing WS-relay mesh path.
    ///
    /// W-GRPVIDEO-PERM: a camera-permission denial does NOT throw here —
    /// unlike a room-connect failure, losing the camera must degrade to an
    /// audio-only SFU call (mic still published), never abort the whole
    /// call. See `ensureCameraAuthorized`'s kdoc for why this check exists.
    ///
    /// W-GRPTELEM: `callId` (new) is stored so every subsequent telemetry
    /// event — including the ones fired asynchronously from RoomDelegate
    /// callbacks below — can attach it. Was previously not threaded
    /// through at all (`GroupCallController` held its own `activeCallId`
    /// but never passed it down here).
    public func connect(url: String, token: String, callId: String) async throws {
        self.callId = callId
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
        // W-GRPTELEM (item a): the `call.media.connected`-equivalent — fired
        // right here, NOT from a delegate callback, because no RoomDelegate
        // method fires on a successful INITIAL connect in this SDK version
        // (`didFailToConnectWithError` only covers the failure half; the
        // closest success signal, `roomDidConnect(_:)`, would double-fire
        // this exact event since `room.connect` above already only returns
        // once connected). `peer_prefix`/`sas_source` are shaped to match
        // `CallMediaTelemetry.recordConnected`'s parameters 1:1 so
        // `AppState`'s wiring can route this kind straight into it (see
        // that class's kdoc) and get the heartbeat/summary pair for free.
        emitTelemetry("call.media.connected", [
            "transport": "sfu",
            "call_type": wantsVideo ? "video" : "audio",
            "participant_count": room.remoteParticipants.count + 1,
            "peer_prefix": "group:\(room.remoteParticipants.count + 1)",
            "sas_source": "sfu"
        ])
        attachStatsReporting(to: room.localParticipant.firstAudioTrack)
        if wantsVideo {
            if await ensureCameraAuthorized() {
                _ = try await room.localParticipant.setCamera(enabled: true)
                print("[GroupCallController][telemetry] local video track published identity=\(room.localParticipant.identity?.stringValue ?? "self")")
                onLocalVideoTrack?(room.localParticipant.firstCameraVideoTrack)
                attachStatsReporting(to: room.localParticipant.firstCameraVideoTrack)
            } else {
                // Graceful audio-only fallback: mic is already published
                // above, we simply never publish a camera track. No throw —
                // a camera-permission denial must not tear down the whole
                // SFU connection.
                emitTelemetry("call.media.camera_permission_denied")
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
        let track = enabled ? room.localParticipant.firstCameraVideoTrack : nil
        onLocalVideoTrack?(track)
        if enabled {
            attachStatsReporting(to: track)
        }
    }

    /// W-GRPMUTEFIX (item 6, 2026-07-16 wire contract) — the REAL SFU
    /// mic-toggle, mirroring `setCameraEnabled`/`setScreenShareEnabled`'s
    /// shape exactly. Confirmed pre-existing gap: `connect()` above calls
    /// `room.localParticipant.setMicrophone(enabled: true)` exactly ONCE at
    /// connect time and nothing else in this file ever toggled it again —
    /// `GroupCallController.setMuted(_:)` only ever gated the LEGACY
    /// WS-relay-mesh `sendOutgoingOpusFrame` path, so pressing "mute" during
    /// an actual LiveKit-SFU call (the default/production transport) did
    /// NOT silence the outbound LiveKit audio track. This is the method
    /// that actually does.
    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard let room = room else { return }
        _ = try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    /// W-GRPSCREENSHARE: mid-call screen-share on/off.
    ///
    /// `enabled=true` calls the SDK's own `LocalParticipant.setScreenShare
    /// (enabled:)` directly — verified against the actual fork source
    /// (`Participant/LocalParticipant.swift`), not assumed:
    ///   - `setScreenShare(enabled:)` is `try await set(source: .screenShareVideo,
    ///     enabled: true)`.
    ///   - On iOS, `set(source:enabled:)`'s `.screenShareVideo` branch checks
    ///     `defaultScreenShareCaptureOptions.useBroadcastExtension`, which
    ///     defaults to `BroadcastBundleInfo.hasExtension` — `true` once our
    ///     `RTCAppGroupIdentifier`/`RTCScreenSharingExtension` Info.plist
    ///     overrides resolve to a real App-Group container (see
    ///     `QAudionBroadcastExtension`'s wiring) — so no custom `RoomOptions`
    ///     override is needed here.
    ///   - When `useBroadcastExtension` is true and `BroadcastManager.shared.
    ///     isBroadcasting` is NOT yet true, this branch itself calls
    ///     `BroadcastManager.shared.requestActivation()` (shows the SYSTEM
    ///     `RPSystemBroadcastPickerView`) and returns `nil` — so this method
    ///     deliberately does NOT invoke the picker itself; the SDK already
    ///     owns that UI, and inventing a second picker call site here would
    ///     just double-show it.
    ///   - The REAL publish happens asynchronously, later, once the user
    ///     actually starts the broadcast from the system picker:
    ///     `LocalParticipant`'s own `init` subscribes to `BroadcastManager.
    ///     shared.isBroadcastingPublisher` and re-invokes `setScreenShare
    ///     (enabled: true)` itself at that point (confirmed in the same
    ///     file). That second, SDK-internal call is what actually creates
    ///     the `BroadcastScreenCapturerTrack` and publishes it — this
    ///     method's own `try await` only covers the FIRST call (picker
    ///     request), so a caller must not treat this call's return as
    ///     "screen share is now live". `onLocalScreenShareChanged` /
    ///     `onRemoteScreenShareTrack` (via the `didPublishTrack`/
    ///     `didUnpublishTrack` `RoomDelegate` hooks below) are the actual
    ///     source of truth for that.
    ///
    /// `enabled=false` unpublishes the track (`setScreenShare(enabled:
    /// false)` — this hits the `else { unpublish(publication:) }` branch of
    /// `set(source:enabled:)` since `.screenShareVideo` is neither `.camera`
    /// nor `.microphone`) AND explicitly calls `BroadcastManager.shared.
    /// requestStop()`. Both are required: unpublishing alone does NOT stop
    /// the underlying ReplayKit recording — `LKSampleHandler` (the broadcast
    /// extension process) only tears itself down when it receives the
    /// `.broadcastRequestStop` Darwin notification (confirmed by reading
    /// that file's actual `init`, not assumed); without calling
    /// `requestStop()` here, the system status-bar recording indicator and
    /// the extension process would keep running after the room-side track
    /// is gone.
    public func setScreenShareEnabled(_ enabled: Bool) async throws {
        guard let room = room else { return }
        if enabled {
            _ = try await room.localParticipant.setScreenShare(enabled: true)
        } else {
            _ = try await room.localParticipant.setScreenShare(enabled: false)
            BroadcastManager.shared.requestStop()
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
        // W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): this is the
        // earliest point a REMOTE track exists locally at all — logging it
        // separates "never subscribed" (SFU/ICE/transport issue) from
        // "subscribed but never decrypts" (E2EE issue, see
        // `didUpdateE2EEState` below) and from "subscribed+decrypts but the
        // UI never binds it to a tile" (app-layer binding issue).
        // W-GRPTELEM: the `video.stats`/`call.audio.stats` receiver side —
        // see `attachStatsReporting`'s kdoc. Applies to every subscribed
        // track regardless of source (camera/screen-share/mic).
        attachStatsReporting(to: publication.track)
        if let audioTrack = publication.track as? RemoteAudioTrack {
            print("[GroupCallController][telemetry] remote audio track subscribed identity=\(identity)")
            emitTelemetry("call.audio.remote_track", ["identity": identity, "track_sid": publication.sid.stringValue])
            onRemoteAudioTrack?(identity, audioTrack)
        } else if let videoTrack = publication.track as? RemoteVideoTrack {
            // W-GRPSCREENSHARE: a participant can publish a camera track AND
            // a screen-share track simultaneously (two independent
            // `Track.Source` values) — split on `publication.source` and
            // route each to its OWN callback, mirroring Android's identical
            // split in `GroupCallRoom.wireEvents`'s `TrackSubscribed`
            // handling. Routing both through `onRemoteVideoTrack` would
            // silently drop whichever published second.
            if publication.source == .screenShareVideo {
                print("[GroupCallController][telemetry] remote screen-share track subscribed identity=\(identity)")
                emitTelemetry("video.remote_track", ["identity": identity, "kind": "screen_share", "track_sid": publication.sid.stringValue])
                onRemoteScreenShareTrack?(identity, videoTrack)
            } else {
                print("[GroupCallController][telemetry] remote video track subscribed identity=\(identity)")
                emitTelemetry("video.remote_track", ["identity": identity, "kind": "camera", "track_sid": publication.sid.stringValue])
                onRemoteVideoTrack?(identity, videoTrack)
            }
        }
    }

    /// W-GRPSCREENSHARE: only the screen-share case is handled here (clears
    /// the tile on unsubscribe) — mirrors Android's identical split in
    /// `GroupCallRoom.wireEvents`'s `TrackUnsubscribed` handling. Camera-
    /// track unsubscribe (a peer turning their camera off while remaining in
    /// the call) has no handler in this file either, before or after this
    /// change — today's `onSfuParticipant` only clears a tile on full
    /// participant DEPARTURE, not on camera-off. That is a separate,
    /// PRE-EXISTING gap, out of this change's scope — not fixed here to
    /// avoid touching unrelated behavior.
    public func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        // W-GRPTELEM: stop the stats-reporting timer for this track
        // regardless of source — the screen-share-only gate right below is
        // this method's PRE-EXISTING UI-callback scope, not a reason to
        // leave a camera/mic track's SDK-internal 1s poll running after
        // it's gone.
        detachStatsReporting(from: publication.track)
        guard publication.source == .screenShareVideo else { return }
        let identity = participant.identity?.stringValue ?? ""
        print("[GroupCallController][telemetry] remote screen-share track unsubscribed identity=\(identity)")
        onRemoteScreenShareTrack?(identity, nil)
    }

    /// W-GRPSCREENSHARE: OUR OWN screen-share track publish/unpublish —
    /// see `onLocalScreenShareChanged`'s kdoc for why this is the actual
    /// source of truth (not `setScreenShareEnabled`'s own return).
    public func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        print("[GroupCallController][telemetry] local screen-share track published")
        onLocalScreenShareChanged?(true)
    }

    public func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        print("[GroupCallController][telemetry] local screen-share track unpublished")
        onLocalScreenShareChanged?(false)
    }

    public func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        // W-GRPCALL-DIAG: the SDK-level counterpart to a successful
        // `didSubscribeTrack` above — if this fires for a peer whose track
        // publish the SFU logs confirm succeeded, the failure is on OUR
        // subscribe side (ICE/transport), not the sender's publish.
        print("[GroupCallController][telemetry] remote track subscribe FAILED identity=\(participant.identity?.stringValue ?? "") sid=\(trackSid) error=\(error)")
        emitTelemetry("video.remote_track_failed", [
            "identity": participant.identity?.stringValue ?? "",
            "track_sid": trackSid.stringValue,
            "error": "\(error)"
        ])
    }

    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        emitTelemetry("call.media.participant", ["identity": participant.identity?.stringValue ?? "", "present": true])
        onParticipant?(participant.identity?.stringValue ?? "", true)
    }

    /// Tier-1 layout toggle (item 5, 2026-07-16 wire contract) — native
    /// active-speaker detection, wired for the first time. Surfaces the
    /// identities so the (future) UI layer can pin/enlarge whoever the SDK
    /// currently names as speaking; `Participant.identity` is nil only in
    /// pathological SDK states, so those entries are dropped rather than
    /// surfaced as an empty-string identity.
    public func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        onSpeakingParticipantsChanged?(participants.compactMap { $0.identity?.stringValue })
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        emitTelemetry("call.media.participant", ["identity": participant.identity?.stringValue ?? "", "present": false])
        onParticipant?(participant.identity?.stringValue ?? "", false)
    }

    public func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        emitTelemetry("call.media.sfu_connect_failed", ["error": error.map { "\($0)" } ?? "unknown"])
        if let error = error { onError?(error) }
    }

    public func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        // NOTE: a mid-call SFU disconnect does NOT currently auto-fall-back
        // to the WS-relay mesh (that fallback today only covers the INITIAL
        // connect attempt — see `GroupCallController.handleSfuToken`). This
        // just surfaces the error; resuming the mesh mid-call is a known
        // follow-up, not silently claimed as handled here.
        emitTelemetry("call.media.sfu_disconnected", ["error": error.map { "\($0)" } ?? "none"])
        if let error = error { onError?(error) }
    }

    /// W-GRPTELEM (item b) — ongoing SFU connection-state telemetry, the
    /// heartbeat-equivalent asked for in the confirmed-facts recon.
    /// Verified against the real `RoomDelegate` protocol at the pinned
    /// fork's base tag (`sigarone/client-sdk-swift@2.13.0-aes256-livekit`,
    /// untouched from upstream `livekit/client-sdk-swift@2.13.0` outside
    /// the AES-256/E2EE bits per `Package.swift`'s own comment) rather than
    /// assumed — this method DOES exist on `RoomDelegate` in this SDK
    /// version. Fires on every SFU-level transition
    /// (`.connecting`/`.connected`/`.reconnecting`/`.disconnected`), a
    /// strictly richer signal than a fixed-interval heartbeat: a
    /// `.reconnecting` that never resolves for the rest of the call is
    /// visible here, where a fixed heartbeat would simply go silent
    /// (indistinguishable from "app suspended").
    public func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        emitTelemetry("call.media.sfu_connection_state", [
            "state": "\(connectionState)",
            "from": "\(oldConnectionState)"
        ])
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
        emitTelemetry("call.media.e2ee_state", ["identity": identity ?? "?", "kind": kind, "state": state.toString()])
        // W-GRPSENDERKEY-NACK (2026-07-17) — forward this SAME signal
        // operationally, not just diagnostically: GroupCallController
        // reacts to missing_key/decryption_failed by nudging the sender to
        // reship their key (see its onE2eeStateChanged wiring in
        // handleSfuToken).
        if let identity = identity {
            onE2eeStateChanged?(identity, kind, state.toString())
        }
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

extension LiveKitGroupCallRoom: TrackDelegate {
    /// W-GRPTELEM: the `video.stats`/`call.audio.counts` equivalent of
    /// `QAudionWebRtcCallController.pollVideoStatsOnce` — see
    /// `attachStatsReporting`'s kdoc for why this rides the SDK's native
    /// per-track timer instead of a hand-rolled one.
    ///
    /// W-GRPTELEM-KEYNAMES (2026-07-17) — every field name here (both kinds)
    /// MUST match what `bcrypto-server/tools/tune-report.py`'s `build_legs()`
    /// literally reads via `attrs.get(...)` — it is a dumb dict-key parser,
    /// not a schema-aware one, and a mismatched key silently renders as "X"
    /// with no error anywhere. Confirmed live: this method's ORIGINAL field
    /// names (`out_packets_sent`, `in_packets_received`, `in_frames_dropped`,
    /// etc.) and, for audio, its ORIGINAL kind (`call.audio.stats` — the
    /// parser only recognizes `call.audio.counts`, there is no fallback)
    /// left every iOS group-call leg's audio panel and several video fields
    /// permanently blank across 3 live tests today, hiding real e2ee/decrypt
    /// data that WAS being collected. Video's core counters already matched
    /// by name (kept below); audio's did not (kind AND every key renamed,
    /// mirroring Android's `GroupCallRoom.kt.pollAudioStats()`: packetsSent→
    /// tx_enc, packetsReceived→rx_recv, packetsReceived-packetsLost→rx_dec,
    /// packetsLost→rx_dec_err — same reconciliation Android's own kdoc
    /// documents doing for parity with the 1:1 kind tune-report.py was
    /// originally written against).
    ///
    /// W-GRPTELEM-VIDEODETAIL (2026-07-17) — `in_codec`/`out_codec`/`in_fps`/
    /// `out_fps` added: verified against the EXACT pinned SDK source (a
    /// local clone of `sigarone/client-sdk-swift@2.13.0-aes256-livekit`,
    /// diffed byte-identical against upstream `v2.13.0` for the stats
    /// files) rather than guessed. `TrackStatistics.codec: [CodecStatistics]`
    /// is a SEPARATE array joined via `codecId` (no direct codec-name
    /// property on the RTP stream stats themselves — mirrors the join
    /// pattern the 1:1 path's `pollVideoStatsOnce` already does by hand
    /// against the raw WebRTC `RTCStatisticsReport`, confirming this join
    /// shape is the right one for this stats-model family). `framesPerSecond`
    /// IS a first-class field directly on both in/outbound stream stats —
    /// no join needed for that one.
    public func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics: [VideoCodec: TrackStatistics]) {
        guard let room = self.room else { return }
        let identity = Self.resolveIdentity(forTrack: track, in: room) ?? "?"
        let isLocal = identity == (room.localParticipant.identity?.stringValue ?? "self")
        func codecMime(_ codecId: String?) -> String {
            guard let codecId = codecId,
                  let entry = statistics.codec.first(where: { $0.id == codecId }) else { return "?" }
            return entry.mimeType ?? "?"
        }
        switch track.kind {
        case .video:
            if isLocal, let out = statistics.outboundRtpStream.first {
                emitTelemetry("video.stats", [
                    "identity": identity,
                    "direction": "out",
                    "out_frames_enc": Int(out.framesEncoded ?? 0),
                    "out_key_frames_enc": Int(out.keyFramesEncoded ?? 0),
                    "out_bytes": Int(out.bytesSent ?? 0),
                    "out_frame_w": Int(out.frameWidth ?? 0),
                    "out_frame_h": Int(out.frameHeight ?? 0),
                    "out_fps": out.framesPerSecond ?? -1,
                    "out_codec": codecMime(out.codecId),
                    "out_encoder_impl": out.encoderImplementation ?? "?",
                    "out_quality_limit": out.qualityLimitationReason?.rawValue ?? "?"
                ])
            } else if let inb = statistics.inboundRtpStream.first {
                emitTelemetry("video.stats", [
                    "identity": identity,
                    "direction": "in",
                    "in_frames_dec": Int(inb.framesDecoded ?? 0),
                    "in_frames_rec": Int(inb.framesReceived ?? 0),
                    "in_bytes": Int(inb.bytesReceived ?? 0),
                    "in_frame_w": Int(inb.frameWidth ?? 0),
                    "in_frame_h": Int(inb.frameHeight ?? 0),
                    "in_fps": inb.framesPerSecond ?? -1,
                    "in_codec": codecMime(inb.codecId),
                    // tune-report.py reads "in_freeze" (not "in_freeze_count").
                    "in_freeze": Int(inb.freezeCount ?? 0),
                    "in_frames_dropped": Int(inb.framesDropped ?? 0),
                    "in_decoder_impl": inb.decoderImplementation ?? "?"
                ])
            }
        case .audio:
            if isLocal, let out = statistics.outboundRtpStream.first {
                // tune-report.py only recognizes kind "call.audio.counts" for
                // audio TX/RX counters (see W-GRPTELEM-KEYNAMES) — "call.audio.stats"
                // was silently dropped by build_legs(), never a recognized kind.
                emitTelemetry("call.audio.counts", [
                    "identity": identity,
                    "direction": "out",
                    "tx_enc": Int(out.packetsSent ?? 0),
                    "out_bytes": Int(out.bytesSent ?? 0)
                ])
            } else if let inb = statistics.inboundRtpStream.first {
                let received = Int(inb.packetsReceived ?? 0)
                let lost = Int(inb.packetsLost ?? 0)
                emitTelemetry("call.audio.counts", [
                    "identity": identity,
                    "direction": "in",
                    "rx_recv": received,
                    "rx_dec": max(received - lost, 0),
                    "rx_dec_err": lost,
                    "in_jitter": inb.jitter ?? -1,
                    "in_bytes": Int(inb.bytesReceived ?? 0),
                    "in_concealed_samples": Int(inb.concealedSamples ?? 0)
                ])
            }
        case .none:
            break
        @unknown default:
            break
        }
    }

    /// Same rationale as `resolveIdentity(for publication:in:)` above, but
    /// keyed off the `Track` itself (the `TrackDelegate` callback doesn't
    /// hand us a `TrackPublication`) — named distinctly (`forTrack:`
    /// rather than reusing the `for:` label) purely to avoid any reader
    /// confusion between the two overloads, not because Swift requires it.
    private static func resolveIdentity(forTrack track: Track, in room: Room) -> String? {
        if room.localParticipant.trackPublications.values.contains(where: { $0.track === track }) {
            return room.localParticipant.identity?.stringValue ?? "self"
        }
        for (identity, participant) in room.remoteParticipants
            where participant.trackPublications.values.contains(where: { $0.track === track }) {
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
    /// W-GRPSCREENSHARE: stub counterpart of the real class's same-named
    /// property — kept so `GroupCallController` compiles identically in
    /// both build configurations (see this stub's own doc comment above).
    public var onRemoteScreenShareTrack: ((_ identity: String, _ track: AnyObject?) -> Void)?
    public var onLocalScreenShareChanged: ((Bool) -> Void)?
    public var onParticipant: ((_ identity: String, _ present: Bool) -> Void)?
    public var onError: ((Error) -> Void)?
    /// Tier-1 layout toggle — stub counterpart of the real class's
    /// same-named property (see this stub's own doc comment above).
    public var onSpeakingParticipantsChanged: ((_ identities: [String]) -> Void)?
    /// W-GRPTELEM — stub counterpart of the real class's same-named
    /// property (see this stub's own doc comment above). Never fires here.
    public var onTelemetry: ((_ kind: String, _ callId: String?, _ attrs: [String: Any]) -> Void)?
    /// W-GRPSENDERKEY-NACK — stub counterpart of the real class's same-named
    /// property (see this stub's own doc comment above). Never fires here.
    public var onE2eeStateChanged: ((_ identity: String, _ kind: String, _ state: String) -> Void)?

    public init(video: Bool) { super.init() }

    public func connect(url: String, token: String, callId: String) async throws {
        throw LiveKitUnavailableError.notAvailable
    }

    public func applyKey(_ key: GroupMediaKey) { /* no-op */ }

    public func setCameraEnabled(_ enabled: Bool) async throws {
        throw LiveKitUnavailableError.notAvailable
    }

    /// W-GRPMUTEFIX — stub counterpart of the real class's same-named
    /// method (see this stub's own doc comment above).
    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        throw LiveKitUnavailableError.notAvailable
    }

    public func setScreenShareEnabled(_ enabled: Bool) async throws {
        throw LiveKitUnavailableError.notAvailable
    }

    public func disconnect() async { /* no-op */ }
}

#endif
