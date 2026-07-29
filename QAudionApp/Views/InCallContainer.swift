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

        // Peer info from callContactId. Resolution order (mirrors Android CallPeerNameViewModel):
        //   1. Local ContactsStore by userId (QR-paired or phone-book imported)
        //   2. Server GET /api/v1/users/{id} if not in ContactsStore
        //   3. Abbreviated userId (first 8 + last 4) as last resort
        appState.$callContactId
            .receive(on: RunLoop.main)
            .sink { [weak self] cid in
                guard let self, let cid = cid else { return }
                let stored = self.contactsStore.load().first(where: { $0.userId == cid })
                // W-EXTPREFIX consolidation (2026-07-29): this used to accept
                // ANY non-empty stored name, including a legacy placeholder
                // ("Phone #100"/"New User") — which then ALSO suppressed the
                // network refetch below (`if localName == nil`), permanently
                // freezing the bad value for the rest of the call. Gated on
                // the canonical `DisplayName.isPlaceholderName` instead.
                let localName: String? = (stored?.displayName).flatMap {
                    (!$0.isEmpty && !DisplayName.isPlaceholderName($0)) ? $0 : nil
                }
                let avatarUrl = stored?.avatarUrl
                let fingerprint: String = {
                    guard let pk = stored?.pubkey else {
                        return String(cid.prefix(8)) + "…" + String(cid.suffix(4))
                    }
                    return (try? Fingerprint.format(pubkey: pk))
                        ?? String(cid.prefix(8)) + "…" + String(cid.suffix(4))
                }()
                let fallbackName: String = DisplayName.shortUserFallback(cid)

                // Apply local result immediately so the UI is not blank.
                self.update {
                    $0.peer = InCallViewModel.PeerInfo(
                        userId: cid,
                        displayName: localName ?? fallbackName,
                        avatarUrl: avatarUrl,
                        fingerprint: fingerprint
                    )
                }

                // W444: if no local contact, kick off a server lookup to get
                // the peer's real display name (mirrors Android step 4).
                if localName == nil, let provider = self.appState?.liveProvider {
                    // Capture primitives before entering Task — avoids type-checker
                    // timeouts (CLAUDE.md §13) and weak-self capture complexity.
                    let capturedCid = cid
                    let capturedFallback = fallbackName
                    let capturedFingerprint = fingerprint
                    let capturedAvatar = avatarUrl
                    Task { [weak self] in
                        guard let self else { return }
                        guard let pub = try? await provider.accountApi.getPublicUser(userId: capturedCid) else { return }
                        // Pre-bind all String construction outside await/MainActor calls.
                        let rawName: String? = pub.displayName
                        // NIM-fix2b: sanitise displayName — trim whitespace, strip RTL/LTR
                        // override codepoints (U+202A–202E, U+2066–2069), cap at 100 chars.
                        // W-EXTPREFIX consolidation (2026-07-29): sanitising alone does not
                        // catch a legacy placeholder shape ("Phone #100"/"New User") an
                        // un-migrated server/peer might still send — this used to persist
                        // that verbatim into the rubrica. Same canonical check + bare-digit
                        // extension fallback as `NameResolutionService.apply`.
                        let sanitisedName = StringSanitiser.displayName(rawName, fallback: "")
                        let resolvedName: String
                        if !sanitisedName.isEmpty, !DisplayName.isPlaceholderName(sanitisedName) {
                            resolvedName = sanitisedName
                        } else if let ext = pub.extensionNumber, ext > 0 {
                            resolvedName = String(ext)
                        } else {
                            resolvedName = capturedFallback
                        }
                        // NIM-fix2c: only accept https:// avatar URLs;
                        // reject file://, data://, javascript: and other dangerous schemes.
                        let rawAvatarStr: String? = pub.avatarUrl
                        let resolvedAvatar: URL? = Self.sanitiseAvatarUrl(rawAvatarStr, fallback: capturedAvatar)
                        await MainActor.run {
                            self.update {
                                $0.peer = InCallViewModel.PeerInfo(
                                    userId: capturedCid,
                                    displayName: resolvedName,
                                    avatarUrl: resolvedAvatar,
                                    fingerprint: capturedFingerprint
                                )
                            }
                            // Persist so future calls resolve locally without a server round-trip.
                            // OR-fix4: preserve existing phoneHash — server /users/{id} doesn't
                            // return it for privacy; overwriting with "" would erase a QR-paired
                            // or phone-book-imported contact's hash.
                            //
                            // W-AUTOSAVE fix (found auditing this reconstruction for the
                            // phoneNumber/extension additions): this call site was ALSO
                            // silently dropping pubkey / verifiedFingerprintHex / verifiedAtMs
                            // / verificationMethod / presenceAuth / presenceFloor on every
                            // upsert here — any in-call name resolution for a peer that had
                            // previously been QR-paired, manually verified, or NFC-presence-
                            // confirmed would wipe all of that the first time this branch fired
                            // for them. Thread every existing field through unchanged, same as
                            // the other reconstruction sites in this repo (ContactsStore.rebuild,
                            // NameResolutionService.apply, PeerTrustEvaluator.markVerified).
                            if !resolvedName.isEmpty && resolvedName != capturedFallback {
                                let existing = self.contactsStore.load()
                                    .first(where: { $0.userId == capturedCid })
                                let contact = ContactsStore.StoredContact(
                                    userId: capturedCid,
                                    displayName: resolvedName,
                                    phoneHash: existing?.phoneHash ?? "",
                                    avatarUrl: resolvedAvatar,
                                    lastSeen: existing?.lastSeen,
                                    isVerified: existing?.isVerified ?? false,
                                    pubkey: existing?.pubkey,
                                    verifiedFingerprintHex: existing?.verifiedFingerprintHex,
                                    verifiedAtMs: existing?.verifiedAtMs,
                                    verificationMethod: existing?.verificationMethod,
                                    presenceAuth: existing?.presenceAuth,
                                    presenceFloor: existing?.presenceFloor,
                                    phoneNumber: existing?.phoneNumber,
                                    `extension`: existing?.`extension`
                                )
                                self.contactsStore.upsert(contact)
                            }
                        }
                    }
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

    // MARK: - NIM security helpers

    /// NIM-fix2c: Accept only https:// URLs for peer avatars.
    /// Rejects file://, data://, javascript: and any other scheme that
    /// could trigger unintended I/O or ImageIO parsing of attacker bytes.
    private static func sanitiseAvatarUrl(_ raw: String?, fallback: URL?) -> URL? {
        guard let raw, let url = URL(string: raw) else { return fallback }
        guard url.scheme == "https" else { return fallback }
        return url
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
