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

        // Peer info from callContactId.
        //
        // 2026-07-29 fix (Pavel live-test evidence: an active call showed
        // the bare extension "135" for the whole call — no name, no phone
        // number saved anywhere) — this sink used to hand-roll its OWN
        // resolution (local ContactsStore → its own `getPublicUser` call →
        // its own ext/name fallback), completely independent of the
        // canonical `DisplayName.forUser` chain every other in-call/ring
        // surface uses (`LiveInCallScreen.resolvePeerDisplayName`,
        // `HomeView`'s in-call banner, `ContentView`'s outgoing screen —
        // all pass `appState.incomingCallerName`, the value ALREADY
        // correctly resolved at ring time and held for the whole call).
        // This sink alone ignored `incomingCallerName`, so a peer whose
        // name resolved fine at ring regressed to the bare extension the
        // moment the call became active. It also never read or persisted
        // `pub.phoneNumber` at all — only `NameResolutionService.
        // enrichFromCallProfile` does that — so the real phone number could
        // never be saved via this path either. Routing through the same
        // canonical chain used everywhere else fixes both at once.
        appState.$callContactId
            .receive(on: RunLoop.main)
            .sink { [weak self] cid in
                guard let self, let cid = cid else { return }
                self.resolvePeer(for: cid)
                // The canonical chain's own async enrichment
                // (`NameResolutionService.ensureResolved` →
                // `enrichFromCallProfile`, the only path that persists the
                // peer's phone number / backfills a blank extension) only
                // fires from `DisplayName.forUser`'s tier-6 miss — i.e.
                // NEVER when `incomingCallerName` already resolved the name
                // via tier 2, which is the common case for an established
                // call. Fire it explicitly here so a call-linked peer (see
                // `AppState`'s `markCallLinkedPeer` call at its two
                // call-start sites) always gets its phone/extension
                // enrichment attempted for every real call, independent of
                // which tier resolved the display name. Cheap to call
                // redundantly — internally deduped + cooldown-gated.
                NameResolutionService.shared.ensureResolved(userId: cid)
            }
            .store(in: &cancellables)

        // Re-resolve when NameResolutionService's async enrichment (device-
        // contact match, or the profile fetch kicked off above) lands a
        // real name/phone/avatar into the rubrica after the fact — without
        // this, a peer resolved via the async path only updates the NEXT
        // time some other state change happens to redraw this screen.
        NotificationCenter.default.publisher(for: .contactsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let cid = self.appState?.callContactId else { return }
                self.resolvePeer(for: cid)
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

    /// Canonical peer-name resolution for the active call — a single call
    /// into `DisplayName.forUser`, mirroring `LiveInCallScreen.
    /// resolvePeerDisplayName` exactly (same `incomingCallerName` seed) so
    /// the ring banner, the in-call title, and the rubrica all agree
    /// instead of drifting via independently hand-rolled copies. See the
    /// `$callContactId` sink's doc comment above for why this replaced the
    /// old ad hoc `getPublicUser` fetch.
    private func resolvePeer(for cid: String) {
        let contacts = self.contactsStore.load()
        let match = contacts.first(where: { $0.userId == cid })
        let callerName = self.appState?.incomingCallerName
        let serverDisplay = (callerName?.isEmpty == false) ? callerName : nil
        let displayName = DisplayName.forUser(cid, serverDisplay: serverDisplay, contacts: contacts)
        let fingerprint: String = {
            guard let pk = match?.pubkey else {
                return String(cid.prefix(8)) + "…" + String(cid.suffix(4))
            }
            return (try? Fingerprint.format(pubkey: pk))
                ?? String(cid.prefix(8)) + "…" + String(cid.suffix(4))
        }()
        self.update {
            $0.peer = InCallViewModel.PeerInfo(
                userId: cid,
                displayName: displayName,
                avatarUrl: match?.avatarUrl,
                fingerprint: fingerprint
            )
        }
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
