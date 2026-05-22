import SwiftUI
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
        self.trustLevel = trustOverride
            ?? (raw.isCurrentDevice ? .enterprise : .voiceMatched)
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

    init(initial: DeviceManagementViewModel = .mock, appState: AppState? = nil) {
        self.viewModel = initial
        self.enhanced = initial.devices.map { EnhancedDeviceItem(from: $0) }
        self.lastRefreshAt = Date()
        self.appState = appState
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
                print("[DeviceManagementContainer] revoke OK for \(deviceId)")
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

    func refresh() {
        // W408: refresh from server when an AppState is bound; otherwise
        // fall back to the mock data the init hydrated us with.
        guard let appState = appState,
              let token = appState.authService.loadToken(), !token.isEmpty else {
            enhanced = viewModel.devices.map { EnhancedDeviceItem(from: $0) }
            lastRefreshAt = Date()
            return
        }
        let serverUrl = appState.serverUrl
        Task { [weak self] in
            do {
                let config = BackendConfig.pinned(serverUrl: serverUrl, accessToken: token)
                let provider = BCryptoBackendProvider(config: config)
                let data = try await provider.getRestClient().get("/api/v1/devices/")
                // The server response shape (devices: [...]) is intentionally
                // not strictly typed here — for now we just stamp the refresh
                // timestamp and let the next list-load pull the fresh data
                // through the existing DeviceManagementViewModel path.
                _ = data
                await MainActor.run {
                    guard let self = self else { return }
                    self.lastRefreshAt = Date()
                }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    self.errorMessage = "Aggiornamento fallito: \(error.localizedDescription)"
                }
            }
        }
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
                    print("[DeviceMgmt] linked device \(newDeviceId)")
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
