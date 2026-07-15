import SwiftUI
import QAudionEngine

/// Group call screen with participant grid and controls.
/// Max 8 participants in 2-column layout with speaking indicators.
struct GroupCallView: View {
    @ObservedObject var viewModel: GroupCallViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chiamata di gruppo")
                            .font(.headline).foregroundColor(.white)
                        Text("\(viewModel.participants.count) partecipanti")
                            .font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                    if viewModel.callState == .active {
                        Text(viewModel.elapsedTime)
                            .font(.caption).monospacedDigit()
                            .foregroundColor(Color(red: 0, green: 0.9, blue: 0.47))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

                // Participant grid
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ], spacing: 12) {
                        ForEach(viewModel.participants) { participant in
                            ParticipantTile(participant: participant)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Spacer()

                // Control bar
                HStack(spacing: 32) {
                    // Mute button
                    Button {
                        viewModel.toggleMute()
                    } label: {
                        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(viewModel.isMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }

                    // W-GRPVIDEO: camera on/off. Only shown once the call is
                    // actually riding the LiveKit SFU (isUsingSfu) — the
                    // WS-relay mesh fallback path has no video pipeline, so
                    // there is nothing to toggle. Works whether the call
                    // started as audio or video: publishing a fresh camera
                    // track mid-call is a supported LiveKit path (see
                    // GroupCallController.setVideoEnabled kdoc).
                    if viewModel.isSfuActive {
                        Button {
                            viewModel.toggleVideo()
                        } label: {
                            Image(systemName: viewModel.isVideoEnabled ? "video.fill" : "video.slash.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(viewModel.isVideoEnabled ? Color.white.opacity(0.15) : Color.red.opacity(0.3))
                                .clipShape(Circle())
                        }
                    }

                    // End call button
                    Button {
                        viewModel.endCall()
                        dismiss()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 40)
            }

            // W-GRPVIDEO: self-preview PiP, bottom-trailing — mirrors the
            // 1:1 VideoCallView's localPreview placement. Only shown while
            // our own camera track is actually publishing.
            if let selfTrack = viewModel.selfVideoTrack {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        GroupCallVideoView(track: selfTrack)
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
                            .padding(.trailing, 16)
                            .padding(.bottom, 120)
                    }
                }
            }
        }
    }
}

struct ParticipantTile: View {
    let participant: GroupCallViewModel.ParticipantUI

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let track = participant.videoTrack {
                    GroupCallVideoView(track: track)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 64, height: 64)

                    Text(String(participant.displayName.prefix(1)).uppercased())
                        .font(.title).fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: participant.videoTrack != nil ? 120 : 64)
            .overlay(
                RoundedRectangle(cornerRadius: participant.videoTrack != nil ? 12 : 32)
                    .stroke(participant.isSpeaking ? Color(red: 0, green: 0.9, blue: 0.47) : Color.clear, lineWidth: 3)
            )

            Text(participant.displayName)
                .font(.caption).foregroundColor(.white)
                .lineLimit(1)

            if participant.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.caption2).foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
    }
}

// MARK: - ViewModel

class GroupCallViewModel: ObservableObject {
    struct ParticipantUI: Identifiable {
        let id: String
        var displayName: String
        var isMuted: Bool = false
        var isSpeaking: Bool = false
        /// W-GRPVIDEO: type-erased `RemoteVideoTrack` (see
        /// `LiveKitGroupCallRoom`'s doc comment for why) — nil until the
        /// SFU subscribes this participant's camera; cleared again on
        /// participant departure. Rendered via `GroupCallVideoView`.
        var videoTrack: AnyObject? = nil
    }

    @Published var participants: [ParticipantUI] = []
    @Published var callState: BCryptoGroupCallManager.State = .idle
    @Published var isMuted = false
    @Published var elapsedTime = "0:00"
    /// W-GRPVIDEO: our own camera preview (type-erased `LocalVideoTrack`),
    /// nil when off.
    @Published var selfVideoTrack: AnyObject? = nil
    /// W-GRPVIDEO: mirrors whether OUR camera is currently publishing —
    /// seeded from the call's `callType` on the `.active` transition
    /// (`GroupCallController.wantsVideo`, surfaced via `callWantsVideo`),
    /// then flipped by `toggleVideo()`.
    @Published var isVideoEnabled = false
    /// W-GRPVIDEO: whether the call is riding the LiveKit SFU right now —
    /// gates the camera-toggle button (the WS-relay mesh fallback has no
    /// video pipeline).
    @Published var isSfuActive = false

    private let manager: BCryptoGroupCallManager
    /// W367: optional GroupCallController (W354/W358/W366) bound to
    /// the audio pipeline. When set, mute toggles and end-call route
    /// through the controller so capture/playback start/stop in
    /// lockstep with call state. Falls back to direct manager calls
    /// if nil (legacy preview path).
    private let controller: GroupCallController?
    private var startTime = Date()
    private var timer: Timer?

    init(manager: BCryptoGroupCallManager, controller: GroupCallController? = nil) {
        self.manager = manager
        self.controller = controller

        // W-GRPVIDEO: `controller` is captured `weak` here even though this
        // closure is only ever installed ONTO `controller.onManagerStateChanged`
        // itself — a strong capture would make controller <-> closure a
        // self-cycle (controller retains the closure, closure retains
        // controller) that ARC can never break, independent of this
        // ViewModel's own (separate) strong `self.controller` reference.
        // Mirrors `[weak self]` on every `manager.on*` closure in
        // `GroupCallController.wireManagerCallbacks()`.
        let onState: (BCryptoGroupCallManager.State) -> Void = { [weak self, weak controller] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.callState = state
                if state == .active {
                    self.isSfuActive = controller?.isUsingSfu ?? false
                    self.isVideoEnabled = controller?.callWantsVideo ?? false
                }
            }
            if state == .active { self?.startTimer() }
            if state == .ended { self?.timer?.invalidate() }
        }
        let onParticipants: ([BCryptoGroupCallManager.Participant]) -> Void = { [weak self] list in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Preserve any already-attached video track for a
                // participant that survives this roster refresh — a plain
                // `list.map` would otherwise drop it every time the WS
                // roster updates (join/leave of ANY member re-sends the
                // full list).
                let existingTracks = Dictionary(uniqueKeysWithValues: self.participants.map { ($0.id, $0.videoTrack) })
                self.participants = list.map {
                    ParticipantUI(id: $0.id, displayName: $0.displayName,
                                  isMuted: $0.isMuted, isSpeaking: $0.isSpeaking,
                                  videoTrack: existingTracks[$0.id] ?? nil)
                }
            }
        }
        if let controller = controller {
            // W-GRPUI: `manager.onStateChanged`/`onParticipantsChanged` are
            // single-slot closures already owned by `controller` (it needs
            // them for the audio-pipeline lifecycle) — observe its
            // passthrough instead of overwriting them directly.
            controller.onManagerStateChanged = onState
            controller.onParticipantsChanged = onParticipants
            // W-GRPVIDEO: bind the LiveKit track callbacks here (rather
            // than in AppState) — this ViewModel is the SFU render-target,
            // and `onRemoteVideoTrack`/`onLocalVideoTrack`/`onSfuParticipant`
            // are single-slot closures on the controller just like the two
            // above, so the same "bind once, here" pattern applies.
            controller.onRemoteVideoTrack = { [weak self] identity, track in
                DispatchQueue.main.async {
                    guard let self = self, let idx = self.participants.firstIndex(where: { $0.id == identity }) else { return }
                    self.participants[idx].videoTrack = track
                }
            }
            controller.onLocalVideoTrack = { [weak self] track in
                DispatchQueue.main.async { self?.selfVideoTrack = track }
            }
            controller.onSfuParticipant = { [weak self] identity, present in
                guard !present else { return }
                DispatchQueue.main.async {
                    guard let self = self, let idx = self.participants.firstIndex(where: { $0.id == identity }) else { return }
                    self.participants[idx].videoTrack = nil
                }
            }
        } else {
            manager.onStateChanged = onState
            manager.onParticipantsChanged = onParticipants
        }
    }

    func toggleMute() {
        isMuted = manager.toggleMute()
        // W367: also flip the controller's mute so the audio pipeline
        // gates outgoing PCM frames (without this, mute is UI-only and
        // audio still streams to peers).
        controller?.setMuted(isMuted)
    }

    /// W-GRPVIDEO: flip the local camera. Optimistic UI update (mirrors
    /// `toggleMute`'s pattern of flipping first) — reverted if the async
    /// LiveKit call actually fails.
    func toggleVideo() {
        guard let controller = controller else { return }
        let target = !isVideoEnabled
        isVideoEnabled = target
        Task { [weak self] in
            let ok = await controller.setVideoEnabled(target)
            if !ok {
                await MainActor.run { self?.isVideoEnabled = !target }
            }
        }
    }

    func endCall() {
        // W367: stop the audio pipeline cleanly via the controller; if
        // no controller is bound (legacy preview), fall through to the
        // raw manager.endGroupCall().
        if let controller = controller {
            controller.endCallForAll()
        } else {
            manager.endGroupCall()
        }
    }

    private func startTimer() {
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.startTime))
            let min = elapsed / 60
            let sec = elapsed % 60
            DispatchQueue.main.async {
                self.elapsedTime = String(format: "%d:%02d", min, sec)
            }
        }
    }
}
