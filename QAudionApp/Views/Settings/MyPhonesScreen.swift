import SwiftUI
import QAudionEngine

/// W44: "I miei numeri" — multi-phone management screen. Subset of Android
/// `ProfileScreen.kt` focused on the unique iOS-missing feature: the
/// ability to attach **multiple** phone numbers to one Q-Audion account so
/// peers can reach you via any of them (reverse discovery + dial-by-phone).
///
/// Wire-shape parity with Android: on save, the full list of E.164 phone
/// numbers is pushed to the server as **peppered hashes** via
/// `GET /contacts/pepper` + `POST /contacts/phones` (see `savePhones`
/// below) — this IS live-wired to the real server, not a stub. Numbers are
/// also mirrored to local `UserDefaults` so the UX stays usable offline.
/// (Stale note removed 2026-07-29 — this doc comment previously said
/// "engine wiring deferred", which was true when the screen only persisted
/// locally; confirmed wired end-to-end since commit `080db8b`.)
///
/// The "Profilo" entry (AccountSettingsScreen) stays the canonical
/// display-name / status / avatar editor. This screen ONLY handles the
/// phone-numbers portion of the Android ProfileScreen — keeps the existing
/// iOS profile flow untouched while adding the missing surface.
@MainActor
final class MyPhonesContainer: ObservableObject {
    @Published private(set) var phones: [String] = []
    @Published var newPhone: String = ""
    @Published var savingProfile: Bool = false
    @Published var savingPhones: Bool = false
    @Published var error: String? = nil

    // W-PHONEVERIFY (2026-07-30, Pavel): adding a number here now requires
    // proving ownership via SMS-OTP — the SAME rigor as initial phone
    // registration — instead of the old flow (add(2) → save → silently
    // push an unverified hash). `pendingOtpPhone` non-nil means step 2 of
    // 2 (code entry) is showing for that normalized E.164 number.
    @Published var pendingOtpPhone: String? = nil
    @Published var otpCode: String = ""
    @Published var requestingOtp: Bool = false
    @Published var verifyingOtp: Bool = false
    @Published var otpError: String? = nil

    private let phonesKey = "com.qaudion.profile.myPhones"

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
        // 2026-07-29 fix: the extension row used to read a dead
        // UserDefaults key (`com.qaudion.profile.dialExtension`) that
        // nothing in the app ever wrote — only `DevResetScreen` cleared
        // it — so the row never rendered. The REAL, server-fetched
        // extension is cached by `AppState` under `currentUserDialExtension`
        // (populated from `getProfile().dialExtension`, see
        // `AppState.swift`). The screen now reads that live via
        // `appState.currentUserDialExtension` directly in the view body
        // instead of a stale container copy — see `MyPhonesScreen.headerCard`.
    }

    /// Step 1 of 2: validate the typed number and request an SMS-OTP code
    /// for it (`POST /api/v1/profile/phone/otp/request`) — the SAME
    /// endpoint/rigor as post-registration phone verification elsewhere in
    /// the app. On success, `pendingOtpPhone` is set and the screen shows
    /// the code-entry step; nothing is added to the local list yet.
    func beginAddPhone(serverUrl: String, token: String?) async {
        error = nil
        let trimmed = newPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Inserisci un numero in formato E.164 (es. +393331234567)."
            return
        }
        // Normalize via the same helper FastSetup uses — keeps cross-
        // platform `phone_hash` parity intact (the server hashes the
        // canonical E.164 form, not the raw user input).
        let normalized: String
        do {
            normalized = try PhoneHashHelper.normalizeE164(trimmed)
        } catch {
            self.error = "Numero non valido: \(error.localizedDescription)"
            return
        }
        if phones.contains(normalized) {
            self.error = "Numero già presente nella lista."
            return
        }
        guard let token, !token.isEmpty else {
            self.error = "Sessione non attiva — accedi per verificare un numero."
            return
        }

        requestingOtp = true
        defer { requestingOtp = false }
        let rest = Self.restClient(serverUrl: serverUrl, token: token)
        do {
            let body = try JSONSerialization.data(withJSONObject: ["phone_number": normalized])
            _ = try await rest.post("/api/v1/profile/phone/otp/request", body: body)
            pendingOtpPhone = normalized
            otpCode = ""
            otpError = nil
        } catch {
            self.error = "Richiesta codice fallita: \(error.localizedDescription)"
        }
    }

    /// Step 2 of 2: verify the SMS code against `pendingOtpPhone`
    /// (`POST /api/v1/profile/phone/otp/verify`). Only on success is the
    /// number appended to the local list and persisted — matching how the
    /// server only enrolls it into discovery once ownership is proven.
    @discardableResult
    func confirmOtp(serverUrl: String, token: String?) async -> Bool {
        guard let phone = pendingOtpPhone else { return false }
        let trimmedCode = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            otpError = "Inserisci il codice ricevuto via SMS."
            return false
        }
        guard let token, !token.isEmpty else {
            otpError = "Sessione non attiva."
            return false
        }

        verifyingOtp = true
        defer { verifyingOtp = false }
        let rest = Self.restClient(serverUrl: serverUrl, token: token)
        do {
            let body = try JSONSerialization.data(withJSONObject: ["phone_number": phone, "code": trimmedCode])
            _ = try await rest.post("/api/v1/profile/phone/otp/verify", body: body)
            phones.append(phone)
            persist()
            newPhone = ""
            pendingOtpPhone = nil
            otpCode = ""
            otpError = nil
            return true
        } catch {
            otpError = "Codice non valido o scaduto: \(error.localizedDescription)"
            return false
        }
    }

    /// Abandon the pending verification (e.g. user taps "Annulla") without
    /// adding anything — the server-side OTP simply expires unused.
    func cancelOtp() {
        pendingOtpPhone = nil
        otpCode = ""
        otpError = nil
    }

    private static func restClient(serverUrl: String, token: String) -> BCryptoRestClient {
        let config = BackendConfig.pinned(serverUrl: serverUrl, accessToken: token)
        return BCryptoBackendProvider(config: config).getRestClient()
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
    func savePhones(serverUrl: String, token: String?) async {
        savingPhones = true
        error = nil
        defer { savingPhones = false }

        // 1. Persist locally regardless of server outcome.
        persist()

        // 2. Build provider — bail if not signed in (no token).
        guard let token = token, !token.isEmpty else {
            // Local-only mode: lascia un info-banner nessun-token così l'utente
            // sa che la lista non è stata propagata al server.
            self.error = "Sessione non attiva — numeri salvati solo localmente."
            return
        }
        let config = BackendConfig.pinned(serverUrl: serverUrl,
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
    /// 2026-08-06 fix: the trash button used to call `container.removePhone`
    /// immediately on tap, no confirmation — every other destructive action
    /// added across Settings this pass (sign-out, device revoke, cache
    /// wipe, PSK delete, threat-report delete) confirms first.
    @State private var pendingRemovePhone: String?

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
        .alert("Rimuovere questo numero?",
               isPresented: Binding(
                   get: { pendingRemovePhone != nil },
                   set: { if !$0 { pendingRemovePhone = nil } }
               )) {
            Button("Annulla", role: .cancel) { pendingRemovePhone = nil }
            Button("Rimuovi", role: .destructive) {
                if let phone = pendingRemovePhone {
                    container.removePhone(phone)
                    snackbar?.show(.init(text: "Numero rimosso.", severity: .info))
                }
                pendingRemovePhone = nil
            }
        } message: {
            Text("I contatti non potranno più raggiungerti su questo numero.")
        }
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

            // Extension (server-assigned, read-only). 2026-07-29: read
            // live from AppState's server-fetched cache instead of the
            // container's own dead UserDefaults key (see load() comment
            // above) — nothing ever wrote that key so this row never
            // rendered before.
            if let ext = appState.currentUserDialExtension, let extInt = Int(ext) {
                extensionRow(extInt)
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
            if container.pendingOtpPhone != nil {
                Spacer().frame(height: 8)
                otpVerifyCard
            }
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
            // Pavel, 2026-07-29: bare digits, no "#" (or any other) prefix —
            // same rule as every other rendering of this identity, self or peer.
            Text(String(ext))
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
                pendingRemovePhone = phone
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
                Task {
                    await container.beginAddPhone(serverUrl: appState.serverUrl, token: appState.authService.loadToken())
                }
            } label: {
                if container.requestingOtp {
                    ProgressView()
                        .tint(scheme.onPrimary)
                        .frame(width: 48, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(scheme.primary)
                        )
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(scheme.onPrimary)
                        .frame(width: 48, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(scheme.primary)
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(container.requestingOtp)
            .accessibilityLabel("Verifica e aggiungi numero")
        }
    }

    // MARK: - OTP verification step (W-PHONEVERIFY)

    /// Shown in place of nothing extra when `pendingOtpPhone` is set —
    /// a code was just sent via SMS and must be confirmed before the
    /// number is added to the list / enrolled server-side.
    @ViewBuilder
    private var otpVerifyCard: some View {
        if let phone = container.pendingOtpPhone {
            VStack(alignment: .leading, spacing: 8) {
                Text("Codice inviato a \(phone)")
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
                if let otpErr = container.otpError {
                    Text(otpErr)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(extras.riskHigh)
                }
                HStack(spacing: 8) {
                    TextField("Codice a 6 cifre",
                              text: Binding(
                                get: { container.otpCode },
                                set: { container.otpCode = String($0.prefix(6)) }
                              ))
                        .font(.system(size: 16, design: .monospaced))
                        .keyboardType(.numberPad)
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
                        Task {
                            let ok = await container.confirmOtp(
                                serverUrl: appState.serverUrl, token: appState.authService.loadToken())
                            if ok {
                                snackbar?.show(.init(text: "Numero verificato e aggiunto.", severity: .info))
                            }
                        }
                    } label: {
                        Text(container.verifyingOtp ? "…" : "Verifica")
                            .qaudionStyle(type.labelLarge)
                            .foregroundStyle(scheme.onPrimary)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(scheme.primary)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(container.verifyingOtp || container.otpCode.isEmpty)
                }
                Button("Annulla") {
                    container.cancelOtp()
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(scheme.surfaceVariant.opacity(0.3))
            )
        }
    }

    // MARK: - Save + error

    private var saveButton: some View {
        Button {
            Task {
                await container.savePhones(serverUrl: appState.serverUrl, token: appState.authService.loadToken())
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
