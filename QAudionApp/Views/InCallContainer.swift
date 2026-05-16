import SwiftUI
import Combine
import QAudionEngine

@MainActor
final class InCallContainer: ObservableObject {

    @Published private(set) var viewModel: InCallViewModel = .mock

    private weak var appState: AppState?
    private let contactsStore: ContactsStore
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, contactsStore: ContactsStore = ContactsStore()) {
        self.appState = appState
        self.contactsStore = contactsStore
        rebuild()
        bindAppState()
        bindCallService()
    }

    // MARK: - Bindings

    private func bindAppState() {
        guard let appState = appState else { return }

        // Waveform scalars: derive peak amplitude from the sample arrays AppState publishes.
        appState.$txWaveform
            .receive(on: RunLoop.main)
            .sink { [weak self] samples in
                let peak = samples.map { abs($0) }.max() ?? 0
                self?.update { $0.waveformTx = Double(peak) }
            }
            .store(in: &cancellables)

        appState.$rxWaveform
            .receive(on: RunLoop.main)
            .sink { [weak self] samples in
                let peak = samples.map { abs($0) }.max() ?? 0
                self?.update { $0.waveformRx = Double(peak) }
            }
            .store(in: &cancellables)

        appState.$cipherWaveform
            .receive(on: RunLoop.main)
            .sink { [weak self] samples in
                let peak = samples.map { abs($0) }.max() ?? 0
                self?.update { $0.waveformCipher = Double(peak) }
            }
            .store(in: &cancellables)

        // Peer info from callContactId. Resolves displayName / avatarUrl /
        // fingerprint from the local ContactsStore when the userId matches a
        // QR-paired or phonebook-discovered contact; falls back to userId
        // and the unknown-fingerprint placeholder otherwise.
        appState.$callContactId
            .receive(on: RunLoop.main)
            .sink { [weak self] cid in
                guard let self, let cid = cid else { return }
                let stored = self.contactsStore.load().first(where: { $0.userId == cid })
                let displayName = stored?.displayName ?? cid
                let avatarUrl = stored?.avatarUrl
                let fingerprint: String = {
                    // W439: When the peer is not QR-paired (no pubkey in
                    // ContactsStore), the old placeholder "????.????.????.????"
                    // was shown verbatim under the peer name during every call.
                    // Instead show the abbreviated userId (first 8 + last 4)
                    // so testers can still cross-reference the peer without
                    // seeing a confusing row of question marks.
                    guard let pk = stored?.pubkey else {
                        let head = String(cid.prefix(8))
                        let tail = String(cid.suffix(4))
                        return head + "…" + tail
                    }
                    return (try? Fingerprint.format(pubkey: pk)) ?? {
                        let head = String(cid.prefix(8))
                        let tail = String(cid.suffix(4))
                        return head + "…" + tail
                    }()
                }()
                self.update {
                    $0.peer = InCallViewModel.PeerInfo(
                        userId: cid,
                        displayName: displayName,
                        avatarUrl: avatarUrl,
                        fingerprint: fingerprint
                    )
                }
            }
            .store(in: &cancellables)

        // Security state derived from callState + deepfakeAlert.
        Publishers.CombineLatest(appState.$callState, appState.$deepfakeAlert)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, alert in
                let security: InCallViewModel.SecurityState
                if alert {
                    security = .insecureFallback
                } else if state == .encrypted {
                    security = .secure
                } else {
                    security = .verifying
                }
                self?.update { $0.security = security }
            }
            .store(in: &cancellables)
    }

    private func bindCallService() {
        guard let cs = appState?.callService else { return }

        // Primary: CallService fires onDurationTick on its timer's thread.
        // Hop to MainActor before touching the view model.
        cs.onDurationTick = { [weak self] dur in
            Task { @MainActor [weak self] in
                self?.update { $0.callDuration = dur }
            }
        }

        // W439 fallback: CallService.startDurationTimer() uses
        // Timer.scheduledTimer without specifying a run loop. If that
        // method is ever called from a background thread its timer ends
        // up on a run loop that isn't spinning, so onDurationTick never
        // fires and the in-call timer stays frozen at 00:00.
        // This Combine timer always fires on RunLoop.main and polls
        // callDurationSeconds directly — one extra read per second is cheap.
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let cs = self.appState?.callService else { return }
                self.update { $0.callDuration = cs.callDurationSeconds }
            }
            .store(in: &cancellables)
    }

    // MARK: - User actions

    func tapMute() {
        guard let cs = appState?.callService else { return }
        let newMuted = !cs.isMuted
        cs.setMuted(newMuted)
        update { vm in
            vm.controls = InCallViewModel.Controls(
                isMuted: newMuted,
                isSpeakerOn: vm.controls.isSpeakerOn,
                isOnHold: vm.controls.isOnHold,
                endCallStyle: vm.controls.endCallStyle
            )
        }
        // Bridge through CallKit so the system mute UI stays in sync.
        if let kit = appState?.callKit, let id = appState?.activeCallKitId {
            Task { try? await kit.setMuted(uuid: id, isMuted: newMuted) }
        }
    }

    func tapSpeaker() {
        // AVAudioSession route override not yet implemented — toggle is UI-only for now.
        update { vm in
            vm.controls = InCallViewModel.Controls(
                isMuted: vm.controls.isMuted,
                isSpeakerOn: !vm.controls.isSpeakerOn,
                isOnHold: vm.controls.isOnHold,
                endCallStyle: vm.controls.endCallStyle
            )
        }
        appState?.setSpeaker(viewModel.controls.isSpeakerOn)
    }

    func tapHold() {
        guard let cs = appState?.callService else { return }
        let newHold = !cs.isOnHold
        cs.setOnHold(newHold)
        update { vm in
            vm.controls = InCallViewModel.Controls(
                isMuted: vm.controls.isMuted,
                isSpeakerOn: vm.controls.isSpeakerOn,
                isOnHold: newHold,
                endCallStyle: vm.controls.endCallStyle
            )
        }
        if let kit = appState?.callKit, let id = appState?.activeCallKitId {
            Task { try? await kit.setOnHold(uuid: id, isOnHold: newHold) }
        }
    }

    func tapEnd() {
        appState?.endCall()
        if let kit = appState?.callKit, let id = appState?.activeCallKitId {
            Task { await kit.reportCallEnded(uuid: id, reason: .userEnded) }
        }
    }

    // MARK: - Internals

    private func rebuild() {
        // Seed with mock; live values flow in via Combine sinks above.
        viewModel = .mock
    }

    private func update(_ mutate: (inout MutableInCallViewModel) -> Void) {
        var m = viewModel.toMutable()
        mutate(&m)
        viewModel = m.toImmutable()
    }
}

// MARK: - Mutable mirror

/// Mutable counterpart to the all-let InCallViewModel. Internal to InCallContainer.
private struct MutableInCallViewModel {
    var peer: InCallViewModel.PeerInfo
    var security: InCallViewModel.SecurityState
    var callDuration: TimeInterval
    var waveformTx: Double
    var waveformRx: Double
    var waveformCipher: Double
    var controls: InCallViewModel.Controls
    var shouldShowSasPrompt: Bool
    var showVideoPip: Bool

    func toImmutable() -> InCallViewModel {
        InCallViewModel(
            peer: peer,
            security: security,
            callDuration: callDuration,
            waveformTx: waveformTx,
            waveformRx: waveformRx,
            waveformCipher: waveformCipher,
            controls: controls,
            shouldShowSasPrompt: shouldShowSasPrompt,
            showVideoPip: showVideoPip
        )
    }
}

private extension InCallViewModel {
    func toMutable() -> MutableInCallViewModel {
        MutableInCallViewModel(
            peer: peer,
            security: security,
            callDuration: callDuration,
            waveformTx: waveformTx,
            waveformRx: waveformRx,
            waveformCipher: waveformCipher,
            controls: controls,
            shouldShowSasPrompt: shouldShowSasPrompt,
            showVideoPip: showVideoPip
        )
    }
}
