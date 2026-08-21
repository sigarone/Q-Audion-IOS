import SwiftUI
import UIKit
import QAudionEngine

/// Modello UI-only enrichito vs il `DeviceManagementViewModel.Device` engine.
/// Aggiunge `kind` (5 type granulari), `trustLevel` (4 livelli sicurezza)
/// e `platformTag` (OS version detail) finché l'engine non li espone
/// dal lato server. 1:1 mapping con Android `DeviceItemUi`.
public struct EnhancedDeviceItem: Identifiable, Equatable {
    public enum Kind: Equatable {
        case phonePrimary, phoneSecondary, desktop, tablet, watch
    }

    public enum TrustLevel: String, Equatable {
        case unverified   = "UNVERIFIED"
        case voiceMatched = "VOICE MATCHED"
        case sas          = "SAS"
        case enterprise   = "ENTERPRISE"
    }

    public let id: String                // = deviceId
    public let deviceId: String
    public let displayName: String
    public let kind: Kind
    public let isCurrentDevice: Bool
    public let trustLevel: TrustLevel
    public let lastSeenLabel: String     // "ora", "2h fa", "in chiamata", …
    public let platformTag: String       // "iOS 18.3", "Android 15 · One UI 7.0"
    public let canRevoke: Bool

    /// Mapping dall'engine `DeviceManagementViewModel.Device`.
    /// `kind` derivato da `platform`; `trustLevel` placeholder a
    /// `.voiceMatched` (fino a engine surface). `platformTag` passa il
    /// platform.rawValue capitalizzato.
    public init(from raw: DeviceManagementViewModel.Device,
                trustOverride: TrustLevel? = nil) {
        self.id = raw.deviceId
        self.deviceId = raw.deviceId
        self.displayName = raw.deviceName
        self.kind = Self.deriveKind(platform: raw.platform,
                                    deviceName: raw.deviceName)
        self.isCurrentDevice = raw.isCurrentDevice
        // 2026-08-06 fix: every non-current device used to hardcode
        // .voiceMatched regardless of whether any voice verification ever
        // happened for it — DeviceRow renders that in the same green
        // "VOICE MATCHED" badge as a real .enterprise trust level, so
        // every linked device looked like it carried a genuine security
        // attestation that was actually fabricated. .unverified is the
        // honest default until the engine surfaces a real per-device
        // trust signal (same TODO the old comment already flagged, just
        // landing on the non-misleading placeholder instead).
        self.trustLevel = trustOverride
            ?? (raw.isCurrentDevice ? .enterprise : .unverified)
        self.lastSeenLabel = Self.formatLastSeen(raw.lastSeen)
        self.platformTag = Self.platformTag(for: raw.platform,
                                            deviceName: raw.deviceName)
        self.canRevoke = raw.canRevoke
    }

    /// Init manuale per preview / mock.
    public init(deviceId: String, displayName: String, kind: Kind,
                isCurrentDevice: Bool, trustLevel: TrustLevel,
                lastSeenLabel: String, platformTag: String,
                canRevoke: Bool) {
        self.id = deviceId
        self.deviceId = deviceId
        self.displayName = displayName
        self.kind = kind
        self.isCurrentDevice = isCurrentDevice
        self.trustLevel = trustLevel
        self.lastSeenLabel = lastSeenLabel
        self.platformTag = platformTag
        self.canRevoke = canRevoke
    }

    private static func deriveKind(platform: DeviceManagementViewModel.Device.Platform,
                                   deviceName: String) -> Kind {
        let name = deviceName.lowercased()
        if name.contains("watch") { return .watch }
        if name.contains("ipad") || name.contains("tablet") { return .tablet }
        switch platform {
        case .iOS, .android: return .phonePrimary
        case .desktop:       return .desktop
        case .unknown:       return .phoneSecondary
        }
    }

    private static func platformTag(for platform: DeviceManagementViewModel.Device.Platform,
                                    deviceName: String) -> String {
        switch platform {
        case .iOS:      return "iOS"
        case .android:  return "Android"
        case .desktop:  return "macOS"
        case .unknown:  return "—"
        }
    }

    private static func formatLastSeen(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

@MainActor
final class DeviceManagementContainer: ObservableObject {
    @Published var viewModel: DeviceManagementViewModel
    @Published private(set) var enhanced: [EnhancedDeviceItem] = []
    /// W303: timestamp of last refresh — stamped at construction
    /// and after every refresh() call. Surfaces in the UI as
    /// "Aggiornato N minuti fa" so testers know the list isn't
    /// stale.
    @Published private(set) var lastRefreshAt: Date = Date()

    /// W408: optional AppState ref so revoke() can reach the live
    /// REST client (auth token + serverUrl). Pre-W408 this was nil,
    /// preserving the .mock-only init for previews/tests.
    private weak var appState: AppState?

    /// 2026-08-06 fix: the real server (`bcrypto-lite`) only registers a
    /// DELETE handler on `/api/v1/devices/` — there is no `GET`/list
    /// endpoint (confirmed against `account_lifecycle.go`/`main.go`; the
    /// old `refresh()` below silently discarded whatever it got back).
    /// `initial: DeviceManagementViewModel = .mock` used to be the
    /// unconditional default for every real caller too, since
    /// `DeviceManagementScreen.init(state:)` never passed `initial:` —
    /// every user permanently saw the developer's own hardcoded devices
    /// ("Pavel's iPhone 13", "Pixel 7", "Pavel's MacBook Pro") including a
    /// live REVOCA button wired to a DELETE call against a nonexistent
    /// device id. Android hit the identical missing-endpoint gap first
    /// (see `DeviceManagerViewModel.kt`'s own kdoc) and settled on the
    /// honest fix: show only the real current device, sourced from local
    /// auth state, until the server ships a real list endpoint. Mirrored
    /// here — `.mock` now stays reserved for SwiftUI previews only (no
    /// production call site passes it).
    init(initial: DeviceManagementViewModel? = nil, appState: AppState? = nil) {
        let resolved = initial ?? Self.currentDeviceOnly(deviceId: appState?.authService.loadDeviceId())
        self.viewModel = resolved
        self.enhanced = resolved.devices.map { EnhancedDeviceItem(from: $0) }
        self.lastRefreshAt = Date()
        self.appState = appState
    }

    /// Builds a single-device view model from real local state — the
    /// device id `AuthService` persisted at login/register, plus the
    /// actual device name/OS version. No network round-trip: mirrors
    /// Android's `buildCurrentDevice()`, which is local-only for the
    /// same reason (no server list endpoint to call).
    ///
    /// Takes `deviceId` as a plain `String?`, NOT `AppState` directly —
    /// CLAUDE.md §16: a new function taking `AppState` as a parameter
    /// type has caused a silent "Build IPA" failure before (Swift 6
    /// Sendable-inference walking AppState's ~2000-line type graph
    /// exceeds a compiler budget, and xcbeautify swallows the resulting
    /// diagnostic). Callers already have `appState` and extract the one
    /// primitive value they need before calling in.
    private static func currentDeviceOnly(deviceId: String?) -> DeviceManagementViewModel {
        let deviceId = deviceId ?? "local-device"
        let name = UIDevice.current.name.isEmpty ? "Questo dispositivo" : UIDevice.current.name
        let now = Date()
        let device = DeviceManagementViewModel.Device(
            deviceId: deviceId,
            deviceName: name,
            platform: .iOS,
            linkedAt: now,
            lastSeen: now,
            isCurrentDevice: true,
            canRevoke: false
        )
        return DeviceManagementViewModel(devices: [device])
    }

    /// W408 — real revocation: DELETE /api/v1/devices/<id> with the
    /// user's auth token. Optimistically removes from the local list
    /// on success; on failure restores the row + sets errorMessage so
    /// the snackbar surface can prompt the user to retry.
    @Published var errorMessage: String?

    func revoke(deviceId: String) {
        // Optimistic remove first so the UI updates immediately.
        let removed = enhanced.first { $0.deviceId == deviceId }
        enhanced.removeAll { $0.deviceId == deviceId }

        guard let appState = appState,
              let token = appState.authService.loadToken(), !token.isEmpty else {
            // No live auth — revert and bail out (caller likely a preview).
            if let r = removed { enhanced.append(r) }
            print("[DeviceManagementContainer] revoke skipped — no auth token")
            return
        }

        let serverUrl = appState.serverUrl
        Task { [weak self] in
            do {
                let config = BackendConfig.pinned(serverUrl: serverUrl, accessToken: token)
                let provider = BCryptoBackendProvider(config: config)
                _ = try await provider.getRestClient().delete("/api/v1/devices/\(deviceId)")
                // I8: deviceId truncated — full ids don't belong in the
                // uploadable log ring buffer (LiveLogStreamer stdout tee).
                print("[DeviceManagementContainer] revoke OK for \(deviceId.prefix(8))…")
            } catch {
                // Restore the row on failure so the user can retry.
                await MainActor.run {
                    guard let self = self else { return }
                    if let r = removed { self.enhanced.append(r) }
                    self.errorMessage = "Revoca fallita: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 2026-08-06 fix: there is no server list endpoint to call (see
    /// `init`'s comment) — the old body called `GET /api/v1/devices/`
    /// (a route the server never registers for GET) and threw away
    /// whatever came back either way, so the "AGGIORNA" button never did
    /// anything but bump a timestamp. Rebuilding from local state is
    /// honest AND actually useful: it picks up a device-name change
    /// (Settings → General → About → Name) without needing a relaunch.
    func refresh() {
        let resolved = Self.currentDeviceOnly(deviceId: appState?.authService.loadDeviceId())
        viewModel = resolved
        enhanced = resolved.devices.map { EnhancedDeviceItem(from: $0) }
        lastRefreshAt = Date()
    }
}

/// Device management sub-screen. W41.A enhanced port di Android
/// `DeviceManagerScreen.kt` — aggiunge trust badges + device kind icons +
/// header hint + CTA "COLLEGA NUOVO DISPOSITIVO" + Italian copy
/// uppercase + revoke confirm dialog.
struct DeviceManagementScreen: View {
    @StateObject var container: DeviceManagementContainer

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    @State private var showingRevokeConfirm: String? = nil  // deviceId pending
    @State private var showingLinkNew: Bool = false

    init(state: AppState) {
        self._container = StateObject(wrappedValue: DeviceManagementContainer(appState: state))
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerHint
                    linkNewButton.padding(.top, 12)

                    SettingsSectionHeader("DISPOSITIVI COLLEGATI")
                    VStack(spacing: 8) {
                        ForEach(container.enhanced) { device in
                            DeviceRow(device: device) {
                                showingRevokeConfirm = device.deviceId
                            }
                        }
                    }
                    if container.enhanced.isEmpty {
                        Text("Nessun dispositivo collegato.")
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.horizontal, 14).padding(.top, 12)
                    }

                    // W303: 'Aggiornato N minuti fa' — surfaces the
                    // last-refresh timestamp so the user knows whether
                    // the list is fresh or stale. Useful especially
                    // since the refresh is a stub today (no real
                    // server fetch); the timestamp at least makes the
                    // toolbar Refresh button visibly do something.
                    Text(Self.lastRefreshLabel(container.lastRefreshAt))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.horizontal, 14).padding(.top, 8)

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Dispositivi")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    container.refresh()
                    snackbar?.show(.init(text: "Lista aggiornata.", severity: .info,
                                         durationSeconds: 2))
                } label: {
                    Text("AGGIORNA")
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.2)
                        .foregroundStyle(scheme.primary)
                }
            }
        }
        .alert("Revocare dispositivo?",
               isPresented: revokeAlertBinding) {
            Button("Annulla", role: .cancel) { showingRevokeConfirm = nil }
            Button("Revoca", role: .destructive) {
                if let id = showingRevokeConfirm {
                    container.revoke(deviceId: id)
                    snackbar?.show(.init(
                        text: "Dispositivo revocato.",
                        severity: .info
                    ))
                }
                showingRevokeConfirm = nil
            }
        } message: {
            Text("Una volta revocato, il dispositivo non potrà accedere all'account. Le chiavi di sessione verranno invalidate.")
        }
        .sheet(isPresented: $showingLinkNew) {
            NavigationStack {
                LinkNewDeviceScreen { newDeviceId in
                    showingLinkNew = false
                    snackbar?.show(.init(
                        text: "Dispositivo collegato.",
                        severity: .info
                    ))
                    // I8: truncate device id before it reaches the uploadable
                    // log ring buffer.
                    print("[DeviceMgmt] linked device \(newDeviceId.prefix(8))…")
                    container.refresh()
                }
            }
        }
    }

    // MARK: - Header hint

    private var headerHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DISPOSITIVI ATTIVI · \(container.enhanced.count)")
                .qaudionStyle(type.labelSmall)
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text("Ogni dispositivo linkato mantiene un keypair X25519 attestato. La revoca invalida il keypair lato server e triggera un remote wipe.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surfaceVariant.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Link new device button

    private var linkNewButton: some View {
        Button { showingLinkNew = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "qrcode")
                    .font(.system(size: 16, weight: .semibold))
                Text("COLLEGA NUOVO DISPOSITIVO")
                    .qaudionStyle(type.labelLarge)
                    .tracking(1.1)
            }
            .foregroundStyle(scheme.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.primary)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var revokeAlertBinding: Binding<Bool> {
        Binding(
            get: { showingRevokeConfirm != nil },
            set: { newValue in if !newValue { showingRevokeConfirm = nil } }
        )
    }

    /// W303: format the last-refresh timestamp as 'Aggiornato N minuti fa'
    /// using RelativeDateTimeFormatter with Italian locale. Static so
    /// the call site stays trivial — CLAUDE.md §13.
    private static func lastRefreshLabel(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.unitsStyle = .full
        let rel: String = f.localizedString(for: date, relativeTo: Date())
        return "Aggiornato " + rel
    }
}

// MARK: - Device row (enhanced)

private struct DeviceRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let device: EnhancedDeviceItem
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(scheme.surfaceVariant.opacity(0.6))
                    .frame(width: 40, height: 40)
                Image(systemName: kindIcon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(scheme.onSurface)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .qaudionStyle(type.titleSmall)
                        .foregroundStyle(scheme.onSurface)
                        .lineLimit(1)
                    if device.isCurrentDevice {
                        Text("QUESTO DISPOSITIVO")
                            .qaudionStyle(type.labelSmall)
                            .tracking(1.2)
                            .foregroundStyle(extras.success)
                    }
                }
                Text(device.platformTag)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .modifier(MonoSmall())
                HStack(spacing: 6) {
                    Text(device.trustLevel.rawValue)
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.1)
                        .foregroundStyle(trustColor)
                    Text("·")
                        .foregroundStyle(scheme.onSurfaceVariant)
                    Text(device.lastSeenLabel)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .modifier(MonoSmall())
                }
            }

            Spacer(minLength: 8)

            if device.canRevoke {
                Button(action: onRevoke) {
                    Text("REVOCA")
                        .qaudionStyle(type.labelMedium)
                        .tracking(1.0)
                        .foregroundStyle(extras.riskHigh)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(device.isCurrentDevice
                        ? extras.success.opacity(0.6)
                        : scheme.outline.opacity(0.35),
                        lineWidth: 1)
        )
    }

    private var kindIcon: String {
        switch device.kind {
        case .phonePrimary, .phoneSecondary: return "iphone"
        case .desktop:                       return "laptopcomputer"
        case .tablet:                        return "ipad"
        case .watch:                         return "applewatch"
        }
    }

    private var trustColor: Color {
        switch device.trustLevel {
        case .unverified:   return extras.warning
        case .voiceMatched: return extras.success
        case .sas:          return scheme.primary
        case .enterprise:   return extras.success
        }
    }
}

private struct MonoSmall: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(.caption, design: .monospaced))
    }
}
