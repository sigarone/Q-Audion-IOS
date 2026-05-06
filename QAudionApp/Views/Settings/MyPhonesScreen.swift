import SwiftUI
import QAudionEngine

/// W44: "I miei numeri" — multi-phone management screen. Subset of Android
/// `ProfileScreen.kt` focused on the unique iOS-missing feature: the
/// ability to attach **multiple** phone numbers to one Q-Audion account so
/// peers can reach you via any of them (reverse discovery + dial-by-phone).
///
/// Wire-shape parity with Android: on save, the full list of E.164 phone
/// numbers is pushed to the server as **peppered hashes** via
/// `POST /contacts/phones`. Engine wiring for that endpoint is deferred —
/// today the screen persists locally to `UserDefaults` so the UX is
/// complete even before the server endpoint surfaces.
///
/// The "Profilo" entry (AccountSettingsScreen) stays the canonical
/// display-name / status / avatar editor. This screen ONLY handles the
/// phone-numbers portion of the Android ProfileScreen — keeps the existing
/// iOS profile flow untouched while adding the missing surface.
@MainActor
final class MyPhonesContainer: ObservableObject {
    @Published private(set) var myExtension: Int? = nil
    @Published private(set) var phones: [String] = []
    @Published var newPhone: String = ""
    @Published var savingProfile: Bool = false
    @Published var savingPhones: Bool = false
    @Published var error: String? = nil

    private let phonesKey = "com.qaudion.profile.myPhones"
    private let extensionKey = "com.qaudion.profile.dialExtension"

    init() {
        load()
    }

    func load() {
        // Stub: load from UserDefaults until engine surfaces a real
        // `/profile/phones` endpoint. The Android source pulls these via
        // `SettingsViewModel.state.myPhones` from a server fetch — when
        // the iOS engine catches up, swap this method for that fetch.
        if let stored = UserDefaults.standard.array(forKey: phonesKey) as? [String] {
            phones = stored
        }
        let ext = UserDefaults.standard.integer(forKey: extensionKey)
        myExtension = ext > 0 ? ext : nil
    }

    /// Validate + add. Returns true on success (so the UI can clear the
    /// input field), false on E.164 validation failure (the inline error
    /// banner explains why).
    @discardableResult
    func addPhone() -> Bool {
        error = nil
        let trimmed = newPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Inserisci un numero in formato E.164 (es. +393331234567)."
            return false
        }
        // Normalize via the same helper FastSetup uses — keeps cross-
        // platform `phone_hash` parity intact (the eventual server push
        // hashes the canonical E.164 form, not the raw user input).
        let normalized: String
        do {
            normalized = try PhoneHashHelper.normalizeE164(trimmed)
        } catch {
            self.error = "Numero non valido: \(error.localizedDescription)"
            return false
        }
        if phones.contains(normalized) {
            self.error = "Numero già presente nella lista."
            return false
        }
        phones.append(normalized)
        persist()
        newPhone = ""
        return true
    }

    func removePhone(_ p: String) {
        phones.removeAll { $0 == p }
        persist()
    }

    /// W54 (Track B engine wire): pubblica i phoneNumbers come peppered
    /// hashes al server via:
    ///   1. GET  /api/v1/contacts/pepper          → fetch pepper
    ///   2. SHA-256(pepper ‖ E.164) per ogni numero (PepperedPhoneHash)
    ///   3. DELETE /api/v1/contacts/phones        → wipe set precedente
    ///   4. POST  /api/v1/contacts/phones         → register nuovi hashes
    ///
    /// Idempotente: il server replace l'intero set ad ogni POST. Best-effort
    /// graceful degrade quando il server non espone l'endpoint pepper
    /// (`getContactPepper` 404 / network error) — la persistenza locale
    /// in UserDefaults rimane comunque, così l'app funziona offline.
    ///
    /// Parità con Android `SettingsViewModel.pushPeppered(phones:)`.
    func savePhones(appState: AppState) async {
        savingPhones = true
        error = nil
        defer { savingPhones = false }

        // 1. Persist locally regardless of server outcome.
        persist()

        // 2. Build provider — bail if not signed in (no token).
        guard let token = appState.authService.loadToken(), !token.isEmpty else {
            // Local-only mode: lascia un info-banner nessun-token così l'utente
            // sa che la lista non è stata propagata al server.
            self.error = "Sessione non attiva — numeri salvati solo localmente."
            return
        }
        let config = BackendConfig(serverUrl: appState.serverUrl,
                                   accessToken: token)
        let provider = BCryptoBackendProvider(config: config)
        let rest = provider.getRestClient()

        // 3. Fetch pepper (alg + base64). Server response shape varies
        //    by build — accettiamo sia { pepper } (shape iOS-engine) sia
        //    { pepper_b64, alg } (shape Android).
        let (pepperBytes, alg): (Data, String)
        do {
            let pepperData = try await rest.get("/api/v1/contacts/pepper")
            guard let json = try JSONSerialization.jsonObject(with: pepperData) as? [String: Any] else {
                self.error = "Risposta pepper non valida."
                return
            }
            if let b64 = json["pepper_b64"] as? String,
               let bytes = Data(base64Encoded: b64) {
                pepperBytes = bytes
                alg = (json["alg"] as? String) ?? "sha-256-pepper-prefix"
            } else if let raw = json["pepper"] as? String {
                // Older shape: pepper as raw UTF-8 string.
                pepperBytes = Data(raw.utf8)
                alg = "sha-256-pepper-prefix"
            } else {
                self.error = "Pepper mancante nella risposta server."
                return
            }
        } catch {
            // Best-effort: server senza endpoint pepper → fallback locale.
            self.error = "Server pepper non raggiungibile — numeri salvati solo localmente."
            return
        }

        // 4. Compute peppered hashes locally with the byte form of the
        //    pepper (W343 — feeding a base64 string into SHA-256
        //    silently broke server-side matching against Android peers).
        let hashes: [String] = phones.compactMap { e164 in
            try? PepperedPhoneHash.hash(phone: e164, pepperBytes: pepperBytes)
        }

        // 5. DELETE old set (best-effort).
        _ = try? await rest.delete("/api/v1/contacts/phones")

        // 6. POST new set if non-empty.
        guard !hashes.isEmpty else { return }
        let body: [String: Any] = ["alg": alg, "hashes": hashes]
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            _ = try await rest.post("/api/v1/contacts/phones", body: data)
        } catch {
            self.error = "Push numeri al server fallito: \(error.localizedDescription)"
        }
    }

    private func persist() {
        UserDefaults.standard.set(phones, forKey: phonesKey)
        // W295: stamp the last-saved timestamp so the UI can show
        // "Aggiornato N minuti fa" — gives the user feedback that
        // changes actually landed in storage.
        UserDefaults.standard.set(Date(), forKey: lastSavedKey)
    }

    private let lastSavedKey = "com.qaudion.profile.myPhones.lastSavedAt"

    /// W295: last-saved date (or nil if never saved on this device).
    /// Read by the screen body to render the timestamp row.
    var lastSavedAt: Date? {
        UserDefaults.standard.object(forKey: lastSavedKey) as? Date
    }
}

/// "I miei numeri" screen — Italian-only port of the multi-phone block
/// inside Android `ProfileScreen.kt` (lines 154-295).
struct MyPhonesScreen: View {
    @StateObject private var container = MyPhonesContainer()
    @EnvironmentObject private var appState: AppState
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerCard
                    if let err = container.error {
                        errorBanner(err)
                    }
                    saveButton
                    // W295: last-saved-at row. Renders only if the
                    // user has saved at least once (fresh installs see
                    // nothing). Builds the label via static helper to
                    // keep the closure body trivial — CLAUDE.md §13.
                    if let saved = container.lastSavedAt {
                        Text(Self.lastSavedLabel(saved))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.top, 4)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationTitle("I miei numeri")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// W295: format the last-saved timestamp as 'Aggiornato N minuti fa'
    /// using RelativeDateTimeFormatter with Italian locale. Static so
    /// the call site closure remains trivial.
    private static func lastSavedLabel(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.unitsStyle = .full
        let rel: String = f.localizedString(for: date, relativeTo: Date())
        return "Aggiornato " + rel
    }

    // MARK: - Header card (extension + phones)

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("I MIEI NUMERI")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Spacer().frame(height: 8)

            // Extension (server-assigned, read-only).
            if let ext = container.myExtension {
                extensionRow(ext)
                Spacer().frame(height: 6)
            }

            Text("NUMERI DI TELEFONO")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer().frame(height: 4)
            Text("Peers ti raggiungono via uno qualsiasi dei numeri qui sotto. Puoi aggiungerne più di uno.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer().frame(height: 6)

            ForEach(container.phones, id: \.self) { phone in
                phoneRow(phone)
            }
            if container.phones.isEmpty {
                Text("Nessun numero ancora registrato.")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .padding(.vertical, 6)
            }

            Spacer().frame(height: 4)
            addPhoneRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(scheme.primary.opacity(0.35), lineWidth: 1)
        )
    }

    private func extensionRow(_ ext: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("INTERNO")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 80, alignment: .leading)
            Text("#\(ext)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(scheme.onSurface)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = String(ext)
                snackbar?.show(.init(text: "Interno copiato.", severity: .info))
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copia interno")
        }
        .padding(.vertical, 4)
    }

    private func phoneRow(_ phone: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(phone)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(scheme.onSurface)
            Spacer(minLength: 0)
            Button {
                container.removePhone(phone)
                snackbar?.show(.init(text: "Numero rimosso.", severity: .info))
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(extras.riskHigh)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rimuovi")
        }
        .padding(.vertical, 4)
    }

    private var addPhoneRow: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("+39 333 1234567",
                      text: Binding(
                        get: { container.newPhone },
                        set: { container.newPhone = String($0.prefix(20)) }
                      ))
                .font(.system(size: 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.phonePad)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(scheme.surfaceVariant.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
                )
            Button {
                if container.addPhone() {
                    snackbar?.show(.init(text: "Numero aggiunto.", severity: .info))
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(scheme.onPrimary)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(scheme.primary)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Aggiungi numero")
        }
    }

    // MARK: - Save + error

    private var saveButton: some View {
        Button {
            Task {
                await container.savePhones(appState: appState)
                if container.error == nil {
                    snackbar?.show(.init(
                        text: "Numeri salvati e pubblicati al server.",
                        severity: .info))
                }
            }
        } label: {
            Text(container.savingPhones
                 ? "Aggiornamento numeri…"
                 : "Salva")
                .qaudionStyle(type.labelLarge)
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(container.savingPhones
                              ? scheme.surfaceVariant
                              : scheme.primary)
                )
        }
        .buttonStyle(.plain)
        .disabled(container.savingPhones)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(extras.riskHigh)
            Text(msg)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.riskHigh)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(extras.riskHigh.opacity(0.12))
        )
    }
}

#Preview {
    NavigationStack {
        MyPhonesScreen()
            .environmentObject(AppState())
    }
    .qAudionTheme(dark: true)
}
