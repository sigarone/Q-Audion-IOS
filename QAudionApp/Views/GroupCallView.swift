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
                HStack(spacing: 40) {
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
        }
    }
}

struct ParticipantTile: View {
    let participant: GroupCallViewModel.ParticipantUI

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 64, height: 64)

                Text(String(participant.displayName.prefix(1)).uppercased())
                    .font(.title).fontWeight(.semibold)
                    .foregroundColor(.white)
            }
            .overlay(
                Circle()
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
    }

    @Published var participants: [ParticipantUI] = []
    @Published var callState: BCryptoGroupCallManager.State = .idle
    @Published var isMuted = false
    @Published var elapsedTime = "0:00"

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

        let onState: (BCryptoGroupCallManager.State) -> Void = { [weak self] state in
            DispatchQueue.main.async { self?.callState = state }
            if state == .active { self?.startTimer() }
            if state == .ended { self?.timer?.invalidate() }
        }
        let onParticipants: ([BCryptoGroupCallManager.Participant]) -> Void = { [weak self] list in
            DispatchQueue.main.async {
                self?.participants = list.map {
                    ParticipantUI(id: $0.id, displayName: $0.displayName,
                                  isMuted: $0.isMuted, isSpeaking: $0.isSpeaking)
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
