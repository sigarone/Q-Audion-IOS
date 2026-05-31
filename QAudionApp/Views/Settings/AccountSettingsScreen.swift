import SwiftUI
import PhotosUI
import UIKit
import QAudionEngine

@MainActor
final class AccountSettingsContainer: ObservableObject {

    @Published private(set) var viewModel: AccountSettingsViewModel
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var draftDisplayName: String = ""
    @Published var draftStatusMessage: String = ""
    /// Local-only "public" phone number used as caller-id substitution
    /// on outbound calls. Pure digits — see `LocalCallerIdSettings`.
    /// Bound to a SwiftUI TextField; persisted to UserDefaults on save
    /// (NOT shipped to the server).
    @Published var draftLocalPhone: String = ""
    /// W445: Read-only snapshot of the phone list managed by MyPhonesScreen.
    /// Loaded from the same UserDefaults key that MyPhonesContainer writes
    /// (`com.qaudion.profile.myPhones`). Refreshed on appear so the section
    /// stays in sync after the user returns from MyPhonesScreen.
    @Published private(set) var publicPhones: [String] = []

    // OR-fix1: weak to avoid retain cycle AppState → View → Container → AppState
    // (mirrors InCallContainer which already uses weak var appState: AppState?)
    private weak var appState: AppState?
    private let avatarUploader: AvatarUploader

    init(appState: AppState) {
        self.appState = appState
        // W73: start with an EMPTY state, NOT `.mock` (which had the
        // hardcoded "4242" extension that surfaced as the user's own
        // dial number after a fast-setup login). The screen renders a
        // loading skeleton until `loadFromServer()` populates real data.
        self.viewModel = AccountSettingsViewModel(
            userId: appState.currentUserId ?? "",
            phoneHash: "",
            displayName: nil,
            statusMessage: nil,
            avatarUrl: nil,
            dialExtension: nil
        )
        self.draftDisplayName = ""
        self.draftStatusMessage = ""
        // Read the local public phone (digits-only) from UserDefaults
        // so the SwiftUI form pre-fills with the persisted value.
        self.draftLocalPhone = LocalCallerIdSettings.phoneNumber() ?? ""
        self.avatarUploader = AvatarUploader(appState: appState)
        self.publicPhones = Self.loadPublicPhones()
    }

    // MARK: - W445: Multi-phone helpers

    private static let myPhonesKey = "com.qaudion.profile.myPhones"

    private static func loadPublicPhones() -> [String] {
        UserDefaults.standard.array(forKey: myPhonesKey) as? [String] ?? []
    }

    func refreshPublicPhones() {
        publicPhones = Self.loadPublicPhones()
    }

    // MARK: - W445: Handle

    /// Derived handle: '@' + first 8 chars of userId.
    /// The server does not yet expose a dedicated handle field — this is
    /// the placeholder shown until the backend surfaces one.
    var handle: String {
        let uid = viewModel.userId
        guard uid.count >= 8 else { return uid.isEmpty ? "" : "@" + uid }
        let prefix: Substring = uid.prefix(8)
        let prefixStr: String = String(prefix)
        return "@" + prefixStr
    }

    // MARK: - W445: Icon avatar

    func setIconAvatar(_ iconName: String) {
        let url: String = "sficon://" + iconName
        UserDefaults.standard.set(url, forKey: "qaudion.profile.iconAvatar")
        viewModel = AccountSettingsViewModel(
            userId: viewModel.userId,
            phoneHash: viewModel.phoneHash,
            displayName: viewModel.displayName,
            statusMessage: viewModel.statusMessage,
            avatarUrl: URL(string: url),
            dialExtension: viewModel.dialExtension
        )
    }

    func logout() {
        guard let appState else { return }
        appState.logout()
    }

    func loadFromServer() {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            isLoading = false
            return
        }
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                let profile = try await provider.accountApi.getProfile()
                await MainActor.run {
                    // W73: take phone_hash + extension from the SERVER
                    // response, not the local placeholder. The
                    // bcrypto-server `/profile` GET handler now returns
                    // both fields (commit `feat(server): expose
                    // extension+phone_hash on /profile`). For legacy
                    // accounts where the server hasn't rolled out yet
                    // these stay nil/0 and the UI shows "—".
                    let extString: String?
                    if let ext = profile.dialExtension, ext > 0 {
                        extString = String(ext)
                    } else {
                        extString = nil
                    }
                    self.viewModel = AccountSettingsViewModel(
                        userId: profile.userId,
                        phoneHash: profile.phoneHash ?? "",
                        displayName: profile.displayName,
                        statusMessage: profile.statusMessage,
                        avatarUrl: profile.avatarUrl.flatMap(URL.init(string:)),
                        dialExtension: extString
                    )
                    self.draftDisplayName = profile.displayName ?? ""
                    self.draftStatusMessage = profile.statusMessage ?? ""
                    // W444: propagate dialExtension to AppState so SettingsScreen
                    // profileHandle and InCallContainer show the real short number.
                    self.appState?.currentUserDialExtension = extString
                    if let extString = extString {
                        UserDefaults.standard.set(extString, forKey: "currentUserDialExtension")
                    } else {
                        UserDefaults.standard.removeObject(forKey: "currentUserDialExtension")
                    }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func saveProfile() {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return
        }
        // Persist the local public phone on every save. The setter
        // strips non-digits and clears the key when the field is empty
        // so we never end up with garbage in UserDefaults.
        LocalCallerIdSettings.setPhoneNumber(draftLocalPhone)
        // Re-read so the binding shows the canonicalised digits-only form
        // (handles the case where the user typed e.g. "+39 333 …" and we
        // stripped the punctuation).
        draftLocalPhone = LocalCallerIdSettings.phoneNumber() ?? ""
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                try await provider.accountApi.updateProfile(
                    displayName: draftDisplayName.isEmpty ? nil : draftDisplayName,
                    statusMessage: draftStatusMessage.isEmpty ? nil : draftStatusMessage,
                    avatarUrl: nil
                )
                loadFromServer()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Audit P0 #2.12 — GDPR data export
    /// Pulls /api/v1/account/export and presents a system Share sheet
    /// so the user can save the JSON envelope to Files or AirDrop it
    /// to a desktop. Best-effort; errors surface as errorMessage.
    func exportMyData(presenting: UIViewController) {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return
        }
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                let data = try await provider.accountApi.accountExport()
                let ts = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .prefix(15)
                let filename = "qaudion-server-export-\(ts).json"
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(filename)
                try data.write(to: tmp)
                await MainActor.run {
                    let share = UIActivityViewController(
                        activityItems: [tmp],
                        applicationActivities: nil,
                    )
                    presenting.present(share, animated: true)
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Audit P0 #2.12 — GDPR right-to-be-forgotten
    /// Fires DELETE /api/v1/account first, then triggers local logout
    /// via AuthService regardless of server response. The user wants
    /// to be forgotten — a server 5xx must not block the local wipe.
    /// Caller wraps this in a confirmation alert per UX guidelines.
    func deleteAccount() {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return
        }
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                // Best-effort server delete; ignore errors below.
                try? await provider.accountApi.deleteAccount()
                // Local logout — clears the keychain + tokens.
                try await provider.accountApi.logout()
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = nil
                    // Caller (host SwiftUI view) should observe the
                    // auth state and route back to onboarding.
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    /// True when no draft field differs from the persisted value.
    /// Includes the local public phone so editing it alone is enough to
    /// arm the Save button.
    var isDraftUnchanged: Bool {
        let persistedPhone = LocalCallerIdSettings.phoneNumber() ?? ""
        let trimmed = draftLocalPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlus = trimmed.hasPrefix("+")
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        let normalisedDraftPhone = hasPlus ? "+" + digits : digits
        return draftDisplayName == (viewModel.displayName ?? "") &&
               draftStatusMessage == (viewModel.statusMessage ?? "") &&
               normalisedDraftPhone == persistedPhone
    }

    func uploadAvatar(image: UIImage) {
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                _ = try await avatarUploader.uploadAndApply(image: image)
                loadFromServer()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func makeProvider() -> BCryptoBackendProvider? {
        guard let appState,
              let token = appState.authService.loadToken(), !token.isEmpty else { return nil }
        let config = BackendConfig.pinned(serverUrl: appState.serverUrl, accessToken: token)
        return BCryptoBackendProvider(config: config)
    }
}

/// Account / Profile sub-screen. W31 design-token refactor —
/// migrated from stock Form to the design system. Same bindings:
/// avatar upload via PhotosPicker, draftDisplayName + draftStatusMessage
/// edits, saveProfile() submission, server load on appear.
struct AccountSettingsScreen: View {
    @StateObject var container: AccountSettingsContainer
    @State private var selectedItem: PhotosPickerItem?
    /// W445: shows AvatarIconPicker sheet.
    @State private var showingIconPicker = false
    @State private var showLogoutConfirm = false

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    init(appState: AppState) {
        self._container = StateObject(
            wrappedValue: AccountSettingsContainer(appState: appState)
        )
    }

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = container.errorMessage {
                        errorBanner(error).padding(.top, 8)
                    }

                    SettingsSectionHeader("FOTO PROFILO")
                    photoSection

                    SettingsSectionHeader("IDENTITÀ")
                    VStack(spacing: 8) {
                        tapCopyRow(label: "User ID",
                                   value: container.viewModel.userId)
                        // Phone hash: hidden when empty or zero (no phone registered).
                        if !phoneHashShort.isEmpty && phoneHashShort != "0" {
                            tapCopyRow(label: "Phone Hash",
                                       value: phoneHashShort)
                        }
                        if let ext = container.viewModel.dialExtension {
                            kvRow(label: "Interno",
                                  value: ext,
                                  mono: true)
                        }
                    }

                    SettingsSectionHeader("PROFILO")
                    VStack(spacing: 12) {
                        textField(label: "Nome visualizzato",
                                  value: $container.draftDisplayName,
                                  placeholder: "es. Mario Rossi",
                                  capitalization: .words)
                        textField(label: "Stato / nota",
                                  value: $container.draftStatusMessage,
                                  placeholder: "es. Disponibile dalle 9 alle 18",
                                  capitalization: .sentences)
                    }

                    // Caller-id substitution. Locally-stored only —
                    // never pushed to the server. Pure digits so the
                    // callee's CallKit can dial it back. When unset
                    // the server fills the call_offer's `caller_display`
                    // field with the user's internal extension.
                    SettingsSectionHeader("CALLER-ID")
                    VStack(spacing: 12) {
                        phoneNumberField(
                            label: "Numero telefono pubblico",
                            value: $container.draftLocalPhone,
                            placeholder: "es. +393331234567"
                        )
                        Text("Mostrato come ID chiamante alle persone che chiami. Puoi usare il prefisso internazionale (es. +39). Salvato solo su questo dispositivo.")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // W445: NUMERI PUBBLICI — read-only snapshot from
                    // MyPhonesScreen's UserDefaults store. Manage via the
                    // "I miei numeri" entry in the main settings list.
                    SettingsSectionHeader("NUMERI PUBBLICI")
                    publicPhonesSection

                    Spacer().frame(height: 16)
                    saveButton
                    Spacer().frame(height: 12)
                    logoutButton
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Profilo")
        .onAppear {
            container.loadFromServer()
            container.refreshPublicPhones()
        }
        .sheet(isPresented: $showingIconPicker) {
            AvatarIconPicker { icon in container.setIconAvatar(icon) }
        }
        .confirmationDialog(
            "Uscire da Q-Audion?",
            isPresented: $showLogoutConfirm,
            titleVisibility: .visible
        ) {
            Button("Esci", role: .destructive) {
                container.logout()
            }
            Button("Annulla", role: .cancel) { }
        } message: {
            Text("Dovrai accedere di nuovo per usare le chat e le chiamate.")
        }
        .onChange(of: selectedItem) { newItem in
            Task {
                guard let item = newItem,
                      let data = try? await item.loadTransferable(type: Data.self),
                      let img = UIImage(data: data) else { return }
                container.uploadAvatar(image: img)
                selectedItem = nil
            }
        }
    }

    // MARK: - Photo section

    private var photoSection: some View {
        HStack(spacing: 16) {
            avatarImage
            VStack(alignment: .leading, spacing: 4) {
                PhotosPicker(
                    selection: $selectedItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                        Text("Cambia foto")
                            .qaudionStyle(type.labelLarge)
                    }
                    .foregroundStyle(scheme.primary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(
                        Capsule().stroke(scheme.primary.opacity(0.6), lineWidth: 1)
                    )
                }
                .disabled(container.isLoading)

                // W445: icon avatar alternative (no camera/library needed).
                Button {
                    showingIconPicker = true
                } label: {
                    Label("Scegli icona", systemImage: "person.crop.square")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.primary)
                }
                .buttonStyle(.plain)
                .disabled(container.isLoading)

                if container.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
                            .tint(scheme.onSurfaceVariant)
                        Text("Caricamento…")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.onSurfaceVariant)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 88)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let url = container.viewModel.avatarUrl {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                ProgressView().tint(scheme.onSurfaceVariant)
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(Circle().stroke(scheme.outline.opacity(0.4), lineWidth: 1))
        } else {
            let avatarLabel: String = {
                if !container.draftDisplayName.isEmpty { return container.draftDisplayName }
                if let ext = container.viewModel.dialExtension, !ext.isEmpty { return ext }
                return "?"
            }()
            QAudionAvatar(displayName: avatarLabel,
                          size: 64,
                          shortNumber: container.viewModel.dialExtension)
        }
    }

    // MARK: - Public phones section (W445)

    /// Read-only list from MyPhonesScreen's UserDefaults store, plus a
    /// navigation hint so the user knows where to manage them.
    @ViewBuilder
    private var publicPhonesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if container.publicPhones.isEmpty {
                Text("Nessun numero registrato. Gestiscili da \"I miei numeri\".")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(scheme.surfaceVariant.opacity(0.4))
                    )
            } else {
                ForEach(container.publicPhones.indices, id: \.self) { idx in
                    let phone: String = container.publicPhones[idx]
                    HStack {
                        Text(phone)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(scheme.onSurface)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(scheme.surfaceVariant.opacity(0.4))
                    )
                }
            }
            Text("Per aggiungere o rimuovere numeri vai su Impostazioni > I miei numeri.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rows / fields

    private var phoneHashShort: String {
        let h = container.viewModel.phoneHash
        guard h.count > 12 else { return h }
        return "\(h.prefix(12))…"
    }

    private func kvRow(label: String, value: String, mono: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .modifier(MonoIfNeededA(mono: mono))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }

    /// W307: kvRow variant with tap-to-copy. Mirror of the
    /// AboutSettingsScreen pattern (W297). Tapping copies `value` to
    /// UIPasteboard + fires HapticFeedback.messageSent. Trailing
    /// clipboard icon telegraphs the gesture.
    private func tapCopyRow(label: String, value: String) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            #if canImport(UIKit)
            UIPasteboard.general.string = value
            HapticFeedback.messageSent()
            #endif
        }
    }

    /// Phone number field supporting E.164 format ("+39…") or plain digits.
    /// Uses phonePad keyboard (has "+", "*", "#"). Strips spaces/dashes/parens
    /// but keeps a leading "+". Caps at 20 chars.
    private func phoneNumberField(label: String,
                                  value: Binding<String>,
                                  placeholder: String) -> some View {
        let sanitisedBinding = Binding<String>(
            get: { value.wrappedValue },
            set: { newValue in
                let hasPlus = newValue.hasPrefix("+")
                let digits = newValue.filter { $0.isASCII && $0.isNumber }
                let canonical = hasPlus ? "+" + digits : digits
                value.wrappedValue = String(canonical.prefix(20))
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)

            TextField("", text: sanitisedBinding,
                      prompt: Text(placeholder).foregroundColor(scheme.onSurfaceVariant))
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(scheme.primary)
                .keyboardType(.phonePad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(container.isLoading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(scheme.surfaceVariant.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
                )
        }
    }

    private func textField(label: String,
                           value: Binding<String>,
                           placeholder: String,
                           capitalization: TextInputAutocapitalization) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)

            TextField("", text: value,
                      prompt: Text(placeholder).foregroundColor(scheme.onSurfaceVariant))
                .qaudionStyle(type.bodyMedium)
                .foregroundColor(scheme.onSurface)
                .tint(scheme.primary)
                .textInputAutocapitalization(capitalization)
                .disabled(container.isLoading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(scheme.surfaceVariant.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
                )
        }
    }

    private var logoutButton: some View {
        Button {
            showLogoutConfirm = true
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .regular))
                Text("Esci dall'account")
                    .qaudionStyle(type.bodyMedium)
            }
            .foregroundStyle(extras.riskHigh)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(extras.riskHigh.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(extras.riskHigh.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.riskHigh)
                .padding(.top, 1)
            Text(msg)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }

    // MARK: - Save button

    private var saveButton: some View {
        Button {
            container.saveProfile()
            // Optimistic feedback. Il container chiama loadFromServer()
            // dopo updateProfile e setta errorMessage in caso di
            // failure. Per ora mostriamo solo il success ottimista
            // e lasciamo il banner riskHigh esistente per gli errori.
            snackbar?.show(.init(
                text: "Profilo aggiornato.",
                severity: .info
            ))
        } label: {
            HStack {
                if container.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(scheme.onPrimary)
                    Text("Salvataggio…")
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.onPrimary)
                } else {
                    Text("Salva")
                        .qaudionStyle(type.labelLarge)
                        .tracking(0.8)
                        .foregroundStyle(scheme.onPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(saveEnabled ? scheme.primary : scheme.surfaceVariant)
            )
            .opacity(saveEnabled ? 1.0 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!saveEnabled)
    }

    private var saveEnabled: Bool {
        !container.isLoading && !container.isDraftUnchanged
    }
}

private struct MonoIfNeededA: ViewModifier {
    let mono: Bool
    func body(content: Content) -> some View {
        if mono {
            content.font(.system(.caption, design: .monospaced))
        } else {
            content
        }
    }
}
