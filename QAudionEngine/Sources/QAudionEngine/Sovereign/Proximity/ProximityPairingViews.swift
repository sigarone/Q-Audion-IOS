#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import UIKit

// Proximity pairing v1 — SwiftUI screens (spec §9 human step). Plain SwiftUI
// on purpose, like NfcExchangeView: this module cannot see the app's design
// tokens. All protocol and persistence work lives in ProximityPairingViewDriver
// (ProximityPairingDriver.swift); these views only render its `phase`.
//
// The host is responsible for screenshot / recording protection of the
// displayer screen (spec §6, `ScreenshotLockService`), since that service
// lives in the app target.

/// The phone that SHOWS the rotating QR code and waits for the other phone to
/// connect over Bluetooth. Starts on appear, cancels on disappear. After a
/// retryable failure a fresh code appears automatically after 3 s.
public struct ProximityPairingDisplayerView: View {
    @StateObject private var driver: ProximityPairingViewDriver

    /// - Parameters:
    ///   - localUserId: this account's server user id (non-empty).
    ///   - displayName: resolves a peer userId to the name shown next to the SAS.
    ///   - onCompleted: fired once, only after both users confirmed AND the key
    ///     was stored in the vault.
    public init(localUserId: String,
                displayName: @escaping (String) -> String,
                onCompleted: @escaping (ProximityPairingResult) -> Void) {
        _driver = StateObject(wrappedValue: ProximityPairingViewDriver(localUserId: localUserId,
                                                                       scanPayload: nil,
                                                                       displayName: displayName,
                                                                       onCompleted: onCompleted,
                                                                       onRescan: nil))
    }

    public var body: some View {
        ProximityPairingPanel(driver: driver)
            .onAppear { driver.start() }
            .onDisappear { driver.stop() }
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
                onCompleted: @escaping (ProximityPairingResult) -> Void,
                onRescan: @escaping () -> Void) {
        _driver = StateObject(wrappedValue: ProximityPairingViewDriver(localUserId: localUserId,
                                                                       scanPayload: payload,
                                                                       displayName: displayName,
                                                                       onCompleted: onCompleted,
                                                                       onRescan: onRescan))
    }

    public var body: some View {
        ProximityPairingPanel(driver: driver)
            .onAppear { driver.start() }
            .onDisappear { driver.stop() }
    }
}

// MARK: - Copy

private enum ProximityPairingCopy {
    static let displayerCaption: String =
        "Fai inquadrare questo codice dall'altro telefono con Q-Audion (Contatti → + → Scansiona QR). "
        + "Tieni i telefoni vicini: il Bluetooth li collega da solo."
    static let preparingCode: String = "Preparazione del codice…"
    static let preparing: String = "Preparazione…"
    static let confirmHint: String = "Controlla che l'altro telefono mostri lo stesso codice, poi conferma."
    static let confirmTitle: String = "Coincide, conferma"
    static let rejectTitle: String = "Non coincide"
    static let waitingForPeer: String = "In attesa della conferma sull'altro telefono…"
    static let newCode: String = "Nuovo codice"
    static let scanAgain: String = "Scansiona di nuovo"
    static let qrAccessibility: String = "Codice QR di associazione"
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
            confirmationActions(info.localConfirmed)
        }
    }

    @ViewBuilder
    private func confirmationActions(_ localConfirmed: Bool) -> some View {
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
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
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
