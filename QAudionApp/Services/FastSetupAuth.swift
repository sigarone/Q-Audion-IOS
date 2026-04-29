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
        await appState.loginWithPhoneHash(phoneHash: phoneHash, credential: payload.password)
        if let err = appState.errorMessage {
            return err
        }

        // Best-effort profile push so peers see a friendly name.
        // Failure is non-fatal — local login is already complete.
        let resolvedName = payload.resolvedDisplayName
        if let token = appState.authService.loadToken() {
            let backend = BCryptoBackendProvider(
                config: BackendConfig(serverUrl: PinnedServerHost.url, accessToken: token)
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

    // Note: Android passes a `deviceName` to `LoginUseCase.invoke(...)`.
    // The iOS `AuthService.login(phoneNumber:password:serverUrl:)` does
    // NOT yet thread `deviceName` through — fixing that requires touching
    // the engine wire (USER WT). Tracked as a follow-up. The server
    // accepts the request without device_name today (it falls back to
    // `Phone iOS` server-side), so fast-setup still works end-to-end.
}
