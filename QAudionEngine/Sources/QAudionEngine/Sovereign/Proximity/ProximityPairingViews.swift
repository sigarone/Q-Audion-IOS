#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import Combine
import UIKit

// Proximity pairing v1 — SwiftUI screens (spec §9 human step). Plain SwiftUI
// on purpose, like NfcExchangeView: this module cannot see the app's design
// tokens. All protocol and persistence work lives in ProximityPairingViewDriver
// (ProximityPairingDriver.swift); these views only render its `phase`.
//
// Screen capture (recording, mirroring, sharing), screenshots and the app
// going to the background are handled here (spec §6): the displayer stops
// showing the code while the screen is captured, replaces the session after
// a screenshot, and never keeps a pairing running in the background. The host
// may still add `ScreenshotLockService` on top.

/// The phone that SHOWS the rotating QR code and waits for the other phone to
/// connect over Bluetooth. Starts on appear, cancels on disappear. After a
/// retryable failure a fresh code appears automatically after 3 s.
public struct ProximityPairingDisplayerView: View {
    @StateObject private var driver: ProximityPairingViewDriver

    /// - Parameters:
    ///   - localUserId: this account's server user id (non-empty).
    ///   - displayName: resolves a peer userId to the name shown next to the SAS.
    ///   - serverIdentityKeys: the Ed25519 identity keys a userId's account
    ///     published on the server (empty when unknown/offline). When given,
    ///     the confirmation screen says whether the peer's phone proved one of
    ///     them, and "Coincide" waits up to 5 s for the answer.
    ///   - onCompleted: fired once, only after both users confirmed AND the key
    ///     was stored in the vault.
    ///   - onTelemetryEvent: privacy-safe lifecycle events (started/failed/
    ///     cancelled) for the host's telemetry pipeline — no ids, keys, SAS
    ///     digits or names, ever (see `ProximityPairingTelemetryEvent`).
    public init(localUserId: String,
                displayName: @escaping (String) -> String,
                serverIdentityKeys: ((String) async -> Set<Data>)? = nil,
                onCompleted: @escaping (ProximityPairingSummary) -> Void,
                onTelemetryEvent: ((ProximityPairingTelemetryEvent) -> Void)? = nil) {
        _driver = StateObject(wrappedValue: ProximityPairingViewDriver(localUserId: localUserId,
                                                                       scanPayload: nil,
                                                                       displayName: displayName,
                                                                       onCompleted: onCompleted,
                                                                       onRescan: nil,
                                                                       serverIdentityKeys: serverIdentityKeys,
                                                                       onTelemetryEvent: onTelemetryEvent))
    }

    public var body: some View {
        ProximityPairingPanel(driver: driver)
            .onAppear {
                driver.screenCaptureChanged(ProximityPairingViewDriver.isScreenCaptured())
                driver.start()
            }
            .onDisappear { driver.stop() }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                driver.screenCaptureChanged(ProximityPairingViewDriver.isScreenCaptured())
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                driver.screenshotTaken()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                driver.appDidEnterBackground()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                driver.appWillEnterForeground()
            }
    }
}

/// The phone that SCANNED a `qaudion://pair/` code: connects to the displayer
/// over Bluetooth on appear (no OS pairing dialog, no device list), cancels on
/// disappear. A scanned code is single-use; after a failure `onRescan` sends
/// the user back to the camera.
public struct ProximityPairingScannerView: View {
    @StateObject private var driver: ProximityPairingViewDriver

    public init(payload: ProximityQrPayload,
                localUserId: String,
                displayName: @escaping (String) -> String,
                serverIdentityKeys: ((String) async -> Set<Data>)? = nil,
                onCompleted: @escaping (ProximityPairingSummary) -> Void,
                onRescan: @escaping () -> Void,
                onTelemetryEvent: ((ProximityPairingTelemetryEvent) -> Void)? = nil) {
        _driver = StateObject(wrappedValue: ProximityPairingViewDriver(localUserId: localUserId,
                                                                       scanPayload: payload,
                                                                       displayName: displayName,
                                                                       onCompleted: onCompleted,
                                                                       onRescan: onRescan,
                                                                       serverIdentityKeys: serverIdentityKeys,
                                                                       onTelemetryEvent: onTelemetryEvent))
    }

    public var body: some View {
        ProximityPairingPanel(driver: driver)
            .onAppear { driver.start() }
            .onDisappear { driver.stop() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                driver.appDidEnterBackground()
            }
    }
}

// MARK: - Copy

private enum ProximityPairingCopy {
    static var displayerCaption: String {
        String(localized: "pairing.panel.displayer_caption", defaultValue: "Fai inquadrare questo codice dall'altro telefono: Contatti → Associa di persona → Scansiona un codice.", comment: "In-person pairing, under the QR code: the other person scans it with their phone; the arrows describe the menu path in the app")
    }
    static var preparingCode: String {
        String(localized: "pairing.panel.preparing_code", defaultValue: "Preparazione del codice…", comment: "In-person pairing: the QR code is being prepared")
    }
    static var preparing: String {
        String(localized: "pairing.panel.preparing", defaultValue: "Preparazione…", comment: "In-person pairing on the scanning phone: preparing the connection")
    }
    static var confirmHint: String {
        String(localized: "pairing.panel.confirm_hint", defaultValue: "Controlla che l'altro telefono mostri lo stesso codice, poi conferma.", comment: "In-person pairing: ask the user to check that the other phone shows the same 6-digit code, then confirm")
    }
    static var confirmTitle: String {
        String(localized: "pairing.panel.confirm", defaultValue: "Coincide, conferma", comment: "In-person pairing button: the two codes match, confirm")
    }
    static var rejectTitle: String {
        String(localized: "pairing.panel.reject", defaultValue: "Non coincide", comment: "In-person pairing button: the two codes do not match")
    }
    static var waitingForPeer: String {
        String(localized: "pairing.panel.waiting_for_peer", defaultValue: "In attesa della conferma sull'altro telefono…", comment: "In-person pairing: waiting for the other person to confirm on their phone")
    }
    static var newCode: String {
        String(localized: "pairing.panel.new_code", defaultValue: "Nuovo codice", comment: "In-person pairing button after a failure on the phone showing the code: show a new QR code")
    }
    static var scanAgain: String {
        String(localized: "pairing.panel.scan_again", defaultValue: "Scansiona di nuovo", comment: "In-person pairing button after a failure on the scanning phone: scan the code again")
    }
    static var qrAccessibility: String {
        String(localized: "pairing.panel.qr_a11y", defaultValue: "Codice QR di associazione", comment: "VoiceOver label of the pairing QR code image")
    }
    static var serverChecking: String {
        String(localized: "pairing.panel.server_checking", defaultValue: "Verifica dell'account sul server…", comment: "In-person pairing: checking on the server that the account really published this phone's key")
    }
    static var serverConfirmed: String {
        String(localized: "pairing.panel.server_confirmed", defaultValue: "Account verificato: la chiave di questo telefono è quella pubblicata dall'account.", comment: "In-person pairing: the server confirmed that the key of the other phone is the one published by the account")
    }
    static var serverUnknown: String {
        String(localized: "pairing.panel.server_unknown", defaultValue: "Impossibile verificare l'account sul server: controlla bene chi hai davanti.", comment: "In-person pairing: the account could not be checked on the server, so the user must be careful about who is in front of them")
    }
    static var serverMismatch: String {
        String(localized: "pairing.panel.server_mismatch", defaultValue: "Attenzione: questo account ha pubblicato sul server chiavi diverse da quella di questo telefono. La persona davanti a te potrebbe non essere il titolare dell'account: conferma solo se ne sei certo.", comment: "In-person pairing warning: the account published different keys on the server than the one of the phone in front of the user; confirm only if completely sure")
    }
}

// MARK: - Shared panel

private struct ProximityPairingPanel: View {
    @ObservedObject var driver: ProximityPairingViewDriver

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                phaseContent
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch driver.phase {
        case .preparing:
            progressBlock(preparingText)
        case .showingCode:
            codeBlock
        case .working(let text):
            progressBlock(text)
        case .confirming(let info):
            confirmationBlock(info)
        case .completed(let text):
            completedBlock(text)
        case .failed(let text):
            failedBlock(text)
        }
    }

    // MARK: Precomputed strings

    private var preparingText: String {
        if driver.isDisplayer { return ProximityPairingCopy.preparingCode }
        return ProximityPairingCopy.preparing
    }

    private var retryTitle: String {
        if driver.isDisplayer { return ProximityPairingCopy.newCode }
        return ProximityPairingCopy.scanAgain
    }

    private var retryIcon: String {
        if driver.isDisplayer { return "arrow.clockwise" }
        return "qrcode.viewfinder"
    }

    // MARK: Blocks

    private func progressBlock(_ text: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 40)
    }

    private var codeBlock: some View {
        VStack(spacing: 20) {
            qrCodeView
            Text(ProximityPairingCopy.displayerCaption)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Black-on-white with a white margin in every appearance, so the quiet
    /// zone survives dark mode.
    @ViewBuilder
    private var qrCodeView: some View {
        if let image = driver.qrImage {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 280)
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(ProximityPairingCopy.qrAccessibility)
        } else {
            ProgressView()
                .frame(width: 280, height: 280)
        }
    }

    private func confirmationBlock(_ info: ProximityPairingViewDriver.Confirmation) -> some View {
        VStack(spacing: 18) {
            if let warning = info.warning {
                warningBox(warning)
            }
            if info.serverCheck == .mismatch {
                warningBox(ProximityPairingCopy.serverMismatch)
            }
            Text(info.peerName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(ProximityPairingCopy.confirmHint)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(info.groupedSas)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.vertical, 8)
            serverCheckLine(info.serverCheck)
            confirmationActions(info.localConfirmed, checking: info.serverCheck == .checking)
        }
    }

    @ViewBuilder
    private func serverCheckLine(_ check: ProximityPairingViewDriver.ServerCheck) -> some View {
        switch check {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text(ProximityPairingCopy.serverChecking)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .confirmed:
            Label(ProximityPairingCopy.serverConfirmed, systemImage: "checkmark.seal.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            Label(ProximityPairingCopy.serverUnknown, systemImage: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .notAvailable, .mismatch:
            EmptyView()
        }
    }

    @ViewBuilder
    private func confirmationActions(_ localConfirmed: Bool, checking: Bool) -> some View {
        if localConfirmed {
            HStack(spacing: 10) {
                ProgressView()
                Text(ProximityPairingCopy.waitingForPeer)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: 12) {
                Button(action: driver.confirm) {
                    Label(ProximityPairingCopy.confirmTitle, systemImage: "checkmark")
                        .font(.title3.weight(.semibold))
                        .padding()
                        .frame(maxWidth: 280)
                        .background(checking ? Color.gray : Color.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .disabled(checking)
                Button(action: driver.reject) {
                    Label(ProximityPairingCopy.rejectTitle, systemImage: "xmark")
                        .font(.title3.weight(.semibold))
                        .padding()
                        .frame(maxWidth: 280)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func warningBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red, lineWidth: 1.5))
    }

    private func completedBlock(_ text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text(text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 40)
    }

    private func failedBlock(_ text: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text(text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: driver.retry) {
                Label(retryTitle, systemImage: retryIcon)
                    .font(.title3)
                    .padding()
                    .frame(maxWidth: 260)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.top, 40)
    }
}
#endif
