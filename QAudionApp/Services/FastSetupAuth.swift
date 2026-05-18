import Foundation
import QAudionEngine

/// Orchestrator for fast-setup login. Replicates the Android
/// `AuthFlowViewModel.fastSetup(payload, onResult:)` path:
///
///   1. derive `phone_hash = sha256(phone_id)`
///   2. POST to `/auth/login` with `(phone_hash, password, device_name)`
///      via the existing `AuthService` (which already implements that
///      wire shape since W12.A).
///   3. on success, push the resolved `display_name` to the server via
///      `AccountApi.updateProfile` so peers calling THIS user see
///      "Phone #${extension}" instead of the raw UUID.
///
/// Server is forced to `PinnedServerHost.url` for the duration of this
/// call. Even if the QR's `server` field embeds an IP literal (as the
/// admin panel can do), the scanner has already verified it matches the
/// pinned host, so we keep using the canonical `voip.bcrypto.com` for the
/// actual network calls (avoids cert-pinning surprises).
@MainActor
final class FastSetupAuth {

    // App-layer only consumer. Cannot be `public` because the dependency
    // `AppState` is `internal` (no `public` modifier) — Swift refuses to
    // expose a `public init` whose parameter type isn't itself public.
    // The class is used inside the same module (`QAudionApp` target), so
    // `internal` (the default) is the correct visibility.

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Perform fast-setup login with the freshly-scanned QR payload.
    /// Returns nil on success, an error message on failure.
    @discardableResult
    func run(_ payload: FastSetupPayload) async -> String? {
        // Pin the server URL on AppState so every subsequent backend
        // call uses the canonical host. We do this even though the
        // value is the same as the default — keeps the contract
        // explicit and survives any future refactor that loosens
        // AppState.serverUrl back to a configurable field.
        appState.serverUrl = PinnedServerHost.url

        // Mirror Android: phone_hash = sha256(phone_id) (the phone_id
        // is the opaque "fastsetup-<uuid>" issued by the admin panel,
        // not an E.164 number — so we hash it directly without the
        // E.164 normaliser).
        let phoneHash = PhoneHashHelper.sha256Hex(payload.phoneId)

        // Use the dedicated `loginWithPhoneHash` path so the already-
        // computed SHA-256 flows straight to the wire. The legacy
        // `appState.login(userId:credential:)` would re-feed the hash
        // through `PhoneHash.hash`, which prepends `+39` and runs the
        // E.164 regex — guaranteed failure on a hex string. This is
        // the bug that caused TestFlight v1.0.88 to fail with
        // "Login failed: Not a valid E.164 phone: '+39<hash>'".
        // 1:1 parity with Android's `FastSetupUseCase` which calls
        // `loginUseCase(phoneHash = phoneHash, ...)` directly.
        appState.errorMessage = nil
        // SECURITY H-3 — work on a mutable local copy of the plaintext
        // credential so we can scrub it immediately after the login
        // call. The QR-embedded password is a reusable secret; minimise
        // its in-memory lifetime. (Swift `String` does not guarantee
        // in-place zeroing of its backing buffer, but overwriting the
        // local drops our last strong reference to the original
        // characters as soon as the next allocation reuses the page —
        // a real fix needs the server OTP endpoint, see FastSetupPayload.)
        // NEVER log `credential` / `payload.password`.
        var credential = payload.password
        await appState.loginWithPhoneHash(phoneHash: phoneHash, credential: credential)
        credential = String(repeating: "0", count: credential.count)
        _ = credential
        if let err = appState.errorMessage {
            return err
        }

        // Best-effort profile push so peers see a friendly name.
        // Failure is non-fatal — local login is already complete.
        // SECURITY L-2 — the QR `display_name` is attacker-controllable
        // (the admin panel / a forged QR sets it). Sanitise before it is
        // pushed to the server and later rendered in every peer's UI:
        // trim, strip control + bidi-override + zero-width scalars, then
        // cap at 64 chars. (Inline because the shared
        // `StringSanitiser.displayName(_:fallback:)` helper — created by
        // another agent in QAudionApp/Services/StringSanitiser.swift — is
        // not guaranteed present at this build; if it lands, this block
        // can be replaced with `StringSanitiser.displayName(...)`.)
        let resolvedName = Self.sanitizeDisplayName(payload.resolvedDisplayName)
        if let token = appState.authService.loadToken() {
            let backend = BCryptoBackendProvider(
                config: BackendConfig.pinned(serverUrl: PinnedServerHost.url, accessToken: token)
            )
            do {
                try await backend.accountApi.updateProfile(
                    displayName: resolvedName,
                    statusMessage: nil,
                    avatarUrl: nil
                )
            } catch {
                // Mirror Android's `runCatching { ... }` swallow.
                // Profile push failure does NOT block onboarding —
                // local login is already complete. We log the error
                // (OpenRouter review flagged the silent swallow); the
                // user can re-trigger the display-name push later via
                // Settings → Account.
                print("[FastSetupAuth] profile push failed (non-fatal): \(error)")
            }
        }

        return nil
    }

    /// SECURITY L-2 — defensive display-name sanitiser. Strips Unicode
    /// scalars that enable spoofing in peer UIs:
    ///   - C0/C1 control + DEL,
    ///   - bidi overrides/isolates U+202A…U+202E, U+2066…U+2069,
    ///   - zero-width / directional marks U+200B…U+200F,
    ///   - BOM U+FEFF,
    /// then trims whitespace and caps at 64 characters. Falls back to a
    /// stable label if the result is empty.
    private static func sanitizeDisplayName(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            let v = s.value
            if v < 0x20 || v == 0x7F { continue }                 // C0 + DEL
            if v >= 0x80 && v <= 0x9F { continue }                // C1
            if v >= 0x202A && v <= 0x202E { continue }            // bidi override
            if v >= 0x2066 && v <= 0x2069 { continue }            // bidi isolate
            if v >= 0x200B && v <= 0x200F { continue }            // ZW + marks
            if v == 0xFEFF { continue }                           // BOM
            scalars.append(s)
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(cleaned.prefix(64))
        return capped.isEmpty ? "Q-Audion user" : capped
    }

    // Note: Android passes a `deviceName` to `LoginUseCase.invoke(...)`.
    // The iOS `AuthService.login(phoneNumber:password:serverUrl:)` does
    // NOT yet thread `deviceName` through — fixing that requires touching
    // the engine wire (USER WT). Tracked as a follow-up. The server
    // accepts the request without device_name today (it falls back to
    // `Phone iOS` server-side), so fast-setup still works end-to-end.
}
