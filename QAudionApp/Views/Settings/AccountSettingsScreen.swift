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

    /// Cache-busted local avatar URL. `AvatarUploader.selfAvatarCacheURL`
    /// always resolves to the SAME path (`self.jpg`) — re-uploading a new
    /// photo overwrites those bytes in place without changing the URL
    /// string, so `AsyncImage`'s default `URLSession`/`URLCache` (keyed on
    /// URL equality, not content) can go on serving the OLD image after a
    /// re-upload. Appending the avatar version as a fragment forces a new
    /// URL value on every version bump — the fragment is not part of the
    /// path FileManager/URLSession resolve for a `file://` URL, so the
    /// actual bytes read are unaffected, only the cache key. `static` (not
    /// an instance computed property) so it can be called from `init`
    /// before `self` is fully initialized. Takes the version as a plain
    /// `Int`, NOT `AppState` — see CLAUDE.md §16: a NEW function taking
    /// `AppState` directly as a parameter type has caused a silent
    /// "Build IPA" failure before (bisected v1.0.386→v1.0.397); callers
    /// already legitimately read `appState.selfAvatarVersion` themselves.
    private static func selfAvatarCacheURLBusted(version: Int) -> URL? {
        guard let base = AvatarUploader.selfAvatarCacheURL else { return nil }
        return URL(string: base.absoluteString + "#v\(version)")
    }

    private static let iconAvatarKey = "qaudion.profile.iconAvatar"
    /// Which of the two mutually-exclusive self-avatar choices is
    /// currently active — "icon" or "photo". Fix (2026-07-31): before this,
    /// `setIconAvatar` only updated the in-memory `viewModel` — the very
    /// next `loadFromServer()` (fires on every `.onAppear`, i.e. every time
    /// the user navigates back into this screen) unconditionally rebuilt
    /// `avatarUrl` from the LOCAL PHOTO CACHE ONLY, silently discarding the
    /// icon choice with no error — "set an icon, go back, find the old
    /// photo again". Now both `setIconAvatar` and a successful photo
    /// upload record which one is current, and every `avatarUrl`
    /// computation checks this flag first.
    private static let avatarKindKey = "qaudion.profile.avatarKind"

    private static func resolveAvatarURL(version: Int) -> URL? {
        if UserDefaults.standard.string(forKey: avatarKindKey) == "icon",
           let iconString = UserDefaults.standard.string(forKey: iconAvatarKey),
           let iconURL = URL(string: iconString) {
            return iconURL
        }
        return selfAvatarCacheURLBusted(version: version)
    }

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
            avatarUrl: Self.resolveAvatarURL(version: appState.selfAvatarVersion),
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
        UserDefaults.standard.set(url, forKey: Self.iconAvatarKey)
        UserDefaults.standard.set("icon", forKey: Self.avatarKindKey)
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
                        // E2EE avatar transport (2026-07-30): the self-avatar
                        // preview reads the LOCAL plaintext cache
                        // (AvatarUploader.uploadAndApply writes it), never
                        // profile.avatarUrl — that field pointed at a
                        // plaintext server URL any authenticated account
                        // could fetch, exactly the gap this replaces.
                        avatarUrl: Self.resolveAvatarURL(version: self.appState?.selfAvatarVersion ?? 0),
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

    /// Fix (2026-07-31, found during full-audit): this used to be
    /// fire-and-forget — the caller (`saveButton`) called it then showed a
    /// "Profilo aggiornato" success toast SYNCHRONOUSLY right after, with
    /// zero knowledge of whether the network call had even started, let
    /// alone succeeded. During the confirmed WS/network-instability window
    /// this session root-caused, a slow or failing `updateProfile` call
    /// left the user seeing an immediate false "saved" toast while the
    /// actual save silently failed in the background (the existing
    /// `errorMessage` banner would eventually appear, but after a toast had
    /// already told them it worked). Now `async` and returns whether it
    /// actually succeeded, so the caller can wait for the real result
    /// before deciding what to show.
    @discardableResult
    func saveProfile() async -> Bool {
        guard let provider = makeProvider() else {
            errorMessage = "Not signed in"
            return false
        }
        // Persist the local public phone on every save. The setter
        // strips non-digits and clears the key when the field is empty
        // so we never end up with garbage in UserDefaults.
        LocalCallerIdSettings.setPhoneNumber(draftLocalPhone)
        // Re-read so the binding shows the canonicalised digits-only form
        // (handles the case where the user typed e.g. "+39 333 …" and we
        // stripped the punctuation).
        draftLocalPhone = LocalCallerIdSettings.phoneNumber() ?? ""
        await MainActor.run { self.isLoading = true; self.errorMessage = nil }
        do {
            try await provider.accountApi.updateProfile(
                displayName: draftDisplayName.isEmpty ? nil : draftDisplayName,
                statusMessage: draftStatusMessage.isEmpty ? nil : draftStatusMessage,
                avatarUrl: nil
            )
            loadFromServer()
            return true
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
            return false
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
        // Fix (2026-07-31, found during full-audit): single choke point for
        // every avatar-set entry path (library picker, camera) — guards
        // against a second pick racing an upload already in flight,
        // regardless of which UI path triggered it, instead of duplicating
        // the check at each call site.
        guard !isLoading else { return }
        Task {
            await MainActor.run { self.isLoading = true; self.errorMessage = nil }
            do {
                _ = try await avatarUploader.uploadAndApply(image: image)
                // Settings-avatar fix (2026-07-31): this used to call
                // `loadFromServer()` here, which does a full `/profile`
                // network round trip just to re-derive `avatarUrl` — a
                // field that isn't even server-sourced (see the kdoc in
                // `loadFromServer`, it always reads the LOCAL cache). A
                // slow or failing network request left the user staring at
                // an unchanged preview after a successful local upload,
                // reading as "avatar setting doesn't work". The upload
                // itself is 100% local + fire-and-forget broadcast by this
                // point (`uploadAndApply` already wrote the cache file and
                // bumped the version), so update the preview from that
                // directly and never gate it on the network.
                await MainActor.run {
                    // A freshly-uploaded photo always supersedes a prior
                    // icon choice — see `avatarKindKey` kdoc.
                    UserDefaults.standard.set("photo", forKey: Self.avatarKindKey)
                    self.viewModel = AccountSettingsViewModel(
                        userId: self.viewModel.userId,
                        phoneHash: self.viewModel.phoneHash,
                        displayName: self.viewModel.displayName,
                        statusMessage: self.viewModel.statusMessage,
                        avatarUrl: Self.resolveAvatarURL(version: self.appState?.selfAvatarVersion ?? 0),
                        dialExtension: self.viewModel.dialExtension
                    )
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
    /// 2026-07-31: camera capture for the avatar — parity with Android
    /// ("Scatta foto") and Desktop, which both already had a camera option
    /// alongside the file/library picker. `PhotosPicker` only reaches the
    /// photo library, never the live camera, so this was a genuine gap,
    /// not a bug in the existing picker.
    @State private var showingCamera = false

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
                    // never pushed to the server. When unset the server
                    // fills the call_offer's `caller_display` field with
                    // the user's internal extension.
                    //
                    // 2026-07-29: was a free-text field (any string the
                    // user typed). Now a single-select: "la mia estensione"
                    // or one of the numbers from MyPhonesScreen's list —
                    // the underlying mechanism (`LocalCallerIdSettings`,
                    // embedded per-call into `call_offer.caller_display`)
                    // is unchanged; this is a UI constraint on top of it.
                    // Does not affect discoverability of the
                    // non-selected identifier — both stay reachable via
                    // `directory/by-extension` and peppered discovery
                    // regardless of which one is the active caller-id.
                    SettingsSectionHeader("CALLER-ID")
                    VStack(spacing: 12) {
                        callerIdPicker
                        Text("Mostrato come ID chiamante alle persone che chiami. Scegli tra la tua estensione o uno dei numeri elencati in \"Numeri pubblici\" qui sotto. Salvato solo su questo dispositivo.")
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
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapturePicker { image in
                container.uploadAvatar(image: image)
            }
            .ignoresSafeArea()
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
            guard let item = newItem else { return }
            // Fix (2026-07-31, found during full-audit): guard against a
            // second pick landing while an upload from the first is still
            // in flight — camera + library picker + icon picker all funnel
            // into the same `container.isLoading`/upload state, and nothing
            // previously stopped a rapid double-pick from racing.
            guard !container.isLoading else {
                selectedItem = nil
                return
            }
            Task {
                // Fix (2026-07-31, found during full-audit): `try?` here
                // swallowed BOTH `loadTransferable` throwing and
                // `UIImage(data:)` returning nil with zero feedback — the
                // picker sheet just closed and nothing visibly happened,
                // reading as "picking a photo doesn't work" with no error
                // shown anywhere.
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        container.errorMessage = "Impossibile leggere la foto selezionata."
                        selectedItem = nil
                        return
                    }
                    guard let img = UIImage(data: data) else {
                        container.errorMessage = "Formato immagine non valido."
                        selectedItem = nil
                        return
                    }
                    container.uploadAvatar(image: img)
                } catch {
                    container.errorMessage = error.localizedDescription
                }
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

                // 2026-07-31: camera capture, parity with Android/Desktop
                // ("Scatta foto") — PhotosPicker above only reaches the
                // photo library, never the live camera.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showingCamera = true
                    } label: {
                        Label("Scatta foto", systemImage: "camera")
                            .qaudionStyle(type.labelSmall)
                            .foregroundStyle(scheme.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(container.isLoading)
                }

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
        if let url = container.viewModel.avatarUrl, url.scheme == "sficon", let iconName = url.host {
            // Icon-avatar fix (2026-07-31): `setIconAvatar` stores a
            // pseudo `sficon://<SF-Symbol-name>` URL, never a real
            // network/file resource — `AsyncImage` has no protocol handler
            // for that scheme, and its 2-closure initializer has no
            // `.failure` state to fall back to, so a failed load just kept
            // showing the placeholder `ProgressView()` FOREVER. That's the
            // "spinner spins forever, icon never registers" bug. Render
            // the symbol directly instead of routing it through
            // AsyncImage/URLSession at all.
            Circle()
                .fill(scheme.primary.opacity(0.12))
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: iconName)
                        .font(.system(size: 28))
                        .foregroundStyle(scheme.primary)
                )
                .overlay(Circle().stroke(scheme.outline.opacity(0.4), lineWidth: 1))
        } else if let url = container.viewModel.avatarUrl {
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

    /// 2026-07-29 — caller-id single-select. Options are "la mia
    /// estensione" (tag `""`, clears `LocalCallerIdSettings` so the
    /// server falls back to the extension — see `save()`'s existing
    /// `LocalCallerIdSettings.setPhoneNumber(draftLocalPhone)` call,
    /// unchanged) plus every number from `container.publicPhones`
    /// (same UserDefaults-backed list `MyPhonesScreen` manages).
    private var callerIdPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Numero telefono pubblico")
                .qaudionStyle(type.labelSmall)
                .tracking(1.0)
                .foregroundStyle(scheme.onSurfaceVariant)

            Picker("Numero telefono pubblico", selection: $container.draftLocalPhone) {
                Text(extensionOptionLabel).tag("")
                ForEach(callerIdOptions, id: \.self) { phone in
                    Text(phone).tag(phone)
                }
            }
            .pickerStyle(.menu)
            .tint(scheme.onSurface)
            .disabled(container.isLoading)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Label for the "use my extension" picker option — includes the
    /// actual extension when known, matching the "Interno" kvRow above.
    /// Pavel, 2026-07-29: bare digits, no "Int." prefix — applies to the
    /// LOCAL user's own extension exactly like every peer-facing site.
    private var extensionOptionLabel: String {
        if let ext = container.viewModel.dialExtension, !ext.isEmpty {
            return "La mia estensione (\(DisplayName.formatExtension(ext)))"
        }
        return "La mia estensione"
    }

    /// Picker options: `container.publicPhones` plus — defensively — the
    /// CURRENTLY saved `draftLocalPhone` value if it's non-empty and not
    /// already in that list (e.g. a value set before this screen switched
    /// from free-text to a picker, or before the number was added to
    /// MyPhonesScreen's list). Without this a stale/foreign saved value
    /// would leave the Picker's `selection` binding matching no tag.
    private var callerIdOptions: [String] {
        var opts = container.publicPhones
        let current = container.draftLocalPhone
        if !current.isEmpty && !opts.contains(current) {
            opts.insert(current, at: 0)
        }
        return opts
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
            // Fix (2026-07-31, found during full-audit): the success toast
            // now fires only after `saveProfile` actually confirms the
            // server accepted the update — see its kdoc. A failure still
            // surfaces via the existing `container.errorMessage` banner,
            // set inside `saveProfile` itself; no separate handling needed
            // here.
            Task {
                if await container.saveProfile() {
                    snackbar?.show(.init(
                        text: "Profilo aggiornato.",
                        severity: .info
                    ))
                }
            }
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

/// Camera capture for the avatar (2026-07-31) — parity with Android/Desktop's
/// "Scatta foto". SwiftUI has no native camera-capture view; `UIImagePickerController`
/// with `.sourceType = .camera` is still Apple's own supported path for this
/// (AVFoundation's own camera UI would be considerably more code for the
/// same result). `PHPickerViewController`/`PhotosPicker` cannot open the
/// live camera at all — they're library-only.
private struct CameraCapturePicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onDismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onDismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onDismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onDismiss = onDismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            onDismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDismiss()
        }
    }
}
