import SwiftUI
import QAudionEngine

/// Entitlements Task 4 (2026-08-17) — the ENTIRE Pro-unlock UX on iOS
/// (design doc §7.5/§14.2, hard constraint): an invite-code-only redeem
/// sheet. **No price shown anywhere. No purchase flow. No StoreKit.** This
/// app ships through internal TestFlight today, where App Store guideline
/// 3.1.1 does not yet apply, but building a purchase-flow-shaped UI now
/// would need tearing out the moment external distribution starts — so the
/// neutral version is built now, once, rather than under deadline pressure
/// later.
///
/// Presentation: designed to be shown via `.sheet(isPresented:)` — this
/// app's real convention for a short, self-contained form (confirmed by
/// investigation: `GroupInviteSheet.swift`/`AttachmentSendOptionsSheet`
/// inside `GroupCallChatPanel.swift`, both `.sheet`, both self-applying
/// `.presentationDetents` on their own root view rather than requiring the
/// presenting call site to remember to configure sizing). Task 5 (real
/// locked UI call sites, not built here) is expected to present this with
/// `.sheet(isPresented: $showUpgradeSheet) { UpgradeSheet(capability:
/// capability) }` with no extra configuration needed — matching the
/// `GatedAction` sketch in the design doc.
///
/// Container/View split follows this app's real existing convention for a
/// simple form (`MyPhonesScreen.swift`'s `MyPhonesContainer`/
/// `MyPhonesScreen` pair — flat `@Published` properties on a plain
/// `ObservableObject`, NOT Android's `data class State` + Hilt-injected
/// ViewModel shape, since this app has no DI container, confirmed during
/// Task 3's own investigation). `UpgradeSheetContainer` takes no
/// dependencies at construction time (SwiftUI `@StateObject` can't see
/// `@EnvironmentObject` at init time) — `redeem(api:capabilityGate:)`
/// receives its dependencies as call-time parameters instead, the same
/// shape `MyPhonesContainer.beginAddPhone(serverUrl:token:)` already
/// establishes.
@MainActor
final class UpgradeSheetContainer: ObservableObject {
    @Published var codeInput: String = ""
    @Published private(set) var submitting: Bool = false
    @Published var error: String?
    @Published private(set) var success: Bool = false
    /// True when the server reports this exact code was already redeemed
    /// by this same account (idempotent replay, design doc §5.3) — lets
    /// the UI say "già attivo" instead of "attivato!".
    @Published private(set) var alreadyRedeemed: Bool = false

    func onCodeChanged(_ value: String) {
        codeInput = value
        error = nil
    }

    /// Validates the pasted code's checksum LOCALLY first, via
    /// `verifyActivationCodeChecksum` (cheap, instant, offline — design
    /// doc §5.1's client-side pre-check), before ever calling
    /// `api.redeemActivationCode`. Only a checksum-valid code reaches the
    /// network — a mistyped or garbled code never spends a network
    /// round-trip (or this account's server-side failed-attempt budget,
    /// `bfActivationRedeemFailure` in `entitlements_redemption.go`) to
    /// find that out. Same two-stage shape as Android's
    /// `UpgradeSheetViewModel.redeem`.
    ///
    /// On success, adopts the inline EGT the redemption response already
    /// carries via `capabilityGate.adopt(_:)` — **never**
    /// `capabilityGate.refresh()`. This is the load-bearing correctness
    /// point of this whole file (see `CapabilityGate.adopt(_:)`'s own doc
    /// and Android's Task 5 review, whole-phase-review fix I-1): the
    /// server mints the fresh token INLINE specifically to avoid a
    /// round-trip, and on the idempotent-replay path
    /// (`response.alreadyRedeemed == true`) the server deliberately does
    /// NOT fire the `entitlements_changed` doorbell — so discarding this
    /// inline token in favor of a follow-up `refresh()` would be a second
    /// network call that can fail silently, and on replay it would be the
    /// ONLY way to ever deliver the grant, with no guarantee it fires at
    /// all. `adopt()` can legitimately reject the token it was just
    /// handed (e.g. a stale pinned entitlement pubkey on this build) —
    /// that should be rare, but falling back to `refresh()` as a SECOND
    /// attempt only in that case is cheap insurance against ending this
    /// method with `success = true` while the capability is still locked,
    /// matching Android's exact fallback shape.
    func redeem(api: EntitlementsApiClient, capabilityGate: CapabilityGate) async {
        let trimmed = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard verifyActivationCodeChecksum(trimmed) else {
            // Fails fast, entirely offline — no api/capabilityGate call of
            // any kind happens on this branch.
            error = "Codice non valido — controlla di averlo copiato per intero."
            return
        }
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            let response = try await api.redeemActivationCode(trimmed)
            if !capabilityGate.adopt(response.token) {
                RTLog.warn("entitlements", "UpgradeSheet: inline EGT from redeem response rejected locally, falling back to refresh()")
                await capabilityGate.refresh()
            }
            success = true
            alreadyRedeemed = response.alreadyRedeemed
        } catch {
            self.error = Self.redemptionErrorMessage(error)
        }
    }

    /// Maps a failed `api.redeemActivationCode` call to a real, localized,
    /// user-facing message, routed by HTTP status the same way Android's
    /// `redemptionErrorMessage` routes (`handleEntitlementsRedeem`'s real
    /// status codes: 400 invalid/unknown/revoked/expired/bind-mismatch
    /// code, 401/403 session no longer valid, 409 conflict — exhausted /
    /// already redeemed by a different account / grant revoked, 429
    /// rate-limited, 503 activation codes or entitlement signing disabled
    /// server-side).
    ///
    /// KNOWN GAP vs Android, not silently papered over: Android further
    /// distinguishes the THREE 409 conflict reasons by parsing
    /// `HttpException.response()?.errorBody()`'s `{"error": "..."}` JSON.
    /// `BCryptoRestClient.request()` (this app's shared REST client, used
    /// by every endpoint) discards the response BODY on any non-2xx
    /// status — it throws `BCryptoError.httpError(status)` with the
    /// status code only, never the body — so that per-reason distinction
    /// is not reachable from here without changing `BCryptoRestClient`'s
    /// error contract app-wide, which is out of scope for this file. 409
    /// therefore routes to one generic conflict message on iOS today.
    private static func redemptionErrorMessage(_ error: Error) -> String {
        guard let bcError = error as? BCryptoError else {
            return "Errore di rete — verifica la connessione e riprova."
        }
        switch bcError {
        case .httpError(let status):
            switch status {
            case 400: return "Codice non valido."
            case 401, 403: return "Sessione non attiva — accedi di nuovo."
            case 409: return "Codice già utilizzato o non disponibile."
            case 429: return "Troppi tentativi — riprova più tardi."
            case 500...599: return "Errore del server — riprova più tardi."
            default: return "Errore imprevisto."
            }
        case .unauthorized:
            return "Sessione non attiva — accedi di nuovo."
        default:
            return "Errore imprevisto."
        }
    }
}

/// The redeem sheet itself. `capability` names WHICH locked feature the
/// user tapped through — used only for the benefit-framed description
/// text, never as a client-side unlock decision (the server, not this
/// enum case, decides what the redeemed code actually grants).
struct UpgradeSheet: View {
    let capability: Capability

    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionSnackbar) private var snackbar
    @Environment(\.dismiss) private var dismiss
    @StateObject private var container = UpgradeSheetContainer()

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(scheme.outline.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 16) {
                header
                Divider().background(scheme.outline.opacity(0.3))
                Text(capability.upgradeSheetBenefitDescription)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                codeField
                if let error = container.error {
                    Text(error)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(extras.riskHigh)
                }
                if container.success {
                    Text(container.alreadyRedeemed ? "Codice già attivo su questo account." : "Attivato — la funzione è ora disponibile.")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.primary)
                }
                submitButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(scheme.surface.ignoresSafeArea())
        .presentationDetents([.medium])
        .onChange(of: container.success) { success in
            guard success else { return }
            snackbar?.show(.init(
                text: container.alreadyRedeemed ? "Codice già attivo su questo account." : "Funzione attivata.",
                severity: .info))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20))
                .foregroundStyle(scheme.primary)
                .frame(width: 36, height: 36)
                .background(scheme.primary.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Funzione Pro")
                    .qaudionStyle(type.titleSmall)
                    .foregroundStyle(scheme.onSurface)
                Text("Inserisci un codice di attivazione per sbloccarla")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Spacer()
        }
    }

    private var codeField: some View {
        TextField(
            "QA1-XXXXX-XXXXX-XXXXX-CC",
            text: Binding(
                get: { container.codeInput },
                set: { container.onCodeChanged(String($0.prefix(24))) }
            )
        )
        .font(.system(size: 15, design: .monospaced))
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .disabled(container.submitting || container.success)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((container.error != nil ? extras.riskHigh : scheme.outline).opacity(0.4), lineWidth: 1)
        )
    }

    private var submitButton: some View {
        Button {
            Task {
                await container.redeem(api: makeApi(), capabilityGate: appState.capabilityGate)
            }
        } label: {
            Text(container.submitting ? "Attivazione…" : (container.success ? "Attivato" : "Attiva"))
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(container.submitting || container.success ? scheme.surfaceVariant : scheme.primary)
                )
        }
        .disabled(container.submitting || container.success || container.codeInput.isEmpty)
    }

    /// Builds a fresh `EntitlementsApiClient` wired to the live
    /// `BCryptoRestClient` the same way `AppState.capabilityGate`'s own
    /// lazy initializer does (`api.getRestClient = { appState.liveProvider
    /// ?.getRestClient() }`) — reading `liveProvider` via a closure at CALL
    /// time, not caching a reference, for the same reason that file's own
    /// doc gives: it can be nil (not yet connected) or get replaced
    /// (reconnect) over the object's lifetime. Built fresh per redeem
    /// attempt rather than stored on `AppState`, matching
    /// `MyPhonesContainer.restClient(serverUrl:token:)`'s existing
    /// per-call construction pattern — this is a cheap wrapper class, not
    /// a connection, so there is nothing to pool.
    private func makeApi() -> EntitlementsApiClient {
        let api = BCryptoEntitlementsApiClient()
        api.getRestClient = { [weak appState] in appState?.liveProvider?.getRestClient() }
        return api
    }
}

/// Maps each `Capability` to a short, benefit-framed description — "what
/// do I get", not the raw feature key. This app has no `Localizable
/// .strings`/`NSLocalizedString` mechanism anywhere (confirmed by
/// investigation: every other screen, e.g. `MyPhonesScreen.swift`, hard-
/// codes Italian copy directly in Swift source), so this follows that same
/// established convention rather than introducing a new one. One entry per
/// `Capability` case is enforced by the exhaustive `switch` below (no
/// `default` branch) — adding a new `Capability` without adding its
/// benefit string here is a compile error, not a silently blank sheet,
/// mirroring Android's `capabilityDescriptionRes`'s own exhaustiveness
/// rationale.
extension Capability {
    var upgradeSheetBenefitDescription: String {
        switch self {
        case .callsVideo: return "Sblocca le videochiamate 1:1."
        case .callsGroup: return "Sblocca le chiamate di gruppo."
        case .callsGroupVideo: return "Sblocca il video nelle chiamate di gruppo."
        case .files: return "Sblocca l'invio di file e allegati."
        case .vpn: return "Sblocca l'accesso alla VPN integrata."
        case .kms: return "Sblocca la gestione avanzata delle chiavi (KMS)."
        case .psk: return "Sblocca le chiavi pre-condivise (PSK) per le chiamate."
        case .keyManagement: return "Sblocca la gestione avanzata dell'identità e delle chiavi."
        case .nfc: return "Sblocca lo scambio di chiavi via NFC."
        case .meshBle: return "Sblocca la messaggistica mesh via Bluetooth."
        case .voiceBiometrics: return "Sblocca l'autenticazione biometrica vocale."
        case .backup: return "Sblocca il backup cifrato dei dati."
        }
    }
}
