## 2026-08-22 - Token Leakage via Swift Struct Default Reflection
**Vulnerability:** The authentication credential structs (`OtpAuthResult`, `AuthCredentials`, and `AuthTokenPair`) implicitly relied on Swift's default reflection when logged or printed, which exposed sensitive fields (`accessToken`, `refreshToken`) in plaintext logs.
**Learning:** In Swift, logging structs directly with `print()` or similar functions will enumerate and output all their stored properties if they don't explicitly override it. This creates a critical risk of leaking tokens or passwords into logs, analytics, or debugging tools.
**Prevention:** Always explicitly implement `CustomStringConvertible` and `CustomDebugStringConvertible` for any struct or class containing credentials, tokens, or sensitive user data, specifically redacting those fields (e.g., returning `"<redacted>"`).

## 2026-08-23 - Token Leakage via Swift Struct Default Reflection in Device Renew Client
**Vulnerability:** Similar to previous token leakage, `BCryptoDeviceRenewClient.RenewedTokens` and `BCryptoDeviceRenewClient.RenewResp` did not override default reflection, risking exposure of `accessToken` and `refreshToken` in logs.
**Learning:** Same as above - inner private structs or specific client structs must also be considered for redaction if they contain sensitive data.
**Prevention:** Ensured `CustomStringConvertible` and `CustomDebugStringConvertible` implementations were added to redact sensitive fields within `DeviceRenewClient`.
