import SwiftUI
import UIKit
import CoreLocation
import CoreLocationUI
import QAudionEngine

/// "Condividi posizione" (docs/LOCATION_SHARING.md 1.5): send the current position as a message, or share it live for a chosen time.
///
///  1. "Invia la posizione attuale": the system `LocationButton`, which grants a one-time authorisation without a prior permission prompt,
///     with the live accuracy under it ("Precisione ±12 m"). When only approximate location is granted the sheet says so and offers the
///     one-off request of the exact position; there is no manual "approximate" option.
///  2. "Condividi la posizione in tempo reale", with the durations of `DU_PRESETS`: 15 minutes, 1 hour, 8 hours, 24 hours. Offered in a
///     1:1 chat only. Before the first live share ever, a short explainer.
///
/// Nothing is sent, and nothing is asked of the system, until the user taps. The sheet is reached only while location sharing is
/// enabled (the entry point is hidden otherwise).
struct LocationShareSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.dismiss) private var dismiss

    /// Where the position goes: the name of the contact (or of the group), for the explainer.
    let peerName: String
    /// A live share is offered in a 1:1 chat only.
    let allowsLive: Bool
    /// The duration to point out (asked for through Siri or Shortcuts); the user still taps it, or another one, to confirm.
    var suggestedLiveSeconds: Int64? = nil
    /// Sends the position as a pin; `nil` on success, otherwise the sentence that says why not.
    let onSendPin: (LocationReading) -> String?
    /// Starts a live share of this many seconds; `nil` on success, otherwise the sentence that says why not.
    let onStartLive: (LocationReading, Int64) -> String?

    private static let explainerSeenKey: String = "qaudion.location.live_explainer_seen"

    @State private var working: Bool = false
    @State private var notice: String? = nil
    @State private var showSettingsButton: Bool = false
    @State private var currentAccuracy: Int? = nil
    @State private var reducedAccuracy: Bool = false
    @State private var showExplainer: Bool = false
    @State private var pendingDuration: Int64 = 0
    /// The explainer precedes the system location request (permission not decided yet): it has the one Continue button and
    /// leads to the request. When the permission is already decided it confirms the share and keeps a cancel button.
    @State private var explainerIsPriming: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sendCurrentSection
                    if allowsLive {
                        liveSection
                    } else {
                        Text(verbatim: LocationCardStrings.sheetGroupPinOnly)
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }
                    if working {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(verbatim: LocationCardStrings.gettingFix)
                                .qaudionStyle(type.bodySmall)
                                .foregroundStyle(scheme.onSurfaceVariant)
                        }
                    }
                    if let notice {
                        noticeView(notice)
                    }
                }
                .padding(16)
            }
            .background(scheme.background)
            .navigationTitle(Text(verbatim: LocationCardStrings.sheetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocationCardStrings.cancel) { dismiss() }
                }
            }
        }
        .alert(Text(verbatim: LocationCardStrings.sheetShareLive), isPresented: $showExplainer) {
            Button(LocationCardStrings.explainerContinue) { explainerConfirmed() }
            if !explainerIsPriming {
                Button(LocationCardStrings.cancel, role: .cancel) { pendingDuration = 0 }
            }
        } message: {
            Text(verbatim: LocationCardStrings.explainer(name: peerName))
        }
        .task { await refreshAccuracy() }
    }

    // MARK: Sections

    private var sendCurrentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: LocationCardStrings.sheetSendCurrent)
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            LocationButton(.sendCurrentLocation) {
                sendCurrentTapped()
            }
            .symbolVariant(.fill)
            .foregroundColor(.white)
            .cornerRadius(22)
            .frame(maxWidth: 320, minHeight: 44)
            .disabled(working)
            if reducedAccuracy {
                Text(verbatim: LocationCardStrings.sheetApproximate)
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                Button(LocationCardStrings.sheetFullAccuracy) {
                    LocationService.shared.requestTemporaryFullAccuracy()
                }
                .qaudionStyle(type.labelMedium)
            } else if let accuracy = currentAccuracy {
                Text(verbatim: LocationCardStrings.sheetAccuracy(metres: accuracy))
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: LocationCardStrings.sheetShareLive)
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
            VStack(spacing: 8) {
                presetButton(LocationCardStrings.sheetPreset15m, seconds: 900)
                presetButton(LocationCardStrings.sheetPreset1h, seconds: 3_600)
                presetButton(LocationCardStrings.sheetPreset8h, seconds: 28_800)
                presetButton(LocationCardStrings.sheetPreset24h, seconds: 86_400)
            }
        }
    }

    private func presetButton(_ title: String, seconds: Int64) -> some View {
        Button(action: { presetTapped(seconds) }) {
            HStack {
                Image(systemName: "location.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(verbatim: title)
                    .qaudionStyle(type.bodyMedium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(scheme.onSurface)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(scheme.surfaceVariant.opacity(0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(scheme.primary, lineWidth: suggestedLiveSeconds == seconds ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private func noticeView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: text)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.error)
            if showSettingsButton {
                Button(LocationCardStrings.openSettings) { openSystemSettings() }
                    .qaudionStyle(type.labelMedium)
            }
        }
    }

    // MARK: Actions

    private func sendCurrentTapped() {
        guard !working else { return }
        notice = nil
        showSettingsButton = false
        working = true
        Task { await sendPin() }
    }

    private func presetTapped(_ seconds: Int64) {
        guard !working else { return }
        notice = nil
        showSettingsButton = false
        pendingDuration = seconds
        let seen: Bool = UserDefaults.standard.bool(forKey: Self.explainerSeenKey)
        if seen {
            working = true
            Task { await startLive(duration: seconds) }
        } else {
            explainerIsPriming = LocationService.shared.isNotDetermined
            showExplainer = true
        }
    }

    private func explainerConfirmed() {
        if explainerIsPriming {
            // Continue leads to the system request only; nothing is shared until the user picks a duration again.
            pendingDuration = 0
            working = true
            Task { await askForPermissionOnly() }
            return
        }
        UserDefaults.standard.set(true, forKey: Self.explainerSeenKey)
        working = true
        let seconds: Int64 = pendingDuration
        Task { await startLive(duration: seconds) }
    }

    @MainActor
    private func askForPermissionOnly() async {
        await awaitPermissionDecision()
        let service = LocationService.shared
        LocationTelemetry.permission(state: service.authorizationLabel)
        if !service.isAuthorized {
            notice = LocationCardStrings.permissionDenied
            showSettingsButton = true
        }
        working = false
    }

    @MainActor
    private func awaitPermissionDecision() async {
        let service = LocationService.shared
        guard service.isNotDetermined else { return }
        service.requestWhenInUse()
        var waited: Int = 0
        while service.isNotDetermined && waited < 240 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    @MainActor
    private func refreshAccuracy() async {
        let service = LocationService.shared
        guard service.isAuthorized else { return }
        reducedAccuracy = service.isReducedAccuracy
        let result = await service.requestOneShot(timeout: 8)
        if case .success(let reading) = result {
            let metres: Int = Int(reading.horizontalAccuracy.rounded(.up))
            currentAccuracy = max(1, metres)
            reducedAccuracy = reading.reducedAccuracy
        }
    }

    // MARK: Flows

    /// A fix for a send: asks for the permission first when it was never asked, then for one position.
    @MainActor
    private func obtainReading() async -> LocationReading? {
        let service = LocationService.shared
        await awaitPermissionDecision()
        LocationTelemetry.permission(state: service.authorizationLabel)
        if !service.isAuthorized {
            notice = LocationCardStrings.permissionDenied
            showSettingsButton = true
            working = false
            return nil
        }
        switch await service.requestOneShot(timeout: 15) {
        case .success(let reading):
            return reading
        case .failure(let failure):
            switch failure {
            case .denied:
                notice = LocationCardStrings.permissionDenied
                showSettingsButton = true
            case .unavailable, .timeout:
                notice = LocationCardStrings.fixUnavailable
            }
            working = false
            return nil
        }
    }

    @MainActor
    private func sendPin() async {
        guard let reading = await obtainReading() else { return }
        let failure: String? = onSendPin(reading)
        finish(failure)
    }

    @MainActor
    private func startLive(duration: Int64) async {
        guard let reading = await obtainReading() else { return }
        let failure: String? = onStartLive(reading, duration)
        finish(failure)
    }

    @MainActor
    private func finish(_ failure: String?) {
        working = false
        if let failure {
            notice = failure
        } else {
            dismiss()
        }
    }
}
